//
//  字句解析 [4.3][LX-01〜LX-04]。
//
import Foundation

/// 字句。`sourceOffset` はフォーマット文字列内の文字位置（編集画面の下線用）[HP-04]。
public enum FormatToken: Sendable, Equatable {
    case reservedWord(FieldRef, sourceRange: Range<Int>)
    case pairOpen(PairDelimiter, at: Int)
    case pairClose(PairDelimiter, at: Int)
    case separator(SeparatorDelimiter, sourceRange: Range<Int>)
    /// 連続する空白は 1 個に畳む [LX-04][WS-03]。
    case whitespace(at: Int)
    case literal(String, sourceRange: Range<Int>)
}

public enum FormatLexer {

    /// フォーマット文字列を字句へ分解する。
    ///
    /// 予約語は**最長一致**で読む [LX-01]。`@labelgroup12` は
    /// `@labelgroup1` + `2` ではなく `@labelgroup12` として読む [MT-12]。
    public static func lex(_ format: String, delimiters: DelimiterSet) throws(FormatCompileError)
        -> [FormatToken]
    {
        let chars = Array(format)
        var tokens: [FormatToken] = []
        var i = 0
        var literalStart = 0
        var literal = ""

        func flushLiteral() {
            guard !literal.isEmpty else { return }
            tokens.append(.literal(literal, sourceRange: literalStart..<i))
            literal = ""
        }

        let pairs = delimiters.enabledPairs
        let separators = delimiters.enabledSeparators

        while i < chars.count {
            let c = chars[i]

            // ① 予約語
            if c == "@" {
                flushLiteral()
                guard let (field, length) = readReservedWord(chars, at: i) else {
                    throw FormatCompileError.unknownReservedWord(unknownWordText(chars, at: i), at: i)
                }
                tokens.append(.reservedWord(field, sourceRange: i..<(i + length)))
                i += length
                literalStart = i
                continue
            }

            // ② ペア型の開き／閉じ
            if let pair = pairs.first(where: { $0.open == c }) {
                flushLiteral()
                tokens.append(.pairOpen(pair, at: i))
                i += 1; literalStart = i; continue
            }
            if let pair = pairs.first(where: { $0.close == c }) {
                flushLiteral()
                tokens.append(.pairClose(pair, at: i))
                i += 1; literalStart = i; continue
            }

            // ③ セパレータ型（最長一致）[DLI-03]
            if let (sep, length) = readSeparator(chars, at: i, separators: separators) {
                flushLiteral()
                tokens.append(.separator(sep, sourceRange: i..<(i + length)))
                i += length; literalStart = i; continue
            }

            // ④ 空白（連続をまとめて 1 個）[LX-04]
            if Whitespace.isWhitespace(c) {
                flushLiteral()
                let start = i
                while i < chars.count, Whitespace.isWhitespace(chars[i]) { i += 1 }
                tokens.append(.whitespace(at: start))
                literalStart = i
                continue
            }

            // ⑤ それ以外はリテラル
            if literal.isEmpty { literalStart = i }
            literal.append(c)
            i += 1
        }
        flushLiteral()
        return tokens
    }

    // MARK: - 内部

    /// 予約語を最長一致で読む。`@labelgroup` + 1 桁以上の数字も扱う [LX-01][LX-02]。
    /// 戻り値は `(フィールド, 消費した文字数)`。
    static func readReservedWord(_ chars: [Character], at i: Int) -> (FieldRef, Int)? {
        // `@labelgroup` を先に見る。`@labelgroup1` は `@l…` で始まる他の予約語と
        // 衝突しないが、桁数が可変なので表による最長一致では扱えない。
        let prefix = Array(ReservedWordTable.labelGroupPrefix)
        if matches(chars, at: i, prefix) {
            var j = i + prefix.count
            var digits = ""
            while j < chars.count, let d = chars[j].wholeNumberValue, chars[j].isASCII, (0...9).contains(d) {
                digits.append(chars[j]); j += 1
            }
            // 数字が続かない `@labelgroup` は予約語として認めない（番号が必須）。
            if let n = Int(digits), !digits.isEmpty {
                return (.labelGroup(n), j - i)
            }
            return nil
        }
        for entry in ReservedWordTable.entries {
            if matches(chars, at: i, Array(entry.word)) {
                return (entry.field, entry.word.count)
            }
        }
        return nil
    }

    static func matches(_ chars: [Character], at i: Int, _ needle: [Character]) -> Bool {
        guard i + needle.count <= chars.count else { return false }
        for k in 0..<needle.count where chars[i + k] != needle[k] { return false }
        return true
    }

    static func readSeparator(_ chars: [Character], at i: Int,
                              separators: [SeparatorDelimiter]) -> (SeparatorDelimiter, Int)? {
        var best: (SeparatorDelimiter, Int)?
        for sep in separators {
            for variant in sep.variantsByLengthDesc {
                let v = Array(variant)
                if matches(chars, at: i, v), v.count > (best?.1 ?? 0) {
                    best = (sep, v.count)
                }
            }
        }
        return best
    }

    /// 未知の予約語のエラーメッセージ用に、`@` から始まる語を切り出す。
    static func unknownWordText(_ chars: [Character], at i: Int) -> String {
        var j = i + 1
        while j < chars.count, chars[j].isLetter || chars[j].isNumber { j += 1 }
        return String(chars[i..<j])
    }
}
