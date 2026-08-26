//
//  孤立レコードを削除・再紐づけする前の写し [OR-04][OR-02][UD-03]。
//
//  `LabelSnapshot` のファイル版。あちらと同じ理由でこの形が成り立つ——
//  **`managedFile.id` は AUTOINCREMENT なので、削除された ID は二度と
//  再利用されず、元の ID をそのまま取り戻せる**［実測: ライブストアの
//  `sqlite_master` に `AUTOINCREMENT` があることを確認］。
//
//  > **記録との食い違いについて。** 07章 §7.3 の表と CLAUDE.md は
//  > 「`label` と `labelGroup` だけ AUTOINCREMENT、`managedFile` は付けない」と
//  > 書いていたが、`QooMigrations` は全テーブルで `autoIncrementedPrimaryKey`
//  > （GRDB のこれは `autoincrement: true`）を使っており、実装は最初から
//  > 付いている。実測に合わせて記録のほうを訂正した。
//
//  ## 全列を持つ
//  Undo の契約は「**ちょうど**戻す」ことなので、再生成可能な列 [DB-03] も
//  含めて全部持つ。部分的に戻すと「⌘Z したのに値が変わっている」という、
//  画面からは理由の読み取れない壊れ方になる。
//
//  **列を足したらここにも足す必要がある**——写し忘れると黙って値が失われる
//  （`LibrarySettingsPayload.init(from:)` で実際に踏んだ形）。それを機械的に
//  捕まえるため、「削除 → 復元 → 全列が一致」の往復テスト
//  （`OrphanRepositoryTests.everyColumnSurvivesADeleteAndRestore`）を置いてある。
//
import Foundation

public struct ManagedFileSnapshot: Sendable, Hashable {
    /// ラベル紐づけ 1 件ぶん。**`manuallyRemoved` の行も含む**——除去の印は
    /// 「付いていない」ではなく「外したと記録されている」という別の状態で、
    /// 落とすと ⌘Z のあと再スキャンでラベルが復活する [RC-04]。
    public struct LabelAssignment: Sendable, Hashable {
        public let labelID: LabelID
        public let origin: LabelOrigin
        public let assignedAt: Date

        public init(labelID: LabelID, origin: LabelOrigin, assignedAt: Date) {
            self.labelID = labelID
            self.origin = origin
            self.assignedAt = assignedAt
        }
    }

    public let id: FileID
    public let libraryID: LibraryID
    public let identity: FileIdentity          // [ID-01]
    public let relativePath: String
    public let filename: String
    public let normalizedName: String          // 再生成可能 [DB-03]
    public let searchKey: String               // 再生成可能 [SR-06]
    public let fileSize: Int64
    public let createdAt: Date
    public let modifiedAt: Date
    public let title: String?
    public let titleOrigin: ValueOrigin        // [RP-11]
    public let seriesName: String?
    public let seriesKey: String?              // [RA-04][DU-02]
    public let volume: VolumeValue             // volumeNumber / volumeKind / volumeRaw
    public let authorName: String?             // [RW-16]
    public let rating: Int                     // [RA-01]
    public let coverImageRef: String?          // [CV-06]
    public let coverImageSource: CoverSource   // [IV-03]
    public let isArchived: Bool                // [FA-05]
    public let archivedFromPath: String?       // [FA-04]
    public let archivedAt: Date?
    public let isBookFolder: Bool              // 再生成可能 [IF-04]
    public let isDuplicateRepresentativePinned: Bool
    public let pageCount: Int?                 // 再生成可能 [DT-05]
    public let subfolderCount: Int?            // 再生成可能 [DT-06]
    public let firstImageWidth: Int?           // 再生成可能 [DU-21]
    public let firstImageHeight: Int?          // 再生成可能
    public let trashedAt: Date?                // [TR-03]
    public let state: FileState                // [ID-06][TR-01]
    public let lastParsedFormatID: String?
    public let libraryTypeMismatch: Bool       // [RW-01]
    public let metadataStamp: String?          // [EM-07]
    public let metadataSource: String?
    public let metadataJSON: String?
    public let hasVolumeConflict: Bool         // [EM-26][EM-31]
    public let labels: [LabelAssignment]

