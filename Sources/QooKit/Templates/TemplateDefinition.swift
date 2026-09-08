//
//  プリセットテンプレートと巻数フォーマットセット [11.3][11.4][LT-01〜LT-06][MT-02]。
//
//  **コード内のリテラルではなくリソース（JSON）として持つ** [MT-02]。
//  `Sources/QooKit/Resources/Templates/` に置き、`Bundle.module` から読む。
//  ユーザー定義テンプレートも同じ DTO で入出力できる [LT-06]。
//
import Foundation

public struct VolumeSetDefinition: Sendable, Codable, Hashable {
    public struct Entry: Sendable, Codable, Hashable {
        /// 正規表現。巻数は `(?<volume>…)` か唯一のキャプチャグループから取る。
        public let source: String
        /// 省略時は `.volume`。`separator` はシリーズ名を切るだけで巻数を持たない。
        public let kind: VolumePatternKind?
    }
    public let sets: [String: [Entry]]

    private enum CodingKeys: String, CodingKey { case sets }

    public init(sets: [String: [Entry]]) { self.sets = sets }

    /// 巻数フォーマットセットを 1 つも持たない定義。読み込みに失敗した経路が
    /// 「何も無い」を表すために使う（`nil` を配り歩くより取り違えが少ない）。
    public static let empty = VolumeSetDefinition(sets: [:])

    /// 名前で引いて `VolumePattern` の列にする。列挙順が優先順になる [SE-21]。
    ///
    /// **役割は集合そのものではなく、呼び出し側が渡す** [MF-07][MF-09]。
    /// `ES-Standard` のような名前から推測させると、名前と中身が食い違っても
    /// コンパイラも静的検査も止められない——テンプレートが `episodeSet:` として
    /// 指したのだから話数、と決まるほうが取り違えようがない。
    public func patterns(named name: String,
                         role: PatternRole = .volume) -> [VolumePattern]? {
        guard let entries = sets[name] else { return nil }
        return entries.enumerated().map { i, e in
            VolumePattern(source: e.source, priority: i,
                          kind: e.kind ?? .volume, role: role)
        }
    }
}

public struct LibraryTypeTemplate: Sendable, Codable, Hashable, Identifiable {
    public struct FieldSpec: Sendable, Codable, Hashable {
        public let index: Int
        public let name: String
        /// `false` = 自動ラベル付与の対象外（ユーザーが手動で設定するまで無効）。
        public let autoAssign: Bool?
        public var assignsAutomatically: Bool { autoAssign ?? true }
    }

    public struct FolderLevelSpec: Sendable, Codable, Hashable {
        public enum Kind: String, Sendable, Codable { case singleLabelGroup, format, none }
        public let kind: Kind
        public let labelGroup: Int?
        public let format: String?
    }

    /// プリセットの安定した識別子。アプリ更新をまたいだ同定に使う [LT-10]。
    public let key: String
    public let displayName: String
    public let libraryTypeName: String
    /// 改訂の検出用 [LT-10][LT-12]。
    public let version: Int
    /// **JSON のキーは `labelGroups` のまま**——`library-types.json` に
    /// 書かれている綴りで、改名すると読めなくなる。Swift 側の呼び名だけ
    /// フィールドへ揃えるため `fields` を計算プロパティとして併設する。
    public let labelGroups: [FieldSpec]
    public var fields: [FieldSpec] { labelGroups }
    /// 予約語 → ラベルフィールド番号 [RW-13]。
    public let semanticBindings: [String: Int]
    /// 階層番号（文字列キー）→ 割り当て [AL-01〜AL-03]。
    public let folderLevels: [String: FolderLevelSpec]
    /// 優先順に並んだファイル名フォーマット [FF-03]。
    public let filenameFormats: [String]
    public let volumeSet: String
    /// `@episode` 用の正規表現セット名 [MF-09][MF-14]。省略時は使わない。
    ///
    /// **`String?` にしてあるのは、この鍵を持たない既存の文書
    /// （`library-types.json` の 4 プリセット・ユーザー定義テンプレート・
    /// 登録時の定義 `registeredTemplateJSON`）をそのまま読むため**
    /// ——非 Optional にすると `keyNotFound` で文書全体の取り込みが失敗する。
    public let episodeSet: String?
    /// `@season` 用の正規表現セット名 [MF-09][MF-14]。
    public let seasonSet: String?
    /// `@date` 用の正規表現セット名 [MF-09][MF-19]。
    public let dateSet: String?
    /// 対象拡張子 [MF-14]。**省略時は `AppDefaults.Library.targetExtensions`**
    /// （要件定義書 11.4 節の「全テンプレート共通」）。
    ///
    /// 映像プリセットだけがこれを持つ——コミックの容器（`cbz` 等）で映像
    /// ライブラリを登録すると走査が 1 件も拾わず、しかも**画面には
    /// 「0 件」としか出ない**ので理由が読めない。
    public let targetExtensions: [String]?
    /// `title` を持たない行の表示名の組み立て [SE-33][MF-11]。省略時は
    /// `@series @volume`（コミックの既定）。
    public let seriesTitleFormat: String?

