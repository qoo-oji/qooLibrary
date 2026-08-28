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
    /// - 各パターンの一致を**全部集めてから**、左端優先・同じ左端なら長い方・
    ///   さらに同じなら登録順で、重ならないように選ぶ [PT-06]。
    ///   位置ごとに全パターンを試すより桁で速い。
    /// - `prefix` / `suffix` 指定は一致範囲で絞る [PT-05]。
    /// - 照合は全角を畳んだ射影に対して行い、大文字小文字は無視する [PT-04]。
    public static func mask(_ text: String,
                            tokens: [CompiledProtectedToken]) -> ParseInput {
        let original = Array(text)
        guard !tokens.isEmpty else {
            return ParseInput(text)
        }

        let subject = FoldedSubject(original)
        var candidates: [(range: Range<Int>, order: Int)] = []

        for (order, token) in tokens.enumerated() {
            guard !token.health.isAbandoned(token.id) else { continue }
            let outcome = token.regex.allMatches(in: subject,
                                                 budget: AppLimits.Format.regexMatchBudget)
            if outcome.abandoned {
                token.health.markAbandoned(token.id)
                continue
            }
            for match in outcome.matches {
                switch token.position {
                case .prefix where match.range.lowerBound != 0: continue
                case .suffix where match.range.upperBound != original.count: continue
                default: break
                }
                candidates.append((match.range, order))
            }
        }

        guard !candidates.isEmpty else {
            return ParseInput(text)
        }

        // 左端優先 → 長い方 → 登録順。
        candidates.sort {
            if $0.range.lowerBound != $1.range.lowerBound {
                return $0.range.lowerBound < $1.range.lowerBound
            }
            if $0.range.count != $1.range.count { return $0.range.count > $1.range.count }
            return $0.order < $1.order
        }

        var selected: [Range<Int>] = []
        var consumedUpTo = 0
        for candidate in candidates where candidate.range.lowerBound >= consumedUpTo {
            selected.append(candidate.range)
            consumedUpTo = candidate.range.upperBound
        }

        var maskedChars: [Character] = []
        var originRanges: [Range<Int>] = []
        var placeholderCount = 0
        var truncated = false
        var nextSelection = 0
        var i = 0

        while i < original.count {
            // 先頭が現在位置と一致する採用済みの範囲があるか。
            if nextSelection < selected.count, selected[nextSelection].lowerBound == i {
                let range = selected[nextSelection]
                nextSelection += 1
                if placeholderCount < AppLimits.Format.maskPlaceholderCapacity,
                   let placeholder = placeholder(at: placeholderCount) {
                    maskedChars.append(placeholder)
                    originRanges.append(range)
                    placeholderCount += 1
                    i = range.upperBound
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
                CharacterCanonicalization.canonical($0)
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
}
