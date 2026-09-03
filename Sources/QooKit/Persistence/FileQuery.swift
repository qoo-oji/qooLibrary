//
//  一覧の問い合わせ [7.5][RP2-03]。
//
//  **SQL を引数に取る API を作らない** [A-02]。永続化の実装を差し替えられるよう、
//  ここでは抽象的な条件だけを表す。
//
import Foundation

public struct FileQuery: Sendable, Hashable {
    public enum Scope: Sendable, Hashable {
        /// 特定フォルダ（`relativePath` のディレクトリ部分）。
        case folder(path: String, recursive: Bool)
        case library
    }

    /// フォルダ表示モード / ライブラリ表示モード [VM-01]。
    public enum DisplayMode: String, Sendable, Hashable, Codable { case folder, libraryFlat }

    public enum SortKey: String, Sendable, Hashable, CaseIterable, Codable {
        case filename, title, series, volume, fileSize, createdAt, modifiedAt, rating
    }

    public struct SortSpec: Sendable, Hashable, Codable {
        public let key: SortKey
        public let ascending: Bool
        public init(key: SortKey, ascending: Bool = true) {
            self.key = key
            self.ascending = ascending
        }
        public static let byFilename = SortSpec(key: .filename)
    }

    /// 評価フィルタ [RT-01][RT-03]。
    ///
    /// **「選んだ星以上」と「星と完全一致」を切り替えられること**が要件 [RT-03]。
    /// 以前は `minimum` と `unratedOnly` の 2 つで表していたが、その形では
    /// 「星 3 ちょうど」を書けない——`unratedOnly` は `.exact` の星 0 として
    /// 吸収した（`rating` 列は未評価を 0 で持つ）。
    public struct RatingFilter: Sendable, Hashable, Codable {
        public enum Mode: String, Sendable, Hashable, CaseIterable, Codable {
            case atLeast
            case exact
        }

        /// 0〜5 [RT-01]。**`init` で丸める**——範囲外を弾かずに黙って
        /// 通すと、`rating >= 9` のような決して一致しない条件が
        /// 「フィルタが壊れている」ようにしか見えない形で表に出る。
        public let stars: Int
        public let mode: Mode

        public init(stars: Int, mode: Mode = .atLeast) {
            self.stars = max(0, min(5, stars))
            self.mode = mode
        }

        /// 未評価だけを見る。
        public static let unrated = RatingFilter(stars: 0, mode: .exact)

        /// **合成された `init(from:)` を使わない** [SH-06]。あちらは `let` へ
        /// 直に代入するので、上の `init` が持つ丸めを素通りする——シェルフの
        /// 条件は DB と JSON バックアップの両方を往復するため、壊れた文書や
        /// 手で編集された JSON から `stars = 9` のような決して一致しない
        /// 条件が入り込む余地を残さない。
        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.init(stars: try c.decode(Int.self, forKey: .stars),
                      mode: try c.decode(Mode.self, forKey: .mode))
        }
    }

    /// 未整理のファイルだけに絞る [UR3-01][UR3-05]。
    ///
    /// **未整理 ＝ `unresolvedFile` の記録が残っているファイル**（ファイル名が
    /// どのフォーマットにも一致しなかったもの [AL-30〜34]）。ステージ 4 で
    /// 専用ウインドウを廃し、**中央ペインの通常の一覧**として出せるように
    /// した [UR3-02]——リネーム・Quick Look・ラベル付けといった普段の操作が
    /// そのまま使えることがこの機能の要点だったのに、専用ウインドウはそれを
    /// 妨げていた。
    public enum UnresolvedFilter: String, Sendable, Hashable, CaseIterable {
        /// 片付ける対象だけ。**「以後無視する」[AL-33] としたものは含めない**
        /// ——これが既定の見え方で、件数もこちらで数える。
        case pending
        /// 「無視したものも表示」。**空になった理由を取り違えないため**に要る
        /// ——全部無視しただけなのに「すべて一致しています」と出ると嘘になる
        /// ［§15.6 の実機検証で見つけた形］。
        case includingIgnored
    }

    public var libraryID: LibraryID
    public var scope: Scope
    public var mode: DisplayMode
    /// グループ内 OR × グループ間 AND [LF-08〜LF-10]。
    public var labelSelection: [FieldID: Set<LabelID>]
    public var ratingFilter: RatingFilter?
    public var searchText: String?
    public var includeArchived: Bool
    /// **`grouping` が `.off` のときは効かない**——グループが無ければ
    /// 「重複」も定義できないため [DU-11]。
    public var duplicatesOnly: Bool          // [DU-11]
    /// `nil` なら絞らない [UR3-01]。
    public var unresolvedFilter: UnresolvedFilter?
    /// 同じ作品のファイルを 1 行に畳むか [DU-01][DU-02]。
    ///
    /// **ライブラリ表示モードでしか効かせない** [DU-04]——呼び出し側が
    /// `.folder` のときは `.off` を渡すこと。フォルダ表示モードは実体の
    /// 一覧なので、畳むと「ディスクにある物と画面が食い違う」ことになる。
    public var grouping: DuplicateGrouping   // [DU-01][DU-04]
    public var sort: SortSpec
    public var offset: Int
    /// 遅延読み込み [PF-10]。**全件を materialize しない** [FI-05]。
    public var limit: Int

    public init(libraryID: LibraryID,
                scope: Scope = .library,
                mode: DisplayMode = .folder,
                labelSelection: [FieldID: Set<LabelID>] = [:],
                ratingFilter: RatingFilter? = nil,
                searchText: String? = nil,
                includeArchived: Bool = false,
                duplicatesOnly: Bool = false,
                unresolvedFilter: UnresolvedFilter? = nil,
                grouping: DuplicateGrouping = .off,
                sort: SortSpec = .byFilename,
                offset: Int = 0,
                limit: Int = AppLimits.Query.defaultPageSize) {
        self.libraryID = libraryID
        self.scope = scope
        self.mode = mode
        self.labelSelection = labelSelection
        self.ratingFilter = ratingFilter
        self.searchText = searchText
        self.includeArchived = includeArchived
        self.duplicatesOnly = duplicatesOnly
        self.unresolvedFilter = unresolvedFilter
        self.grouping = grouping
        self.sort = sort
        self.offset = offset
        self.limit = limit
    }
}