    public var id: String { key }

    public init(key: String, displayName: String, libraryTypeName: String,
                version: Int, labelGroups: [FieldSpec],
                semanticBindings: [String: Int],
                folderLevels: [String: FolderLevelSpec],
                filenameFormats: [String], volumeSet: String,
                episodeSet: String? = nil, seasonSet: String? = nil,
                dateSet: String? = nil, targetExtensions: [String]? = nil,
                seriesTitleFormat: String? = nil)
    {
        self.key = key
        self.displayName = displayName
        self.libraryTypeName = libraryTypeName
        self.version = version
        self.labelGroups = labelGroups
        self.semanticBindings = semanticBindings
        self.folderLevels = folderLevels
        self.filenameFormats = filenameFormats
        self.volumeSet = volumeSet
        self.episodeSet = episodeSet
        self.seasonSet = seasonSet
        self.dateSet = dateSet
        self.targetExtensions = targetExtensions
        self.seriesTitleFormat = seriesTitleFormat
    }

    /// 役割ごとに引く集合名。`nil` の役割はこのテンプレートでは使わない。
    ///
    /// **`.volume` だけ必須で残りは任意**——コミックのプリセットは巻数しか
    /// 持たず、映像のプリセットが話数・シーズンを足す [MF-14]。
    public var patternSetNames: [(role: PatternRole, name: String)] {
        var out: [(PatternRole, String)] = [(.volume, volumeSet)]
        if let episodeSet { out.append((.episode, episodeSet)) }
        if let seasonSet { out.append((.season, seasonSet)) }
        if let dateSet { out.append((.date, dateSet)) }
        return out
    }

    public var semanticKeywordBindings: [SemanticKeyword: Int] {
        var out: [SemanticKeyword: Int] = [:]
        for (raw, field) in semanticBindings {
            guard let keyword = SemanticKeyword(rawValue: raw) else { continue }
            out[keyword] = field
        }
        return out
    }
}

public struct LibraryTypeTemplateBundle: Sendable, Codable {
    public let presets: [LibraryTypeTemplate]
    private enum CodingKeys: String, CodingKey { case presets }
}

// MARK: - 読み込み

public enum BuiltInTemplates {
    public enum LoadError: Error, Equatable {
        case resourceNotFound(String)
        case malformed(String, String)
    }

    public static let volumeSetsResource = "volume-sets"
    public static let libraryTypesResource = "library-types"

    /// 巻数フォーマットセット [11.3]。
    public static func volumeSets() throws -> VolumeSetDefinition {
        try decode(VolumeSetDefinition.self, from: volumeSetsResource)
    }

    /// プリセットのライブラリタイプ [11.4]。
    /// `@mediatype` の照合語彙の**既定部分** [TY-01]。
    ///
    /// **プリセットの `libraryTypeName` から導出する**——手書きの一覧にすると、
    /// プリセットを足したときに片方だけ古くなる（`check-personal-identifiers` が
    /// 除外語を `library-types.json` から導いているのと同じ考え方）。
    /// 実際に使う語彙はこれに「そのライブラリの『本の種別』フィールドに既に
    /// あるラベル」を合わせたもので、後者があるおかげで**利用者独自の種別も育つ**。
    public static func mediaTypes() throws -> [String] {
        Array(Set(try libraryTypes().map(\.libraryTypeName)))
            .filter { !$0.isEmpty }.sorted()
    }

    public static func libraryTypes() throws -> [LibraryTypeTemplate] {
        try decode(LibraryTypeTemplateBundle.self, from: libraryTypesResource).presets
    }

    static func decode<T: Decodable>(_ type: T.Type, from resource: String) throws -> T {
        guard let url = Bundle.module.url(forResource: resource, withExtension: "json",
                                          subdirectory: "Templates")
                ?? Bundle.module.url(forResource: resource, withExtension: "json") else {
            throw LoadError.resourceNotFound(resource)
        }
        do {
            return try JSONDecoder().decode(T.self, from: Data(contentsOf: url))
        } catch {
            throw LoadError.malformed(resource, String(describing: error))
        }
    }
}

