//
//  タイトルを持たない行の表示名を組み立てる [SE-33][MF-11]。
//
//  `title` はファイル名フォーマットに `@title` があるときにしか入らない
//  [FF-19]。`@series @volume` だけのコミックや、`@series @episode 「@subtitle」`
//  の映像では **`title` が空のまま**で、そのままだとファイル名がそのまま
//  一覧に出る——`(一般コミック) [著者A] 作品名 第01巻.cbz` のような、
//  読みたい情報とノイズが混ざった綴りになる。
//
//  ライブラリ設定の「シリーズ名の組み立て」[SE-33] がその形を決める。
//  **2026-09-08 まで、この設定は保存されるだけで誰も読まなかった**
//  （05章 SE2-05 に［未実装］と記録されていた）。ここがその読み手である。
//
import Foundation

public enum DisplayTitle {

    /// 組み立てに使える部品。
    public struct Parts: Sendable, Hashable {
        public var series: String?
        public var volume: String?
        public var season: Double?
        public var episode: Double?
        public var subtitle: String?

        public init(series: String? = nil, volume: String? = nil,
                    season: Double? = nil, episode: Double? = nil,
                    subtitle: String? = nil) {
            self.series = series
            self.volume = volume
            self.season = season
            self.episode = episode
            self.subtitle = subtitle
        }
    }

    /// 数値を表示用の文字列にする。整数なら小数点を出さない（`1` / `12.5`）。
    public static func numberText(_ value: Double) -> String {
        value == value.rounded() && abs(value) < 1e15
            ? String(Int64(value))
            : String(value)
    }

    /// フォーマットへ部品を差し込む。**1 つも差し込めなければ `nil`。**
    ///
    /// ## 落とす規則
    /// - **値の無い予約語はそこだけ落とす。** 前後の空白は最後に畳む。
    /// - **括弧の対は、中に値が 1 つも入らなければ丸ごと落とす**
    ///   ——`「@subtitle」` でサブタイトルが無いとき `「」` を残さないため。
    /// - **素のリテラルは落とさない。** `S@seasonE@episode` のような繋ぎ方を
    ///   すると、シーズンが無い行で `SE01` という綴りが残る——だから既定の
    ///   フォーマットは括弧か空白でしか部品を繋がない。この限界は
    ///   `MANUAL.md` にも書いてある。
    ///
    /// **括弧はライブラリの区切り設定に依存させない。** 組み立ては表示の
    /// 都合であって照合ではないので、`「」` を*解析の*区切りとして有効に
    /// していないライブラリでも `「@subtitle」` の括弧は落とせなければならない
    /// ——既定の `DelimiterSet` で字句解析すると `「` がリテラルになり、
    /// サブタイトルが無い行に `「」` だけが残る。
    public static let compositionDelimiters = DelimiterSet(
        pairs: DelimiterSet.availablePairs.map { PairDelimiter(open: $0.open, close: $0.close) },
        separators: [])

    public static func compose(format: String, parts: Parts) -> String? {
        guard let tokens = try? FormatLexer.lex(format, delimiters: compositionDelimiters)
        else { return nil }
        let rendered = render(tokens[...], parts: parts)
        guard rendered.hasValue else { return nil }
        let text = collapseWhitespace(rendered.text)
        return text.isEmpty ? nil : text
    }

    /// 予約語ひとつぶんの値。差し込めないものは `nil`。
    static func value(of ref: FieldRef, parts: Parts) -> String? {
        switch ref {
        case .series:   return parts.series
        case .volume:   return parts.volume
        case .season:   return parts.season.map(numberText)
        case .episode:  return parts.episode.map(numberText)
        case .subtitle: return parts.subtitle
        // ほかの予約語は行が持たない。**書かれていても静かに落とす**
        // ——設定画面がここで使える語を案内するので、エラーにはしない。
        default:        return nil
        }
    }

    private static func render(_ tokens: ArraySlice<FormatToken>,
                               parts: Parts) -> (text: String, hasValue: Bool) {
        var out = ""
        var hasValue = false
        var i = tokens.startIndex
        while i < tokens.endIndex {
            switch tokens[i] {
            case .literal(let s, _):
                out += s
            case .whitespace:
                out += " "
            case .separator(let sep, _):
                out += sep.canonical
            case .reservedWord(let ref, _):
                if let v = value(of: ref, parts: parts)?
                    .trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty {
                    out += v
                    hasValue = true
                }
            case .pairOpen(let pair, _):
                guard let close = matchingClose(tokens, from: i, pair: pair) else {
                    // 対にならない開き括弧はリテラルとして残す（字句解析が
                    // 通っている以上ここへは来ないが、落として黙るよりよい）。
                    out += String(pair.open)
                    break
                }
                let inner = render(tokens[(i + 1)..<close], parts: parts)
                if inner.hasValue {
                    out += String(pair.open) + inner.text + String(pair.close)
                    hasValue = true
                }
                i = close                      // 閉じ括弧まで読み飛ばす
            case .pairClose(let pair, _):
                out += String(pair.close)      // 対にならない閉じ括弧（同上）
            }
            i += 1
        }
        return (out, hasValue)
    }

    /// `from` の開き括弧に対応する閉じ括弧の位置。入れ子を数える。
    private static func matchingClose(_ tokens: ArraySlice<FormatToken>,
                                      from: ArraySlice<FormatToken>.Index,
                                      pair: PairDelimiter) -> ArraySlice<FormatToken>.Index? {
        var depth = 0
        var i = from
        while i < tokens.endIndex {
            switch tokens[i] {
            case .pairOpen(let p, _) where p.open == pair.open:   depth += 1
            case .pairClose(let p, _) where p.close == pair.close:
                depth -= 1
                if depth == 0 { return i }
            default: break
            }
            i += 1
        }
        return nil
    }

    /// 連続した空白を 1 つに畳み、前後を落とす。**落とした部品の跡が
    /// 二重の空白として残らないようにするのが目的。**
    private static func collapseWhitespace(_ s: String) -> String {
        var out = ""
        var pendingSpace = false
        for c in s {
            if Whitespace.isWhitespace(c) {
                pendingSpace = !out.isEmpty
                continue
            }
            if pendingSpace { out.append(" "); pendingSpace = false }
            out.append(c)
        }
        return out
    }
}
