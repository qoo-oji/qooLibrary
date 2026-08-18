//
//  空白の扱い [WS-01〜WS-07][NM-03]。
//
import Foundation

public enum Whitespace {
    /// 空白とみなすスカラー [NM-03]。
    /// 改行はファイル名に現れないが、現れた場合も空白として扱う。
    @inlinable
    public static func isWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x20,      // SPACE
             0x3000,    // IDEOGRAPHIC SPACE（全角スペース）
             0x09,      // TAB
             0xA0,      // NO-BREAK SPACE
             0x0A, 0x0D: // LF / CR
            return true
        default:
            return false
        }
    }

    @inlinable
    public static func isWhitespace(_ c: Character) -> Bool {
        // 空白は必ず単一スカラーの grapheme。合成文字が空白になることはない。
        guard let first = c.unicodeScalars.first, c.unicodeScalars.count == 1 else { return false }
        return isWhitespace(first)
    }

    /// フォーマット定義の保存時正規化: 連続空白 → 半角 1 個 [WS-03][WS-04]。
    public static func normalizeLiteral(_ format: String) -> String {
        var out = ""
        out.reserveCapacity(format.count)
        var pendingSpace = false
        for c in format {
            if isWhitespace(c) {
                pendingSpace = true
            } else {
                if pendingSpace { out.append(" "); pendingSpace = false }
                out.append(c)
            }
        }
        // 末尾の空白は 1 個に畳んで残す（フォーマット末尾の空白は意味を持ちうる）。
        if pendingSpace { out.append(" ") }
        return out
    }
}