// MARK: - テンプレート → 設定スナップショット

public enum TemplateInstantiation {
    public enum Error: Swift.Error, Equatable {
        case unknownVolumeSet(String)
        case formatFailed(String, FormatCompileError)
        case folderFormatFailed(level: Int, FormatCompileError)
    }

    /// テンプレートが参照する正規表現セットを、役割ごとに引いて 1 本の列にする
    /// [MF-09]。見つからない名前は `missing` に返す（判断は呼び出し側）。
    ///
    /// **`priority` は集合ごとに 0 から振り直される。** 照合は役割で絞ってから
    /// 行う（`VolumeMatcher.matches(role:)`）ので、役割をまたいだ番号の重なりは
    /// 同長のときの決着 [SE-21] に影響しない。
    static func volumePatterns(for template: LibraryTypeTemplate,
                               volumeSets: VolumeSetDefinition)
        -> (patterns: [VolumePattern], missing: [String])
    {
        var patterns: [VolumePattern] = []
        var missing: [String] = []
        for (role, name) in template.patternSetNames {
            guard let found = volumeSets.patterns(named: name, role: role) else {
                missing.append(name)
                continue
            }
            patterns.append(contentsOf: found)
        }
        return (patterns, missing)
    }

    /// テンプレートからパーサ用の設定スナップショットを組み立てる [LT-03]。
    ///
    /// ライブラリ登録時に一度だけ呼び、以後の設定変更はライブラリ側に写す
    /// （テンプレート本体には影響しない）[LT-03]。
    public static func snapshot(from template: LibraryTypeTemplate,
                               volumeSets: VolumeSetDefinition,
                               libraryID: LibraryID,
                               displayName: String = "",
                               mediaTypeVocabulary: [String] = [],
                               delimiters: DelimiterSet = .default,
                               /// 省略すると `draft(from:)` と**同じ既定**が入る。
                               /// 揃えないと、ここで測った結果が実際に登録された
                               /// ライブラリの挙動と食い違う。
                               protectedTokens: [ProtectedToken]
                                   = AppDefaults.Library.protectedTokenPatterns.map {
                                       ProtectedToken(pattern: $0)
                                   })
        throws(Error) -> LibrarySettingsSnapshot
    {
        let (patterns, missingSets) = volumePatterns(for: template,
                                                     volumeSets: volumeSets)
        // **`episodeSet` 等の綴り誤りもここで止める。** 黙って飛ばすと、話数を
        // 取るはずのライブラリが 1 件も一致しないまま登録される。
        if let missing = missingSets.first { throw .unknownVolumeSet(missing) }
        let semantic = template.semanticKeywordBindings
        let context = FormatCompilationContext(
            delimiters: delimiters,
            mediaTypeVocabulary: mediaTypeVocabulary.isEmpty
                ? [template.libraryTypeName] : mediaTypeVocabulary,
            semanticBindings: semantic)

        var formats: [CompiledFormat] = []
        formats.reserveCapacity(template.filenameFormats.count)
        for (i, source) in template.filenameFormats.enumerated() {
            do {
                formats.append(try FormatCompiler.compile(source, context: context, priority: i))
            } catch {
                throw .formatFailed(source, error)
            }
        }

        var levels: [Int: FolderLevelMappingSpec.Assignment] = [:]
        for (rawLevel, spec) in template.folderLevels {
            guard let level = Int(rawLevel) else { continue }
            switch spec.kind {
            case .none:
                // **`Assignment.none` と明示する。** 素の `.none` は Swift が
                // `Optional.none` と解釈し、辞書への `nil` 代入＝**キー削除**に
                // なる（コンパイラも警告する）。DB からの復元経路
                // （`SQLiteLibraryRepository.settingsSnapshot`）は修飾ずみで
                // キーを残すため、揃えないとテンプレート由来と DB 由来で
                // 辞書の形が食い違う。現時点の唯一の読み手
                // （`FolderLabelResolver.labelsFromPath`）は「キーが無い」も
                // 「`.none`」も同じく読み飛ばすので挙動は変わらないが、
                // 「その階層は明示的に割り当てない」[AL-03] と「設定されて
                // いない」は別の意味であり、区別を失ってはならない。
                levels[level] = FolderLevelMappingSpec.Assignment.none
            case .singleLabelGroup:
                guard let field = spec.labelGroup else { continue }
                levels[level] = .singleLabelGroup(index: field)
            case .format:
                guard let source = spec.format else { continue }
                do {
                    levels[level] = .format(try FormatCompiler.compile(source, context: context))
                } catch {
                    throw .folderFormatFailed(level: level, error)
                }
            }
        }

        return LibrarySettingsSnapshot(
            libraryID: libraryID,
            displayName: displayName,
            mediaTypeVocabulary: context.mediaTypeVocabulary,
            delimiters: delimiters,
            protectedTokens: ProtectedTokenCompiler.compileAll(protectedTokens),
            filenameFormats: formats,
            folderLevelAssignments: levels,
            volumeFormats: VolumePatternCompiler.compileAll(patterns),
            semanticBindings: semantic)
    }
}

