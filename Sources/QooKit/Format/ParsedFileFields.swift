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
    /// [MF-03] サブタイトル。ラベルにはしない（本ごとの値）。
    public let subtitle: String?
    /// [MF-04] シーズン。**明示の `@season` が `@episode` の暗黙より優先** [MF-06]。
    public let season: Double?
    /// [MF-05] 話数。
    public let episode: Double?
    /// [MF-19] 公開日。**ISO 8601 の部分形**（`2024` / `2024-01` / `2024-01-15`）。
    public let releaseDate: String?
    /// ラベルグループ番号 → 付与する値。セマンティック予約語ぶんも畳み込み済み。
    public let labelValues: [Int: [String]]
    public let spans: [FieldSpan]

    public init(matchedFormatID: UUID, title: String?, seriesName: String?,
                volume: VolumeValue, authorName: String?, labelValues: [Int: [String]],
                spans: [FieldSpan], subtitle: String? = nil, season: Double? = nil,
                episode: Double? = nil, releaseDate: String? = nil) {
        self.matchedFormatID = matchedFormatID
        self.title = title
        self.seriesName = seriesName
        self.volume = volume
        self.authorName = authorName
        self.subtitle = subtitle
        self.season = season
        self.episode = episode
        self.releaseDate = releaseDate
        self.labelValues = labelValues
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
        // 静かな壊れ方をする（`@studio` を足した最初の版で実際に踏みかけた）。
        //
        // 列挙は `allCases` の順で回す——辞書の列挙順は不定で、そのまま使うと
        // 同じ入力でもラベルの並びが実行ごとに変わりうる。
        let authorName = result.fields[.author]?.text

        // メディア向けの 4 値 [MF-03〜06][MF-19]。
        //
        // **`@season` は 2 つの出どころを持つ** [MF-06]——明示の `@season` と、
        // `@episode` のパターンが `(?<season>…)` で同時に読んだ値（`S01E01` 形）。
        // **明示が暗黙に勝つ**：利用者がフォーマットに `@season` と書いたなら、
        // それが答えである。
        //
        // **ラベル化より前に求める。** 束縛された `@season` のラベルは
        // この導出値から作るため——`S01E01` 形では `result.fields[.season]` が
        // 空なので、素直に `text` を読むと**束縛したフィールドが永久に空**になる
        // （`@series` が導出値を使うのとまったく同じ理由 [SE-02]）。
        let episodeField = result.fields[.episode]
        let season = result.fields[.season]?.volume?.number ?? episodeField?.impliedSeason

        for keyword in SemanticKeyword.allCases {
            guard let group = settings.semanticBindings[keyword] else { continue }
            // `@series` と `@season` だけは**導出された値**を使う。
            //
            // `@season` のラベルは**正規化した番号**にする（`S01` や `第1期` と
            // いった生の綴りではなく）——同じシーズンが書き方の違いで別々の
            // ラベルに割れると、フィールドを軸にした分類が成立しない。
            let value: String?
            switch keyword {
            case .series: value = seriesName
            case .season: value = season.map(Self.numberLabel)
            default:      value = result.fields[keyword.fieldRef]?.text
            }
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
            spans: result.spans,
            subtitle: result.fields[.subtitle]?.text,
            season: season,
            episode: episodeField?.volume?.number,
            releaseDate: result.fields[.date]?.date)
    }

    /// 数値をラベル用の文字列にする。整数なら小数点を出さない（`1` / `1.5`）。
    ///
    /// **表示言語に依存させない。** これは DB へ保存されるラベルの綴りで、
    /// 表示のたびに変わってはならない（`VolumeFormatter` の既定値と同じ扱い）。
    static func numberLabel(_ value: Double) -> String {
        value == value.rounded() && abs(value) < 1e15
            ? String(Int64(value))
            : String(value)
    }
}
