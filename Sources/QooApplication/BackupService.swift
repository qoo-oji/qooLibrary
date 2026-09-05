//
//  自動バックアップの合成 [BK-01〜BK-05][MG-10]。
//
//  置き場所と剪定は `BackupStore`（`QooInfrastructure`）、DB から写す仕事は
//  `BackupRepository` / `QooDatabase`（`QooPersistence`）。**両方に依存して
//  よいのはこの層だけ** [A-01][A-02] なので、契機ごとの束ね方はここが持つ。
//
import Foundation
import QooInfrastructure
import QooKit
import QooPersistence

/// 1 世代を取った結果。
public struct BackupOutcome: Sendable, Equatable {
    public var reason: BackupReason
    /// JSON [BK-05]。**移行前 [MG-10] だけは `nil` になりうる**——古いスキーマは
    /// 現行の record 型で読めないため（下記 ``snapshotBeforeMigration``）。
    public var documentURL: URL?
    /// ストア複製を取らなかった契機では `nil` [BackupReason.copiesStore]。
    public var storeURL: URL?
    /// 剪定で消した世代の数 [BK2-03]。
    public var prunedCount: Int
    /// 整合性検査 [RB-03] を通らなかったため**取らなかった**とき真。
    ///
    /// このとき他のフィールドは無意味で、呼び出し側は先へ進んでよい
    /// ——バックアップが取れないことを理由に、利用者が頼んだ操作そのものを
    /// 断るほうが害が大きい [NV3-01 と同じ判断]。
    public var skippedAsUnhealthy: Bool = false
}

/// スナップショットを取る [BK-01][BK-02]。
///
/// 順序は ①整合性検査 ②JSON ③ストア複製 ④剪定。
///
/// **「良いバックアップを壊れた状態で上書きする」［外部調査］への答えは、
/// 順序ではなくファイル名のほうにある**——世代は毎回**新しい名前**で書き、
/// 既存の世代を上書きすることが構造的に無い（`BackupFileName` がミリ秒まで
/// 持つのはそのため）。加えて①が「壊れた状態を世代として残す」のを止める。
///
/// ④を最後に置くのは、**世代数が一時的にも `keep` を下回らない**ようにする
/// ため。これは穏当な利点であって、上の 2 つほど強い保証ではない。
public struct BackupService: Sendable {
    public let store: BackupStore
    public let appVersion: String?
    /// 世代数の上書き。`nil` なら**剪定のたびに環境設定から読み直す**
    /// [BK-01「環境設定で変更可能」]——構築時に固定すると、設定を変えても
    /// 次の起動まで効かない。テストはここを渡して環境設定に触れずに試す。
    public let documentGenerationsOverride: Int?
    public let storeGenerationsOverride: Int?

    public init(store: BackupStore = BackupStore(), appVersion: String? = nil,
                documentGenerations: Int? = nil, storeGenerations: Int? = nil) {
        self.store = store
        self.appVersion = appVersion
        self.documentGenerationsOverride = documentGenerations
        self.storeGenerationsOverride = storeGenerations
    }

    // MARK: - 契機

    /// 起動時 [BK-01]。**間隔を空けて取る。**
    ///
    /// 前回の起動時スナップショットから `AppLimits.Backup.launchSnapshotInterval`
    /// 経っていなければ何もせず `nil` を返す——毎起動で取ると 10 世代が
    /// 「今日の 10 回の起動」で埋まり、履歴として役に立たなくなる。
    @discardableResult
    public func snapshotOnLaunch(repository: any BackupRepository,
                                 database: QooDatabase,
                                 now: Date = Date()) async throws -> BackupOutcome?
    {
        if let last = try store.latest(kind: .document, reason: .launch),
           now.timeIntervalSince(last.date) < AppLimits.Backup.launchSnapshotInterval
        {
            return nil
        }
        return try await snapshot(reason: .launch, repository: repository,
                                  database: database, now: now)
    }