// MARK: - テンプレート → 編集草案 [LT-03][LS-01]

extension TemplateInstantiation {

    /// テンプレートから**編集できる草案**を組み立てる [LT-03][LS-01]。
    ///
    /// ## `snapshot(from:)` との違い
    /// あちらはパーサ用に**コンパイル済み**の設定を返すので、そこから元の
    /// ソース文字列は復元できない——編集には使えない（`LibrarySettingsDraft`
    /// の型コメント参照）。こちらはソース文字列のまま返す。
    ///
    /// ## ここが返す値は「登録される内容そのもの」でなければならない
    /// 有効化ダイアログはこの草案を見せて編集させ、**同じ草案が
    /// `LibraryRepository.register(_:draft:template:)` へ渡って DB になる**。
    /// テンプレート由来の既定値をここと登録側の 2 箇所に書くと、片方だけ
    /// 直したときに「見たものと登録されたものが違う」という、最も気づき
    /// にくい壊れ方をする。**既定値の出どころはこの関数 1 つに閉じること。**
    ///
    /// - Parameter colors: ラベルフィールドの配色 [MT-13]。件数ぶん渡す。
    ///   `QooKit` は配色の決め方を知っているが（`LabelColorPalette`）、
    ///   呼び出し側が別の割り当てを持つ場合に差し替えられるようにしておく。
    public static func draft(from template: LibraryTypeTemplate,
                             volumeSets: VolumeSetDefinition,
                             displayName: String,
                             mediaTypeVocabulary: [String] = []) -> LibrarySettingsDraft {
        let colors = LabelColorPalette.palette(count: max(template.fields.count, 1))
        let fields = template.fields
            .sorted { $0.index < $1.index }
            .enumerated()
            .map { offset, spec in
                let color = colors[min(offset, colors.count - 1)]
                return FieldDraft(
                    index: spec.index, name: spec.name,
                    colorHexLight: color.hexLight, colorHexDark: color.hexDark,
                    assignsAutomatically: spec.assignsAutomatically)
            }

        let volumes = volumePatterns(for: template, volumeSets: volumeSets).patterns
            .map { VolumeFormatDraft(source: $0.source, isEnabled: true,
                                     kind: $0.kind, role: $0.role) }

        // 階層は**番号順に並べる**。辞書の列挙順は不定で、そのまま渡すと
        // 開くたびに行の並びが変わる。
        let levels = template.folderLevels
            .compactMap { rawLevel, spec -> FolderLevelDraft? in
                guard let level = Int(rawLevel) else { return nil }
                let assignment: FolderLevelDraft.Assignment
                switch spec.kind {
                case .none:
                    assignment = FolderLevelDraft.Assignment.none
                case .singleLabelGroup:
                    guard let field = spec.labelGroup else { return nil }
                    assignment = .singleLabelGroup(index: field)
                case .format:
                    guard let source = spec.format else { return nil }
                    assignment = .format(source: source)
                }
                return FolderLevelDraft(level: level, assignment: assignment)
            }
            .sorted { $0.level < $1.level }

        return LibrarySettingsDraft(
            displayName: displayName,
            thumbnailsAlwaysHidden: false,
            // **持たないテンプレートには既定を入れる** [要件定義書 11.4 節:
            // 「対象拡張子は全テンプレート共通」]。空で登録すると走査が
            // `.DS_Store` まで拾うので、ここが既定を入れる正しい場所である。
            // 映像プリセット [MF-14] だけが自分の一覧を持つ。
            targetExtensions: template.targetExtensions
                ?? AppDefaults.Library.targetExtensions.sorted(),
            imageExtensions: [],
            delimiters: .default,
            // テンプレートは保護文字列を持たないので、ここで既定を入れる
            // （対象拡張子と同じ理由・同じ場所）[2026-08 のユーザー要望]。
            protectedTokens: AppDefaults.Library.protectedTokenPatterns.map {
                ProtectedToken(pattern: $0)
            },
            fields: fields,
            semanticBindings: template.semanticKeywordBindings,
            filenameFormats: template.filenameFormats.map {
                FilenameFormatDraft(source: $0, isEnabled: true)
            },
            volumeFormats: volumes,
            folderLevels: levels,
            seriesTitleCompositionFormat: template.seriesTitleFormat ?? "@series @volume",
            mediaTypeVocabulary: mediaTypeVocabulary)
    }

