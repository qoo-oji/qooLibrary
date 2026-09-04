//
//  ユーザー定義テンプレート [LT-02][LT-05][LT-06]。
//
//  ## プリセットと何が違うか
//  プリセット（`LibraryTypeTemplate`）が持つのは 9 項目で、対象拡張子・保護
//  文字列・区切り・シリーズ名の組み立て・フィールドの色は持たない——それらは
//  `TemplateInstantiation.draft(from:)` が既定値として入れる。**既定値の
//  出どころをあの 1 箇所に閉じるための意図的な非対称**なので、プリセットの
//  書式は据え置く［ユーザー判断、2026-09-04］。
//
//  ユーザー定義はその逆で、**編集した設定をそのまま再利用したい**のが目的
//  なので、草案（`LibrarySettingsDraft`）が持つ設定を漏れなく保存する。
//  プリセット型に揃えると、保存して読み直した瞬間に 11 項目が黙って落ち、
//  とくに**編集した巻数フォーマットは丸ごと消える**（あちらはセット名参照）。
//
//  ## 扱いは同等にする
//  一覧・推奨・登録・編集はすべて**草案へ畳んでから**行う。プリセットは
//  `draft(from:)`、ユーザー定義は `settings.draft(...)` で草案になるので、
//  そこから先の経路は 1 本で済む。
//
//  ## 参照名を持たない
//  プリセットは巻数フォーマットを `volumeSet: "VS-Full"` という**名前**で
//  参照するが、ユーザー定義は具体パターンを持つ。取り込んだ文書が存在しない
//  セット名を指していて**巻数を一切読まない状態になる**、という失敗様式が
//  構造的に起こらない（同種の実例: OrcaSlicer の「対応するプリンタを先に
//  インポートしてください」）。
//
import Foundation

// MARK: - 設定本体

/// テンプレートが持つ設定。`LibrarySettingsDraft` の**永続化できる部分**の写し。
///
/// ## 鍵は草案のプロパティ名に揃える
/// `UserTemplateCoverageTests` が `Mirror` で草案の全プロパティを走査し、
/// ここに同名の鍵があるか、意図的な除外に載っているかを検査する。**草案へ
/// 設定を足したらこの型にも足すこと**——忘れるとそのテストが落ちる。
///
/// ## 意図的に持たないもの
/// | 何 | なぜ |
/// |---|---|
/// | `displayName` | ライブラリの表示名はフォルダ名に追随する [RG3-31]。テンプレートが持つと登録時に食い違う |
/// | `otherLibraryTypeNames` | 「自分以外のライブラリの型名」という**文脈**であって設定ではない |
/// | 各 draft の `id` | 開くたびに振り直す揮発値。持つと 2 つのテンプレートが同じ id を配る |
/// | `FieldDraft.persistentID` | DB の行 ID。テンプレートに持たせると別ライブラリの行を指す |
public struct UserTemplateSettings: Sendable, Codable, Hashable {

    /// フィールド 1 件 [LG-01]。
    public struct Field: Sendable, Codable, Hashable {
        public var index: Int
        public var name: String
        public var colorHexLight: String
        public var colorHexDark: String
        public var assignsAutomatically: Bool

        public init(index: Int, name: String, colorHexLight: String,
                    colorHexDark: String, assignsAutomatically: Bool) {
            self.index = index
            self.name = name
            self.colorHexLight = colorHexLight
            self.colorHexDark = colorHexDark
            self.assignsAutomatically = assignsAutomatically
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            index = try c.decodeIfPresent(Int.self, forKey: .index) ?? 1
            name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
            colorHexLight = try c.decodeIfPresent(String.self, forKey: .colorHexLight) ?? ""
            colorHexDark = try c.decodeIfPresent(String.self, forKey: .colorHexDark) ?? ""
            assignsAutomatically =
                try c.decodeIfPresent(Bool.self, forKey: .assignsAutomatically) ?? true
        }
    }

    /// ファイル名フォーマット 1 本 [FF-03]。
    public struct FilenameFormat: Sendable, Codable, Hashable {
        public var source: String
        public var isEnabled: Bool

        public init(source: String, isEnabled: Bool) {
            self.source = source
            self.isEnabled = isEnabled
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            source = try c.decodeIfPresent(String.self, forKey: .source) ?? ""
            isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        }
    }

    /// 巻数フォーマット 1 本 [SE-21]。**セット名ではなく実体を持つ**（型の解説）。
    public struct VolumeFormat: Sendable, Codable, Hashable {
        public var source: String
        public var isEnabled: Bool
        public var kind: VolumePatternKind

