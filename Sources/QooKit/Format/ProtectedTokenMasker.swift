//
//  保護文字列のマスク [9.2.3][PT-01〜PT-11][PTI-01〜PTI-06]。
//
//  マスクは**パース前**に行う [PTI-01]。マスク後の PUA 文字は区切り文字にも
//  フィールド境界にもならないため、自由文字列フィールドに自然に吸収される [PT-02]。
//
import Foundation

public enum ProtectedTokenMasker {

    /// 保護文字列を PUA 文字へ退避した入力を作る。
    ///
    /// - 有効なトークンを**正規化キーの長い順**に並べ、入力の左から順に、
    ///   その位置で一致する最初のトークンを採る（最長一致・左優先）[PT-06]。
    /// - `prefix` / `suffix` 指定は位置で絞る [PT-05]。
    /// - 完全一致のみ。前方一致・正規表現は提供しない [PT-11][PTI-04]。
    public static func mask(_ text: String,
                            tokens: [ProtectedToken],
                            caseSensitive: Bool = false) -> ParseInput {
        let original = Array(text)
        let enabled = tokens.filter(\.isEnabled)
        guard !enabled.isEmpty else {
            return ParseInput(text, caseSensitive: caseSensitive)
        }

        // 正規化キーは NFC + 全角半角 + 空白畳み込み + 小文字化 [PT-04]。
        let candidates = enabled
            .map { (token: $0, key: Array($0.normalizedKey)) }
            .filter { !$0.key.isEmpty }
            .sorted { $0.key.count > $1.key.count }

        var maskedChars: [Character] = []
        var originRanges: [Range<Int>] = []
        var placeholderCount = 0
        var truncated = false
        var i = 0

        while i < original.count {
            var hit: (length: Int, Void)?
            for candidate in candidates {
                guard let length = matchLength(candidate.key, in: original, at: i) else { continue }
                switch candidate.token.position {
                case .prefix where i != 0: continue
                case .suffix where i + length != original.count: continue
                default: break
                }
                hit = (length, ())
                break
            }

            if let hit {
                if placeholderCount < AppLimits.Format.maskPlaceholderCapacity,
                   let placeholder = placeholder(at: placeholderCount) {
                    maskedChars.append(placeholder)
                    originRanges.append(i..<(i + hit.length))
                    placeholderCount += 1
                    i += hit.length
                    continue
                }
                // 上限超過。マスクせず素通しし、呼び出し側へ知らせる [PTI-05]。
                truncated = true
            }
            maskedChars.append(original[i])
            originRanges.append(i..<(i + 1))
            i += 1
        }

        return ParseInput(
            originalChars: original,
            maskedChars: maskedChars,
            canonicalChars: maskedChars.map {
                CharacterCanonicalization.canonical($0, caseSensitive: caseSensitive)
            },
            originRanges: originRanges,
            maskTruncated: truncated)
    }

    /// PUA U+E000〜U+E0FF [PTI-05]。区切り文字にもフィールド境界にもならない。
    static func placeholder(at n: Int) -> Character? {
        guard n < AppLimits.Format.maskPlaceholderCapacity else { return nil }
        guard let scalar = Unicode.Scalar(AppLimits.Format.maskPlaceholderBase + UInt32(n)) else { return nil }
        return Character(scalar)
    }

    public static func isPlaceholder(_ c: Character) -> Bool {
        guard c.unicodeScalars.count == 1, let s = c.unicodeScalars.first else { return false }
        let base = AppLimits.Format.maskPlaceholderBase
        return s.value >= base && s.value < base + UInt32(AppLimits.Format.maskPlaceholderCapacity)
    }

    /// 正規化キーが `original` の位置 `i` に一致するなら、消費した**原文の**文字数を返す。
    ///
    /// キーは空白を畳んだ形なので、キー中の空白 1 個は入力の空白 **1 個以上**に
    /// 対応させる。こうしないと、同じ保護文字列でも入力側の空白の数が違うだけで
    /// 一致しなくなる [PT-04][WS-01 と同じ考え方]。
    static func matchLength(_ key: [Character], in original: [Character], at i: Int) -> Int? {
        var k = 0
        var j = i
        while k < key.count {
            if Whitespace.isWhitespace(key[k]) {
                var n = 0
                while j + n < original.count, Whitespace.isWhitespace(original[j + n]) { n += 1 }
                guard n > 0 else { return nil }
                j += n
                k += 1
            } else {
                guard j < original.count else { return nil }
                guard CharacterCanonicalization.canonical(original[j], caseSensitive: false) == key[k]
                else { return nil }
                j += 1
                k += 1
            }
        }
        return j - i
    }
}
