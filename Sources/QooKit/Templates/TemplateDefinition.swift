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
        public let source: String
        public let ordinalRank: Int?
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
            VolumePattern(source: e.source, priority: i, ordinalRank: e.ordinalRank)
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
                               allLibraryDisplayNames: [String] = [],
                               delimiters: DelimiterSet = .default,
                               protectedTokens: [ProtectedToken] = [],
                               normalization: NormalizationOptions = .default)
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
            allLibraryDisplayNames: allLibraryDisplayNames,
            semanticBindings: semantic,
            normalization: normalization)

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
            allLibraryDisplayNames: allLibraryDisplayNames,
            delimiters: delimiters,
            protectedTokens: protectedTokens,
            filenameFormats: formats,
            folderLevelAssignments: levels,
            volumeFormats: VolumePatternCompiler.compileAll(volumePatterns),
            semanticBindings: semantic,
            normalization: normalization)
    }
}
