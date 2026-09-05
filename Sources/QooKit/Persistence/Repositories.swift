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
    public let isOnline: Bool                 // [SB-05]
    public let isReadOnlyDueToFS: Bool        // [FS-08]
    public let fileCount: Int
    public let settingsRevision: Int          // [VT-02]
    /// 同じ作品のファイルを 1 行に畳むか [DU-01][DU-02]。**既定は無効。**
    ///
    /// 一覧を組み立てるたびに要るので設定の要約に載せてある——ここに
    /// 無いと、行を描く直前に設定を読み直す経路を新しく作ることになる。
    public let duplicateGrouping: DuplicateGrouping

    public init(id: LibraryID, uuid: UUID, displayName: String, resolvedPath: String,
                volumeUUID: String, libraryTypeID: LibraryTypeID,
                isOnline: Bool, isReadOnlyDueToFS: Bool, fileCount: Int, settingsRevision: Int,
                duplicateGrouping: DuplicateGrouping = .off) {
        self.id = id
        self.uuid = uuid
        self.displayName = displayName
        self.resolvedPath = resolvedPath
        self.volumeUUID = volumeUUID
        self.libraryTypeID = libraryTypeID
        self.isOnline = isOnline
        self.isReadOnlyDueToFS = isReadOnlyDueToFS
        self.fileCount = fileCount
        self.settingsRevision = settingsRevision
        self.duplicateGrouping = duplicateGrouping
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
    /// 登録時のプリセット定義 [LT-10][LT-13]。**差分の base。**
    ///
    /// `nil` は「持っていない」＝**改訂の差分の対象外**。ユーザー定義
    /// テンプレート・白紙からの登録と、v17 より前に作られた行がこれになる。
    /// 読めない JSON も `nil` に倒す——推測で埋めると、実際とは違う版を
    /// 基準にした差分を「正しいもの」として見せることになる。
    func registeredTemplate(libraryID: LibraryID) async throws -> LibraryTypeTemplate?
    /// 差分を確認し終えたら base を最新へ進める [LT-16]。
    ///
    /// **適用した項目だけでなく、見送った項目も含めて「この改訂は判断済み」**に
    /// なる——進めないと同じ差分を毎回見せることになり、LT-12 の通知が
    /// 永久に消えない。取り消しは適用前の値を書き戻す。
    func setRegisteredTemplate(_ template: LibraryTypeTemplate?,
                               libraryID: LibraryID) async throws

    /// フォルダ名＝表示名 [RG3-31]。リネームへの追随のためにだけ呼ぶ。
    ///
    /// **`settingsRevision` も上げる**——表示名は `@libraryname` の照合値
    /// [RW-04] としてパーサのスナップショットに焼き込まれているので、
    /// 上げないと改名後もキャッシュされた古い名前で照合され続ける [VT-02]。
    func setDisplayName(_ name: String, libraryID: LibraryID) async throws

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
    /// 現在フォルダの**直下**にある蔵書の「ファイル名 → 行 ID」[RL3-01]。
    ///
    /// 中央ペインのコンテキストメニュー（ラベルの付け外し）が、フォルダ表示
    /// モードの実体一覧を DB の行へ対応付けるための経路。メニューは遅延構築で
    /// 非同期の後追い更新が効かないため、事前に読める対応表が要る。
    /// 名前は同一ディレクトリ内で一意（ファイルシステムの名前空間はファイルと
    /// フォルダを分けない）なので、この対応で取り違えは起きない。
    func fileIDsByChildName(libraryID: LibraryID, relativePath: String) async throws -> [String: FileID]
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

    // MARK: - ファイル保管庫 [FA-01〜FA-17][FAW-01〜FAW-05]

    /// 保管庫にあるファイル [FAW-01]。元のフォルダ・名前の順に返す。
    ///
    /// **オンラインを要らない**——`isArchived` は DB の属性で、実体を 1 度も
    /// 見ない（孤立 [OR2-06] とは逆に、オフラインでも正しく一覧できる）。
    /// ただし**戻す操作は実ファイルを動かす**ので、そちらは呼び出し側が
    /// オンラインを確かめること。
    func archivedFiles(libraryID: LibraryID) async throws -> [ArchivedFile]
    /// ライブラリごとの保管庫の件数。左ペインの出し分けに使う（1 問い合わせ）。
    func archivedFileCounts() async throws -> [LibraryID: Int]

    // --- 重複ファイル [DU-05][DU-08][DU-20][DU-22] ---

    /// 同じ組の全メンバーを**代表順**で [DU-20]。
    func duplicateGroupMembers(containing id: FileID,
                               mode: DuplicateGrouping) async throws -> [FileRow]
    /// 数え終わった遅延メタデータを控える [MD-02][DU-22]。
    func cacheArchiveMetadata(pageCount: Int, subfolderCount: Int,
                              firstImageWidth: Int?, firstImageHeight: Int?,
                              for id: FileID) async throws
    /// 保管庫の出入りを記録する [FA-04][FA-05]。
    ///
    /// **実ファイルを動かした「あと」に呼ぶこと。** `relativePath` は受領書から
    /// 作る——衝突で連番が付く [FA-13] ことがあるので、予定のパスを書くと
    /// 実体とずれる。
    ///
    /// **ラベルの件数を数え直す必要はもう無い** [DB-02 撤回]。件数は表示のたびに
    /// 数える [§19.13 #1] ので、保管庫の出入りは自動的に反映される——「`state` や
    /// `isArchived` を変える経路を新設するたびに数え直しが要る」という穴
    /// （2 度踏んだ）が構造ごと消えた。
    func setArchived(_ moves: [VaultMove], archived: Bool) async throws
    /// フォルダ配下の行（相対パス付き）[FDA-01]。
    ///
    /// フォルダを丸ごと運んだあと、配下の行の相対パスを付け替えるために使う
    /// ——1 回の `rename(2)` で運ぶ [FDA-01] ので、動いたことを DB へ写す側は
    /// 「どの行が中に居たか」を自分で知る必要がある。
    ///
    /// `folderRelativePath` が空文字ならライブラリ全体。ゴミ箱の行は含めない。
    func filesUnder(libraryID: LibraryID, folderRelativePath: String) async throws
        -> [FileID: String]

    /// 不要になった孤立レコードを消す [OR-04]。紐づけは cascade で消える。
    func deleteFiles(_ ids: [FileID]) async throws
    /// 削除・再紐づけの前に控える写し [UD-03]。存在しない ID は飛ばす。
    func fileSnapshots(ids: [FileID]) async throws -> [ManagedFileSnapshot]
    /// 写しの状態へちょうど戻す。**`id` を明示して `INSERT` する**
    /// （`managedFile.id` は AUTOINCREMENT なので元の ID が空いたまま残る）。
    func restoreFiles(_ snapshots: [ManagedFileSnapshot]) async throws
    /// パーサの結果を書き戻す [RC-01]。
    func applyParsedFields(_ fields: ParsedFileFields?, to id: FileID) async throws

    // MARK: - 未解決ファイル [AL-30〜AL-34][UR-01〜UR-06]

    /// 走査 1 チャンクぶんの「未解決かどうか」を反映する [AL-31]。
    ///
    /// **記録と削除を 1 つの呼び出しにまとめてある。** 別々にすると、
    /// フォーマットを足して解決したのに古い記録が残る（またはその逆）という
    /// 食い違いが、呼び出し側の書き忘れで起こりうる——走査は収束型 [FO-20]
    /// なので、観測した集合をそのまま渡せば必ず正しくなる形にする。
    ///
    /// - Parameters:
    ///   - unresolved: 未解決と判定したもの。既に記録があれば名前を更新し、
    ///     **名前が変わっていれば無視フラグを解く**［ユーザー判断、2026-08］。
    ///   - resolved: 解決していると判定したもの。記録があれば消す。
    func syncUnresolved(unresolved: [UnresolvedObservation], resolved: [FileID],
                        libraryID: LibraryID, now: Date) async throws

    /// 未解決ファイルの一覧 [UR-01][UR-02]。相対パス順。
    ///
    /// **`state != .active` のものは出さない** ——実体が見つからなくなった
    /// ものは「見つからないファイル」[OR-01] の担当で、こちらに出すと
    /// 同じ 1 件が 2 つの画面に別の意味で並ぶ。
    func unresolvedFiles(libraryID: LibraryID, includeIgnored: Bool) async throws
        -> [UnresolvedFile]

    /// ライブラリごとの未解決の内訳 [AL-33]。**「片付けるべき件数」と
    /// 「無視した件数」を分けて返す**——左ペインの「N 件」は前者だが、
    /// 空状態の文言は後者を知らないと嘘になる（無視しただけなのに
    /// 「すべて一致しています」と言ってしまう）。0 件のライブラリは現れない。
    func unresolvedFileCounts() async throws -> [LibraryID: UnresolvedCounts]

    /// 1 件だけの未解決の記録 [UR3-04]。`nil` = そのファイルは未解決ではない。
    ///
    /// **一覧（`unresolvedFiles`）を引いて絞らない。** 右ペインは選択が
    /// 変わるたびにこれを引くので、ライブラリ全体の未解決を毎回読むと
    /// 5,000 件の未整理を抱えたライブラリで選択のたびにその全件が流れる。
    func unresolvedHint(id: FileID) async throws -> UnresolvedHint?

    /// 「以後無視する」の切り替え [AL-33][UR-05]。
    func setUnresolvedIgnored(_ ids: [FileID], _ ignored: Bool) async throws

    // MARK: - シリーズの提案 [SS-01〜SS-08、19章 §19.5]

    /// 提案の候補になる本 [SS-08]。
    ///
    /// 除くのは **シリーズ設定済み・基本情報を保護済み・保管庫内・ゴミ箱**
    /// [SS-08]。加えて `state != .active` のものも出さない——実体が見つからない
    /// ものは「見つからないファイル」[OR-01] の担当で、そこに出るものを
    /// こちらにも出すと同じ 1 件が 2 つの画面に別の意味で並ぶ
    /// （`unresolvedFiles` と同じ判断）。
    ///
    /// - Parameter circleFieldID: `@circle` を束縛しているフィールド [SS-02]。
    ///   サークルは `authorName` のような専用列を持たずラベルとして入るので、
    ///   **どのフィールドを見るかは呼び出し側が設定から解決する**。`nil` なら
    ///   著者名だけを鍵にする。
    func seriesSuggestionCandidates(libraryID: LibraryID,
                                    circleFieldID: FieldID?) async throws
        -> [SeriesSuggestionCandidate]

    /// 「以後この提案を出さない」の付け外し [SS-05]。
    ///
    /// **付けるものと外すものを 1 度に渡す。** ⌘Z は「変更前の状態を 1 件ずつ
    /// 書き戻す」ので、1 回の取り消しで付ける側と外す側が混ざる——別々の
    /// 呼び出しにすると、その途中で片方だけ反映された状態があり得る。
    ///
    /// 値は**印を立てた時点のタイトル**。現在のタイトルと食い違えば読み出し側が
    /// 「無視していない」と扱うので、名前が変われば自動的に解ける。
    func updateSeriesSuggestionIgnored(set marks: [FileID: String],
                                       clear ids: [FileID]) async throws

    /// いま立っている無視印 [SS-05]。⌘Z が変更前の値を控えるのに使う。
    func seriesSuggestionIgnoredTitles(ids: [FileID]) async throws -> [FileID: String]

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
    /// **保護は見ない**（`applyParsedFields` のように据え置く細工はしない）
    /// ——守る側と、意図して書き換える側は別の操作である。保護を付けるのは
    /// 呼び出し側のコマンドで、編集と同じ Undo 単位で行う [PR-03]。
    /// **保護スコープも同じトランザクションで書く** [PR-03]。別々に呼ぶと
    /// 「値は変わったが保護が付いていない」状態があり得て、次の走査で手で
    /// 直した値が黙って自動値へ戻る。呼び出し側が忘れられないよう引数にする。
    func setFields(_ edit: FileFieldEdit, id: FileID,
                   protectedScopes: Set<ProtectionScope>) async throws

    // MARK: - メタデータの保護 [PR-01〜PR-09]

    /// 保護スコープを置き換える [PR-03][PR-04][PR-05]。
    ///
    /// **ファイルごとに違う集合を渡せる**——Undo が「変更前の集合を 1 件ずつ」
    /// 書き戻すため [RA-06 と同じ理由]。複数選択に一律の集合を書き戻すと、
    /// 元から保護されていたファイルの保護まで落とす。
    func setProtectedScopes(_ scopes: [FileID: Set<ProtectionScope>]) async throws

    /// いま保護されているスコープを読む [PR-05]。
    ///
    /// `FileRow` からも取れるが、コマンドは行を持たずに ID だけを持つことが
    /// あるので、ID から直に引ける口を用意する（変更前の値を控えるのに要る）。
    func protectedScopes(ids: [FileID]) async throws -> [FileID: Set<ProtectionScope>]

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

public struct FieldSummary: Sendable, Hashable, Identifiable {
    public let id: FieldID
    public let libraryID: LibraryID
    public let index: Int
    public let name: String
    public let colorHexLight: String
    public let colorHexDark: String
    public let displayOrder: Int
    /// そのフィールドが持つラベルの総数。**非表示のものも数える** [LA3-03]
    /// ——フィールド編集ウインドウは非表示のラベルも一覧に出すので、ここで
    /// 除くと「ラベルはあるのに空のフィールド」に見える。
    ///
    /// **ラベルフィルタの出し分けにはこの値を使わない** [LA3-05]。あちらは
    /// 「見えるラベルが 1 件でもあるか」で決めるが、それは実体の件数から
    /// 導く値で（`LabelFilterModel` が読んだラベルから求める）、ここに
    /// 2 つ目の意味を持たせると §19.13 #1 と同じ取り違えを生む。
    public let labelCount: Int

    public init(id: FieldID, libraryID: LibraryID, index: Int, name: String,
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
    public let fieldID: FieldID
    public let name: String                // 原文 [N-03]
    public let normalizedName: String
    public let colorHex: String?           // nil → フィールド色を継承 [CO-06]
    public let isPinned: Bool              // [LB-03]
    /// **手動で非表示にした印** [LA3-02]。実体が無いことによる非表示は
    /// ``isHidden`` ではなく ``fileCount`` が 0 であることから導く [LA3-01]。
    public let isHidden: Bool
    /// **生きている実体の件数。これが唯一の件数である** [LA3-01][§19.13 #1]。
    ///
    /// 数えるのは `state = active` かつ**ファイル保管庫の外** [FA-05] のファイル
    /// ——つまりラベルフィルタが返しうるファイルそのもの。0 なら LA3-01 により
    /// 自動的に非表示になる。
    ///
    /// **かつては意味の違う件数を 2 つ持っていた**（フィルタ用と、保管庫の
    /// ファイルも数える編集ウインドウ用 [LE-05]）。0 件ラベルの赤字 [LE-04] が
    /// 撤回された [LA3-04] ことで後者の存在理由が消え、逆に「バッジは 3 件と
    /// 出ているのに一覧では非表示」という食い違いを生むだけになったので
    /// 1 つに統合した［ユーザー判断］。
    ///
    /// **非正規化列ではない**——表示のたびに数える。実測（10 万件・50 万紐づけ）
    /// で非正規化列を読むのと同等以下（109.4 → 105.3 ms）だったため
    /// [DB-02 撤回]。
    public let fileCount: Int

    public init(id: LabelID, fieldID: FieldID, name: String, normalizedName: String,
                colorHex: String?, isPinned: Bool, isHidden: Bool, fileCount: Int) {
        self.id = id
        self.fieldID = fieldID
        self.name = name
        self.normalizedName = normalizedName
        self.colorHex = colorHex
        self.isPinned = isPinned
        self.isHidden = isHidden
        self.fileCount = fileCount
    }

    /// 一覧に出すべきか [LA3-01][LA3-05]。**手動の印と実体の有無の両方**を見る。
    ///
    /// 判定をここに置くのは、フィルタ・右ペインの候補・フィールド編集の
    /// 3 箇所が同じ規則を別々に書かないため（`PinnedLabelListing` と同じ考え方）。
    public var isVisible: Bool { !isHidden && fileCount > 0 }
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
/// 件数は持たない——実体から導く値なので、復元すれば自然に一致する [LA3-01]。
public struct LabelSnapshot: Sendable, Hashable {
    /// 紐づけ 1 件ぶん。
    public struct Assignment: Sendable, Hashable {
        public let fileID: FileID
        public let assignedAt: Date

        public init(fileID: FileID, assignedAt: Date) {
            self.fileID = fileID
            self.assignedAt = assignedAt
        }
    }

    public let id: LabelID
    public let fieldID: FieldID
    public let name: String
    public let normalizedName: String
    public let colorHex: String?
    public let isPinned: Bool
    public let isHidden: Bool              // [LA3-02]
    /// そのラベルの紐づけ全件。
    public let assignments: [Assignment]

    public init(id: LabelID, fieldID: FieldID, name: String, normalizedName: String,
                colorHex: String?, isPinned: Bool, isHidden: Bool,
                assignments: [Assignment]) {
        self.id = id
        self.fieldID = fieldID
        self.name = name
        self.normalizedName = normalizedName
        self.colorHex = colorHex
        self.isPinned = isPinned
        self.isHidden = isHidden
        self.assignments = assignments
    }
}

/// ラベル編集で、利用者に伝えるべき理由がある失敗 [LE-07][LE-11]。
///
/// 素の制約違反のまま投げると「UNIQUE constraint failed: label.labelGroupId,
/// label.normalizedName」がそのまま画面に出る。**呼び出し側が次の一手を出せる
/// ようにする**——改名の衝突なら「代わりに統合しますか」を勧められる [LE-11]。
public enum LabelEditError: Error, Sendable, Hashable {
    /// 同じフィールドに、正規化後が同じ名前のラベルが既にある [LB-01][N-03]。
    case nameAlreadyExists(existing: LabelID, name: String)
    /// 別のラベルフィールドへは統合できない [LB-07]。
    case crossFieldMerge
    case labelNotFound(LabelID)
}

/// 1 ファイル 1 ラベルぶんの紐づけの変更 [RL-01][RL-07]。
///
/// **付いている／いないの 2 値**。「外した印」という第 3 の状態は保護スコープ
/// へ移った [PR-08] ので、Undo は行の有無だけを書き戻せばよい（変更前の状態を
/// 1 件ずつ持つ、という形は評価 [RA-06] と同じ）。
public struct LabelAssignmentChange: Sendable, Hashable {
    public let fileID: FileID
    /// `false` は紐づけを消す。
    public let isAssigned: Bool

    public init(fileID: FileID, isAssigned: Bool) {
        self.fileID = fileID
        self.isAssigned = isAssigned
    }
}

public protocol LabelRepository: Sendable {
    func fields(libraryID: LibraryID) async throws -> [FieldSummary]
    /// ラベルフィルタでの表示順 [LF-03][LG-07]。**ライブラリ単位の永続設定で
    /// 全ウインドウ共有** [ST-23]——ウインドウごとに違う順序で並ぶと、
    /// 同じライブラリを 2 枚開いたときにどちらが正しいか言えなくなる。
    ///
    /// 渡された順に 0 から振り直す。一覧に無いフィールドには触れない。
    func setFieldOrder(_ orderedIDs: [FieldID]) async throws
    func field(libraryID: LibraryID, index: Int) async throws -> FieldSummary?
    /// そのフィールドのラベルを、生きている実体の件数付きで返す [LF-04][LE-03]。
    ///
    /// **手動で非表示にしたものも含めて返す** [LA3-03]——出し分けは呼び出し側の
    /// 都合（フィルタは隠す [LA3-05]、フィールド編集は控えめに見せる）で、
    /// リポジトリはそれを知らない。判定は `LabelSummary.isVisible` にある。
    func labels(fieldID: FieldID) async throws -> [LabelSummary]
    /// 無ければ作る。一意性は `(fieldID, 正規化名)` [LB-01][N-03][LA-07]。
    func ensureLabel(fieldID: FieldID, name: String) async throws -> LabelID
    func assign(fileID: FileID, labelID: LabelID) async throws
    func unassign(fileID: FileID, labelID: LabelID) async throws
    /// 1 ファイルのラベルを、走査が導いた集合へ揃える [RC-01][PR-01]。
    ///
    /// **保護されたフィールド [PR-02] のラベルには触れない。** その判定は
    /// この関数の中で行う（`managedFile.protectedScopes` と `label.labelGroupId`
    /// を読む）——呼び出し側に渡させると、次に足す呼び出し元が忘れる。
    func replaceAutoLabels(fileID: FileID, labelIDs: Set<LabelID>) async throws
    /// 1 ファイルの紐づけを、指定した集合へちょうど揃える。
    ///
    /// **保護を見ない**——⌘Z は「元の状態へちょうど戻す」ことなので、いまの
    /// 保護に左右されてはならない（`replaceAutoLabels` との違いはそこだけ）。
    func setLabels(fileID: FileID, labelIDs: Set<LabelID>) async throws
    func labelIDs(fileID: FileID) async throws -> [LabelID]
    /// 複数ファイルの紐づけを 1 度に読む [RL-04][RP-02]。
    ///
    /// 1 件ずつ引くと、選択したファイルの数だけ読み取りトランザクションが
    /// 開く。右ペインは選択が変わるたびに読み直すので、そこは 1 回で済ませる。
    func assignments(fileIDs: [FileID]) async throws -> [FileID: Set<LabelID>]
    /// 1 つのラベルの紐づけを、ファイルごとに指定した状態へ揃える [RL-01][RL-07]。
    ///
    /// **1 トランザクションで書く** [RP2-04]——一括付与の途中で失敗したときに、
    /// 半分だけ付いた状態を残さない。`AssignLabelCommand` の `execute()` と
    /// `undo()` がどちらもこれを使う（戻すのも「指定した状態へ揃える」ことに
    /// 他ならないので、復元のための別 API を作らない）。
    /// **保護スコープも同じトランザクションで書く** [PR-03]（`setFields` と
    /// 同じ理由）。ファイルごとに違う集合を渡せる——⌘Z は 1 件ずつ元の集合へ
    /// 戻す。
    func applyAssignments(labelID: LabelID, _ changes: [LabelAssignmentChange],
                          protectedScopes: [FileID: Set<ProtectionScope>]) async throws
    /// 2 つのラベルを統合する [LB-07][LE-11]。`source` の行は消え、紐づけは
    /// `target` へ移る。
    ///
    /// 同じファイルに両方が付いていたら 1 行に畳む。**紐づけは付いている／
    /// いないの 2 値**になったので、どちらを残すかを決める規則は要らない
    /// （保護は紐づけではなくフィールド単位に付く [PR-02]）。
    ///
    /// **別フィールドへは統合できない** [LB-07]——ラベルの一意性はフィールド内で
    /// 定義されており [LB-01]、またぐと「フィールドを移す」という別の操作になる。
    func merge(_ source: LabelID, into target: LabelID) async throws           // [LB-07]
    /// 改名 [LB-06]。紐づけは維持される（行の ID が変わらないため何もしなくてよい）。
    ///
    /// 同じフィールドに正規化後が同じ名前があれば `LabelEditError.nameAlreadyExists`。
    /// **素の UNIQUE 制約違反を投げない**——呼び出し側が「代わりに統合」を
    /// 勧められるよう、衝突相手の ID を添えて返す [LE-11]。
    func rename(_ id: LabelID, to name: String) async throws                   // [LB-06]
    /// 手動での非表示の切り替え [LA3-02]。**「保管庫」ではない**——実体が
    /// 無いことによる非表示は導出なので、この印は「実体があるのに出したくない」
    /// ラベルにしか使わない。
    func setHidden(_ ids: [LabelID], _ hidden: Bool) async throws              // [LA3-02]
    func setPinned(_ id: LabelID, _ pinned: Bool) async throws                 // [LB-03]
    /// ラベル固有色 [LE-10][CO-06]。`nil` へ戻すとフィールド色を継承する。
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
    /// 別の意味を持つ API を作らない。
    func restore(_ snapshots: [LabelSnapshot]) async throws
}

// MARK: - シェルフ [SH-01〜SH-12]

/// 保存した絞り込み [19章 §19.2]。**ライブラリ単位の永続設定で全ウインドウ共有**
/// [ST-23]——ピン留め [PN-04] やフィールドの並び順 [LG-07] と同じ扱い。
public protocol ShelfRepository: Sendable {
    /// 並び順で返す [SH-10]。
    func shelves(libraryID: LibraryID) async throws -> [ShelfSummary]
    /// 末尾へ足す [SH-01]。**名前の一意性は要求しない** [SH-03]——同名を
    /// 拒むと「自分自身と衝突する」判定を書くことになり、そこは先行実装
    /// （Calibre の保存済み検索）が実際に壊した箇所である。並びで区別できる。
    func create(libraryID: LibraryID, name: String,
                condition: ShelfCondition) async throws -> ShelfID
    /// 上書き保存 [SH-04]。条件だけを差し替える（名前と並びは動かさない）。
    func updateCondition(_ id: ShelfID, _ condition: ShelfCondition) async throws
    func rename(_ id: ShelfID, to name: String) async throws                  // [SH-03]
    func delete(_ ids: [ShelfID]) async throws                                // [SH-02]
    /// 渡された順に 0 から振り直す [SH-10]。一覧に無い行には触れない。
    func setOrder(_ orderedIDs: [ShelfID]) async throws
    /// 削除の Undo 用。**行 ID ごと控える** [SH-11]。
    func snapshot(ids: [ShelfID]) async throws -> [ShelfSummary]
    /// 写しを**同じ行 ID で**作り直す [SH-11]。`shelf.id` は AUTOINCREMENT で
    /// 再利用されないので成り立つ（`LabelSnapshot` の復元と同じ）。
    func restore(_ shelves: [ShelfSummary]) async throws
}
