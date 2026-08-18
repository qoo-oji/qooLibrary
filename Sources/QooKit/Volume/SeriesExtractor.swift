//
//  シリーズ抽出 [10.1 節][SE-02][SE-07][RW-06〜RW-10]。
//
import Foundation

public enum SeriesExtractor {
    public struct Output: Sendable, Equatable {
        /// `nil` = シリーズ名を導けなかった（`@series` 無効）[SE-07]。
        public let seriesName: String?
        public let volume: VolumeValue
        /// タイトル内で巻数が占めていた範囲（文字位置）。
        public let volumeRange: Range<Int>?

        public static let empty = Output(seriesName: nil, volume: .none, volumeRange: nil)
    }

    /// `@series` を直接書いていないフォーマットにマッチした場合に呼ぶ [SE-02]。
    ///
    /// タイトル末尾から巻数を照合し、見つかればその手前をシリーズ名とする。
    public static func extract(fromTitle title: String,
                               patterns: [CompiledVolumePattern]) -> Output {
        let chars = Array(title)
        guard let match = VolumeMatcher.matchAtEnd(chars, patterns: patterns) else {
            return .empty                                        // [SE-07]
        }
        let head = String(chars[0..<match.range.lowerBound])
        let series = TextNormalizer.trimWhitespace(head)          // 末尾の空白を除去 [SE-02]
        return Output(seriesName: series.isEmpty ? nil : series,
                      volume: match.value,
                      volumeRange: match.range)
    }

    /// `@volume` だけを直接指定したフォーマット向け [RW-10]。
    ///
    /// `@title` から「`@volume` 相当の表記」を除去してシリーズ名を導く。巻数の値は
    /// `@volume` で得たものをそのまま使い、ここでは**除去だけ**を行う。
    public static func stripVolumeToken(fromTitle title: String,
                                        patterns: [CompiledVolumePattern]) -> String? {
        let chars = Array(title)
        guard let match = VolumeMatcher.matchAtEnd(chars, patterns: patterns) else {
            // 末尾に巻数相当が無ければタイトルをそのままシリーズ名とみなす。
            let trimmed = TextNormalizer.trimWhitespace(title)
            return trimmed.isEmpty ? nil : trimmed
        }
        let head = TextNormalizer.trimWhitespace(String(chars[0..<match.range.lowerBound]))
        return head.isEmpty ? nil : head
    }
}
