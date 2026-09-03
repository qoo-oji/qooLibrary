//
//  ライブラリ表示モードの一覧 [VM-10〜VM-16][LV-04][IV-05][IV-07][FI-05]。
//
//  **フォルダ表示モードとは一覧の源が逆**である。フォルダ表示モードは実体の
//  一覧を `LabelFilterModel.allowedChildNames` で絞る——すべてのファイル操作が
//  可能でなければならず [VM-03]、フィルタ全 OFF なら DB に載っていないもの
//  （対象拡張子外）も見える必要がある [VM-01] ため。ライブラリ表示モードは
//  逆に、対象拡張子ファイルとブックフォルダだけをフラットに出す [VM-10] ので、
//  **DB の行そのものが一覧の源**になる。
//
//  ここを `QooApplication` に置いているのは `LabelFilterModel` と同じ理由——
//  アプリターゲット（`qooLibraryApp`）のコードは `swift test` から触れない。
//  判定（どの行を出すか・どう並べるか・次を読むべきか）はこの層に置き、View は
//  受け取った行を描くだけにする。
//
import Foundation
import Observation
import QooInfrastructure
import QooKit

/// 中央ペインがライブラリ表示モードで描く一覧。`WindowState` が 1 つ持つ
/// （**ウインドウ固有** [ST-20][ST-22]——同じライブラリを 2 枚開けば別々に
/// 並べ替えられる）。
@MainActor
@Observable
public final class LibraryContentModel {
    /// 一覧の状態。**空と失敗を取り違えない** [ER-01]——問い合わせに失敗した
    /// ときに黙って 0 件を見せると、「このフォルダには 1 冊も無い」と読めて
    /// しまう。
    public enum State: Sendable, Equatable {
        /// ライブラリ表示モードではない／ライブラリの外／DB が未準備。
        case inactive
        case loading
        case ready
        case failed(String)
    }

    /// 一覧の 1 行。`FileRow` に、描くのに要る 2 つ（実体の URL と表示名）を
    /// 添えたもの。
    ///
    /// **URL を持たせているのは選択・操作のため**——選択 [`WindowState.selection`]
    /// も右ペイン [`LibraryServices.fileRow(at:in:)`] もリネーム・削除も URL を
    /// 単位にしており、ライブラリ表示モードだけ別の単位にすると経路が二重になる。
    public struct Row: Sendable, Hashable, Identifiable {
        public let file: FileRow
        public let url: URL
        /// ユーザー指定カバーの複製の場所 [IV-02①][CV-06]。`coverImageSource`
        /// が `.userSpecified` のときだけ入る。
        ///
        /// **実体があるかは見ていない**——存在確認は I/O なので、実際に描く
        /// ときに `CoverResolution` がサイドカーの探索とまとめて 1 回で行う。
        /// ここで持つのは**パスの組み立てだけ**（`UserCoverStore.url(forRef:)`
        /// は純粋な計算）なので、200 行ぶん作っても費用が無い。
        public let userCoverURL: URL?
        /// この行が代表している組の件数 [DU-06]。**1 は「重複していない」**。
        /// バッジを出すかどうかはこの値だけで決まる。
        public let duplicateCount: Int
        public var id: URL { url }

        /// 重複の組を代表しているか [DU-06][DU-12]。
        public var isDuplicateRepresentative: Bool { duplicateCount > 1 }

        public init(file: FileRow, url: URL, userCoverURL: URL? = nil,
                    duplicateCount: Int = 1) {
            self.file = file
            self.url = url
            self.userCoverURL = userCoverURL
            self.duplicateCount = duplicateCount
        }

        /// 一覧に出す名前 [IV-05][IV-07]。
        public var displayName: String { LibraryContentModel.displayName(for: file) }
    }

    public private(set) var state: State = .inactive
    public private(set) var rows: [Row] = []
    /// 絞り込み後の総数 [LF-11]。`rows.count` は読み込んだぶんだけなので別に持つ。
    public private(set) var totalCount = 0
    /// 追加ページを読んでいる最中か。**二重に要求しないための番人**——末尾の行は
    /// スクロールのたびに何度も現れる。
    public private(set) var isLoadingMore = false
    /// 続きを読むのに失敗した理由。**一覧そのものは残す**——読み込み済みの
    /// 行を隠すより、そこまでを見せて再試行できるほうが害が小さい。
    public private(set) var loadMoreFailure: String?

