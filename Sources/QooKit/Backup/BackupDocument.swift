//
//  JSON バックアップの文書 [IE-01〜IE-05][JS-01〜JS-04][BK-05][MG-22][MG-23]。
//
//  **`Foundation` のみ**（`QooKit` の制約 [A-01]）。ここは形だけを持ち、
//  読み書きは `QooPersistence` の実装が行う。
//
//  ## 何を出し、何を出さないか
//  再生成可能なデータ [MG-21] は**出さない**。復旧手順が「新規ストア →
//  JSON インポート → 再スキャン」に収束する [MG-24] 以上、再スキャンで
//  作り直せるものを JSON に持つと、10 万件規模で無駄に膨らむうえ、
//  取り込み時に古い値で実体を上書きする危険まで背負う。
//
//  出す／出さないの判断は `RegenerabilityRegistry`（`QooPersistence`）の
//  宣言と機械的に突き合わせる [MG-23][B-13]——列を足したときに黙って
//  漏れないようにするため、テストがその一致を検証する。
//
//  ## 値によって再生成可能性が変わる列がある
//  `title` は基本情報が保護されているときだけ再生成不可能 [PR-01]、
//  `coverImageRef` は `coverImageSource == "userSpecified"` のときだけ [IV-03]、
//  ラベル紐づけは**そのフィールドが保護されているときだけ** [PR-02]。
//  **列ではなく値で分かれる**ので、判定に使う値（保護スコープ）ごと JSON へ出す。
//
import Foundation

/// バックアップ文書の根 [IE-03]。
public struct BackupDocument: Codable, Sendable, Equatable {
    /// この実装が書き出す版。**読み込みは `<=` で判定する** [IE-14][JS-09]。
    ///
    /// - 1: 巻数フォーマットは `??` / `<space>` の独自記法。序列巻数を `ordinalRank`
    ///      で表した。保護文字列は完全一致のリテラル（`text`）。
    /// - 2: どちらも正規表現。巻数フォーマットは `kind`（volume / separator）を持つ。
    ///      **版 1 の文書は DTO のデコード時にその場で変換する**ので、以前書き出した
    ///      バックアップはそのまま読める。
    /// - 3: メタデータの保護 [PR-01〜PR-09]。`titleOrigin` とラベル紐づけの
    ///      `origin` が消え、`protectedScopes` が入る。**版を上げたのは、古い
    ///      実装が新しい文書を読めなくなるから**——あちらは `titleOrigin` を
    ///      非 Optional で要求しており、無いと文書全体の取り込みが失敗する。
    ///      版 1／2 の文書は取り込み時に `LegacyMetadataProtection` で
    ///      読み替える（DB の `v10_metadataProtection` と同じ規則）。
    public static let currentSchemaVersion = 3

    public var schemaVersion: Int
    public var exportedAt: Date
    /// 書き出したアプリの版。復元時には使わないが、問い合わせの手がかりになる。
    public var appVersion: String?
    public var libraries: [LibraryBackup]

    public init(schemaVersion: Int = BackupDocument.currentSchemaVersion,
                exportedAt: Date,
                appVersion: String?,
                libraries: [LibraryBackup]) {
        self.schemaVersion = schemaVersion
        self.exportedAt = exportedAt
        self.appVersion = appVersion
        self.libraries = libraries
    }
}

// MARK: - ライブラリ

/// 1 ライブラリ分 [IE-02]。
///
/// **同一性キーは `displayName` + `rootPath`** [IE-10][JS-04]。行 ID も inode も
/// 環境依存なので使わない。`uuid` は復元の手がかりとして持つが、別のマシンでは
/// 登録フォルダが別の ID を持つため、突き合わせの主キーにはしない。
public struct LibraryBackup: Codable, Sendable, Equatable {
    public var uuid: UUID
    public var displayName: String
    public var rootPath: String
    public var volumeUUID: String
    public var libraryType: LibraryTypeBackup
    public var duplicateGrouping: String
    public var thumbnailsAlwaysHidden: Bool
    /// `library.settingsJSON` をそのまま持つ [07章 §7.3]。対象拡張子・区切り・
    /// 意味束縛など、可変長でユーザーが編集した設定が入っている。
    public var settings: String
    public var labelGroups: [LabelGroupBackup]
    public var filenameFormats: [FormatBackup]
    public var volumeFormats: [VolumeFormatBackup]
    public var folderLevelMappings: [FolderLevelMappingBackup]
    public var protectedTokens: [ProtectedTokenBackup]
    /// 保存した絞り込み [SH-12][MG-22]。**利用者が作ったもので走査からは
    /// 作り直せない**ので、漏れなく出す。
    ///
    /// **`[ShelfBackup]?` なのは古い文書を読むため**（`isUnresolvedIgnored` と
    /// 同じ事情——合成された `Decodable` はプロパティの既定値を使わないので、
    /// 非 Optional にするとキーの無い版 1〜3 の文書が `keyNotFound` で全体
    /// 失敗する [実測]）。`schemaVersion` は上げていない。キーが増えただけの
    /// 追加は、読み込みが `<=` 判定である以上、古い実装からも読める。
    public var shelves: [ShelfBackup]?
    public var files: [FileBackup]

