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
    /// 現在フォルダの**直下**にあるブックフォルダの名前 [IF-17]。
    ///
    /// フォルダ表示モードでインジケータを出すためだけの経路。判定を
    /// その場で計算する（直下に対象拡張子 0 件かつ画像 1 件以上 [IF-01]）と
    /// **フォルダの数だけ列挙が要る**ので、走査が既に出した答え
    /// （`isBookFolder`）を引く。
    ///
    /// `matchingChildNames` と違い**畳まない**——ブックフォルダ「を含む」
    /// フォルダは通常のフォルダであって、印を付ける対象ではない。
    func bookFolderChildNames(libraryID: LibraryID, relativePath: String) async throws -> Set<String>
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

    // MARK: - 孤立ファイルの整理 [OR-01〜OR-05][ID-05][ID-07]

    /// 孤立レコードと、その再照合候補 [OR-01][OR-02]。
    ///
    /// **候補は保存されていないのでここで引き直す** [ID-05]。走査は
    /// `.nameOnly` でしか一致しなかったものを数えるだけで、その実ファイルは
    /// 新規レコードとして別に入っている——同じ名前の生きているレコードが
    /// その候補である。
    ///
    /// **オフラインのライブラリは呼び出し側が除く** [OR2-06][ID-08][SB-05]。
    /// ここで弾かないのは、リポジトリがボリュームの接続状態を知らないため。
    func orphanedFiles(libraryID: LibraryID) async throws -> [OrphanedFile]
    /// ライブラリごとの孤立件数。**左ペインの出し分けに使う**ので 1 問い合わせで
    /// 返す（`archivedLabelCounts` と同じ理由——ライブラリごとに辿ると、
    /// ⌘Z のたびに走る読み直しが件数ぶんの往復になる）。0 件はキーごと現れない。
    func orphanedFileCounts() async throws -> [LibraryID: Int]
    /// 行の同一性 [ID-01]。候補として提示した行から「観測結果」を組み立てるのに使う
    /// ——`FileRow` は inode を持たない（一覧の表示に要らないため）。
    func identity(of id: FileID) async throws -> FileIdentity?
    /// 同一性の確認待ち [ID-05]。**名前が同じで inode が違う組**を返す。
    ///
    /// `orphanedFiles` と同じ引き直しを使うが、**却下済みの組は除く** [ID-11]。
    func identityMatchesAwaitingDecision(libraryID: LibraryID) async throws -> [OrphanedFile]
    /// 承認された組を確定する [ID-05]。候補側の行を消し、孤立側を実体へ移す。
    ///
    /// **1 トランザクションで行う**——途中で切れると、同じ実体を指す行が 2 つ
    /// 残るか、どちらも指さない状態になる。
    /// - Returns: 消した候補側の ID（Undo が復元する対象）。
    @discardableResult
    func acceptIdentityMatches(_ matches: [IdentityMatch]) async throws -> [FileID]
    /// 「別のファイルだ」という判断を記録する [ID-11]。以後の走査では問い合わせない。
    func rejectIdentityMatches(_ matches: [IdentityMatch]) async throws
    /// 却下の記録を取り消す（Undo 用）。
    func clearIdentityRejections(_ matches: [IdentityMatch]) async throws

    /// 孤立レコードを、実際に観測されたファイルへ結び直す [ID-04]。
    ///
    /// **同じ同一性を持つ別のレコードがあれば、それを消してから結び直す**
    /// ［ユーザー判断］。孤立レコード側のラベル・評価・手動タイトル・カバー指定を
    /// 生かすため——候補側は原則スキャン直後の新規レコードで、失うものが少ない。
    /// 1 トランザクションで行う（片方だけ済んだ状態を残さない）。
    ///
    /// - Returns: 消した重複レコードの ID。無ければ `nil`。
    @discardableResult
    func reattachOrphan(_ id: FileID, to snapshot: FileSnapshot) async throws -> FileID?
    /// 不要になった孤立レコードを消す [OR-04]。紐づけは cascade で消える。
    func deleteFiles(_ ids: [FileID]) async throws
    /// 削除・再紐づけの前に控える写し [UD-03]。存在しない ID は飛ばす。
    func fileSnapshots(ids: [FileID]) async throws -> [ManagedFileSnapshot]
    /// 写しの状態へちょうど戻す。**`id` を明示して `INSERT` する**
    /// （`managedFile.id` は AUTOINCREMENT なので元の ID が空いたまま残る）。
    func restoreFiles(_ snapshots: [ManagedFileSnapshot]) async throws
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

    // MARK: - 評価 [RA-01〜RA-08]

    /// 星を書き込む [RA-01]。`0` は未評価 [RA-02]（`rating` 列は未評価を 0 で持つ
    /// ので、解除は「0 を書く」ことで表す）。範囲外は 0〜5 へ丸める。
    ///
    /// **走査は `rating` に触れない**（`updateInPlace` の SQL に列が無い）ので、
    /// 再スキャンで消えることはない。JSON バックアップにも入る
    /// （`regenerableColumns` に `rating` が無い＝再生成不可能データ [MG-22]）。
    func setRating(_ stars: Int, ids: [FileID]) async throws

    /// 同じシリーズのファイル [RA-04]。**基準のファイル自身も含む。**
    ///
    /// ## `seriesName` ではなく `seriesKey` で照合する
    /// 呼び出し側にシリーズ名を渡させる形（`filesInSeries(libraryID:seriesName:)`）
    /// にすると、**呼び出し側に正規化の責務が移る**——表記ゆれのある巻が黙って
    /// 対象から漏れ、しかも漏れたことは件数を数えても分からない。基準の
    /// ファイルを渡してもらえば、同じ行の正規化済み `seriesKey`（索引
    /// `mf_lib_series`）でそのまま引ける。ライブラリの取り違えも構造的に起きない。
    ///
    /// ## どの状態まで含めるか［設計判断］
    /// **`.trashed` だけを除く。** 評価は DB 上の属性で、実体の有無に関わらず
    /// 保持される [ID-08] ——外付けを抜いている（`.offline`）あいだに全巻へ
    /// 適用したら、挿し直したときだけ 1 冊違う、という形になるほうが驚きが
    /// 大きい。ゴミ箱（`.trashed`）は消す予定のものなので除く。
    ///
    /// シリーズ名を持たなければ空配列を返す [RA-07]。
    func filesInSameSeries(as id: FileID) async throws -> [FileRow]

    // MARK: - 右ペインからの編集 [RP-10〜RP-12][CV-02〜CV-08]

    /// タイトル・シリーズ名・巻数・著者をまとめて書く [RP-10][RP-12]。
    ///
    /// **`seriesKey` はここで導出する** — 呼び出し側に正規化させない [3.8 節]。
    /// `titleOrigin` も渡された値をそのまま書く（`applyParsedFields` のように
    /// `manual` を守る細工はしない）——守る側と、意図して書き換える側は
    /// 別の操作である。
    func setFields(_ edit: FileFieldEdit, id: FileID) async throws

    /// カバー画像の割り当てを書く [CV-02][CV-06][CV-07]。
    ///
    /// **複製そのものの作成・削除はここではしない。** DB は参照だけを持ち
    /// [CL-05]、実体の管理は保存側（`UserCoverStore`）の仕事——混ぜると
    /// 「DB は書けたが複製が無い」「複製はあるが誰も参照していない」の
    /// どちらへも倒れ得る。
    func setCover(_ assignment: CoverAssignment, id: FileID) async throws

    /// そのライブラリでいま参照されているユーザー指定カバーの名前 [CV-06]。
    ///
    /// 起動時に「どの複製も参照されていないか」を確かめるために使う
    /// （`UserCoverStore.purgeUnreferenced`）。
    func userCoverRefs(libraryID: LibraryID) async throws -> Set<String>
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
    /// ラベルフィルタが見せる件数 [LF-11]。非正規化 [DB-02]。
    ///
    /// **ファイル保管庫に入れたファイルは数えない** [FA-05]——保管庫の中身は
    /// フィルタの結果から外れるので、件数だけ残ると数が合わない。
    public let fileCount: Int
    /// ラベル編集ウインドウのバッジが見せる件数 [LE-03][LE-05]。
    ///
    /// **保管庫に入れたファイルも数える** [LE-05]。`fileCount` とわざわざ分けて
    /// いるのは要件が意図的に食い違っているため——フィルタからは外す [FA-05] が、
    /// **バッジには影響させない**。同じ値を使い回すと、ファイルを保管庫へ入れた
    /// だけでラベルが「0 件」＝赤字＝消してよさそう [LE-04][RC-07] に見えてしまう。
    /// 紐づけは維持されているのに、である。
    ///
    /// ファイル保管庫（2-11）が入るまでは `fileCount` と必ず一致する。
    public let fileCountIncludingArchived: Int

    public init(id: LabelID, groupID: LabelGroupID, name: String, normalizedName: String,
                colorHex: String?, isPinned: Bool, isArchived: Bool, fileCount: Int,
                fileCountIncludingArchived: Int? = nil) {
        self.id = id
        self.groupID = groupID
        self.name = name
        self.normalizedName = normalizedName
        self.colorHex = colorHex
        self.isPinned = isPinned
        self.isArchived = isArchived
        self.fileCount = fileCount
        self.fileCountIncludingArchived = fileCountIncludingArchived ?? fileCount
    }
}