    /// まだ読んでいない行があるか [FI-05]。
    public var hasMore: Bool { rows.count < totalCount }

    /// 並べ替え [VM-15]。**SQL の `ORDER BY` に委ねる**——メモリ上で並べ替えると
    /// 「読み込んだ 200 件の中だけが正しく並ぶ」ことになり、ページングと両立しない。
    public private(set) var sort: FileQuery.SortSpec = .byFilename

    /// 直近の問い合わせ。追加ページ [FI-05] は同じ条件の `offset` 違いで問う。
    private var activeQuery: FileQuery?

    /// 世代。**古い結果を捨てるため**に要る [中央ペインの再帰検索と同じ形]——
    /// 条件が変わっても走っている問い合わせは止まらないので、番号が合わない
    /// 結果は無視する。合わせないと、絞り込みを外した直後に古い（絞られた）
    /// 一覧が上書きしてくる。
    private var generation = 0

    public init() {}

    // MARK: - 読み込み

    /// 一覧を先頭ページから読み直す [VM-10〜VM-12]。
    ///
    /// - Parameters:
    ///   - library: 表示中のライブラリ。`nil` なら `.inactive` にして空にする。
    ///   - relativePath: ライブラリの根から見た現在フォルダ [VM-11]。根なら `""`。
    ///   - labelSelection: グループ内 OR × グループ間 AND [LF-08〜LF-10]。
    ///   - ratingFilter: 評価フィルタ [RT-01〜RT-03]。
    ///   - searchText: 名前での絞り込み [SR-01〜SR-03]。
    public func load(library: LibrarySummary?,
                     relativePath: String?,
                     labelSelection: [FieldID: Set<LabelID>] = [:],
                     ratingFilter: FileQuery.RatingFilter? = nil,
                     searchText: String? = nil,
                     services: LibraryServices) async {
        guard let library, let relativePath else {
            clear()
            return
        }
        // グループ化の可否は**ライブラリの設定**が決める [DU-01][DU-02]。
        // `clear()` で戻さずここで毎回入れ直すのは、設定ウインドウで変えた
        // 直後の読み直しでも新しい値が効くようにするため（`settingsRevision`
        // が上がると呼び出し側が読み直す）。
        grouping = library.duplicateGrouping
        // 畳んでいないのに「重複のみ」は意味を持たない [DU-11]。
        let onlyDuplicates = grouping.isEnabled && duplicatesOnly
        let query = Self.makeQuery(libraryID: library.id,
                                   relativePath: relativePath,
                                   labelSelection: labelSelection,
                                   ratingFilter: ratingFilter,
                                   searchText: searchText,
                                   sort: sort,
                                   offset: 0,
                                   grouping: grouping,
                                   duplicatesOnly: onlyDuplicates,
                                   unresolvedFilter: unresolvedFilter)
        generation &+= 1
        let mine = generation
        activeQuery = query
        state = .loading
        isLoadingMore = false
        do {
            let page = try await services.files(query)
            guard mine == generation else { return }
            rows = Self.rows(from: page.rows, libraryRootPath: library.resolvedPath,
                             userCoverURL: { services.userCoverURL(ref: $0, library: library) },
                             duplicateCounts: page.duplicateCounts)
            totalCount = page.totalCount
            state = .ready
        } catch {
            guard mine == generation else { return }
            // **取り消しは失敗ではない**（他のインスペクタのモデルと同じ扱い）。
            // 世代の照合を通っても、`.task(id:)` の取り消しはここへ来る。
            guard !CommandStack.isCancellation(error) else { return }
            rows = []
            totalCount = 0
            state = .failed(error.localizedDescription)
        }
    }

