//
//  永続化のポート [A-02][RP2-01〜RP2-05]。
//
//  **プロトコルと値型は `QooKit`（Foundation のみ）、実装は `QooPersistence`。**
//  上位層はここにだけ依存し、SQL・接続・行の型を知らない。CI の静的検査 B-11 が
//  `GRDB` の import を `QooPersistence` に限定して構造的に守る。
//
import Foundation

// MARK: - ライブラリ

public struct LibrarySummary: Sendable, Hashable, Identifiable {
    public let id: LibraryID
    /// 外部識別子。フェーズ 1 の登録フォルダ ID を引き継ぐ [07章 §7.3]。
    public let uuid: UUID
    public let displayName: String
    public let resolvedPath: String
    public let volumeUUID: String
    public let libraryTypeID: LibraryTypeID
    public let libraryTypeName: String
    public let isOnline: Bool                 // [SB-05]
    public let isReadOnlyDueToFS: Bool        // [FS-08]
    public let fileCount: Int
    public let settingsRevision: Int          // [VT-02]

    public init(id: LibraryID, uuid: UUID, displayName: String, resolvedPath: String,
                volumeUUID: String, libraryTypeID: LibraryTypeID, libraryTypeName: String,
                isOnline: Bool, isReadOnlyDueToFS: Bool, fileCount: Int, settingsRevision: Int) {
        self.id = id
        self.uuid = uuid
        self.displayName = displayName
        self.resolvedPath = resolvedPath
        self.volumeUUID = volumeUUID
        self.libraryTypeID = libraryTypeID
        self.libraryTypeName = libraryTypeName
        self.isOnline = isOnline
        self.isReadOnlyDueToFS = isReadOnlyDueToFS
        self.fileCount = fileCount
        self.settingsRevision = settingsRevision
    }
}

/// ライブラリ登録の入力 [RG-01][RG-07]。
public struct LibraryRegistration: Sendable {
    public let uuid: UUID
    public let displayName: String
    public let bookmarkData: Data
    public let resolvedPath: String
    public let volumeUUID: String
    public let libraryTypeID: LibraryTypeID

    public init(uuid: UUID, displayName: String, bookmarkData: Data,
                resolvedPath: String, volumeUUID: String, libraryTypeID: LibraryTypeID) {
        self.uuid = uuid
        self.displayName = displayName
        self.bookmarkData = bookmarkData
        self.resolvedPath = resolvedPath
        self.volumeUUID = volumeUUID
        self.libraryTypeID = libraryTypeID
    }
}

public protocol LibraryRepository: Sendable {
    func libraries() async throws -> [LibrarySummary]
    func library(id: LibraryID) async throws -> LibrarySummary?
    func library(uuid: UUID) async throws -> LibrarySummary?
    /// パーサへ渡す設定 [VT-01][VT-02]。
    func settingsSnapshot(libraryID: LibraryID) async throws -> LibrarySettingsSnapshot?
    /// **編集用**の設定 [LS-01]。`settingsSnapshot` と違いソース文字列のまま返し、
    /// 無効にしてあるフォーマットも落とさない——編集にスナップショットを使うと、
    /// 保存したときに無効なフォーマットが消える。
    func settingsDraft(libraryID: LibraryID) async throws -> LibrarySettingsDraft?
    /// 設定を保存する [LS-01][LT-03]。**`settingsRevision` の更新はこの中で行う**
    /// ——呼び出し側に任せると、上げ忘れたときパーサが古いコンパイル結果を
    /// 使い続ける [VT-02]。検証に通らない草案は保存しない。
    func updateSettings(_ draft: LibrarySettingsDraft, libraryID: LibraryID) async throws
    func register(_ registration: LibraryRegistration,
                  template: LibraryTypeTemplate) async throws -> LibraryID     // [RG-01][LT-03]
    /// 草案から登録する [RG-01][LT-02][LS-01]。有効化の時点で設定を調整できる
    /// ようにするための経路で、**`template` が `nil` なら白紙から作った
    /// カスタム**（専用の非プリセット型を作る）。
    func register(_ registration: LibraryRegistration,
                  draft: LibrarySettingsDraft,
                  template: LibraryTypeTemplate?) async throws -> LibraryID
    /// `keepLabels` はフェーズ 2 のラベル保管庫へ回すかどうか [RG-06]。
    func unregister(id: LibraryID, keepLabels: Bool) async throws
    func setOnline(_ online: Bool, libraryID: LibraryID) async throws          // [VD-03][VD-05]
    /// ボリュームの改名で移動した根を書き直す [VD-06]。`volumeUUID` は不変なので
    /// ファイルの紐づけは維持される。
    func setResolvedPath(_ path: String, libraryID: LibraryID) async throws