        public init(source: String, isEnabled: Bool, kind: VolumePatternKind) {
            self.source = source
            self.isEnabled = isEnabled
            self.kind = kind
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            source = try c.decodeIfPresent(String.self, forKey: .source) ?? ""
            isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
            kind = try c.decodeIfPresent(VolumePatternKind.self, forKey: .kind) ?? .volume
        }
    }

    /// フォルダ階層の割り当て 1 件 [AL-01〜AL-03]。
    ///
    /// **生値は `library-types.json` と揃える**（`singleLabelGroup` / `format` /
    /// `none`）——同じ意味のものを 2 通りの綴りで書かない。
    public struct FolderLevel: Sendable, Codable, Hashable {
        public enum Kind: String, Sendable, Codable, Hashable {
            case none, singleLabelGroup, format
        }
        public var level: Int
        public var kind: Kind
        /// `kind == .singleLabelGroup` のときだけ意味を持つ。
        public var field: Int?
        /// `kind == .format` のときだけ意味を持つ。**コンパイル前のソース**。
        public var format: String?

        public init(level: Int, kind: Kind, field: Int? = nil, format: String? = nil) {
            self.level = level
            self.kind = kind
            self.field = field
            self.format = format
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            level = try c.decodeIfPresent(Int.self, forKey: .level) ?? 1
            kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .none
            field = try c.decodeIfPresent(Int.self, forKey: .field)
            format = try c.decodeIfPresent(String.self, forKey: .format)
        }
    }

    public var thumbnailsAlwaysHidden: Bool
    public var duplicateGrouping: DuplicateGrouping
    public var targetExtensions: [String]
    public var imageExtensions: [String]
    public var delimiters: DelimiterSet
    /// **`id` を落として持つ**（型の解説の表）。読み込みで振り直す。
    public var protectedTokens: [ProtectedTokenSpec]
    public var fields: [Field]
    /// 予約語の綴り → フィールド番号 [RW-13]。**キーは `SemanticKeyword` の
    /// 生値**——未知の綴りは読み飛ばす（撤去された予約語を含む古い文書のため）。
    public var semanticBindings: [String: Int]
    public var filenameFormats: [FilenameFormat]
    public var volumeFormats: [VolumeFormat]
    public var folderLevels: [FolderLevel]
    public var seriesTitleCompositionFormat: String
    public var readsEmbeddedMetadata: Bool
    public var comicInfoVolumeSource: ComicInfoVolumeSource
    public var opensBookFolderWithApp: Bool

    /// 保護文字列 1 件。`ProtectedToken` から `id` を落としたもの。
    public struct ProtectedTokenSpec: Sendable, Codable, Hashable {
        public var pattern: String
        public var position: ProtectedToken.Position
        public var isEnabled: Bool

        public init(pattern: String, position: ProtectedToken.Position, isEnabled: Bool) {
            self.pattern = pattern
            self.position = position
            self.isEnabled = isEnabled
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            pattern = try c.decodeIfPresent(String.self, forKey: .pattern) ?? ""
            position = try c.decodeIfPresent(ProtectedToken.Position.self,
                                             forKey: .position) ?? .anywhere
            isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        }
    }

    public init(thumbnailsAlwaysHidden: Bool = false,
                duplicateGrouping: DuplicateGrouping = .off,
                targetExtensions: [String] = [],
                imageExtensions: [String] = [],
                delimiters: DelimiterSet = .default,
                protectedTokens: [ProtectedTokenSpec] = [],
                fields: [Field] = [],
                semanticBindings: [String: Int] = [:],
                filenameFormats: [FilenameFormat] = [],
                volumeFormats: [VolumeFormat] = [],
                folderLevels: [FolderLevel] = [],
                seriesTitleCompositionFormat: String = "@series @volume",
                readsEmbeddedMetadata: Bool = true,
                comicInfoVolumeSource: ComicInfoVolumeSource = .ask,
                opensBookFolderWithApp: Bool = false) {
        self.thumbnailsAlwaysHidden = thumbnailsAlwaysHidden
        self.duplicateGrouping = duplicateGrouping
        self.targetExtensions = targetExtensions
        self.imageExtensions = imageExtensions
        self.delimiters = delimiters
        self.protectedTokens = protectedTokens
        self.fields = fields
        self.semanticBindings = semanticBindings
        self.filenameFormats = filenameFormats
        self.volumeFormats = volumeFormats
        self.folderLevels = folderLevels
        self.seriesTitleCompositionFormat = seriesTitleCompositionFormat
        self.readsEmbeddedMetadata = readsEmbeddedMetadata
        self.comicInfoVolumeSource = comicInfoVolumeSource
        self.opensBookFolderWithApp = opensBookFolderWithApp
    }

