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
//  `title` は `titleOrigin == "manual"` のときだけ再生成不可能 [RP-11]、
//  `coverImageRef` は `coverImageSource == "userSpecified"` のときだけ [IV-03]、
//  ラベル紐づけは `origin != "auto"` のときだけ [RC-04]。**列ではなく値で
//  分かれる**ので、これらは判定に使う列ごと JSON へ出す。
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
    public static let currentSchemaVersion = 2

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
    public var caseSensitive: Bool
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
    public var files: [FileBackup]

    public init(uuid: UUID, displayName: String, rootPath: String, volumeUUID: String,
                libraryType: LibraryTypeBackup, caseSensitive: Bool,
                duplicateGrouping: String, thumbnailsAlwaysHidden: Bool,
                settings: String, labelGroups: [LabelGroupBackup],
                filenameFormats: [FormatBackup], volumeFormats: [VolumeFormatBackup],
                folderLevelMappings: [FolderLevelMappingBackup],
                protectedTokens: [ProtectedTokenBackup], files: [FileBackup]) {
        self.uuid = uuid
        self.displayName = displayName
        self.rootPath = rootPath
        self.volumeUUID = volumeUUID
        self.libraryType = libraryType
        self.caseSensitive = caseSensitive
        self.duplicateGrouping = duplicateGrouping
        self.thumbnailsAlwaysHidden = thumbnailsAlwaysHidden
        self.settings = settings
        self.labelGroups = labelGroups
        self.filenameFormats = filenameFormats
        self.volumeFormats = volumeFormats
        self.folderLevelMappings = folderLevelMappings
        self.protectedTokens = protectedTokens
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
    /// `"auto"` / `"manual"`。`manual` のときだけ `title` が意味を持つ [RP-11]。
    public var titleOrigin: String
    public var title: String?
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
    public var isDuplicateRepresentativePinned: Bool
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
                titleOrigin: String, title: String?,
                coverImageSource: String, coverImageRef: String?,
                isArchived: Bool, archivedFromPath: String?, archivedAt: Date?,
                isDuplicateRepresentativePinned: Bool,
                state: String, trashedAt: Date?,
                isUnresolvedIgnored: Bool? = nil, labels: [FileLabelBackup]) {
        self.relativePath = relativePath
        self.filename = filename
        self.rating = rating
        self.titleOrigin = titleOrigin
        self.title = title
        self.coverImageSource = coverImageSource
        self.coverImageRef = coverImageRef
        self.isArchived = isArchived
        self.archivedFromPath = archivedFromPath
        self.archivedAt = archivedAt
        self.isDuplicateRepresentativePinned = isDuplicateRepresentativePinned
        self.state = state
        self.trashedAt = trashedAt
        self.isUnresolvedIgnored = isUnresolvedIgnored
        self.labels = labels
    }

    /// 突き合わせの主キー [IE-10]。
    public var identityKey: String { "\(relativePath)\u{0000}\(filename)" }
}

/// ファイルとラベルの紐づけ [RC-04]。
///
/// **`origin` ごと出す。** `auto` は再スキャンで作り直せるが、`manual` と
/// `manuallyRemoved` は作り直せない——後者は「自動で付いたラベルを人が
/// 外した」という記録で、失うと再スキャンのたびに復活してしまう。
public struct FileLabelBackup: Codable, Sendable, Equatable {
    public var groupIndex: Int
    /// 人が読むため、および将来のライブラリ間マージのため [IE-10]。
    /// 復元の主キーは `groupIndex` + `labelName`。
    public var groupName: String
    public var labelName: String
    public var origin: String
    public var assignedAt: Date

    public init(groupIndex: Int, groupName: String, labelName: String,
                origin: String, assignedAt: Date) {
        self.groupIndex = groupIndex
        self.groupName = groupName
        self.labelName = labelName
        self.origin = origin
        self.assignedAt = assignedAt
    }
}