    // MARK: - 監視と差分スキャンの状態 [SY-01〜SY-05]

    /// 調整役が読む内部状態。`libraries()` とは別にしてあるのは
    /// `LibraryWatchState` のコメント参照。
    func watchStates() async throws -> [LibraryWatchState]
    /// 差分の起点を保存する [SY-02][WA-10]。
    ///
    /// **イベント ID 単独で保存する API を用意しない**［設計判断］。ID だけを
    /// 保存できると、次に読むときそれが同じ FSEvents データベースのものか
    /// 確かめられない——**そのまま渡すと履歴が黙って 0 件になる**
    /// （10章 §10.1.0 の実測）。組でしか保存できない形にして構造的に防ぐ。
    func setFSEventsCheckpoint(_ checkpoint: FSEventsCheckpoint,
                               libraryID: LibraryID) async throws
    /// フルスキャンの完了時刻を記録する [SY-05]。取りこぼしの最終安全網。
    func setLastFullScanAt(_ date: Date, libraryID: LibraryID) async throws
    /// レコード総数。起動時の閾値警告に使う [DB-04][IX-05]。
    func totalFileCount() async throws -> Int
}

// MARK: - ファイル

public protocol ManagedFileRepository: Sendable {
    func find(identity: FileIdentity) async throws -> FileID?                  // [ID-02]
    /// 再照合の候補を確度の高い順に返す [ID-03]。
    func findCandidates(for snapshot: FileSnapshot) async throws -> [ReidentificationCandidate]
    @discardableResult
    func upsert(_ snapshot: FileSnapshot) async throws -> FileID
    /// スキャンのホットパス。500 件バッチで呼ぶ [HP2-02][SE3-05]。
    @discardableResult
    func upsertBatch(_ snapshots: [FileSnapshot]) async throws -> [FileID]
    /// 同一性が変わったレコードの inode を差し替える [ID-04]。
    func reidentify(_ id: FileID, to identity: FileIdentity) async throws
    func setState(_ state: FileState, ids: [FileID]) async throws              // [ID-06][TR-01]
    func markTrashed(_ ids: [FileID], at date: Date) async throws              // [TR-01]
    func purgeExpiredTrashed(retentionDays: Int, now: Date) async throws -> Int // [TR-06]
    func row(id: FileID) async throws -> FileRow?
    func query(_ q: FileQuery) async throws -> FilePage
    func count(_ q: FileQuery) async throws -> Int
    /// フィルタに該当するファイルから、`scope` のフォルダ**直下**の子の名前を集める
    /// [VM-02][LF-14]。
    ///
    /// 「該当ファイル」と「**該当ファイルを配下に持つフォルダ**」が 1 度の
    /// 問い合わせで両方得られる——深い所にある該当ファイルは、その最初のパス成分
    /// （＝直下のフォルダ名）として現れる。フォルダ表示モードで絞り込むための
    /// 唯一の入口で、`query` で全件を取って呼び出し側が畳む形は採らない
    /// （フィルタが緩いとライブラリ全件を materialize することになる [FI-05]）。
    ///
    /// `scope` の `recursive` は**無視して必ず配下全体**を見る。直下だけを見ると
    /// 「該当ファイルを配下に持つフォルダ」を落とす。
    func matchingChildNames(_ q: FileQuery) async throws -> Set<String>
    /// 候補の相対パスのうち、条件に該当するものを返す [LF-14]。
    ///
    /// 検索結果（配下から再帰的に集めた一覧）へフィルタを効かせるための経路。
    /// ``matchingChildNames(_:)`` は直下の子へ畳んでしまうので、深い階層の
    /// 1 件ずつを見分けたいときはこちらを使う。**候補を渡す形にしてあるのは、
    /// 該当ファイル全件を持ち出さないため** [FI-05]——緩いフィルタでは
    /// ライブラリのほぼ全件が該当し得る。
    func matchingRelativePaths(_ q: FileQuery,
                               among candidates: [String]) async throws -> Set<String>
    /// 走査の範囲にあるが今回観測されなかったレコードを返す。
    ///
    /// 孤立にするかどうかは呼び出し側が決める——**ブックフォルダが 1 冊扱いを
    /// 解除された場合は孤立にしてはならない** [IF-05]。実体はまだそこにある。
    func unseen(libraryID: LibraryID, scope: FileQuery.Scope,
                seen: Set<FileID>) async throws -> [FileRow]
    /// 走査の範囲にあるが今回観測されなかったレコードを孤立にする [ID-06]。
    @discardableResult
    func markUnseenAsOrphaned(libraryID: LibraryID, scope: FileQuery.Scope,
                              seen: Set<FileID>) async throws -> Int
    /// 1 冊扱いを解除する [IF-05]。**ラベル紐づけは維持し、孤立にもしない**。
    func releaseBookFolder(_ id: FileID) async throws
    /// パーサの結果を書き戻す [RC-01]。
    func applyParsedFields(_ fields: ParsedFileFields?, to id: FileID) async throws