/// ラベル 1 件と、その紐づけの完全な写し。**削除とマージを ⌘Z で戻すために要る。**
///
/// 付け外し [RL-01] と違い、削除 [LE-07] とマージ [LB-07] は `label` の行そのものを
/// 物理的に消す。戻すには行を作り直すしかなく、そのとき **`id` をそのまま使う**。
///
/// **元の ID へ戻せるのは `label.id` が AUTOINCREMENT だから**［実測］。削除された
/// ID は二度と再利用されないので空いたまま残り、明示指定した `INSERT` で同じ ID を
/// 取り戻せる（`sqlite_sequence` も巻き戻らない）。別 ID で作り直すと、ラベル
/// フィルタでチェック中だった選択やウインドウ状態復元 [ST-26] が黙って外れる
/// ——`label` にだけ AUTOINCREMENT を付けた T-03 の決定③が、想定とは別の形でここでも効く。
///
/// `fileCount` は持たない。非正規化された再生成可能な値なので、復元後に数え直す。
public struct LabelSnapshot: Sendable, Hashable {
    /// 紐づけ 1 件ぶん。
    public struct Assignment: Sendable, Hashable {
        public let fileID: FileID
        public let origin: LabelOrigin
        public let assignedAt: Date

        public init(fileID: FileID, origin: LabelOrigin, assignedAt: Date) {
            self.fileID = fileID
            self.origin = origin
            self.assignedAt = assignedAt
        }
    }

