//
//  フォルダ名フォーマットとラベルの優先解決 [8.3.1〜8.3.5][AL-01〜AL-03][AL-20〜AL-23]。
//
import Foundation

public struct FolderLevelMappingSpec: Sendable {
    /// 1 = ライブラリ直下。
    public let level: Int
    public let assignment: Assignment

    public enum Assignment: Sendable {
        /// フォルダ名全体を 1 つのラベルとする。
        case singleLabelGroup(index: Int)
        /// 1 つのフォルダ名から複数のラベルを取り出す [AL-01][AL-02]。
        case format(CompiledFormat)
        /// この階層は割り当てない [AL-03]。
        case none
    }

    public init(level: Int, assignment: Assignment) {
        self.level = level
        self.assignment = assignment
    }
}

public enum FolderLabelResolver {

    /// 相対パスのディレクトリ部分から、階層ごとの割り当てに従ってラベルを取り出す。
    ///
    /// - Parameters:
    ///   - relativePath: ライブラリ根からの相対パス（ファイル名を含む）。
    ///   - endsWithBookFolder: 末尾のフォルダがブックフォルダなら、それは階層として
    ///     数えない [IF-13]。
    public static func labelsFromPath(_ relativePath: String,
                                      settings: LibrarySettingsSnapshot,
                                      endsWithBookFolder: Bool = false) -> [Int: [String]] {
        var components = relativePath.split(separator: "/").map(String.init)
        guard !components.isEmpty else { return [:] }
        components.removeLast()                      // ファイル名を落とす
        if endsWithBookFolder, !components.isEmpty {
            components.removeLast()                  // ブックフォルダは階層に数えない [IF-13]
        }

        var out: [Int: [String]] = [:]
        for (offset, name) in components.enumerated() {
            let level = offset + 1
            // `Assignment.none` と `Optional.none` を取り違えないよう先に外す。
            guard let assignment = settings.folderLevelAssignments[level] else { continue }
            switch assignment {
            case .none:
                continue                             // [AL-03]

            case .singleLabelGroup(let field):
                let value = TextNormalizer.trimWhitespace(name)
                if !value.isEmpty { out[field, default: []].append(value) }

            case .format(let format):
                let input = ProtectedTokenMasker.mask(
                    name, tokens: settings.protectedTokens)
                let outcome = FormatMatcher.match(format, input: input,
                                                  volumePatterns: settings.volumeFormats)
                // [AL-23] 想定した階層にフォルダがない配置ではエラーにせず素通しする。
                guard let result = outcome.result else { continue }
                // セマンティック予約語をラベルにする [RW-17][RWI-02]。
                //
                // **ファイル名側（`FieldPostProcessor.postProcess`）と揃える。**
                // 揃えないと、同じ `@circle` がファイル名では効いてフォルダ名では
                // 黙って捨てられる——プリセットを予約語ベースへ書き換えた時点で
                // フォルダ階層由来のラベルが消える形になる。
                //
                // 構造化列（`seriesName` / `authorName`）には入れない。ここが返すのは
                // ラベルだけで、フォルダ名からタイトル・シリーズを決める経路は
                // `resolve` が持つ [AL-22]。
                for keyword in SemanticKeyword.allCases {
                    guard let field = settings.semanticBindings[keyword],
                          let text = result.fields[keyword.fieldRef]?.text,
                          !text.isEmpty else { continue }
                    out[field, default: []].append(text)
                }
            }
        }
        return out
    }

    /// フォルダ名とファイル名の優先解決 [AL-20〜AL-22]。
    ///
    /// **優先の単位はラベルフィールドごと**。フォーマット全体ではない [AL-21][FL-01]。
    /// フォルダから得られたフィールドはファイル名側の値を捨て、得られなかった
    /// フィールドだけファイル名側を採る。`@title` は常にファイル名から [AL-22]。
    public static func resolve(relativePath: String,
                               nameWithoutExtension: String,
                               settings: LibrarySettingsSnapshot,
                               parser: some FilenameParsing = FilenameParser(),
                               endsWithBookFolder: Bool = false) -> ResolvedLabels {
        let folderLabels = labelsFromPath(relativePath, settings: settings,
                                          endsWithBookFolder: endsWithBookFolder)   // [AL-20]
        let attempt = parser.attempt(nameWithoutExtension, settings: settings)
        let parsed = attempt.result.map { FieldPostProcessor.postProcess($0, settings: settings) }

        var final = folderLabels
        for (field, values) in parsed?.labelValues ?? [:] where final[field] == nil {
            final[field] = values                                                   // [AL-21]
        }

        return ResolvedLabels(labels: final,
                              title: parsed?.title,                                 // [AL-22]
                              seriesName: parsed?.seriesName,
                              volume: parsed?.volume ?? .none,
                              authorName: parsed?.authorName,
                              matchedFormatID: parsed?.matchedFormatID,
                              nearestFormat: attempt.nearest,
                              folderProvidedGroups: Set(folderLabels.keys))
    }

    public struct ResolvedLabels: Sendable {
        public let labels: [Int: [String]]
        public let title: String?
        public let seriesName: String?
        public let volume: VolumeValue
        public let authorName: String?
        /// `nil` = どのフォーマットにも一致しなかった [AL-31]。
        public let matchedFormatID: UUID?
        /// 一致しなかったときの「最も近いフォーマット」[UR2-05]。
        ///
        /// **ファイル名フォーマットについての推定**で、フォルダ名側は見ない
        /// ——未解決の判定 [AL-31] がファイル名フォーマットの一致で決まるため。
        public let nearestFormat: NearestFormat?
        /// フォルダ名から得たラベルフィールド（ファイル名側を捨てた対象）。
        public let folderProvidedGroups: Set<Int>
    }
}