    // MARK: - 埋め込みメタデータ [EM-07]

    /// 読み取り済みのメタデータ（と、読んだ時点の印）を引く。
    ///
    /// **印が一致すればファイルを開かない**——これがスキャンを実用的な速さに
    /// 保つ唯一の手段で、無いと再スキャンのたびに 5 万件を開き直すことになる
    /// （§9.9 の実測で 7 秒〜10 分）。
    func embeddedMetadataCache(ids: [FileID]) async throws -> [FileID: EmbeddedMetadataCacheEntry]
    /// 読み取り結果を保存する。**読めなかったときも印は書く** [SE3-25]。
    func saveEmbeddedMetadata(_ entries: [FileID: EmbeddedMetadataCacheEntry]) async throws
    /// 巻数の判断待ちのファイル [EM-31]。確認ダイアログが一覧に使う。
    func filesAwaitingVolumeDecision(libraryID: LibraryID) async throws -> [VolumeDecisionCandidate]
    /// 巻数の判断を確定する [EM-33]。
    ///
    /// **再スキャンを要さない。**衝突していた 2 つの値はどちらも
    /// `metadataJSON` に残してあるので、選ばれた側を書き写すだけで済む——
    /// 判断のたびに数万件を走査し直すのは釣り合わない。
    /// - Parameter source: `.number` または `.volume`。`.ask` は何もしない。
    func resolveVolumeConflicts(_ ids: [FileID],
                                using source: ComicInfoVolumeSource) async throws
}

/// DB に置く埋め込みメタデータのキャッシュ 1 件ぶん [EM-07]。
public struct EmbeddedMetadataCacheEntry: Sendable, Hashable {
    /// 読んだ時点の `"mtime|size"`。これが変わったら読み直す。
    public let stamp: String
    /// 読んだ結果。**`nil` は「読んだが持っていなかった」**——「まだ読んでいない」
    /// （＝行が無い）とは別物で、区別しないと毎回開き直すことになる [SE3-25]。
    public let metadata: EmbeddedMetadata?

    public init(stamp: String, metadata: EmbeddedMetadata?) {
        self.stamp = stamp
        self.metadata = metadata
    }

    /// スキャンが観測した内容から印を作る。
    public static func stamp(modifiedAt: Date, fileSize: Int64) -> String {
        "\(modifiedAt.timeIntervalSinceReferenceDate)|\(fileSize)"
    }
}

/// 巻数の判断待ち 1 件 [EM-32]。確認ダイアログが並べて見せる。
public struct VolumeDecisionCandidate: Sendable, Hashable, Identifiable {
    public let id: FileID
    public let filename: String
    public let relativePath: String
    public let conflict: EmbeddedMetadata.VolumeConflict