    public init(id: FileID, libraryID: LibraryID, identity: FileIdentity,
                relativePath: String, filename: String,
                normalizedName: String, searchKey: String,
                fileSize: Int64, createdAt: Date, modifiedAt: Date,
                title: String?, titleOrigin: ValueOrigin,
                seriesName: String?, seriesKey: String?,
                volume: VolumeValue, authorName: String?, rating: Int,
                coverImageRef: String?, coverImageSource: CoverSource,
                isArchived: Bool, archivedFromPath: String?, archivedAt: Date?,
                isBookFolder: Bool, isDuplicateRepresentativePinned: Bool,
                pageCount: Int?, subfolderCount: Int?,
                firstImageWidth: Int?, firstImageHeight: Int?,
                trashedAt: Date?, state: FileState,
                lastParsedFormatID: String?, libraryTypeMismatch: Bool,
                metadataStamp: String?, metadataSource: String?, metadataJSON: String?,
                hasVolumeConflict: Bool, labels: [LabelAssignment]) {
        self.id = id
        self.libraryID = libraryID
        self.identity = identity
        self.relativePath = relativePath
        self.filename = filename
        self.normalizedName = normalizedName
        self.searchKey = searchKey
        self.fileSize = fileSize
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.title = title
        self.titleOrigin = titleOrigin
        self.seriesName = seriesName
        self.seriesKey = seriesKey
        self.volume = volume
        self.authorName = authorName
        self.rating = rating
        self.coverImageRef = coverImageRef
        self.coverImageSource = coverImageSource
        self.isArchived = isArchived
        self.archivedFromPath = archivedFromPath
        self.archivedAt = archivedAt
        self.isBookFolder = isBookFolder
        self.isDuplicateRepresentativePinned = isDuplicateRepresentativePinned
        self.pageCount = pageCount
        self.subfolderCount = subfolderCount
        self.firstImageWidth = firstImageWidth
        self.firstImageHeight = firstImageHeight
        self.trashedAt = trashedAt
        self.state = state
        self.lastParsedFormatID = lastParsedFormatID
        self.libraryTypeMismatch = libraryTypeMismatch
        self.metadataStamp = metadataStamp
        self.metadataSource = metadataSource
        self.metadataJSON = metadataJSON
        self.hasVolumeConflict = hasVolumeConflict
        self.labels = labels
    }
}

/// 孤立レコード 1 件と、その再照合候補 [OR-01][OR-02][ID-05]。
///
/// **候補は DB に保存されていない。** `ScanEngine.reconcile` は `.nameOnly` で
/// しか一致しなかったものを `candidatesForReview` として数えるだけで、その
/// 実ファイルは**新規レコードとして別に作られる**。つまり候補はここで引き直す
/// ——孤立レコードと同じ名前を持つ、生きている（`active`）レコードを探す。
public struct OrphanedFile: Sendable, Hashable, Identifiable {
    public let row: FileRow
    /// ラベル紐づけの件数。削除の確認で「何件のラベルが外れるか」を見せる
    /// [LE-08 と同じ考え方]。`manuallyRemoved` は数えない——利用者から見て
    /// 「付いている」ラベルだけを数えなければ、確認の数字が画面と食い違う。
    public let labelCount: Int
    /// 再照合候補 [OR-02]。確度の高い順。空なら「候補なし」。
    public let candidates: [OrphanCandidate]

    public var id: FileID { row.id }

    public init(row: FileRow, labelCount: Int, candidates: [OrphanCandidate]) {
        self.row = row
        self.labelCount = labelCount
        self.candidates = candidates
    }
}

/// 孤立レコードの再照合候補 1 件 [OR-02][ID-03]③。
public struct OrphanCandidate: Sendable, Hashable, Identifiable {
    public let fileID: FileID
    public let relativePath: String
    public let filename: String
    public let fileSize: Int64
    /// 孤立レコードと**同じ相対パス**か [ID-09]。
    ///
    /// **確信度がまったく違う。** 同じ場所の同じ名前なら差し替え（スキャン版を
    /// 電子版へ、低画質を高画質へ、破損したものを取り直す）がほぼ確実だが、
    /// 別の場所の同名ファイルは「移動」かもしれないし「別シリーズの同じ巻数」
    /// かもしれない——`第01巻.cbz` は複数のシリーズに存在しうる。
    public let samePath: Bool
    /// 孤立レコードと同じ大きさか。**名前だけの一致 [ID-03]③ より、大きさも
    /// 一致するほうが確からしい**ので並べ替えに使う（`ID-03` の①②は走査が
    /// 自動で紐づけ済みなので、ここへ来るのは原則③だけ）。
    public let sizeMatches: Bool

    public var id: FileID { fileID }

    public init(fileID: FileID, relativePath: String, filename: String,
                fileSize: Int64, samePath: Bool = false, sizeMatches: Bool) {
        self.fileID = fileID
        self.relativePath = relativePath
        self.filename = filename
        self.fileSize = fileSize
        self.samePath = samePath
        self.sizeMatches = sizeMatches
    }
}

/// 「この孤立レコードは、この実ファイルのことかもしれない」という組 [ID-05]。
///
/// 走査は名前が同じで inode が違うものを見つけても**自動では紐づけない**。
/// 走り切ってから一括の確認ダイアログでまとめて問い合わせ、承認された組だけを
/// 確定する。**組そのものを記録する必要は無い**——「孤立していて、同じ名前の
/// 生きている行がある」という状態が DB にそのまま表れているため。
public struct IdentityMatch: Sendable, Hashable {
    /// 実体を失った側（ラベル・評価・手動タイトルを持っている）。
    public let orphanID: FileID
    /// 実際に観測された側（走査が新規として作った行）。
    public let candidateID: FileID

    public init(orphanID: FileID, candidateID: FileID) {
        self.orphanID = orphanID
        self.candidateID = candidateID
    }
}
