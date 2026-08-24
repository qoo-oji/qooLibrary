//
//  スキャンが 1 ファイルについて観測した内容 [10.3][ID-01〜ID-08]。
//
//  `QooKit` は Foundation にしか依存しないので、この型が永続化層とスキャンの
//  あいだの共通語になる [A-01][A-02]。
//
import Foundation

public struct FileSnapshot: Sendable, Hashable {
    /// 同一性キー [ID-01]。
    public let identity: FileIdentity
    public let libraryID: LibraryID
    /// ライブラリ根からの相対パス（ファイル名を含む）。
    public let relativePath: String
    public let filename: String
    public let fileSize: Int64
    public let createdAt: Date
    public let modifiedAt: Date
    /// ブックフォルダとして 1 冊に数えるか [IF-01][IF-04]。
    public let isBookFolder: Bool

    public init(identity: FileIdentity, libraryID: LibraryID, relativePath: String,
                filename: String, fileSize: Int64, createdAt: Date, modifiedAt: Date,
                isBookFolder: Bool = false) {
        self.identity = identity
        self.libraryID = libraryID
        self.relativePath = relativePath
        self.filename = filename
        self.fileSize = fileSize
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.isBookFolder = isBookFolder
    }

    /// 拡張子を除いたファイル名。パーサへ渡す値。
    public var nameWithoutExtension: String {
        (filename as NSString).deletingPathExtension
    }
}

public enum FileState: String, Sendable, Codable, Hashable, CaseIterable {
    case active, trashed, orphaned, offline
}

public enum ValueOrigin: String, Sendable, Codable, Hashable { case auto, manual }

public enum CoverSource: String, Sendable, Codable, Hashable { case auto, sidecar, userSpecified }

/// `.manuallyRemoved` を明示的に持つことで「再計算で復活させてはいけない」を
/// 表現する [RC-04]。
public enum LabelOrigin: String, Sendable, Codable, Hashable, CaseIterable {
    case auto, manual, manuallyRemoved

    /// 統合したとき、同じファイルに付いていた 2 つのラベルの `origin` から
    /// 残すほうを決める [LB-07][LE-11]［ユーザー判断］。
    ///
    /// **manual > auto > manuallyRemoved。** 統合は「同じものに 2 つの名前が
    /// 付いていた」を是正する操作なので、どちらかで手で付けていたなら手動として
    /// 残す。素朴に移動先を優先すると、`source` が `manual`・`target` が
    /// `manuallyRemoved` のファイルで**手動付与が黙って消える**——しかも
    /// 件数を見ても気づけない。
    ///
    /// 逆に「統合したのだから一律 `manual`」にはしない。自動付与されたラベルを
    /// まとめただけで再スキャン耐性が変わってしまい（`auto` は再計算で更新されるが
    /// `manual` は守られる [RC-04]）、`manuallyRemoved` の印まで消えて**外した
    /// はずのラベルが復活する**。
    ///
    /// **この 1 行が決定の実体**なので、SQL にも View にも埋めずここに置く
    /// （`LabelEditorModel.candidates` と同じ理由）。
    public static func merging(_ a: LabelOrigin, _ b: LabelOrigin) -> LabelOrigin {
        rank(a) >= rank(b) ? a : b
    }

    private static func rank(_ origin: LabelOrigin) -> Int {
        switch origin {
        case .manual: 2
        case .auto: 1
        case .manuallyRemoved: 0
        }
    }
}

/// 一覧に表示する 1 行 [RP2-02]。`Sendable` な値型で、DB の行そのものではない。
public struct FileRow: Sendable, Hashable, Identifiable {
    public let id: FileID
    public let libraryID: LibraryID
    public let relativePath: String
    public let filename: String
    public let fileSize: Int64
    public let createdAt: Date
    public let modifiedAt: Date
    public let title: String?
    /// タイトルが手動編集されたか [RP-11]。`.manual` の値は再スキャンでも
    /// 埋め込みメタデータでも上書きされない（`applyParsedFields` の SQL が守る）。
    public let titleOrigin: ValueOrigin
    public let seriesName: String?
    public let volume: VolumeValue
    public let authorName: String?
    public let rating: Int
    /// ユーザー指定カバーの複製の名前 [CV-06]。`coverImageSource == .userSpecified`
    /// のときだけ意味を持つ。**複製そのもののパスではない**——置き場所は
    /// `UserCoverStore` が決めるので、DB は参照だけを持つ [CL-05]。
    public let coverImageRef: String?
    public let coverImageSource: CoverSource
    public let state: FileState
    public let isArchived: Bool
    public let isBookFolder: Bool

    public init(id: FileID, libraryID: LibraryID, relativePath: String, filename: String,
                fileSize: Int64, createdAt: Date, modifiedAt: Date, title: String?,
                titleOrigin: ValueOrigin = .auto,
                seriesName: String?, volume: VolumeValue, authorName: String? = nil,
                rating: Int,
                coverImageRef: String? = nil, coverImageSource: CoverSource = .auto,
                state: FileState,
                isArchived: Bool, isBookFolder: Bool) {
        self.id = id
        self.libraryID = libraryID
        self.relativePath = relativePath
        self.filename = filename
        self.fileSize = fileSize
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.title = title
        self.titleOrigin = titleOrigin
        self.seriesName = seriesName
        self.volume = volume
        self.authorName = authorName
        self.rating = rating
        self.coverImageRef = coverImageRef
        self.coverImageSource = coverImageSource
        self.state = state
        self.isArchived = isArchived
        self.isBookFolder = isBookFolder
    }
}

/// ページと総件数を一度に返す。総件数を毎回数え直さないため。
public struct FilePage: Sendable {
    public let rows: [FileRow]
    public let totalCount: Int

    public init(rows: [FileRow], totalCount: Int) {
        self.rows = rows
        self.totalCount = totalCount
    }
}

/// 再照合の候補 [ID-03][ID-05]。
public struct ReidentificationCandidate: Sendable, Hashable {
    public enum Confidence: Sendable, Hashable, Comparable {
        /// 同一相対パス + 同一サイズ [ID-03]①
        case pathAndSize
        /// 同一ファイル名 + 同一サイズ [ID-03]②
        case nameAndSize
        /// 同一ファイル名のみ [ID-03]③ — **自動では紐づけない** [ID-05]
        case nameOnly
    }

    public let fileID: FileID
    public let confidence: Confidence
    public let relativePath: String
    public let filename: String

    public init(fileID: FileID, confidence: Confidence, relativePath: String, filename: String) {
        self.fileID = fileID
        self.confidence = confidence
        self.relativePath = relativePath
        self.filename = filename
    }
}
