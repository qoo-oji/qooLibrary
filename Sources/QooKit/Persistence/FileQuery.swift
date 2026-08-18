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
    public struct RatingFilter: Sendable, Hashable {
        public let minimum: Int
        /// `true` = 未評価（0）だけを見る。
        public let unratedOnly: Bool
        public init(minimum: Int, unratedOnly: Bool = false) {
            self.minimum = minimum
            self.unratedOnly = unratedOnly
        }
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