    /// 破壊的な操作の直前 [BK-02]。**間隔を空けず必ず取る。**
    @discardableResult
    public func snapshot(reason: BackupReason,
                         repository: any BackupRepository,
                         database: QooDatabase,
                         now: Date = Date()) async throws -> BackupOutcome
    {
        guard try await database.integrityCheck() else {
            Log.db.error("整合性検査に通らないのでスナップショットを取らない（理由: \(reason.rawValue)）")
            return BackupOutcome(reason: reason, documentURL: store.directory,
                                 storeURL: nil, prunedCount: 0, skippedAsUnhealthy: true)
        }
        let document = try await repository.export(scope: .everything, appVersion: appVersion)
        // **`FileIO` の上で回す** [NV6-01][NV6-02]。SQLite のオンライン
        // バックアップは中身が全部同期なので（`QooDatabase.backup` の doc）、
        // 協調スレッドプールの上で待つと 71 MB のあいだ 1 本占有する。
        // 呼び出し側（`LibraryServices`）はメインアクタなので、なおさら。
        return try await FileIO.perform {
            try persist(reason: reason, document: document, now: now) { destination in
                try QooDatabase.backup(writer: database.writer, to: destination)
            }
        }
    }

    /// スキーマ移行の直前 [MG-10][BK-02]。**同期。**
    ///
    /// `QooDatabase.open(beforeMigration:)` のフックから呼ぶ。あそこが
    /// 「移行前の DB」に触れる唯一の機会で、しかも同期のクロージャである。
    /// - Returns: `nil` なら**写すものが無かった**（新規ストア）。
    ///   失敗ではないので、呼び出し側は静かに先へ進んでよい。
    @discardableResult
    public func snapshotBeforeMigration(_ handle: any PreMigrationSource,
                                        now: Date = Date()) throws -> BackupOutcome?
    {
        // **新規ストアには移行前の状態が無い。** `open` は移行が未適用なら
        // 必ずフックを呼ぶので、ここで分けないと毎回の初回起動が
        // 「バックアップに失敗」として記録される。
        guard handle.hasExistingSchema else { return nil }
        guard try handle.integrityCheck() else {
            Log.db.error("整合性検査に通らないので移行前スナップショットを取らない")
            return BackupOutcome(reason: .schemaMigration, documentURL: nil,
                                 storeURL: nil, prunedCount: 0, skippedAsUnhealthy: true)
        }

        // **ストア複製を先に取る。**［code-review が実測で発見、2026-09-05］
        //
        // 移行前のストアは定義上「アプリが知らない古いスキーマ」なので、
        // 現行の record 型による JSON の書き出しは**失敗するのが普通**である
        // （v12 未満なら `no such table: shelf`、v14 未満なら `label.isHidden`
        // が無い）。JSON を先にすると、その失敗が **スキーマに依存せず必ず
        // 成功するストア複製まで巻き添えにする**——MG-10 と R-14 が守ろうと
        // している当の状況で、保護がゼロになっていた。
        let storeURL = try store.prepareStoreDestination(reason: .schemaMigration, date: now)
        try copyingStore(to: storeURL) { try handle.copyStore(to: $0) }

        // JSON は「読めれば嬉しい」程度に落とす。読めなくても複製は残る。
        var documentURL: URL?
        do {
            let document = try handle.exportDocument(appVersion: appVersion)
            documentURL = try store.writeDocument(BackupCoding.encode(document),
                                                  reason: .schemaMigration, date: now)
        } catch {
            Log.db.warning("""
                移行前の JSON を書き出せなかった（古いスキーマでは普通に起きる）: \
                \(String(describing: error)) — ストア複製は取れている
                """)
        }
        return BackupOutcome(reason: .schemaMigration, documentURL: documentURL,
                             storeURL: storeURL, prunedCount: prunedCountIgnoringFailure())
    }

    // MARK: - 一覧・剪定

    public func generations() throws -> [BackupGeneration] { try store.generations() }
    public func totalByteCount() throws -> Int64 { try store.totalByteCount() }
    public func remove(_ generation: BackupGeneration) throws { try store.remove(generation) }

