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
    /// `lastFSEventID` が属する FSEvents データベースの識別子 [WA-10]。
    /// **NULL なら `lastFSEventID` を起点として使ってはならない**（§10.1.0）。
    var fsEventsUUID: String?
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
    /// 読んだ時点の "mtime|size" [EM-07]。**読めなかったときも書く**——
    /// 「読んだが無かった」と「まだ読んでいない」を区別しないと、メタデータを
    /// 持たないファイルを毎回開き直すことになる [SE3-25]。
    var metadataStamp: String?
    var metadataSource: String?
    var metadataJSON: String?
    var hasVolumeConflict: Bool

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
            // 挿入時点ではタイトル・シリーズはまだ無い（走査は upsert の
            // **あと**に `applyParsedFields` を呼ぶ）。そちらが最終形を書く。
            searchKey: ManagedFileSearchKey.make(stem: stem, title: nil,
                                                 seriesName: nil, options: options),
            fileSize: snapshot.fileSize,
            createdAt: snapshot.createdAt.timeIntervalSinceReferenceDate,
            modifiedAt: snapshot.modifiedAt.timeIntervalSinceReferenceDate,
            title: nil, titleOrigin: ValueOrigin.auto.rawValue,
            seriesName: nil, seriesKey: nil,
            volumeNumber: nil, volumeKind: VolumeValue.Kind.none.rawValue, volumeRaw: nil,
            authorName: nil, rating: 0,
            coverImageRef: nil, coverImageSource: CoverSource.auto.rawValue,
            // 保管庫の中にあるかは**観測した位置**が決める [SY-10][FA-05]。
            // `archivedFromPath` は走査では書かない——元の場所を知って
            // いるのは保管庫へ移した操作だけで、外部で `.qooarchive` へ
            // 入れられたものは `VaultPath.original` から導く [FA-03]。
            isArchived: snapshot.isArchived, archivedFromPath: nil, archivedAt: nil,
            isBookFolder: snapshot.isBookFolder,
            isDuplicateRepresentativePinned: false,
            pageCount: nil, subfolderCount: nil,
            firstImageWidth: nil, firstImageHeight: nil,
            trashedAt: nil, state: FileState.active.rawValue,
            lastParsedFormatID: nil, libraryTypeMismatch: false,
            metadataStamp: nil, metadataSource: nil, metadataJSON: nil,
            hasVolumeConflict: false)
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
            titleOrigin: ValueOrigin(rawValue: titleOrigin) ?? .auto,
            seriesName: seriesName,
            volume: VolumeValue(kind: VolumeValue.Kind(rawValue: volumeKind) ?? .none,
                                number: volumeNumber, raw: volumeRaw),
            authorName: authorName,
            rating: rating,
            coverImageRef: coverImageRef,
            coverImageSource: CoverSource(rawValue: coverImageSource) ?? .auto,
            state: FileState(rawValue: state) ?? .active,
            isArchived: isArchived,
            archivedFromPath: archivedFromPath,
            archivedAt: archivedAt.map { Date(timeIntervalSinceReferenceDate: $0) },
            isBookFolder: isBookFolder)
    }

    // MARK: - 孤立レコードの Undo 用の写し [OR-02][OR-04][UD-03]

    /// 行の**全列**を写す。
    ///
    /// Undo の契約は「ちょうど戻す」ことなので、再生成可能な列 [DB-03] も
    /// 含める——孤立レコードには実体が無く、走査が埋め直す機会が来ない。
    ///
    /// **列を足したらここと `init(undoSnapshot:)` の両方に足すこと。** 忘れると
    /// ⌘Z のあと黙って値が変わる。それを機械的に捕まえるため、往復テスト
    /// （`OrphanRepositoryTests.everyColumnSurvivesADeleteAndRestore`）が
    /// 「削除 → 復元 → レコードが一致」を検査している。
    func snapshotForUndo(labels: [ManagedFileSnapshot.LabelAssignment]) -> ManagedFileSnapshot {
        ManagedFileSnapshot(
            id: FileID(rawValue: id ?? 0),
            libraryID: LibraryID(rawValue: libraryId),
            identity: FileIdentity(volumeUUID: volumeUUID, inode: UInt64(bitPattern: inode)),
            relativePath: relativePath,
            filename: filename,
            normalizedName: normalizedName,
            searchKey: searchKey,
            fileSize: fileSize,
            createdAt: Date(timeIntervalSinceReferenceDate: createdAt),
            modifiedAt: Date(timeIntervalSinceReferenceDate: modifiedAt),
            title: title,
            titleOrigin: ValueOrigin(rawValue: titleOrigin) ?? .auto,
            seriesName: seriesName,
            seriesKey: seriesKey,
            volume: VolumeValue(kind: VolumeValue.Kind(rawValue: volumeKind) ?? .none,
                                number: volumeNumber, raw: volumeRaw),
            authorName: authorName,
            rating: rating,
            coverImageRef: coverImageRef,
            coverImageSource: CoverSource(rawValue: coverImageSource) ?? .auto,
            isArchived: isArchived,
            archivedFromPath: archivedFromPath,
            archivedAt: archivedAt.map { Date(timeIntervalSinceReferenceDate: $0) },
            isBookFolder: isBookFolder,
            isDuplicateRepresentativePinned: isDuplicateRepresentativePinned,
            pageCount: pageCount,
            subfolderCount: subfolderCount,
            firstImageWidth: firstImageWidth,
            firstImageHeight: firstImageHeight,
            trashedAt: trashedAt.map { Date(timeIntervalSinceReferenceDate: $0) },
            state: FileState(rawValue: state) ?? .active,
            lastParsedFormatID: lastParsedFormatID,
            libraryTypeMismatch: libraryTypeMismatch,
            metadataStamp: metadataStamp,
            metadataSource: metadataSource,
            metadataJSON: metadataJSON,
            hasVolumeConflict: hasVolumeConflict,
            labels: labels)
    }

    /// 写しから行を組み立て直す。**`id` を明示する**——AUTOINCREMENT なので
    /// 削除された ID は空いたまま残っており、そのまま取り戻せる［実測］。
    init(undoSnapshot s: ManagedFileSnapshot) {
        self.init(
            id: s.id.rawValue,
            libraryId: s.libraryID.rawValue,
            inode: Int64(bitPattern: s.identity.inode),
            volumeUUID: s.identity.volumeUUID,
            relativePath: s.relativePath,
            filename: s.filename,
            normalizedName: s.normalizedName,
            searchKey: s.searchKey,
            fileSize: s.fileSize,
            createdAt: s.createdAt.timeIntervalSinceReferenceDate,
            modifiedAt: s.modifiedAt.timeIntervalSinceReferenceDate,
            title: s.title,
            titleOrigin: s.titleOrigin.rawValue,
            seriesName: s.seriesName,
            seriesKey: s.seriesKey,
            volumeNumber: s.volume.number,
            volumeKind: s.volume.kind.rawValue,
            volumeRaw: s.volume.raw,
            authorName: s.authorName,
            rating: s.rating,
            coverImageRef: s.coverImageRef,
            coverImageSource: s.coverImageSource.rawValue,
            isArchived: s.isArchived,
            archivedFromPath: s.archivedFromPath,
            archivedAt: s.archivedAt?.timeIntervalSinceReferenceDate,
            isBookFolder: s.isBookFolder,
            isDuplicateRepresentativePinned: s.isDuplicateRepresentativePinned,
            pageCount: s.pageCount,
            subfolderCount: s.subfolderCount,
            firstImageWidth: s.firstImageWidth,
            firstImageHeight: s.firstImageHeight,
            trashedAt: s.trashedAt?.timeIntervalSinceReferenceDate,
            state: s.state.rawValue,
            lastParsedFormatID: s.lastParsedFormatID,
            libraryTypeMismatch: s.libraryTypeMismatch,
            metadataStamp: s.metadataStamp,
            metadataSource: s.metadataSource,
            metadataJSON: s.metadataJSON,
            hasVolumeConflict: s.hasVolumeConflict)
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
    /// 正規表現 [2026-08 の仕様変更]。
    var source: String
    var priority: Int
    var isEnabled: Bool
    /// `VolumePatternKind` の生値（`volume` / `separator`）。
    var kind: String
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

/// 未解決ファイル [AL-30〜AL-34][UR-01〜UR-06]。**`managedFile` と 1:1**
/// （`managedFileId` に UNIQUE）——行があること自体が「未解決である」を表す。
struct UnresolvedFileRecord: Codable, FetchableRecord, MutablePersistableRecord, Sendable {
    static let databaseTableName = "unresolvedFile"
    var id: Int64?
    var libraryId: Int64
    var managedFileId: Int64
    /// 未解決と判定した時点のファイル名。**現在の名前と突き合わせて
    /// 無視フラグを解く**ために持つ [AL-33、ユーザー判断 2026-08]。
    var filename: String
    var isIgnored: Bool
    var detectedAt: Double
    /// 最も近いフォーマットの推定 [UR2-05]。**まだ誰も書かない**——
    /// パーサに「照合が最も進んだ入力位置」を保持させる必要があり、
    /// ゴールデンテストで固めてある中核を触ることになるため今回は見送った
    /// ［ユーザー判断、2026-08］。列は既に v1 にある。
    var nearestFormatSource: String?
    var nearestFormatReach: Int?
    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

// MARK: - 通知履歴

struct NotificationRecord: Codable, FetchableRecord, MutablePersistableRecord, Sendable {
    static let databaseTableName = "notificationRecord"
    var id: Int64?
    var date: Double
    var category: String
    var severity: Int
    /// 対象・技術詳細・関連画面への導線をまとめた JSON [NT-04][NT-05]。
    ///
    /// **列の名前は v1 の「対象を非正規化して持つ」という意図のまま**だが、
    /// 実際には `NotificationPayload` を入れている——技術詳細も導線も、
    /// SQL で絞り込む対象ではなく、行を開いたときにだけ読むものだからで、
    /// そのために列を 3 つ足す理由が無い（`library.settingsJSON` と同じ判断）。
    var targetJSON: String?
    var title: String
    var body: String
    var isRead: Bool
    /// 操作履歴へのリンク [NT-04]。**まだ誰も書かない**——`operationLog` は
    /// v1 からあるが書き手が無く、操作履歴はメモリのみ（`CommandStack`）。
    var operationLogID: Int64?
    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

/// `notificationRecord.targetJSON` の中身。
struct NotificationPayload: Codable, Sendable {
    var target: NotificationTarget?
    var technicalDetail: String?
    var links: [NotificationLink] = []
}

struct ProtectedTokenRecord: Codable, FetchableRecord, MutablePersistableRecord, Sendable {
    static let databaseTableName = "protectedToken"
    var id: Int64?
    var ownerKind: String
    var ownerID: Int64
    /// 正規表現 [2026-08 の仕様変更]。
    var pattern: String
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
    /// ファイル自身が持つメタデータを読むか [EM-06]。
    var readsEmbeddedMetadata: Bool = true
    /// `ComicInfo.xml` の巻数をどちらの要素から取るか [EM-30]。
    var comicInfoVolumeSource: ComicInfoVolumeSource = .ask
    /// ブックフォルダの「開く」を関連付けアプリに任せるか [IF-18][AS-06]。
    /// **既定は偽**（＝フォルダを開く）——要件が既定をそう定めている。
    var opensBookFolderWithApp: Bool = false
    /// どこまでを黙って同じファイルとみなすか [ID-13]。
    /// **既定は `.sameName`**（＝確認しない）——要件が既定をそう定めている。
    var identityMatchPolicy: IdentityMatchPolicy = .default

    static let empty = LibrarySettingsPayload()

    init() {}

    init(targetExtensions: [String], imageExtensions: [String], delimiters: DelimiterSet,
         semanticBindings: [String: Int], seriesTitleCompositionFormat: String,
         labelGroupOrder: [Int], readsEmbeddedMetadata: Bool,
         comicInfoVolumeSource: ComicInfoVolumeSource,
         opensBookFolderWithApp: Bool,
         identityMatchPolicy: IdentityMatchPolicy) {
        self.targetExtensions = targetExtensions
        self.imageExtensions = imageExtensions
        self.delimiters = delimiters
        self.semanticBindings = semanticBindings
        self.seriesTitleCompositionFormat = seriesTitleCompositionFormat
        self.labelGroupOrder = labelGroupOrder
        self.readsEmbeddedMetadata = readsEmbeddedMetadata
        self.comicInfoVolumeSource = comicInfoVolumeSource
        self.opensBookFolderWithApp = opensBookFolderWithApp
        self.identityMatchPolicy = identityMatchPolicy
    }

    /// **すべてのキーを `decodeIfPresent` で読む。**
    ///
    /// Swift の合成された `Decodable` は**プロパティの既定値を使わず**、
    /// キーが無いと `keyNotFound` で失敗する [実測]。この型は既存の DB に
    /// 保存済みの JSON を読むので、フィールドを足すたびに古い行が
    /// 読めなくなってはならない——`AppAssociationStore` で実際に踏んだ罠と
    /// 同じ形で、あちらは「登録済みのライブラリが全部消えたように見える」
    /// ところまで行きかけた。
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) throws -> T {
            try c.decodeIfPresent(T.self, forKey: key) ?? fallback
        }
        targetExtensions = try value(.targetExtensions, [])
        imageExtensions = try value(.imageExtensions, [])
        delimiters = try value(.delimiters, .default)
        semanticBindings = try value(.semanticBindings, [:])
        seriesTitleCompositionFormat = try value(.seriesTitleCompositionFormat, "@series @volume")
        labelGroupOrder = try value(.labelGroupOrder, [])
        readsEmbeddedMetadata = try value(.readsEmbeddedMetadata, true)
        comicInfoVolumeSource = try value(.comicInfoVolumeSource, .ask)
        opensBookFolderWithApp = try value(.opensBookFolderWithApp, false)
        identityMatchPolicy = try value(.identityMatchPolicy, .default)
        // **フィールドを足したら、ここへ 1 行足すこと。**`CodingKeys` は
        // プロパティから合成されるので鍵は増えるが、この本体に書き忘れても
        // コンパイラは何も言わず、**読まれないまま既定値に落ちる**
        // ——保存はできているのに読み戻せない、という最も分かりにくい形になる
        // （実際 [IF-18] を足したときにこの穴へ落ちた）。忘れたら
        // `LibrarySettingsPayloadTests.everyFieldSurvivesARoundTrip` が落ちる。
    }
}