    public init(uuid: UUID, displayName: String, rootPath: String, volumeUUID: String,
                libraryType: LibraryTypeBackup,
                duplicateGrouping: String, thumbnailsAlwaysHidden: Bool,
                settings: String, labelGroups: [LabelGroupBackup],
                filenameFormats: [FormatBackup], volumeFormats: [VolumeFormatBackup],
                folderLevelMappings: [FolderLevelMappingBackup],
                protectedTokens: [ProtectedTokenBackup],
                shelves: [ShelfBackup]? = nil, files: [FileBackup]) {
        self.uuid = uuid
        self.displayName = displayName
        self.rootPath = rootPath
        self.volumeUUID = volumeUUID
        self.libraryType = libraryType
        self.duplicateGrouping = duplicateGrouping
        self.thumbnailsAlwaysHidden = thumbnailsAlwaysHidden
        self.settings = settings
        self.labelGroups = labelGroups
        self.filenameFormats = filenameFormats
        self.volumeFormats = volumeFormats
        self.folderLevelMappings = folderLevelMappings
        self.protectedTokens = protectedTokens
        self.shelves = shelves
        self.files = files
    }

    /// 突き合わせの主キー [IE-10]。
    public var identityKey: String { "\(displayName)\u{0000}\(rootPath)" }
}

/// ライブラリタイプ [LT-01][LT-05]。
///
/// **`libraryType` の行は複数ライブラリで共有される**ので、復元時は
/// `presetKey` があればプリセットへ、無ければ専用の型を作り直す。
public struct LibraryTypeBackup: Codable, Sendable, Equatable {
    public var presetKey: String?
    public var name: String
    public var libraryTypeName: String
    public var isPreset: Bool
    public var version: Int
    public var definitionJSON: String

    public init(presetKey: String?, name: String, libraryTypeName: String,
                isPreset: Bool, version: Int, definitionJSON: String) {
        self.presetKey = presetKey
        self.name = name
        self.libraryTypeName = libraryTypeName
        self.isPreset = isPreset
        self.version = version
        self.definitionJSON = definitionJSON
    }
}

// MARK: - ラベル

/// ラベルグループ [LG-01]。名前・色はユーザーの設定なので再生成できない [MG-22]。
public struct LabelGroupBackup: Codable, Sendable, Equatable {
    /// ライブラリ内で一意な枠番号。**復元の主キーはこちら**——グループ名は
    /// 後から変えられるので、名前だけを頼りにすると改名した瞬間に別物になる。
    public var groupIndex: Int
    public var name: String
    public var colorHexLight: String
    public var colorHexDark: String
    public var displayOrder: Int
    public var assignsAutomatically: Bool
    public var labels: [LabelBackup]

    public init(groupIndex: Int, name: String, colorHexLight: String, colorHexDark: String,
                displayOrder: Int, assignsAutomatically: Bool, labels: [LabelBackup]) {
        self.groupIndex = groupIndex
        self.name = name
        self.colorHexLight = colorHexLight
        self.colorHexDark = colorHexDark
        self.displayOrder = displayOrder
        self.assignsAutomatically = assignsAutomatically
        self.labels = labels
    }
}

/// ラベル 1 件 [LB-01]。
///
/// `normalizedName` と `fileCount` は出さない——前者は原文から導け、後者は
/// 非正規化キャッシュ [DB-02] でどちらも再生成可能 [MG-21]。
public struct LabelBackup: Codable, Sendable, Equatable {
    public var name: String
    public var colorHex: String?
    public var isPinned: Bool
    public var isArchived: Bool