    // MARK: - 書き込みの共通部分

    /// **JSON → ストア複製 → 剪定**。この順序をここ 1 箇所で守る。
    ///
    /// **同期**——移行前フック [MG-10] も通るため（あれは `open` の中の同期
    /// クロージャ）。非同期版と 2 本持つと、片方だけ直したときに移行前だけが
    /// 壊れる。呼び出し側が `FileIO` の上で回す [NV6-02]。
    private func persist(reason: BackupReason, document: BackupDocument, now: Date,
                         copyStore: (URL) throws -> Void) throws -> BackupOutcome
    {
        let data = try BackupCoding.encode(document)
        let documentURL = try store.writeDocument(data, reason: reason, date: now)
        var storeURL: URL?
        if reason.copiesStore {
            let destination = try store.prepareStoreDestination(reason: reason, date: now)
            try copyingStore(to: destination, copyStore)
            storeURL = destination
        }
        return BackupOutcome(reason: reason, documentURL: documentURL,
                             storeURL: storeURL, prunedCount: prunedCountIgnoringFailure())
    }

    /// 複製を取る。**失敗したら宛先を残さない** [BK3-09]。
    ///
    /// 宛先ファイルは 1 ページも写す前に作られる［code-review が実測で確認］
    /// ので、残すと**中身の無いファイルが「正常な世代」として枠を食い、
    /// 良い世代を押し出す**。JSON 側は `.atomic` が同じ危険を防いでいる。
    private func copyingStore(to destination: URL, _ copy: (URL) throws -> Void) throws {
        do { try copy(destination) }
        catch { store.discard(destination); throw error }
    }

    /// 剪定の失敗で**スナップショットそのものを失敗にしない**
    /// ［code-review で発見］——書き込みは既に済んでいるのに
    /// 「バックアップを作成できませんでした」と伝えることになる。
    /// 古い世代が消せないことは容量の問題であって、安全網の欠落ではない。
    private func prunedCountIgnoringFailure() -> Int {
        do { return try pruneAll() } catch {
            Log.db.warning("世代の剪定に失敗: \(String(describing: error))")
            return 0
        }
    }

    /// 世代数は環境設定から読む [BK-01]（上書きされていなければ）。
    /// **移行前 [MG-10] は別枠で守る**［code-review で発見］——頻度が桁違いに
    /// 低いのに同じ枠に入れると、日常的な契機（ラベルの削除・取り込み）に
    /// 押し出される。押し出されて困るのは、まさに移行が失敗したときである [R-14]。
    @discardableResult
    public func pruneAll() throws -> Int {
        var removed = 0
        for kind in BackupGeneration.Kind.allCases {
            let keep = kind == .document
                ? documentGenerationsOverride ?? Self.configuredDocumentGenerations()
                : storeGenerationsOverride ?? Self.configuredStoreGenerations()
            removed += try store.prune(kind: kind, keep: keep) { $0 != .schemaMigration }.count
            removed += try store.prune(kind: kind,
                                       keep: AppLimits.Backup.migrationGenerations) {
                $0 == .schemaMigration
            }.count
        }
        return removed
    }

    // MARK: - 環境設定 [BK-01]

    public enum PreferenceKeys {
        public static let documentGenerations = "qoo.backup.documentGenerations"
        public static let storeGenerations = "qoo.backup.storeGenerations"
    }

    public static func configuredDocumentGenerations() -> Int {
        clamp(UserDefaults.standard.object(forKey: PreferenceKeys.documentGenerations) as? Int
              ?? AppLimits.Backup.defaultDocumentGenerations)
    }

    public static func configuredStoreGenerations() -> Int {
        clamp(UserDefaults.standard.object(forKey: PreferenceKeys.storeGenerations) as? Int
              ?? AppLimits.Backup.defaultStoreGenerations)
    }

    private static func clamp(_ value: Int) -> Int {
        min(max(value, AppLimits.Backup.minGenerations), AppLimits.Backup.maxGenerations)
    }
}
