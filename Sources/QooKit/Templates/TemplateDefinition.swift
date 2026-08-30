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
    public func patterns(named name: String) -> [VolumePattern]? {
        guard let entries = sets[name] else { return nil }
        return entries.enumerated().map { i, e in
            VolumePattern(source: e.source, priority: i, kind: e.kind ?? .volume)
        }
    }
}

public struct LibraryTypeTemplate: Sendable, Codable, Hashable, Identifiable {
    public struct LabelGroupSpec: Sendable, Codable, Hashable {
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
    public let labelGroups: [LabelGroupSpec]
    /// 予約語 → ラベルグループ番号 [RW-13]。
    public let semanticBindings: [String: Int]
    /// 階層番号（文字列キー）→ 割り当て [AL-01〜AL-03]。
    public let folderLevels: [String: FolderLevelSpec]
    /// 優先順に並んだファイル名フォーマット [FF-03]。
    public let filenameFormats: [String]
    public let volumeSet: String

    public var id: String { key }

    public var semanticKeywordBindings: [SemanticKeyword: Int] {
        var out: [SemanticKeyword: Int] = [:]
        for (raw, group) in semanticBindings {
            guard let keyword = SemanticKeyword(rawValue: raw) else { continue }
            out[keyword] = group
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

    /// テンプレートからパーサ用の設定スナップショットを組み立てる [LT-03]。
    ///
    /// ライブラリ登録時に一度だけ呼び、以後の設定変更はライブラリ側に写す
    /// （テンプレート本体には影響しない）[LT-03]。
    public static func snapshot(from template: LibraryTypeTemplate,
                               volumeSets: VolumeSetDefinition,
                               libraryID: LibraryID,
                               displayName: String = "",
                               allLibraryTypeNames: [String] = [],
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
        guard let volumePatterns = volumeSets.patterns(named: template.volumeSet) else {
            throw .unknownVolumeSet(template.volumeSet)
        }
        let semantic = template.semanticKeywordBindings
        let context = FormatCompilationContext(
            delimiters: delimiters,
            allLibraryTypeNames: allLibraryTypeNames.isEmpty
                ? [template.libraryTypeName] : allLibraryTypeNames,
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
                guard let group = spec.labelGroup else { continue }
                levels[level] = .singleLabelGroup(index: group)
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
            libraryTypeName: template.libraryTypeName,
            allLibraryTypeNames: context.allLibraryTypeNames,
            delimiters: delimiters,
            protectedTokens: ProtectedTokenCompiler.compileAll(protectedTokens),
            filenameFormats: formats,
            folderLevelAssignments: levels,
            volumeFormats: VolumePatternCompiler.compileAll(volumePatterns),
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
    /// - Parameter colors: ラベルグループの配色 [MT-13]。件数ぶん渡す。
    ///   `QooKit` は配色の決め方を知っているが（`LabelColorPalette`）、
    ///   呼び出し側が別の割り当てを持つ場合に差し替えられるようにしておく。
    public static func draft(from template: LibraryTypeTemplate,
                             volumeSets: VolumeSetDefinition,
                             displayName: String,
                             otherLibraryTypeNames: [String] = []) -> LibrarySettingsDraft {
        let colors = LabelColorPalette.palette(count: max(template.labelGroups.count, 1))
        let groups = template.labelGroups
            .sorted { $0.index < $1.index }
            .enumerated()
            .map { offset, spec in
                let color = colors[min(offset, colors.count - 1)]
                return LabelGroupDraft(
                    index: spec.index, name: spec.name,
                    colorHexLight: color.hexLight, colorHexDark: color.hexDark,
                    assignsAutomatically: spec.assignsAutomatically)
            }

        let volumes = (volumeSets.patterns(named: template.volumeSet) ?? [])
            .map { VolumeFormatDraft(source: $0.source, isEnabled: true, kind: $0.kind) }

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
                    guard let group = spec.labelGroup else { return nil }
                    assignment = .singleLabelGroup(index: group)
                case .format:
                    guard let source = spec.format else { return nil }
                    assignment = .format(source: source)
                }
                return FolderLevelDraft(level: level, assignment: assignment)
            }
            .sorted { $0.level < $1.level }

        return LibrarySettingsDraft(
            displayName: displayName,
            libraryTypeName: template.libraryTypeName,
            thumbnailsAlwaysHidden: false,
            // **テンプレートは対象拡張子を持たない** [要件定義書 11.4 節:
            // 「対象拡張子は全テンプレート共通」]。空で登録すると走査が
            // `.DS_Store` まで拾うので、ここで既定を入れるのが正しい場所。
            targetExtensions: AppDefaults.Library.targetExtensions.sorted(),
            imageExtensions: [],
            delimiters: .default,
            // テンプレートは保護文字列を持たないので、ここで既定を入れる
            // （対象拡張子と同じ理由・同じ場所）[2026-08 のユーザー要望]。
            protectedTokens: AppDefaults.Library.protectedTokenPatterns.map {
                ProtectedToken(pattern: $0)
            },
            labelGroups: groups,
            semanticBindings: template.semanticKeywordBindings,
            filenameFormats: template.filenameFormats.map {
                FilenameFormatDraft(source: $0, isEnabled: true)
            },
            volumeFormats: volumes,
            folderLevels: levels,
            seriesTitleCompositionFormat: "@series @volume",
            otherLibraryTypeNames: otherLibraryTypeNames)
    }

    /// 既定フィールド 5 種と、その意味束縛を組み立てる [§19.2][RWI-02]。
    ///
    /// **番号は 1〜5 に固定する。** 番号はフィールドの身元ではない（身元は
    /// 予約語）が、既定が毎回違う番号に散ると、追加フィールドの番号取りと
    /// 設定画面の並びが登録のたびに変わって読みにくい。
    public static func defaultFields(named names: [String])
        -> (groups: [LabelGroupDraft], bindings: [SemanticKeyword: Int])
    {
        let keywords = SemanticKeyword.defaultFields
        let colors = LabelColorPalette.palette(count: keywords.count)
        var groups: [LabelGroupDraft] = []
        var bindings: [SemanticKeyword: Int] = [:]
        for (offset, keyword) in keywords.enumerated() {
            let index = offset + 1
            let color = colors[min(offset, colors.count - 1)]
            let name = offset < names.count && !names[offset].isEmpty
                ? names[offset]
                : String(keyword.rawValue.dropFirst())
            groups.append(LabelGroupDraft(index: index, name: name,
                                          colorHexLight: color.hexLight,
                                          colorHexDark: color.hexDark))
            bindings[keyword] = index
        }
        return (groups, bindings)
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
    ///   - defaultFieldNames: 既定フィールド 5 種の名前を
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
                                  libraryTypeName: String = "",
                                  volumeSetName: String = "VS-Full",
                                  otherLibraryTypeNames: [String] = []) -> LibrarySettingsDraft {
        let volumes = (volumeSets.patterns(named: volumeSetName) ?? [])
            .map { VolumeFormatDraft(source: $0.source, isEnabled: true, kind: $0.kind) }
        let (groups, bindings) = defaultFields(named: defaultFieldNames)
        return LibrarySettingsDraft(
            displayName: displayName,
            libraryTypeName: libraryTypeName,
            targetExtensions: AppDefaults.Library.targetExtensions.sorted(),
            delimiters: .default,
            protectedTokens: AppDefaults.Library.protectedTokenPatterns.map {
                ProtectedToken(pattern: $0)
            },
            // **既定フィールド 5 種を置く** [§19.2]。白紙でも、著者・サークル・
            // ジャンル・イベント・キーワードは最初から使える——「何から始めれば
            // よいか」が分かるうえ、プリセットから登録した場合と持ち物が揃う。
            labelGroups: groups,
            semanticBindings: bindings,
            volumeFormats: volumes,
            otherLibraryTypeNames: otherLibraryTypeNames)
    }
}