    public let id: LabelID
    public let groupID: LabelGroupID
    public let name: String
    public let normalizedName: String
    public let colorHex: String?
    public let isPinned: Bool
    public let isArchived: Bool
    /// そのラベルの紐づけ**全件**。`manuallyRemoved` の行も含む——除去の印は
    /// 「付いていない」ではなく「外したと記録されている」という別の状態で、
    /// 落とすと ⌘Z のあと再スキャンでラベルが復活する [RC-04]。
    public let assignments: [Assignment]

    public init(id: LabelID, groupID: LabelGroupID, name: String, normalizedName: String,
                colorHex: String?, isPinned: Bool, isArchived: Bool,
                assignments: [Assignment]) {
        self.id = id
        self.groupID = groupID
        self.name = name
        self.normalizedName = normalizedName
        self.colorHex = colorHex
        self.isPinned = isPinned
        self.isArchived = isArchived
        self.assignments = assignments
    }
}

/// ラベル編集で、利用者に伝えるべき理由がある失敗 [LE-07][LE-11]。
///
/// 素の制約違反のまま投げると「UNIQUE constraint failed: label.labelGroupId,
/// label.normalizedName」がそのまま画面に出る。**呼び出し側が次の一手を出せる
/// ようにする**——改名の衝突なら「代わりに統合しますか」を勧められる [LE-11]。
public enum LabelEditError: Error, Sendable, Hashable {
    /// 同じグループに、正規化後が同じ名前のラベルが既にある [LB-01][N-03]。
    case nameAlreadyExists(existing: LabelID, name: String)
    /// 別のラベルグループへは統合できない [LB-07]。
    case crossGroupMerge
    case labelNotFound(LabelID)
}

/// 1 ファイル 1 ラベルぶんの紐づけの変更 [RL-01][RL-07]。
///
/// **`origin` を `Optional` で持つのは、Undo が「元の状態」をそのまま書き戻す
/// ため。** `nil` は「紐づけの行が無かった」＝消す、`.manuallyRemoved` は
/// 「外した印が付いていた」[RC-04] を意味し、この 3 種を区別できないと
/// ⌘Z が別の状態へ戻してしまう（評価で「変更前の値を 1 件ずつ持つ」と
/// 決めたのと同じ理由 [RA-06]）。
public struct LabelAssignmentChange: Sendable, Hashable {
    public let fileID: FileID
    /// `nil` は紐づけを消す。
    public let origin: LabelOrigin?

