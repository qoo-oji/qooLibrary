//
//  公開日の照合 [MF-19]。
//
//  `@date` の型付き照合。`@volume` `@season` `@episode` が**数値 1 つ**を取るのに対し、
//  こちらは**年・月・日の 3 つ**を名前付きキャプチャから読み、ISO 8601 の部分形
//  （`2024` / `2024-01` / `2024-01-15`）へ組み立てる。
//
//  ## なぜ部分形の文字列で持つか
//  精度（年だけか、日まであるか）が**値そのものに表れる**ので、精度用の列を別に
//  持たなくてよい。しかも ISO 8601 は**辞書順が時系列順**なので、並びは素の
//  文字列比較で正しくなる。Unix time（`REAL`）にすると「2024 年」を表すのに
//  タイムゾーンの解釈が入り込む。
//
import Foundation

public struct DateMatch: Sendable, Equatable {
    public let patternID: UUID?
    /// 入力（文字配列）における範囲。
    public let range: Range<Int>
    /// ISO 8601 の部分形。
    public let value: String

    public var length: Int { range.count }
}

public enum DateMatcher {

    /// 指定位置から始まる候補を、**長い順（同長なら登録順が先のもの）**で返す。
    ///
    /// **素の数字は候補にしない** [MF-21]。4 桁の数字が何でも年号になると、
    /// 解像度（`1080`）や作品名の数字を拾う——Jellyfin が話数の解析で踏んでいる
    /// のと同じ壊れ方である（#3669）。登録済みのパターンにだけ一致させる。
    public static func matches(in subject: FoldedSubject, at index: Int,
                               patterns: [CompiledVolumePattern]) -> [DateMatch] {
        var out: [DateMatch] = []
        for pattern in patterns where pattern.kind == .volume && pattern.role == .date {
            guard !pattern.health.isAbandoned(pattern.id) else { continue }
            switch pattern.regex.match(anchoredAt: index, in: subject,
                                       budget: AppLimits.Format.regexMatchBudget) {
            case .abandoned:
                pattern.health.markAbandoned(pattern.id)
            case .found(let m):
                if let value = isoValue(of: m, in: subject) {
                    out.append(DateMatch(patternID: pattern.id, range: m.range, value: value))
                }
            case .none:
                break
            }
        }
        return out.enumerated()
            .sorted { ($0.element.length, -$0.offset) > ($1.element.length, -$1.offset) }
            .map(\.element)
    }

    /// 一致から ISO 8601 の部分形を組み立てる。
    ///
    /// 年は `(?<year>…)` から、無ければ**唯一のキャプチャグループ**から読む
    /// （`\(2024\)` のように年だけを取るパターンを素直に書けるようにするため）。
    /// **月が読めなければ日も付けない**——`2024--15` のような形を作らない。
    static func isoValue(of match: RegexMatch, in subject: FoldedSubject) -> String? {
        let yearRange = match.named["year"] ?? match.captureRange
        guard let yearRange, let year = intValue(in: yearRange, of: subject),
              (1000...9999).contains(year) else { return nil }
        var iso = String(format: "%04d", year)

        guard let mr = match.named["month"], let month = intValue(in: mr, of: subject),
              (1...12).contains(month) else { return iso }
        iso += String(format: "-%02d", month)

        guard let dr = match.named["day"], let day = intValue(in: dr, of: subject),
              (1...31).contains(day) else { return iso }
        iso += String(format: "-%02d", day)
        return iso
    }

    /// 畳んだ文字の範囲を整数として読む。`VolumeMatcher.number` と同じ規則
    /// （全角は畳み済み）で、小数は受け付けない。
    static func intValue(in range: Range<Int>, of subject: FoldedSubject) -> Int? {
        guard let d = VolumeMatcher.number(in: range, of: subject),
              d == d.rounded(), d >= 0, d < 1e9 else { return nil }
        return Int(d)
    }
}