    public init(name: String, colorHex: String?, isPinned: Bool, isArchived: Bool) {
        self.name = name
        self.colorHex = colorHex
        self.isPinned = isPinned
        self.isArchived = isArchived
    }
}

// MARK: - シェルフ

/// 保存した絞り込み 1 件 [SH-01][SH-12]。
///
/// **列挙は生の文字列で持つ** — `coverImageSource` / `VolumeFormatBackup.kind`
/// と同じ扱い。型をそのまま埋めると、将来 case を増減したときに**未知の
/// 生値で文書全体の取り込みが失敗する**（`Decodable` は不明な rawValue を
/// エラーにする）。読めない値は取り込み側が既定へ落とす。
public struct ShelfBackup: Codable, Sendable, Equatable {
    public var name: String
    public var displayOrder: Int
    /// 選んでいたラベル。**行 ID ではなく `groupIndex` + ラベル名**で突き合わせる
    /// [JS-04]——行 ID は環境依存で、別のマシンで取り込むと無関係なラベルを指す。
    public var labels: [ShelfLabelBackup]
    /// 0〜5。`nil` なら評価で絞らない [RT-01]。
    public var ratingStars: Int?
    /// `FileQuery.RatingFilter.Mode` の生値（`atLeast` / `exact`）[RT-03]。
    public var ratingMode: String?
    public var searchText: String?
    /// `FileQuery.SortKey` の生値 [VM-15]。
    public var sortKey: String
    public var sortAscending: Bool
    /// `FileQuery.DisplayMode` の生値 [VM-10]。
    public var displayMode: String

    public init(name: String, displayOrder: Int, labels: [ShelfLabelBackup],
                ratingStars: Int?, ratingMode: String?, searchText: String?,
                sortKey: String, sortAscending: Bool, displayMode: String) {
        self.name = name
        self.displayOrder = displayOrder
        self.labels = labels
        self.ratingStars = ratingStars
        self.ratingMode = ratingMode
        self.searchText = searchText
        self.sortKey = sortKey
        self.sortAscending = sortAscending
        self.displayMode = displayMode
    }
}

/// シェルフが参照するラベル [SH-12]。`FileLabelBackup` と同じ主キーの取り方。
public struct ShelfLabelBackup: Codable, Sendable, Equatable {
    public var groupIndex: Int
    public var labelName: String

    public init(groupIndex: Int, labelName: String) {
        self.groupIndex = groupIndex
        self.labelName = labelName
    }
}

// MARK: - フォーマット類

public struct FormatBackup: Codable, Sendable, Equatable {
    public var source: String
    public var priority: Int
    public var isEnabled: Bool

    public init(source: String, priority: Int, isEnabled: Bool) {
        self.source = source
        self.priority = priority
        self.isEnabled = isEnabled
    }
}

public struct VolumeFormatBackup: Codable, Sendable, Equatable {
    /// 正規表現。
    public var source: String
    public var priority: Int
    public var isEnabled: Bool
    /// `VolumePatternKind` の生値（`volume` / `separator`）。
    public var kind: String

    public init(source: String, priority: Int, isEnabled: Bool, kind: String) {
        self.source = source
        self.priority = priority
        self.isEnabled = isEnabled
        self.kind = kind
    }

    private enum CodingKeys: String, CodingKey {
        case source, priority, isEnabled, kind
        /// 版 1 の遺物。読み込みの判別にだけ使い、書き出しはしない。
        case ordinalRank
    }

    /// **`kind` が無い＝版 1 の文書**とみなし、記法と種別をその場で変換する。
    /// 版の番号ではなくキーの有無で判別するのは、文書全体の版に依存せず
    /// この型だけで完結させるため。書き出し側は必ず `kind` を書く。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        priority = try c.decode(Int.self, forKey: .priority)
        isEnabled = try c.decode(Bool.self, forKey: .isEnabled)
        let rawSource = try c.decode(String.self, forKey: .source)

