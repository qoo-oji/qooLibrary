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
    public var nameWithoutExtension: String { FilenameStem.of(filename) }

    /// 保管庫の中にあるか [FA-05][SY-10]。**相対パスから導く**——観測した
    /// 実体の位置が真実なので、初期化子の引数として受け取らない（食い違った
    /// スナップショットを作れる余地を残さない）。外部（Finder 等）で
    /// `.qooarchive` へ出し入れされた場合も、次の走査でこの値が追随する。
    public var isArchived: Bool { VaultPath.isInside(relativePath) }
}

public enum FileState: String, Sendable, Codable, Hashable, CaseIterable {
    case active, trashed, orphaned, offline
}

public enum CoverSource: String, Sendable, Codable, Hashable { case auto, sidecar, userSpecified }

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
    /// 自動更新から守られているスコープ [PR-01][PR-02]。走査はここに含まれる
    /// ものに触れない。**基本情報（タイトル・シリーズ・巻・著者）は `.basic`
    /// の 1 つで表す**——置き換える前の印はタイトルだけを守っており、手で
    /// 直したシリーズ名は次の走査で黙って自動値へ戻っていた。
    public let protectedScopes: Set<ProtectionScope>
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
    /// 保管庫へ移す前の相対パス [FA-04]。右ペインの表示 [DT-11] と、
    /// 戻す先の決定 [FA-07] に使う。外部で `.qooarchive` へ入れられたものは
    /// 記録が無いので `nil`——そのときは `VaultPath.original` が導く [FA-03]。
    public let archivedFromPath: String?
    /// 保管庫へ移した日時 [FAW-05]。
    public let archivedAt: Date?
    public let isBookFolder: Bool
    /// ページ数（画像ファイル数）[DU-21]。アーカイブを開かないと分からないので
    /// **遅延取得**し、`nil` は「まだ数えていない」を意味する [DU-22][MD-01]。
    public let pageCount: Int?
    /// 先頭画像の解像度 [DU-21]。`pageCount` と同じく遅延取得。
    public let firstImageWidth: Int?
    public let firstImageHeight: Int?

    public init(id: FileID, libraryID: LibraryID, relativePath: String, filename: String,
                fileSize: Int64, createdAt: Date, modifiedAt: Date, title: String?,
                protectedScopes: Set<ProtectionScope> = [],
                seriesName: String?, volume: VolumeValue, authorName: String? = nil,
                rating: Int,
                coverImageRef: String? = nil, coverImageSource: CoverSource = .auto,
                state: FileState,
                isArchived: Bool,
                archivedFromPath: String? = nil, archivedAt: Date? = nil,
                isBookFolder: Bool,
                pageCount: Int? = nil,
                firstImageWidth: Int? = nil, firstImageHeight: Int? = nil) {
        self.id = id
        self.libraryID = libraryID
        self.relativePath = relativePath
        self.filename = filename
        self.fileSize = fileSize
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.title = title
        self.protectedScopes = protectedScopes
        self.seriesName = seriesName
        self.volume = volume
        self.authorName = authorName
        self.rating = rating
        self.coverImageRef = coverImageRef
        self.coverImageSource = coverImageSource
        self.state = state
        self.isArchived = isArchived
        self.archivedFromPath = archivedFromPath
        self.archivedAt = archivedAt
        self.isBookFolder = isBookFolder
        self.pageCount = pageCount
        self.firstImageWidth = firstImageWidth
        self.firstImageHeight = firstImageHeight
    }

    /// 数え終わった遅延メタデータを写した複製を返す [DU-22][MD-02]。
    ///
    /// **同じ事実を 2 箇所で持たないために要る。** 比較ビューは測った結果を
    /// 行に持つが、残す 1 件を選ぶ規則 [DU-25] は `FileRow` を見るので、
    /// 反映しないと**「ページ数が最多」を選んでもページ数を見ていない**という、
    /// 画面からは絶対に気づけない形になる（しかもその判断が取り消せない
    /// 削除を駆動する）。
    public func withArchiveMetadata(pageCount: Int?, width: Int?, height: Int?) -> FileRow {
        FileRow(id: id, libraryID: libraryID, relativePath: relativePath,
                filename: filename, fileSize: fileSize, createdAt: createdAt,
                modifiedAt: modifiedAt, title: title, protectedScopes: protectedScopes,
                seriesName: seriesName, volume: volume, authorName: authorName,
                rating: rating, coverImageRef: coverImageRef,
                coverImageSource: coverImageSource, state: state,
                isArchived: isArchived, archivedFromPath: archivedFromPath,
                archivedAt: archivedAt, isBookFolder: isBookFolder,
                pageCount: pageCount, firstImageWidth: width, firstImageHeight: height)
    }

    /// 拡張子を除いたファイル名。**`FileSnapshot` と同じ導出**（`FilenameStem`）
    /// ——再マッチング [AL-34] は実ファイルを列挙し直さず DB の行から
    /// パースし直すので、ここが走査時と 1 文字でも違うと結果が食い違う。
    public var nameWithoutExtension: String { FilenameStem.of(filename) }
}

/// ページと総件数を一度に返す。総件数を毎回数え直さないため。
public struct FilePage: Sendable {
    public let rows: [FileRow]
    /// 絞り込み後の総数。**グループ化しているときはグループ数** [DU-06]。
    public let totalCount: Int
    /// 代表行 → その組の件数 [DU-06]。**2 件以上の組だけを持つ**ので、
    /// 「入っていない ＝ 重複していない」と読める。
    public let duplicateCounts: [FileID: Int]

    public init(rows: [FileRow], totalCount: Int,
                duplicateCounts: [FileID: Int] = [:]) {
        self.rows = rows
        self.totalCount = totalCount
        self.duplicateCounts = duplicateCounts
    }
}

/// 再照合の候補 [ID-03][ID-05]。
public struct ReidentificationCandidate: Sendable, Hashable {
    /// 確度。**宣言順が確度の高い順**で、`Comparable` はそれに従う。
    ///
    /// 引き継ぎは常に自動［ID-13〜15 撤回、§19.8］。確度は候補の並べ替え
    /// （最も確からしい 1 件を選ぶ）にだけ使い、判断は持たない。
    public enum Confidence: Sendable, Hashable, Comparable, CaseIterable {
        /// 同一相対パス + 同一サイズ [ID-03]①
        case pathAndSize
        /// 同一ファイル名 + 同一サイズ [ID-03]② — 場所が変わっただけ
        case nameAndSize
        /// 同一相対パス、サイズは違う [ID-03]③a — **同じ場所での差し替え**
        case pathOnly
        /// 同一ファイル名のみ [ID-03]③b — 移動と差し替えが同時か、別作品の同名
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
