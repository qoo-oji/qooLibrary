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
    public enum DisplayMode: String, Sendable, Hashable { case folder, libraryFlat }

    public enum SortKey: String, Sendable, Hashable, CaseIterable {
        case filename, title, series, volume, fileSize, createdAt, modifiedAt, rating
    }

    public struct SortSpec: Sendable, Hashable {
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
    public struct RatingFilter: Sendable, Hashable {
        public enum Mode: String, Sendable, Hashable, CaseIterable {
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
    }

    public var libraryID: LibraryID
    public var scope: Scope
    public var mode: DisplayMode
    /// グループ内 OR × グループ間 AND [LF-08〜LF-10]。
    public var labelSelection: [LabelGroupID: Set<LabelID>]
    public var ratingFilter: RatingFilter?
    public var searchText: String?
    public var includeArchived: Bool
    public var duplicatesOnly: Bool          // [DU-11]
    public var sort: SortSpec
    public var offset: Int
    /// 遅延読み込み [PF-10]。**全件を materialize しない** [FI-05]。
    public var limit: Int

    public init(libraryID: LibraryID,
                scope: Scope = .library,
                mode: DisplayMode = .folder,
                labelSelection: [LabelGroupID: Set<LabelID>] = [:],
                ratingFilter: RatingFilter? = nil,
                searchText: String? = nil,
                includeArchived: Bool = false,
                duplicatesOnly: Bool = false,
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
        self.sort = sort
        self.offset = offset
        self.limit = limit
    }
}