        if let kind = try c.decodeIfPresent(String.self, forKey: .kind) {
            self.kind = kind
            source = rawSource
        } else {
            let ordinalRank = try c.decodeIfPresent(Int.self, forKey: .ordinalRank)
            // 序列巻数だったものは「シリーズ名を切るだけ」の種別へ移す。
            self.kind = (ordinalRank == nil ? VolumePatternKind.volume : .separator).rawValue
            source = LegacyVolumeNotation.regex(fromVolumeSource: rawSource)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(source, forKey: .source)
        try c.encode(priority, forKey: .priority)
        try c.encode(isEnabled, forKey: .isEnabled)
        try c.encode(kind, forKey: .kind)
    }
}

public struct FolderLevelMappingBackup: Codable, Sendable, Equatable {
    public var level: Int
    public var assignmentKind: String
    public var labelGroupIndex: Int?
    public var formatSource: String?

    public init(level: Int, assignmentKind: String, labelGroupIndex: Int?, formatSource: String?) {
        self.level = level
        self.assignmentKind = assignmentKind
        self.labelGroupIndex = labelGroupIndex
        self.formatSource = formatSource
    }
}

public struct ProtectedTokenBackup: Codable, Sendable, Equatable {
    /// 正規表現。
    public var pattern: String
    public var position: String
    public var isEnabled: Bool

    public init(pattern: String, position: String, isEnabled: Bool) {
        self.pattern = pattern
        self.position = position
        self.isEnabled = isEnabled
    }

    private enum CodingKeys: String, CodingKey {
        case pattern, position, isEnabled
        /// 版 1 の遺物（完全一致のリテラル）。読み込みの判別にだけ使う。
        case text
    }

    /// **`pattern` が無い＝版 1 の文書**とみなし、リテラルを正規表現へ変換する。
    /// 空白の連なりは `\s+` にする——旧実装の弾力的な空白照合 [PT-04] を保つため。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        position = try c.decode(String.self, forKey: .position)
        isEnabled = try c.decode(Bool.self, forKey: .isEnabled)
        if let pattern = try c.decodeIfPresent(String.self, forKey: .pattern) {
            self.pattern = pattern
        } else {
            let literal = try c.decode(String.self, forKey: .text)
            pattern = LegacyVolumeNotation.regex(fromProtectedLiteral: literal)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(pattern, forKey: .pattern)
        try c.encode(position, forKey: .position)
        try c.encode(isEnabled, forKey: .isEnabled)
    }
}

// MARK: - ファイル

/// ファイル 1 件のうち**再生成できない部分だけ** [MG-22]。
///
/// 同一性キーは `relativePath` + `filename` [IE-10][JS-04]。
public struct FileBackup: Codable, Sendable, Equatable {
    public var relativePath: String
    public var filename: String
    /// 評価 [RA-01]。0 は未評価。
    public var rating: Int
    /// **版 2 以前を読むためだけに残してある** [PR-08]。書き出しでは常に
    /// `nil`（キーごと出ない）。取り込みでは `LegacyMetadataProtection` が
    /// これを基本情報スコープの保護へ読み替える。
    public var titleOrigin: String?
    /// 基本情報 [PR-02]。**保護されているときだけ出す**——保護されていない値は
    /// 走査が作り直すので、10 万件ぶん書いても取り込みが何もしない。
    /// **4 つとも出す**のが要点で、`title` だけ出すと保護したシリーズ名や
    /// 巻数が復元で失われる（保護の単位は 4 つで 1 かたまり）。
    public var title: String?
    public var seriesName: String?
    public var volumeNumber: Double?
    public var volumeKind: String?
    public var volumeRaw: String?
    public var authorName: String?
    /// 自動更新から守られているスコープ [PR-02][PR-09]。
    ///
    /// **`field:` の番号はライブラリ内のフィールド番号**（`groupIndex`）で、
    /// DB の行 ID ではない——ラベル紐づけを `groupIndex` で突き合わせるのと
    /// 同じ理由 [JS-04]。行 ID を書くと、別の環境で取り込んだときに無関係な
    /// フィールドを保護する。
    ///
    /// **`[String]?` なのは版 2 以前の文書を読むため**（`isUnresolvedIgnored`
    /// と同じ事情）。`nil` は「この文書は保護を知らない」で、そのときは
    /// `titleOrigin` と紐づけの `origin` から導く。
    public var protectedScopes: [String]?
    /// `CoverSource` の生値（`"auto"` / `"sidecar"` / `"userSpecified"`）。
    /// `userSpecified` のときだけ `coverImageRef` が意味を持つ [IV-03][CV2-02]。
    ///
    /// **`"user"` ではない。** 2-10 でカバーの差し替えを実装するまで書き手が
    /// 居らず、この注記だけが `"user"` と述べていた（実際に書かれるのは
    /// `CoverSource.userSpecified.rawValue`）。判定は `CoverSource.auto` との
    /// 比較で行っているので振る舞いは変わらないが、注記のほうを実態に揃えた。
    public var coverImageSource: String
    public var coverImageRef: String?
    public var isArchived: Bool
    public var archivedFromPath: String?
    public var archivedAt: Date?
    public var state: String
    public var trashedAt: Date?
    /// 未解決一覧で「以後無視する」を立てたか [AL-33][MG-22]。
    ///
    /// **走査からは作り直せない利用者の判断**（`origin == "manual"` と同じ性質）
    /// なので、バックアップに含める。`unresolvedFile` の行そのものは走査が
    /// 作り直すので、出すのはこの 1 つだけでよい——テーブルは `managedFile` と
    /// 1:1 なので、ファイルの属性として畳める。
    ///
    /// **`Bool?` なのは古い文書を読むため。** このキーを持たない版 1／2 の
    /// 文書があり、非 Optional にすると `keyNotFound` で**文書全体の取り込みが
    /// 失敗する**（合成された `Decodable` はプロパティの既定値を使わない [実測]）。
    /// `schemaVersion` は上げていない——読み込みが `<=` 判定なので、キーが
    /// 増えただけの追加は古い実装からも読める。
    public var isUnresolvedIgnored: Bool?
    public var labels: [FileLabelBackup]

