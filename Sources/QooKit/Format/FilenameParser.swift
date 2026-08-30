//
//  フォーマット群の評価と意味づけ [4.8][4.9]。
//
import Foundation

public enum ParsePurpose: Sendable, Hashable {
    /// `@librarytype` 不一致は警告のみ [RW-01]。
    case libraryScan
    /// 不一致はマッチ失敗として次のフォーマットへ（結果的にペンディング）[RW-01][MV-14b]。
    case moveToLibrary
    case convertRename
    case preview
}

/// 「最も近いフォーマット」の推定 [UR2-05][AL-32][PW-02]。
public struct NearestFormat: Sendable, Equatable {
    public let formatID: UUID
    /// 照合が最も進んだ入力位置。大きいほど「近い」。
    public let reachedIndex: Int
}

public protocol FilenameParsing: Sendable {
    /// 拡張子を除いたファイル名（またはフォルダ名）を照合する。
    /// 登録順に評価し、**最初にマッチしたもの**を返す [FF-03]。
    func parse(_ nameWithoutExtension: String,
               settings: LibrarySettingsSnapshot,
               purpose: ParsePurpose) -> ParseResult?

    /// 全フォーマットを試し、すべての結果を返す（編集画面のプレビュー用）[FF-06][HP-05]。
    func parseAll(_ name: String, settings: LibrarySettingsSnapshot) -> [ParseResult]

    /// どのフォーマットにも一致しなかったとき、最も惜しかったものを返す [UR2-05]。
    func nearestFormat(_ name: String, settings: LibrarySettingsSnapshot) -> NearestFormat?
}

public struct FilenameParser: FilenameParsing, Sendable {
    public init() {}

    public func parse(_ nameWithoutExtension: String,
                      settings: LibrarySettingsSnapshot,
                      purpose: ParsePurpose) -> ParseResult? {
        let input = makeInput(nameWithoutExtension, settings: settings)
        for format in enabledFormats(settings) {
            let outcome = FormatMatcher.match(format, input: input,
                                              volumePatterns: settings.volumeFormats)
            guard var result = outcome.result else { continue }

            // `@librarytype` の扱い [RW-01]
            if format.usedFields.contains(.bookType),
               let matched = result.fields[.bookType] {
                let expected = TextNormalizer.normalize(settings.libraryTypeName)
                if matched.normalized != expected {
                    if purpose == .moveToLibrary { continue }   // 次のフォーマットへ
                    result.libraryTypeMismatch = true           // 警告のみ
                }
            }
            return result
        }
        return nil
    }

    public func parseAll(_ name: String, settings: LibrarySettingsSnapshot) -> [ParseResult] {
        let input = makeInput(name, settings: settings)
        return enabledFormats(settings).compactMap {
            FormatMatcher.match($0, input: input,
                                volumePatterns: settings.volumeFormats).result
        }
    }

    public func nearestFormat(_ name: String, settings: LibrarySettingsSnapshot) -> NearestFormat? {
        let input = makeInput(name, settings: settings)
        var best: NearestFormat?
        for format in enabledFormats(settings) {
            let outcome = FormatMatcher.match(format, input: input,
                                              volumePatterns: settings.volumeFormats)
            if outcome.furthestIndex > (best?.reachedIndex ?? -1) {
                best = NearestFormat(formatID: format.id, reachedIndex: outcome.furthestIndex)
            }
        }
        return best
    }

    // MARK: - 内部

    func makeInput(_ name: String, settings: LibrarySettingsSnapshot) -> ParseInput {
        // マスクは**パース前**に行う [PTI-01]。
        ProtectedTokenMasker.mask(name, tokens: settings.protectedTokens)
    }

    func enabledFormats(_ settings: LibrarySettingsSnapshot) -> [CompiledFormat] {
        settings.filenameFormats.filter(\.isEnabled).sorted { $0.priority < $1.priority }
    }
}