    /// 既定フィールド 6 種と、その意味束縛を組み立てる [§19.2][RWI-02]。
    ///
    /// **番号は 1〜6 に固定する。** 番号はフィールドの身元ではない（身元は
    /// 予約語）が、既定が毎回違う番号に散ると、追加フィールドの番号取りと
    /// 設定画面の並びが登録のたびに変わって読みにくい。
    public static func defaultFields(named names: [String])
        -> (fields: [FieldDraft], bindings: [SemanticKeyword: Int])
    {
        let keywords = SemanticKeyword.defaultFields
        let colors = LabelColorPalette.palette(count: keywords.count)
        var fields: [FieldDraft] = []
        var bindings: [SemanticKeyword: Int] = [:]
        for (offset, keyword) in keywords.enumerated() {
            let index = offset + 1
            let color = colors[min(offset, colors.count - 1)]
            let name = offset < names.count && !names[offset].isEmpty
                ? names[offset]
                : String(keyword.rawValue.dropFirst())
            fields.append(FieldDraft(index: index, name: name,
                                          colorHexLight: color.hexLight,
                                          colorHexDark: color.hexDark))
            bindings[keyword] = index
        }
        return (fields, bindings)
    }

    /// 白紙から始める草案 [LT-02、ユーザー要望]。
    ///
    /// **フォーマットを 1 本も持たない。** どのファイル名にも一致しないので、
    /// この状態で走査すると全件が未解決になる [AL-31]——それが正しい
    /// （「まだ何も決めていない」を素直に表す）。有効化ダイアログの
    /// プレビューがその結果をそのまま見せるので、利用者は自分で足しながら
    /// 一致していく様子を確かめられる。
    ///
    /// 巻数フォーマットだけは既定のセットを入れる——巻数の読み取りは
    /// ライブラリタイプに依らずほぼ共通で、空から手で書かせる意味が薄い。
    /// - Parameters:
    ///   - defaultFieldNames: 既定フィールド 6 種の名前を
    ///     `SemanticKeyword.defaultFields` の順で渡す [§19.2]。
    ///     **`QooKit` は表示文字列を持たない** [A-01] ので、UI 層が訳語を渡す。
    ///     件数が足りなければ予約語の綴りで埋める（訳語が無いことは
    ///     設定を壊す理由にならない）。
    ///   - volumeSetName: `volume-sets.json` にある名前（`VS-Full` /
    ///     `VS-Doujin` / `VS-None`）。存在しない名前を渡すと巻数フォーマットが
    ///     空になる——**巻数を一切読まない**状態になるので、名前は実在を確かめて渡す。
    public static func blankDraft(volumeSets: VolumeSetDefinition,
                                  displayName: String,
                                  defaultFieldNames: [String],
                                  volumeSetName: String = "VS-Full",
                                  mediaTypeVocabulary: [String] = []) -> LibrarySettingsDraft {
        let volumes = (volumeSets.patterns(named: volumeSetName) ?? [])
            .map { VolumeFormatDraft(source: $0.source, isEnabled: true, kind: $0.kind) }
        let (fields, bindings) = defaultFields(named: defaultFieldNames)
        return LibrarySettingsDraft(
            displayName: displayName,
            targetExtensions: AppDefaults.Library.targetExtensions.sorted(),
            delimiters: .default,
            protectedTokens: AppDefaults.Library.protectedTokenPatterns.map {
                ProtectedToken(pattern: $0)
            },
            // **既定フィールド 6 種を置く** [§19.2]。白紙でも、著者・サークル・
            // ジャンル・イベント・キーワード・本の種別は最初から使える——「何から始めれば
            // よいか」が分かるうえ、プリセットから登録した場合と持ち物が揃う。
            fields: fields,
            semanticBindings: bindings,
            volumeFormats: volumes,
            mediaTypeVocabulary: mediaTypeVocabulary)
    }
}