    /// 続きを読む [FI-05][PF-10]。一覧の末尾が見えたときに呼ぶ。
    ///
    /// **何度呼ばれても安全**にしてある——末尾の行はスクロールのたびに現れるし、
    /// リストとアイコンの両方から呼ばれる。
    public func loadNextPage(library: LibrarySummary, services: LibraryServices) async {
        guard case .ready = state, hasMore, !isLoadingMore,
              var query = activeQuery else { return }
        query.offset = rows.count
        isLoadingMore = true
        loadMoreFailure = nil
        let mine = generation
        defer { if mine == generation { isLoadingMore = false } }
        do {
            let page = try await services.files(query)
            guard mine == generation else { return }
            // **`totalCount` も更新する**——読んでいる最中に走査が行を足す／
            // 減らすことがあり、古い総数のままだと「もう無いのに読み続ける」か
            // 「まだあるのに止まる」のどちらかになる。
            totalCount = page.totalCount
            let more = Self.rows(from: page.rows, libraryRootPath: library.resolvedPath,
                                 userCoverURL: { services.userCoverURL(ref: $0, library: library) },
                                 duplicateCounts: page.duplicateCounts)
            // 同じ行が二度入らないようにする。ページの境目で走査が行を挿すと
            // `offset` がずれて重複し得る（`Identifiable` の id が衝突すると
            // SwiftUI が実行時に文句を言う）。
            let known = Set(rows.map(\.url))
            rows.append(contentsOf: more.filter { !known.contains($0.url) })
        } catch {
            guard mine == generation else { return }
            guard !CommandStack.isCancellation(error) else { return }
            // **すでに読んだ行は捨てない** [code-review 指摘]。ここで
            // `.failed` にすると、200 件が画面から消えて「1 冊も無い」ように
            // 見えるうえ、`hasMore` の経路も塞がって二度と続きを読めなくなる。
            // 末尾の行が再び現れれば `.onAppear` から自然に再試行される。
            loadMoreFailure = error.localizedDescription
            Log.app.warning("ライブラリ一覧の続きを読めなかった: \(String(describing: error))")
        }
    }

    /// 並べ替えを変える [VM-15]。呼び出し側は続けて ``load(library:relativePath:labelSelection:ratingFilter:searchText:services:)``
    /// を呼ぶこと（`ORDER BY` が変わるので先頭から読み直す必要がある）。
    public func setSort(_ spec: FileQuery.SortSpec) {
        sort = spec
    }

    /// 「重複のみを表示」[DU-11]。**ウインドウ固有の表示状態** [ST-20] なので
    /// DB には保存しない——別のウインドウで同じライブラリを開いたときに
    /// 巻き込まれない。
    public private(set) var duplicatesOnly = false

    public func setDuplicatesOnly(_ on: Bool) {
        duplicatesOnly = on
    }

    /// 未整理のファイルだけを出す [UR3-01][UR3-02]。**ウインドウ固有の表示
    /// 状態** [ST-20]——`duplicatesOnly` と同じ扱いで DB には保存しない。
    ///
    /// **これは絞り込みであって別の一覧ではない**のが要点。同じ
    /// `LibraryContentModel` の経路に乗るので、行の描き方も選択もファイル操作も
    /// 通常のライブラリ表示とまったく同じものが使える [UR3-02]——専用ウインドウ
    /// （旧 §15.6）はそこを妨げていた。
    public private(set) var unresolvedFilter: FileQuery.UnresolvedFilter?

    /// 未整理ビューを見ているか。救済アクションの出し分けに使う [UR3-03]。
    public var showsUnresolvedOnly: Bool { unresolvedFilter != nil }

    public func setUnresolvedFilter(_ filter: FileQuery.UnresolvedFilter?) {
        unresolvedFilter = filter
    }

    /// 一覧がいま組を畳んでいるか [DU-04]。
    /// バッジ・コンテキストメニューの出し分けはこれを見る。
    public private(set) var grouping: DuplicateGrouping = .off

    /// 一覧を捨てて `.inactive` に戻す。モードをフォルダ側へ切り替えたとき、
    /// ライブラリの外へ出たときに呼ぶ。
    public func clear() {
        generation &+= 1
        activeQuery = nil
        rows = []
        totalCount = 0
        isLoadingMore = false
        // **モードも戻す** [DU-04]。残したままだとフォルダ表示モードの
        // 空きスペースに「重複のみを表示」が出続け、そこで切り替えた値が
        // ライブラリ表示へ戻ったときに黙って一覧を絞る。
        grouping = .off
        // **未整理ビューも解く** [UR3-01]。残したままだと、ライブラリの外へ
        // 出て戻ってきたときに一覧が黙って絞られたままになる（`grouping` を
        // 戻しているのと同じ理由）。
        unresolvedFilter = nil
        state = .inactive
    }

