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
    /// ストア複製を取らなかった契機では `nil` [BackupReason.kinds]。
    public var storeURL: URL?
    /// DB の外にあるデータの束 [BK-06]。取らなかった契機では `nil`。
    public var appDataURL: URL?
    /// 剪定で消した世代の数 [BK2-03]。
    public var prunedCount: Int
    /// 整合性検査 [RB-03] を通らなかったため**取らなかった**とき真。
    ///
    /// このとき他のフィールドは無意味で、呼び出し側は先へ進んでよい
    /// ——バックアップが取れないことを理由に、利用者が頼んだ操作そのものを
    /// 断るほうが害が大きい [NV3-01 と同じ判断]。
    public var skippedAsUnhealthy: Bool = false

    /// **設定で切られているため取らなかった**とき真 [BK-07]。
    ///
    /// `skippedAsUnhealthy` と分けてあるのは、伝えるべきことが逆だから
    /// ——あちらは「取れなかった（DB が壊れている）」で調べる必要があるが、
    /// こちらは利用者が選んだ状態なので、何も言わないのが正しい。
    public var skippedByPreference: Bool = false
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

    /// DB の外にあるデータの場所 [BK-06]。**`nil` なら束を取らない。**
    ///
    /// 場所は各ストアが持っているので、両方を見られる `LibraryServices` が
    /// 集めて渡す [A-02]——ここで組み立て直すと綴りが 2 箇所になる。
    public let appDataLocation: AppDataSnapshot.Location?

    /// 設定の上書き [BK-07]。`nil` なら**そのつど環境設定から読み直す**
    /// （世代数と同じ理由: 構築時に固定すると設定を変えても次の起動まで効かない）。
    public let launchIntervalOverride: BackupSettings.LaunchInterval?
    public let beforeDestructiveOverride: Bool?
    public let beforeMigrationOverride: Bool?

    public init(store: BackupStore = BackupStore(), appVersion: String? = nil,
                documentGenerations: Int? = nil, storeGenerations: Int? = nil,
                appDataLocation: AppDataSnapshot.Location? = nil,
                launchInterval: BackupSettings.LaunchInterval? = nil,
                snapshotsBeforeDestructive: Bool? = nil,
                snapshotsBeforeMigration: Bool? = nil) {
        self.store = store
        self.appVersion = appVersion
        self.documentGenerationsOverride = documentGenerations
        self.storeGenerationsOverride = storeGenerations
        self.appDataLocation = appDataLocation
        self.launchIntervalOverride = launchInterval
        self.beforeDestructiveOverride = snapshotsBeforeDestructive
        self.beforeMigrationOverride = snapshotsBeforeMigration
    }

    // MARK: - 設定 [BK-07]

    /// この契機を実行するか [BK-07]。**既定はすべて OFF**（``BackupSettings``）。
    ///
    /// 起動時 [BK-01] は頻度が別に効くので、ここでは「取らない」だけを見る。
    func isEnabled(_ reason: BackupReason) -> Bool {
        switch reason {
        case .launch:
            resolvedLaunchInterval.seconds != nil
        case .schemaMigration:
            beforeMigrationOverride ?? Self.configuredSnapshotsBeforeMigration()
        case .jsonImport, .bulkLabelDelete, .templateApply, .libraryDelete, .beforeRestore:
            beforeDestructiveOverride ?? Self.configuredSnapshotsBeforeDestructive()
        }
    }

    var resolvedLaunchInterval: BackupSettings.LaunchInterval {
        launchIntervalOverride ?? Self.configuredLaunchInterval()
    }

    public static func configuredLaunchInterval() -> BackupSettings.LaunchInterval {
        guard let raw = UserDefaults.standard.string(
                forKey: BackupSettings.PreferenceKeys.launchInterval),
              let value = BackupSettings.LaunchInterval(rawValue: raw)
        else { return .default }
        return value
    }

    public static func configuredSnapshotsBeforeDestructive() -> Bool {
        UserDefaults.standard.object(forKey: BackupSettings.PreferenceKeys.beforeDestructive)
            as? Bool ?? BackupSettings.defaultBeforeDestructive
    }

    public static func configuredSnapshotsBeforeMigration() -> Bool {
        UserDefaults.standard.object(forKey: BackupSettings.PreferenceKeys.beforeMigration)
            as? Bool ?? BackupSettings.defaultBeforeMigration
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
        // [BK-07] 「取らない」なら間隔を見るまでもない。**既定はこちら**。
        guard let interval = resolvedLaunchInterval.seconds else { return nil }
        if let last = try store.latest(kind: .document, reason: .launch),
           now.timeIntervalSince(last.date) < interval
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
        // [BK-07] 利用者が切っている。**何も言わずに先へ進む**——選んだ状態を
        // 毎回知らせるのは雑音で、本当に見てほしい 1 枚まで読み飛ばされる。
        guard isEnabled(reason) else {
            return BackupOutcome(reason: reason, documentURL: nil, storeURL: nil,
                                 appDataURL: nil, prunedCount: 0, skippedByPreference: true)
        }
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
        // [BK-07] **別のトグル**［ユーザー判断］——利用者の操作ではなくアプリの
        // 更新で起きる契機なので、「自分の操作の保険は要らない」という判断と
        // 一緒に切れてしまうのは意図が違う。
        guard isEnabled(.schemaMigration) else {
            return BackupOutcome(reason: .schemaMigration, documentURL: nil, storeURL: nil,
                                 appDataURL: nil, prunedCount: 0, skippedByPreference: true)
        }
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
        // DB の外にあるデータも**同じ時点で**取る [BK-06]。移行はブックマークを
        // 触らないが、復元は「その時点へ丸ごと戻す」ことなので、対で残さないと
        // 戻した先が混ざる。
        let appDataURL = writeAppDataIgnoringFailure(reason: .schemaMigration, now: now)
        return BackupOutcome(reason: .schemaMigration, documentURL: documentURL,
                             storeURL: storeURL, appDataURL: appDataURL,
                             prunedCount: prunedCountIgnoringFailure())
    }

    // MARK: - 復元 [BK-03][IE-16]

    /// 「次の起動で復元する」予約を置く [BK-03]。
    ///
    /// **ここでは何も差し替えない。** 実際の入れ替えは次の起動で
    /// ``applyPendingRestore(storeURL:now:)`` が `QooDatabase.open` の前に行う
    /// （理由は `PendingRestore` の doc）。
    ///
    /// - Throws: 世代が使えない（壊れている／アプリより新しい）ときは
    ///   **予約せずに投げる**。押した直後に理由を言えるほうが、終了して
    ///   起動し直してから「戻せませんでした」と言われるより親切で、
    ///   何より**戻らないと分かっているのにアプリを終了させない**。
    ///
    /// **`async`**——検分は `PRAGMA integrity_check` を走らせる実 I/O で、
    /// 呼び出し側はメインアクタ（環境設定の画面）である。同期で呼ぶと
    /// **復元…を押した瞬間に画面が固まる**［code-review が実測: 34 MB で
    /// 0.39 秒］。`FileIO` の上で回す [NV6-01][NV6-02]。
    public func requestRestore(_ generation: BackupGeneration) async throws {
        guard generation.kind == .store else { throw RestoreError.notAStoreCopy }
        let store = store
        let inspection = await FileIO.perform {
            let result = QooDatabase.inspect(at: generation.url)
            // 第 1 段が書いた世代を検分すると、畳むために一度 WAL のまま
            // 開くので `-shm` が残る。ここで捨てる（この層は削除できる）。
            if result.didNormalizeJournal { store.discardSidecars(of: generation.url) }
            return result
        }
        switch inspection.kind {
        case .usable: break
        case .missing: throw RestoreError.unusable(.generationMissing(generation.fileName))
        case .corrupt: throw RestoreError.unusable(.sourceCorrupt(generation.fileName))
        case .tooNew: throw RestoreError.unusable(.sourceTooNew(generation.fileName))
        case .unreadable(let detail):
            throw RestoreError.unusable(.swapFailed(detail))
        }
        try store.writePendingRestore(PendingRestore(fileName: generation.fileName))
    }

    public func pendingRestore() -> PendingRestore? { store.readPendingRestore() }
    public func cancelPendingRestore() { store.clearPendingRestore() }

    /// 予約があれば差し替える [BK-03][IE-16]。**`QooDatabase.open` の前に呼ぶ。**
    ///
    /// **決して投げない。** ここで投げると、復元に失敗しただけでアプリが
    /// 起動できなくなる——いちばん困っている場面で最後の足場を外すことになる。
    /// 失敗は `RestoreOutcome.failure` として返し、呼び出し側が現ストアの
    /// まま起動を続ける。
    ///
    /// **印は成否に関わらず必ず消す。** 残すと起動のたびに同じ復元を試み、
    /// しかも失敗する理由（世代が無い・壊れている）は繰り返しても変わらない。
    public func applyPendingRestore(storeURL: URL, now: Date = Date()) -> RestoreOutcome? {
        guard let pending = store.readPendingRestore() else { return nil }
        defer { store.clearPendingRestore() }

        let source = store.directory.appendingPathComponent(pending.fileName, isDirectory: false)
        var outcome = RestoreOutcome(restoredFrom: pending.fileName)

        // **差し替える前に確かめる。** 壊れた複製・アプリより新しい複製で
        // 戻すと、その瞬間から起動できなくなる [MG-12]——戻したことで
        // 状況が悪化する形だけは避ける。
        let inspection = QooDatabase.inspect(at: source)
        if inspection.didNormalizeJournal { store.discardSidecars(of: source) }
        switch inspection.kind {
        case .usable: break
        case .missing: outcome.failure = .generationMissing(pending.fileName)
        case .corrupt: outcome.failure = .sourceCorrupt(pending.fileName)
        case .tooNew: outcome.failure = .sourceTooNew(pending.fileName)
        case .unreadable(let detail): outcome.failure = .swapFailed(detail)
        }
        if outcome.failure != nil { return outcome }

        // 退避先は**成否に関わらず**受け取る（`swapInStore` の doc）。
        var archived: URL?
        do {
            outcome.previousStoreURL = try store.swapInStore(
                from: source, storeURL: storeURL, date: now, archivedTo: &archived)
            // 退避したのは**ライブストア**なので WAL のまま `-wal` を連れて
            // きている。畳んで 1 ファイルに揃える——**世代は常に 1 ファイル**
            // という不変条件を保つ（`QooDatabase.normalizeJournal` の doc）。
            if let archived = outcome.previousStoreURL {
                if !QooDatabase.normalizeJournal(at: archived) {
                    Log.db.warning("退避したストアのジャーナルを畳めない: \(Log.path(archived))")
                }
                // 畳むために一度 WAL のまま開くので、その最中に作られた
                // `-shm` が残る［実測］。畳んだ後は意味を持たないので捨てる。
                store.discardSidecars(of: archived)
            }
        } catch {
            outcome.failure = .swapFailed(String(describing: error))
            // 巻き戻しにも失敗していれば、退避先だけが唯一の足場になる。
            //
            // **この分岐はテストで固定できていない**——「複製に失敗し、かつ
            // 巻き戻しにも失敗する」状態を、production へテスト用の口を足さずに
            // 作る手が無い（`swapInStore` の中で 2 段階の I/O を失敗させる
            // 必要がある）。変異を当てても検出できないことを確認済み。
            outcome.previousStoreURL = archived
        }
        if outcome.failure == nil {
            outcome.appDataRestored = restoreAppData(pairedWith: pending.fileName)
        }
        return outcome
    }

    /// DB と**同じ時点**の束を戻す [BK-06]。
    ///
    /// 対応づけはファイル名（`<timestamp>-<reason>`）で行う——`store` と
    /// `appData` は同じ契機・同じ時刻で書かれるので、名前だけで対になる。
    ///
    /// **束が無くても失敗にしない。** 古い版が作った世代には束が無く、
    /// そこから DB だけを戻せること自体は正しい。戻せなかったことは
    /// `RestoreOutcome.appDataRestored` として持ち帰り、UI が伝える。
    private func restoreAppData(pairedWith storeFileName: String) -> Bool {
        guard let location = appDataLocation,
              let parts = BackupFileName.parse(storeFileName) else { return false }
        let name = BackupFileName.make(date: parts.date, reason: parts.reason, kind: .appData)
        let url = store.directory.appendingPathComponent(name, isDirectory: false)
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        do {
            let archive = try store.readAppData(at: url)
            try AppDataSnapshot.restore(archive, to: location,
                                        restoringCoversFrom: store.userCoverPool)
            return true
        } catch {
            Log.db.warning("DB の外にあるデータを戻せなかった: \(String(describing: error))")
            return false
        }
    }

    public enum RestoreError: Error, Equatable {
        /// JSON の世代を渡された。**あちらは取り込み** [IE-11] で戻す
        /// ——ライブラリの行は作れない（ブックマークを JSON に持てない）。
        case notAStoreCopy
        case unusable(RestoreOutcome.Failure)
    }

    // MARK: - 一覧・剪定

    public func generations() throws -> [BackupGeneration] { try store.generations() }
    public func totalByteCount() throws -> Int64 { try store.totalByteCount() }
    /// 世代を 1 件消す。
    ///
    /// **対の束も一緒に消し、参照されなくなったカバーを回収する** [BK-06]
    /// ［code-review で発見］——`appData` は一覧に出さない（`store` と対で、
    /// 単独では復元できない）ので、ここで消さないと**誰も消せないまま残る**。
    /// 剪定は「スナップショットを取った直後」にしか走らないため、
    /// 既定（すべて OFF [BK-07]）ではプールが永久に回収されない。
    public func remove(_ generation: BackupGeneration) throws {
        try store.remove(generation)
        if generation.kind == .store,
           let parts = BackupFileName.parse(generation.fileName)
        {
            let name = BackupFileName.make(date: parts.date, reason: parts.reason,
                                           kind: .appData)
            if let paired = try store.generations().first(where: { $0.fileName == name }) {
                // 1 件の失敗で本体の削除を失敗にしない（剪定と同じ判断）。
                try? store.remove(paired)
            }
        }
        try? store.pruneUserCoverPool()
    }

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
        if reason.kinds.contains(.store) {
            let destination = try store.prepareStoreDestination(reason: reason, date: now)
            try copyingStore(to: destination, copyStore)
            storeURL = destination
        }
        var appDataURL: URL?
        if reason.kinds.contains(.appData) {
            appDataURL = writeAppDataIgnoringFailure(reason: reason, now: now)
        }
        return BackupOutcome(reason: reason, documentURL: documentURL,
                             storeURL: storeURL, appDataURL: appDataURL,
                             prunedCount: prunedCountIgnoringFailure())
    }

    /// DB の外にあるデータの束を書く [BK-06]。
    ///
    /// **失敗でスナップショット全体を失敗にしない**（剪定と同じ判断）——
    /// DB の複製は既に取れており、そちらが主たる戻り道である。束が無い世代は
    /// 「古い版が作った世代」と同じ扱いで復元でき、DB だけが戻る。
    private func writeAppDataIgnoringFailure(reason: BackupReason, now: Date) -> URL? {
        guard let location = appDataLocation else { return nil }
        do {
            let archive = try AppDataSnapshot.capture(location,
                                                      linkingCoversInto: store.userCoverPool)
            if archive.manifest.userCoversSkipped > 0 {
                // 「守れていない」ことは残す [BK-06]。複製へ落として肥大化させる
                // ほうを選ばない以上、せめて数は分かるようにする。
                Log.db.warning("""
                    カバーの複製を \(archive.manifest.userCoversSkipped) 件 \
                    バックアップへ含められなかった（ハードリンクを作れない）
                    """)
            }
            if (archive.manifest.filesUnreadable ?? 0) > 0 {
                Log.db.warning(
                    "設定ファイルを \(archive.manifest.filesUnreadable ?? 0) 件 控えに含められなかった")
            }
            return try store.writeAppData(archive, reason: reason, date: now)
        } catch {
            Log.db.warning("DB の外にあるデータの束を書けなかった: \(String(describing: error))")
            return nil
        }
    }

    /// 複製を取る。**失敗したら宛先を残さない** [BK3-09]。
    ///
    /// 宛先ファイルは 1 ページも写す前に作られる［code-review が実測で確認］
    /// ので、残すと**中身の無いファイルが「正常な世代」として枠を食い、
    /// 良い世代を押し出す**。JSON 側は `.atomic` が同じ危険を防いでいる。
    private func copyingStore(to destination: URL, _ copy: (URL) throws -> Void) throws {
        do { try copy(destination) }
        catch { store.discard(destination); throw error }
        // **付随ファイルを残さない**［実機検証で発見、2026-09-06］。
        //
        // 複製の直後にジャーナル形式を畳む（`QooDatabase.backup`）際、
        // 写されたページのヘッダが WAL なので接続が一度 WAL へ入り、
        // **`-shm` を作って閉じても残す**。`generations()` は解釈しないので
        // **誰にも見えないまま容量を食い、剪定にもかからない**。
        //
        // 消せるのはこの層だけ——`QooPersistence` は削除系の `FileManager`
        // API を呼べない [B-10]。
        store.discardSidecars(of: destination)
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
        // **世代を消した後に**共有プールを掃除する [BK-06]。先に呼ぶと、
        // これから消える世代の参照を数えてしまい、消せるものが残る。
        //
        // **返り値には足さない**［code-review で発見］——`prunedCount` の
        // doc は「消した世代の数」で、カバーの*ファイル*数を混ぜると
        // 「剪定 5000 件」のような読めないログになる。
        let covers = try store.pruneUserCoverPool()
        if covers > 0 {
            Log.db.info("共有プールの複製を \(covers) 件回収した")
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
