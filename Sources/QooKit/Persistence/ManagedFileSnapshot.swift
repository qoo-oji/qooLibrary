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
    public let titleKey: String?               // 再生成可能 [DU-02][DU-03]
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
                normalizedName: String, searchKey: String, titleKey: String? = nil,
                fileSize: Int64, createdAt: Date, modifiedAt: Date,
                title: String?, titleOrigin: ValueOrigin,
                seriesName: String?, seriesKey: String?,
                volume: VolumeValue, authorName: String?, rating: Int,
                coverImageRef: String?, coverImageSource: CoverSource,
                isArchived: Bool, archivedFromPath: String?, archivedAt: Date?,
                isBookFolder: Bool,
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
        self.titleKey = titleKey
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

/// 孤立レコード 1 件 [OR-01]。「見つからないファイル」一覧の 1 行ぶん。
///
/// かつてここにあった再照合候補（`OrphanCandidate`）と確認待ちの組
/// （`IdentityMatch`）は、同一性確認の撤去 [ID-09〜15 撤回、§19.8] とともに
/// 消えた——差し替えは走査がガード付きで自動的に引き継ぐ（`ScanEngine.reconcile`
/// の [ID3-08] ガード参照）ので、確認に出す組がそもそも生まれない。
public struct OrphanedFile: Sendable, Hashable, Identifiable {
    public let row: FileRow
    /// ラベル紐づけの件数。削除の確認で「何件のラベルが外れるか」を見せる
    /// [LE-08 と同じ考え方]。`manuallyRemoved` は数えない——利用者から見て
    /// 「付いている」ラベルだけを数えなければ、確認の数字が画面と食い違う。
    public let labelCount: Int

    public var id: FileID { row.id }

    public init(row: FileRow, labelCount: Int) {
        self.row = row
        self.labelCount = labelCount
    }
}