    public init(fileID: FileID, origin: LabelOrigin?) {
        self.fileID = fileID
        self.origin = origin
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
    /// ライブラリごとのアーカイブ済みラベル件数 [LA-01][15.3 節]。
    ///
    /// ラベル保管庫の整理ウインドウが、左ペインで**保管庫が空のライブラリを
    /// グレーアウトする**ために使う。件数が 0 のライブラリはキーごと現れない。
    ///
    /// **1 回の問い合わせで全ライブラリぶんを返す**［設計判断］。ライブラリ
    /// ごとに `groups` → `labels` と辿ると問い合わせが「ライブラリ数 ×
    /// グループ数」になり、しかもそれが ⌘Z のたびに走る（このウインドウは
    /// `operationHistory.count` を鍵に読み直すため）。
    func archivedLabelCounts() async throws -> [LibraryID: Int]
    /// 無ければ作る。一意性は `(groupID, 正規化名)` [LB-01][N-03][LA-07]。
    func ensureLabel(groupID: LabelGroupID, name: String) async throws -> LabelID
    func assign(fileID: FileID, labelID: LabelID, origin: LabelOrigin) async throws
    func unassign(fileID: FileID, labelID: LabelID, markManuallyRemoved: Bool) async throws // [RC-04]
    /// 1 ファイルの自動ラベルを丸ごと置き換える。手動・手動除外には触れない [RC-04]。
    func replaceAutoLabels(fileID: FileID, labelIDs: Set<LabelID>) async throws
    func labelIDs(fileID: FileID) async throws -> [(labelID: LabelID, origin: LabelOrigin)]
    /// 複数ファイルの紐づけを 1 度に読む [RL-04][RP-02]。
    ///
    /// 1 件ずつ引くと、選択したファイルの数だけ読み取りトランザクションが
    /// 開く。右ペインは選択が変わるたびに読み直すので、そこは 1 回で済ませる。
    func assignments(fileIDs: [FileID]) async throws -> [FileID: [LabelID: LabelOrigin]]
    /// 1 つのラベルの紐づけを、ファイルごとに指定した状態へ揃える [RL-01][RL-07]。
    ///
    /// **1 トランザクションで書く** [RP2-04]——一括付与の途中で失敗したときに、
    /// 半分だけ付いた状態を残さない。`AssignLabelCommand` の `execute()` と
    /// `undo()` がどちらもこれを使う（戻すのも「指定した状態へ揃える」ことに
    /// 他ならないので、復元のための別 API を作らない）。
    func applyAssignments(labelID: LabelID, _ changes: [LabelAssignmentChange]) async throws
    /// 2 つのラベルを統合する [LB-07][LE-11]。`source` の行は消え、紐づけは
    /// `target` へ移る。
    ///
    /// **同じファイルに両方が付いていたら `origin` は manual > auto >
    /// manuallyRemoved で決める**［ユーザー判断］。素朴に `UPDATE OR IGNORE` で
    /// 移すと移動先の値が無条件に残り、`source` が `manual`・`target` が
    /// `manuallyRemoved` のファイルで**手動付与が黙って消える**。統合は
    /// 「同じものに 2 つの名前が付いていた」を是正する操作なので、どちらかで
    /// 手で付けていたなら手動として残す。
    ///
    /// **別グループへは統合できない** [LB-07]——ラベルの一意性はグループ内で
    /// 定義されており [LB-01]、またぐと「グループを移す」という別の操作になる。
    func merge(_ source: LabelID, into target: LabelID) async throws           // [LB-07]
    /// 改名 [LB-06]。紐づけは維持される（行の ID が変わらないため何もしなくてよい）。
    ///
    /// 同じグループに正規化後が同じ名前があれば `LabelEditError.nameAlreadyExists`。
    /// **素の UNIQUE 制約違反を投げない**——呼び出し側が「代わりに統合」を
    /// 勧められるよう、衝突相手の ID を添えて返す [LE-11]。
    func rename(_ id: LabelID, to name: String) async throws                   // [LB-06]
    func setArchived(_ ids: [LabelID], _ archived: Bool) async throws          // [LA-01][LA-08]
    func setPinned(_ id: LabelID, _ pinned: Bool) async throws                 // [LB-03]
    /// ラベル固有色 [LE-10][CO-06]。`nil` へ戻すとグループ色を継承する。
    func setColor(_ id: LabelID, hex: String?) async throws
    /// 削除 [LE-07]。**紐づけも一緒に消える** [LE-08][LB-05]——`fileLabel` の
    /// 外部キーが `ON DELETE CASCADE` なので DB が保証する。
    func deleteLabels(_ ids: [LabelID]) async throws
    /// 行と紐づけの完全な写しを取る。**削除・統合の Undo 用** [LabelSnapshot]。
    ///
    /// 存在しない ID は黙って飛ばす（同時に消えていた場合に、戻せるものまで
    /// 戻せなくなるのを避ける）。
    func snapshot(labelIDs: [LabelID]) async throws -> [LabelSnapshot]
    /// 写しの状態へ**ちょうど**戻す。写しに含まれない紐づけは消える。
    ///
    /// 「指定した状態へ揃える」という `applyAssignments` と同じ形にしてある
    /// ——戻すことも「ある状態へ揃える」ことに他ならないので、復元専用の
    /// 別の意味を持つ API を作らない。`fileCount` は数え直す。
    func restore(_ snapshots: [LabelSnapshot]) async throws
    /// 増分更新の破綻に備えた再集計 [IX-03][IX-04]。実測 844 ms / 10,530 ラベル。
    func recountAll(libraryID: LibraryID) async throws
}
