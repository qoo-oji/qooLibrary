//
//  永続化レコード [07章 §7.3]。
//
//  すべて `struct`（`Sendable`）。`Codable` + `FetchableRecord` で読み書きする
//  ——2 万行のデコードで 20.2 ms、手書き `init(row:)` の 12.1 ms に対し 1.7 倍だが
//  絶対値が小さい [HP2-03、実測]。スキャンのホットパスだけ `cachedStatement` を使う。
//
import Foundation
import GRDB
import QooKit

// MARK: - ライブラリ

struct LibraryTypeRecord: Codable, FetchableRecord, MutablePersistableRecord, Sendable {
    static let databaseTableName = "libraryType"
    var id: Int64?
    var presetKey: String?
    var name: String
    var libraryTypeName: String
    var isPreset: Bool
    var version: Int
    var definitionJSON: String

    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

struct LibraryRecord: Codable, FetchableRecord, MutablePersistableRecord, Sendable {
    static let databaseTableName = "library"
    var id: Int64?
    var uuid: String
    var displayName: String
    var bookmarkData: Data
    var resolvedPath: String
    var volumeUUID: String
    var libraryTypeId: Int64
    var libraryTypeVersion: Int
    var settingsJSON: String
    var caseSensitive: Bool
    var duplicateGrouping: String
    var thumbnailsAlwaysHidden: Bool
    var lastFSEventID: Int64
    var lastFullScanAt: Double?
    var isOnline: Bool
    var isReadOnlyDueToFS: Bool
    var settingsRevision: Int

    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

// MARK: - ラベル

struct LabelGroupRecord: Codable, FetchableRecord, MutablePersistableRecord, Sendable {
    static let databaseTableName = "labelGroup"
    var id: Int64?
    var libraryId: Int64
    var groupIndex: Int
    var name: String
    var colorHexLight: String
    var colorHexDark: String
    var displayOrder: Int
    var assignsAutomatically: Bool

    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

struct LabelRecord: Codable, FetchableRecord, MutablePersistableRecord, Sendable {
    static let databaseTableName = "label"
    var id: Int64?
    var labelGroupId: Int64
    var name: String
    var normalizedName: String
    var colorHex: String?
    var isPinned: Bool
    var isArchived: Bool
    var fileCount: Int

    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

struct FileLabelRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "fileLabel"
    var managedFileId: Int64
    var labelId: Int64
    var origin: String
    var assignedAt: Double
}

// MARK: - ファイル

struct ManagedFileRecord: Codable, FetchableRecord, MutablePersistableRecord, Sendable {
    static let databaseTableName = "managedFile"
    var id: Int64?
    var libraryId: Int64
    var inode: Int64
    var volumeUUID: String
    var relativePath: String
    var filename: String
    var normalizedName: String
    var searchKey: String
    var fileSize: Int64
    var createdAt: Double
    var modifiedAt: Double
    var title: String?
    var titleOrigin: String
    var seriesName: String?
    var seriesKey: String?
    var volumeNumber: Double?
    var volumeKind: String
    var volumeRaw: String?
    var authorName: String?
    var rating: Int
    var coverImageRef: String?
    var coverImageSource: String
    var isArchived: Bool
    var archivedFromPath: String?
    var archivedAt: Double?
    var isBookFolder: Bool
    var isDuplicateRepresentativePinned: Bool
    var pageCount: Int?
    var subfolderCount: Int?
    var firstImageWidth: Int?
    var firstImageHeight: Int?
    var trashedAt: Double?
    var state: String
    var lastParsedFormatID: String?
    var libraryTypeMismatch: Bool

    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

extension ManagedFileRecord {
    /// スキャンが観測した内容から新規レコードを作る。
    init(snapshot: FileSnapshot, options: NormalizationOptions) {
        let stem = snapshot.nameWithoutExtension
        self.init(
            id: nil,
            libraryId: snapshot.libraryID.rawValue,
            inode: Int64(bitPattern: snapshot.identity.inode),
            volumeUUID: snapshot.identity.volumeUUID,
            relativePath: snapshot.relativePath,
            filename: snapshot.filename,
            normalizedName: TextNormalizer.normalize(stem, options: options),
            searchKey: TextNormalizer.searchKey(stem, options: options),
            fileSize: snapshot.fileSize,
            createdAt: snapshot.createdAt.timeIntervalSinceReferenceDate,
            modifiedAt: snapshot.modifiedAt.timeIntervalSinceReferenceDate,
            title: nil, titleOrigin: ValueOrigin.auto.rawValue,
            seriesName: nil, seriesKey: nil,
            volumeNumber: nil, volumeKind: VolumeValue.Kind.none.rawValue, volumeRaw: nil,
            authorName: nil, rating: 0,
            coverImageRef: nil, coverImageSource: CoverSource.auto.rawValue,
            isArchived: false, archivedFromPath: nil, archivedAt: nil,
            isBookFolder: snapshot.isBookFolder,
            isDuplicateRepresentativePinned: false,
            pageCount: nil, subfolderCount: nil,
            firstImageWidth: nil, firstImageHeight: nil,
            trashedAt: nil, state: FileState.active.rawValue,
            lastParsedFormatID: nil, libraryTypeMismatch: false)
    }