    // MARK: - 組み立て（純粋関数）

    /// 問い合わせの組み立て [VM-10〜VM-12]。
    ///
    /// **`scope` は必ず `recursive: true`** [VM-10]——ライブラリ表示モードは
    /// 現在フォルダ**配下**をフラットに出すものなので、直下だけに絞ると
    /// サブフォルダの中の本が 1 冊も出ない。範囲を現在フォルダに限る
    /// [VM-11] のは `path` のほうが担う。
    nonisolated public static func makeQuery(libraryID: LibraryID,
                                 relativePath: String,
                                 labelSelection: [FieldID: Set<LabelID>],
                                 ratingFilter: FileQuery.RatingFilter?,
                                 searchText: String?,
                                 sort: FileQuery.SortSpec,
                                 offset: Int,
                                 grouping: DuplicateGrouping = .off,
                                 duplicatesOnly: Bool = false,
                                 unresolvedFilter: FileQuery.UnresolvedFilter? = nil) -> FileQuery {
        let text = searchText?.trimmingCharacters(in: .whitespacesAndNewlines)
        return FileQuery(
            libraryID: libraryID,
            scope: .folder(path: relativePath, recursive: true),
            mode: .libraryFlat,
            labelSelection: labelSelection,
            ratingFilter: ratingFilter,
            searchText: (text?.isEmpty == false) ? text : nil,
            duplicatesOnly: duplicatesOnly,
            unresolvedFilter: unresolvedFilter,
            grouping: grouping,
            sort: sort,
            offset: offset,
            limit: AppLimits.Query.defaultPageSize)
    }

    /// 一覧の**表示順で**最初に選ばれている行 [VM-22]。
    ///
    /// **`Set` の側から取ってはならない**——`selection` は順序を持たないので、
    /// 「複数選択なら先頭ファイルのフォルダを対象」[VM-22] が実行のたびに
    /// 変わる。一覧の側から引けば、画面で一番上に見えているものになる
    /// （一括リネームの連番が表示順に振られていなかった件と同じ形の間違い）。
    nonisolated public static func firstSelected(in rows: [Row],
                                                 selection: Set<URL>) -> Row? {
        rows.first { selection.contains($0.url) }
    }

    /// 一覧に出す名前 [IV-05][IV-07]。**タイトルが無ければファイル名へ落とす**
    /// ——空白だけのタイトルも「無い」として扱う（DB には手動編集で空白だけの
    /// 値が入り得るし、それを表示すると行が消えたように見える）。
    ///
    /// **判定はここ 1 箇所**。中央ペインの行（`FolderEntry`）もこれを呼ぶ
    /// ——同じ「タイトルかファイル名か」を 2 箇所で書くと、片方だけ直したときに
    /// 一覧とインスペクタで違う名前が出る。
    nonisolated public static func displayName(for file: FileRow) -> String {
        guard let title = file.title?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else { return file.filename }
        return title
    }

    /// DB の行を一覧の行にする。
    ///
    /// **`isDirectory` はブックフォルダかどうかで決める** [IF-10]——ブックフォルダは
    /// 実体がディレクトリだが `managedFile` の 1 行として 1 冊分を表す。
    nonisolated static func rows(from files: [FileRow], libraryRootPath: String,
                                 userCoverURL: (String) -> URL?,
                                 duplicateCounts: [FileID: Int] = [:]) -> [Row] {
        let root = URL(fileURLWithPath: libraryRootPath, isDirectory: true)
        return files.map { file in
            Row(file: file,
                url: root.appendingPathComponent(file.relativePath,
                                                 isDirectory: file.isBookFolder),
                // [IV-02①] 参照があるときだけ場所を組み立てる。I/O は無い。
                userCoverURL: file.coverImageSource == .userSpecified
                    ? file.coverImageRef.flatMap(userCoverURL) : nil,
                duplicateCount: duplicateCounts[file.id] ?? 1)
        }
    }
}