    /// **すべての鍵を `decodeIfPresent` で読む。**
    ///
    /// 合成された `Decodable` は**プロパティの既定値を使わず**、鍵が無いと
    /// `keyNotFound` で失敗する [実測]。取り込む文書は古いアプリが書いたもの
    /// かもしれないので、鍵 1 つの欠落で**文書全体が読めなくなってはならない**
    /// （`LibrarySettingsPayload` と `AppAssociationStore` で踏んだのと同じ罠）。
    /// **フィールドを足したらここへ 1 行足すこと。**忘れると
    /// `UserTemplateTests.everyFieldSurvivesARoundTrip` が落ちる。
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) throws -> T {
            try c.decodeIfPresent(T.self, forKey: key) ?? fallback
        }
        thumbnailsAlwaysHidden = try value(.thumbnailsAlwaysHidden, false)
        duplicateGrouping = try value(.duplicateGrouping, .off)
        targetExtensions = try value(.targetExtensions, [])
        imageExtensions = try value(.imageExtensions, [])
        delimiters = try value(.delimiters, .default)
        protectedTokens = try value(.protectedTokens, [])
        fields = try value(.fields, [])
        semanticBindings = try value(.semanticBindings, [:])
        filenameFormats = try value(.filenameFormats, [])
        volumeFormats = try value(.volumeFormats, [])
        folderLevels = try value(.folderLevels, [])
        seriesTitleCompositionFormat = try value(.seriesTitleCompositionFormat, "@series @volume")
        readsEmbeddedMetadata = try value(.readsEmbeddedMetadata, true)
        comicInfoVolumeSource = try value(.comicInfoVolumeSource, .ask)
        opensBookFolderWithApp = try value(.opensBookFolderWithApp, false)
    }
}

// MARK: - テンプレート 1 件

public struct UserTemplate: Sendable, Codable, Hashable, Identifiable {
    /// 身元。**名前は身元ではない**——同名を許す（[LT-02] は名前の一意性を
    /// 求めていないし、取り込みで名前がぶつかるたびに片方を消すのは危うい）。
    public var id: UUID
    public var name: String
    /// 保存のたびに +1 [LT-10 と同じ考え方]。差分適用 [LT-13〜16] には使わないが、
    /// 取り込み時に「どちらが新しいか」を言えるようにしておく。
    public var version: Int
    public var createdAt: Date
    public var updatedAt: Date
    public var settings: UserTemplateSettings

    public init(id: UUID = UUID(), name: String, version: Int = 1,
                createdAt: Date = Date(), updatedAt: Date = Date(),
                settings: UserTemplateSettings) {
        self.id = id
        self.name = name
        self.version = version
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.settings = settings
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        let created = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        createdAt = created
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? created
        settings = try c.decodeIfPresent(UserTemplateSettings.self, forKey: .settings)
            ?? UserTemplateSettings()
    }
}

// MARK: - 文書（保存ファイル ＝ 書き出し文書）

/// ユーザー定義テンプレートの外部表現 [LT-06]。
///
/// **保存ファイルと書き出し文書で同じ型を使う。** 別々の書式にすると、
/// 保存ファイルを直接渡された取り込みが読めない／逆も然り、という
/// 説明のつかない非対称ができる（OrcaSlicer が「ユーザーのプリセットだけ
/// 書式が違い、どこにも文書化されていない」で報告されている形）。
public struct UserTemplateDocument: Sendable, Codable, Hashable {
    /// **取り込みは `<=` で判定する**（既存の JSON バックアップと同じ作法）
    /// ——新しいアプリが書いた文書を古いアプリが黙って壊しながら読まない。
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var templates: [UserTemplate]

    public init(schemaVersion: Int = UserTemplateDocument.currentSchemaVersion,
                templates: [UserTemplate]) {
        self.schemaVersion = schemaVersion
        self.templates = templates
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        templates = try c.decodeIfPresent([UserTemplate].self, forKey: .templates) ?? []
    }

    /// 読める文書か [F21]。**新しすぎる版は読まない。**
    public var isReadable: Bool { schemaVersion <= Self.currentSchemaVersion }

    // MARK: - 書式

    /// **符号化・復号の設定はこの型が持つ。**
    ///
    /// 保存ファイルと書き出し文書は同じ型なので、`JSONEncoder` を
    /// 呼ぶ側それぞれが設定を決めると**書いた側と読む側で日付の書式が
    /// 食い違う**——実装中に実際にそうなり、保存したファイルが次回の
    /// 読み込みで毎回「壊れている」と判定されて退避されるところだった。
    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