    var fileRow: FileRow {
        FileRow(
            id: FileID(rawValue: id ?? 0),
            libraryID: LibraryID(rawValue: libraryId),
            relativePath: relativePath,
            filename: filename,
            fileSize: fileSize,
            createdAt: Date(timeIntervalSinceReferenceDate: createdAt),
            modifiedAt: Date(timeIntervalSinceReferenceDate: modifiedAt),
            title: title,
            seriesName: seriesName,
            volume: VolumeValue(kind: VolumeValue.Kind(rawValue: volumeKind) ?? .none,
                                number: volumeNumber, ordinalRank: nil, raw: volumeRaw),
            rating: rating,
            state: FileState(rawValue: state) ?? .active,
            isArchived: isArchived,
            isBookFolder: isBookFolder)
    }
}

// MARK: - フォーマット類

struct FilenameFormatRecord: Codable, FetchableRecord, MutablePersistableRecord, Sendable {
    static let databaseTableName = "filenameFormat"
    var id: Int64?
    var libraryId: Int64
    var source: String
    var priority: Int
    var isEnabled: Bool
    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

struct VolumeFormatRecord: Codable, FetchableRecord, MutablePersistableRecord, Sendable {
    static let databaseTableName = "volumeFormat"
    var id: Int64?
    var libraryId: Int64
    var source: String
    var priority: Int
    var isEnabled: Bool
    var ordinalRank: Int?
    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

struct FolderLevelMappingRecord: Codable, FetchableRecord, MutablePersistableRecord, Sendable {
    static let databaseTableName = "folderLevelMapping"
    var id: Int64?
    var libraryId: Int64
    var level: Int
    var assignmentKind: String
    var labelGroupIndex: Int?
    var formatSource: String?
    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

struct ProtectedTokenRecord: Codable, FetchableRecord, MutablePersistableRecord, Sendable {
    static let databaseTableName = "protectedToken"
    var id: Int64?
    var ownerKind: String
    var ownerID: Int64
    var text: String
    var position: String
    var isEnabled: Bool
    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

/// `library.settingsJSON` の中身 [07章 §7.3「設定を JSON 列で持つ理由」]。
///
/// **SQL で絞り込む必要があるものはここへ入れない。**可変長で、件数上限が将来
/// 変わりうる設定だけを畳む [MT-10][MT-15]。
struct LibrarySettingsPayload: Codable, Sendable {
    var targetExtensions: [String] = []
    var imageExtensions: [String] = []          // [IF-02]
    var delimiters: DelimiterSet = .default     // [9.3]
    var semanticBindings: [String: Int] = [:]   // [RW-13]
    var seriesTitleCompositionFormat: String = "@series @volume"   // [SE-33]
    var labelGroupOrder: [Int] = []             // [LG-07][ST-23]

    static let empty = LibrarySettingsPayload()
}