    public init(id: FileID, filename: String, relativePath: String,
                conflict: EmbeddedMetadata.VolumeConflict) {
        self.id = id
        self.filename = filename
        self.relativePath = relativePath
        self.conflict = conflict
    }
}

// MARK: - ラベル

public struct LabelGroupSummary: Sendable, Hashable, Identifiable {
    public let id: LabelGroupID
    public let libraryID: LibraryID
    public let index: Int
    public let name: String
    public let colorHexLight: String
    public let colorHexDark: String
    public let displayOrder: Int
    public let labelCount: Int

    public init(id: LabelGroupID, libraryID: LibraryID, index: Int, name: String,
                colorHexLight: String, colorHexDark: String, displayOrder: Int, labelCount: Int) {
        self.id = id
        self.libraryID = libraryID
        self.index = index
        self.name = name
        self.colorHexLight = colorHexLight
        self.colorHexDark = colorHexDark
        self.displayOrder = displayOrder
        self.labelCount = labelCount
    }
}

public struct LabelSummary: Sendable, Hashable, Identifiable {
    public let id: LabelID
    public let groupID: LabelGroupID
    public let name: String                // 原文 [N-03]
    public let normalizedName: String
    public let colorHex: String?           // nil → グループ色を継承 [CO-06]
    public let isPinned: Bool              // [LB-03]
    public let isArchived: Bool            // [LA-01]
    public let fileCount: Int              // 非正規化 [DB-02]

    public init(id: LabelID, groupID: LabelGroupID, name: String, normalizedName: String,
                colorHex: String?, isPinned: Bool, isArchived: Bool, fileCount: Int) {
        self.id = id
        self.groupID = groupID
        self.name = name
        self.normalizedName = normalizedName
        self.colorHex = colorHex
        self.isPinned = isPinned
        self.isArchived = isArchived
        self.fileCount = fileCount
    }
}

public protocol LabelRepository: Sendable {
    func groups(libraryID: LibraryID) async throws -> [LabelGroupSummary]
    /// ラベルフィルタでの表示順 [LF-03][LG-07]。**ライブラリ単位の永続設定で
    /// 全ウインドウ共有** [ST-23]——ウインドウごとに違う順序で並ぶと、
    /// 同じライブラリを 2 枚開いたときにどちらが正しいか言えなくなる。
    ///
    /// 渡された順に 0 から振り直す。一覧に無いグループには触れない。
    func setGroupOrder(_ orderedIDs: [LabelGroupID]) async throws
    func group(libraryID: LibraryID, index: Int) async throws -> LabelGroupSummary?
    func labels(groupID: LabelGroupID, includeArchived: Bool) async throws -> [LabelSummary]
    /// 無ければ作る。一意性は `(groupID, 正規化名)` [LB-01][N-03][LA-07]。
    func ensureLabel(groupID: LabelGroupID, name: String) async throws -> LabelID
    func assign(fileID: FileID, labelID: LabelID, origin: LabelOrigin) async throws
    func unassign(fileID: FileID, labelID: LabelID, markManuallyRemoved: Bool) async throws // [RC-04]
    /// 1 ファイルの自動ラベルを丸ごと置き換える。手動・手動除外には触れない [RC-04]。
    func replaceAutoLabels(fileID: FileID, labelIDs: Set<LabelID>) async throws
    func labelIDs(fileID: FileID) async throws -> [(labelID: LabelID, origin: LabelOrigin)]
    func merge(_ source: LabelID, into target: LabelID) async throws           // [LB-07]
    func rename(_ id: LabelID, to name: String) async throws                   // [LB-06]
    func setArchived(_ ids: [LabelID], _ archived: Bool) async throws          // [LA-01][LA-08]
    func setPinned(_ id: LabelID, _ pinned: Bool) async throws                 // [LB-03]
    /// 増分更新の破綻に備えた再集計 [IX-03][IX-04]。実測 844 ms / 10,530 ラベル。
    func recountAll(libraryID: LibraryID) async throws
}
