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
    /// 保管庫へ移す前の相対パス [FA-04]。右ペインの表示 [DT-11] と、
    /// 戻す先の決定 [FA-07] に使う。外部で `.qooarchive` へ入れられたものは
    /// 記録が無いので `nil`——そのときは `VaultPath.original` が導く [FA-03]。
    public let archivedFromPath: String?
    /// 保管庫へ移した日時 [FAW-05]。
    public let archivedAt: Date?
    public let isBookFolder: Bool
    /// 代表を手で固定したか [DU-08]。**再生成不可能**なので JSON にも入る [MG-22]。
    public let isDuplicateRepresentativePinned: Bool
    /// ページ数（画像ファイル数）[DU-21]。アーカイブを開かないと分からないので
    /// **遅延取得**し、`nil` は「まだ数えていない」を意味する [DU-22][MD-01]。
    public let pageCount: Int?
    /// 先頭画像の解像度 [DU-21]。`pageCount` と同じく遅延取得。
    public let firstImageWidth: Int?
    public let firstImageHeight: Int?

    public init(id: FileID, libraryID: LibraryID, relativePath: String, filename: String,
                fileSize: Int64, createdAt: Date, modifiedAt: Date, title: String?,
                titleOrigin: ValueOrigin = .auto,
                seriesName: String?, volume: VolumeValue, authorName: String? = nil,
                rating: Int,
                coverImageRef: String? = nil, coverImageSource: CoverSource = .auto,
                state: FileState,
                isArchived: Bool,
                archivedFromPath: String? = nil, archivedAt: Date? = nil,
                isBookFolder: Bool,
                isDuplicateRepresentativePinned: Bool = false,
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
        self.titleOrigin = titleOrigin
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
        self.isDuplicateRepresentativePinned = isDuplicateRepresentativePinned
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
                modifiedAt: modifiedAt, title: title, titleOrigin: titleOrigin,
                seriesName: seriesName, volume: volume, authorName: authorName,
                rating: rating, coverImageRef: coverImageRef,
                coverImageSource: coverImageSource, state: state,
                isArchived: isArchived, archivedFromPath: archivedFromPath,
                archivedAt: archivedAt, isBookFolder: isBookFolder,
                isDuplicateRepresentativePinned: isDuplicateRepresentativePinned,
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
    /// どこまでを自動で引き継ぐかは `IdentityMatchPolicy` が決める [ID-13]。
    /// ここは「何がどう一致したか」だけを表し、判断は持たない。
    public enum Confidence: Sendable, Hashable, Comparable, CaseIterable {
        /// 同一相対パス + 同一サイズ [ID-03]①
        case pathAndSize
        /// 同一ファイル名 + 同一サイズ [ID-03]② — 場所が変わっただけ
        case nameAndSize
        /// 同一相対パス、サイズは違う [ID-03]③a — **同じ場所での差し替え**
        case pathOnly
        /// 同一ファイル名のみ [ID-03]③b — 移動と差し替えが同時か、別作品の同名
        case nameOnly

        /// 孤立一覧の候補（`OrphanCandidate`）から確度を復元する。
        ///
        /// **走査とあとからの引き直しで同じ物差しを使うため**にここへ置く。
        /// 呼び出し側で `samePath ? .pathOnly : .nameOnly` のように畳むと、
        /// サイズも一致している組が実際より低い確度に落ちる。
        public init(samePath: Bool, sizeMatches: Bool) {
            switch (samePath, sizeMatches) {
            case (true, true):   self = .pathAndSize
            case (false, true):  self = .nameAndSize
            case (true, false):  self = .pathOnly
            case (false, false): self = .nameOnly
            }
        }
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
