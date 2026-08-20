//
//  旧記法からの変換（2026-08 の仕様変更）。
//
//  巻数フォーマットは `??`（1 桁以上の数字。小数可）と `<space>`（空白 1 個以上）
//  という独自のメタ記号で書かれていた。保護文字列は完全一致のリテラルだった。
//  どちらも正規表現へ移した。
//
//  この変換は **DB の移行と JSON バックアップの取り込みの両方から使う**。取り込み側を
//  忘れると、以前書き出したバックアップを読めなくなる。
//
import Foundation

public enum LegacyVolumeNotation {

    static let digitsMark = "??"
    static let spaceMark = "<space>"

    /// 旧記法の巻数フォーマットを正規表現へ。
    ///
    /// - `??` → `([0-9]+(?:\.[0-9]+)?)`（最初の 1 つだけキャプチャ）
    /// - `<space>` → `\s+`
    /// - それ以外はリテラルとしてエスケープ
    ///
    /// **`??` が 2 つ以上ある場合、2 つ目以降は非キャプチャにする。** 巻数の値を
    /// 取り出すグループが 1 つに定まらないと、どれが巻数か決められない。
    public static func regex(fromVolumeSource source: String) -> String {
        var out = ""
        var literal = ""
        var usedCapture = false
        let chars = Array(source)
        var i = 0

        func flushLiteral() {
            guard !literal.isEmpty else { return }
            out += escapingWhitespaceElastically(literal)
            literal = ""
        }

        while i < chars.count {
            if matches(chars, at: i, digitsMark) {
                flushLiteral()
                out += usedCapture ? "(?:[0-9]+(?:\\.[0-9]+)?)" : "([0-9]+(?:\\.[0-9]+)?)"
                usedCapture = true
                i += digitsMark.count
            } else if matches(chars, at: i, spaceMark) {
                flushLiteral()
                out += "\\s+"
                i += spaceMark.count
            } else {
                literal.append(chars[i])
                i += 1
            }
        }
        flushLiteral()
        return out
    }

    /// 完全一致のリテラルだった保護文字列を正規表現へ。
    ///
    /// **空白の連なりは `\s+` にする。** 旧実装は「キーの空白 1 個は入力の空白
    /// 1 個以上に対応する」という弾力的な照合をしていた [PT-04][WS-01]。素直に
    /// エスケープすると空白の個数が違うだけで一致しなくなり、挙動が変わる。
    public static func regex(fromProtectedLiteral text: String) -> String {
        escapingWhitespaceElastically(text)
    }

    /// 空白の連なりを `\s+` に、それ以外をリテラルとしてエスケープする。
    static func escapingWhitespaceElastically(_ text: String) -> String {
        var out = ""
        var buffer = ""

        func flush() {
            guard !buffer.isEmpty else { return }
            out += NSRegularExpression.escapedPattern(for: buffer)
            buffer = ""
        }

        var iterator = text.makeIterator()
        var pending: Character? = iterator.next()
        while let c = pending {
            if Whitespace.isWhitespace(c) {
                flush()
                out += "\\s+"
                // 連なりはまとめて 1 つの `\s+` にする。
                var next = iterator.next()
                while let n = next, Whitespace.isWhitespace(n) { next = iterator.next() }
                pending = next
                continue
            }
            buffer.append(c)
            pending = iterator.next()
        }
        flush()
        return out
    }

    static func matches(_ chars: [Character], at i: Int, _ mark: String) -> Bool {
        let markChars = Array(mark)
        guard i + markChars.count <= chars.count else { return false }
        for k in 0..<markChars.count where chars[i + k] != markChars[k] { return false }
        return true
    }
}