    public init(relativePath: String, filename: String, rating: Int,
                titleOrigin: String? = nil, title: String?,
                seriesName: String? = nil, volumeNumber: Double? = nil,
                volumeKind: String? = nil, volumeRaw: String? = nil,
                authorName: String? = nil,
                protectedScopes: [String]? = nil,
                coverImageSource: String, coverImageRef: String?,
                isArchived: Bool, archivedFromPath: String?, archivedAt: Date?,
                state: String, trashedAt: Date?,
                isUnresolvedIgnored: Bool? = nil, labels: [FileLabelBackup]) {
        self.relativePath = relativePath
        self.filename = filename
        self.rating = rating
        self.titleOrigin = titleOrigin
        self.title = title
        self.seriesName = seriesName
        self.volumeNumber = volumeNumber
        self.volumeKind = volumeKind
        self.volumeRaw = volumeRaw
        self.authorName = authorName
        self.protectedScopes = protectedScopes
        self.coverImageSource = coverImageSource
        self.coverImageRef = coverImageRef
        self.isArchived = isArchived
        self.archivedFromPath = archivedFromPath
        self.archivedAt = archivedAt
        self.state = state
        self.trashedAt = trashedAt
        self.isUnresolvedIgnored = isUnresolvedIgnored
        self.labels = labels
    }

    /// 突き合わせの主キー [IE-10]。
    public var identityKey: String { "\(relativePath)\u{0000}\(filename)" }
}

/// ファイルとラベルの紐づけ [PR-08]。
///
/// **行があること＝付いていること。** 再生成できるかどうかは、そのフィールドが
/// 保護されているか [PR-02] で決まる（`FileBackup.protectedScopes`）。
public struct FileLabelBackup: Codable, Sendable, Equatable {
    public var groupIndex: Int
    /// 人が読むため、および将来のライブラリ間マージのため [IE-10]。
    /// 復元の主キーは `groupIndex` + `labelName`。
    public var groupName: String
    public var labelName: String
    /// **版 2 以前を読むためだけに残してある** [PR-08]。書き出しでは常に `nil`。
    /// `manuallyRemoved` の行は取り込みで落とし、`manual` はそのフィールドの
    /// 保護へ読み替える。
    public var origin: String?
    public var assignedAt: Date

    public init(groupIndex: Int, groupName: String, labelName: String,
                origin: String? = nil, assignedAt: Date) {
        self.groupIndex = groupIndex
        self.groupName = groupName
        self.labelName = labelName
        self.origin = origin
        self.assignedAt = assignedAt
    }
}
