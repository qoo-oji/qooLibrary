//
//  照合結果の意味づけ [4.9][RW-01〜RW-17][SE-02][SE-06〜SE-08]。
//
import Foundation

/// 1 ファイルぶんの、意味づけまで済んだ抽出結果。
public struct ParsedFileFields: Sendable {
    public let matchedFormatID: UUID
    public let title: String?
    public let seriesName: String?
    public let volume: VolumeValue
    public let authorName: String?
    /// ラベルグループ番号 → 付与する値。セマンティック予約語ぶんも畳み込み済み。
    public let labelValues: [Int: [String]]
    public let libraryTypeMismatch: Bool
    public let spans: [FieldSpan]

    public init(matchedFormatID: UUID, title: String?, seriesName: String?,
                volume: VolumeValue, authorName: String?, labelValues: [Int: [String]],
                libraryTypeMismatch: Bool, spans: [FieldSpan]) {
        self.matchedFormatID = matchedFormatID
        self.title = title
        self.seriesName = seriesName
        self.volume = volume
        self.authorName = authorName
        self.labelValues = labelValues
        self.libraryTypeMismatch = libraryTypeMismatch
        self.spans = spans
    }
}

public enum FieldPostProcessor {

    /// `ParseResult` を意味づける [4.9]。
    ///
    /// | フォーマットの記述 | シリーズ名 | `@title` からの巻数除去 |
    /// |---|---|---|
    /// | `@series` あり | その値をそのまま [SE-02a] | **行わない** [RW-08] |
    /// | `@volume` のみ | `@title` から巻数相当を除去して導出 [RW-10] | 巻数相当のみ |
    /// | どちらもなし | `@title` 末尾から巻数を除去して導出 [SE-02] | 行う |
    /// | 両方あり | `@series` の値。`@title` は独立フィールド [RW-09] | 行わない |
    public static func postProcess(_ result: ParseResult,
                                   settings: LibrarySettingsSnapshot) -> ParsedFileFields {
        let title = result.fields[.title]?.text
        let directSeries = result.fields[.series]?.text
        let directVolume = result.fields[.volume]?.volume

        var seriesName: String?
        var volume: VolumeValue = directVolume ?? .none

        if let directSeries {
            seriesName = directSeries                                     // [SE-02a][RW-08]
        } else if directVolume != nil {
            seriesName = title.flatMap {
                SeriesExtractor.stripVolumeToken(fromTitle: $0, patterns: settings.volumeFormats)
            }                                                             // [RW-10]
        } else if let title {
            let extracted = SeriesExtractor.extract(fromTitle: title,
                                                    patterns: settings.volumeFormats)
            seriesName = extracted.seriesName                              // [SE-02]
            volume = extracted.volume
        }

        // フィールドへの割り当て。**意味予約語だけが経路**（`@labelgroupN` は
        // v3 ステージ 5 で撤去した）——番号はフィールドの身元ではないので、
        // 番号でフォーマットに書けると並べ替えや改名で意味が変わってしまう。
        var labels: [Int: [String]] = [:]

        // セマンティック予約語のラベル化 [RW-06][RW-11][RWI-02][SE-06][SE-08]
        //
        // **予約語ごとに分岐を書かない。** 書くと、予約語を足したときに
        // ここへ足し忘れて「フォーマットには書けるのにラベルが付かない」という
        // 静かな壊れ方をする（`@circle` を足した最初の版で実際に踏みかけた）。
        //
        // 列挙は `allCases` の順で回す——辞書の列挙順は不定で、そのまま使うと
        // 同じ入力でもラベルの並びが実行ごとに変わりうる。
        let authorName = result.fields[.author]?.text
        for keyword in SemanticKeyword.allCases {
            guard let group = settings.semanticBindings[keyword] else { continue }
            // `@series` だけは**導出された値**を使う——`@title` の末尾から
            // 切り出した場合、`result.fields[.series]` には何も入っていない [SE-02]。
            let value = keyword == .series ? seriesName : result.fields[keyword.fieldRef]?.text
            guard let value, !value.isEmpty else { continue }
            labels[group, default: []].append(value)
        }

        return ParsedFileFields(
            matchedFormatID: result.matchedFormatID,
            title: title,
            seriesName: seriesName,
            volume: volume,
            authorName: authorName,
            labelValues: labels,
            libraryTypeMismatch: result.libraryTypeMismatch,
            spans: result.spans)
    }
}
