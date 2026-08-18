//
//  照合用の 1 文字正準化。
//
//  **文字数を変えないことが不変条件**。原文と正準形を同じ添字体系で扱えるように
//  するためで、これがパーサの `ParseInput` を支えている。
//
import Foundation

public enum CharacterCanonicalization {

    /// 全角→半角のみを畳む（ケースは変えない）。
    public static func foldWidth(_ c: Character) -> Character {
        guard c.unicodeScalars.contains(where: { WidthFolding.fold($0) != $0 }) else { return c }
        var view = String.UnicodeScalarView()
        for s in c.unicodeScalars { view.append(WidthFolding.fold(s)) }
        return single(String(view)) ?? c
    }

    /// 照合用の正準形。全角→半角に加え、`caseSensitive == false` なら小文字化する。
    public static func canonical(_ c: Character, caseSensitive: Bool) -> Character {
        let folded = foldWidth(c)
        guard !caseSensitive else { return folded }
        guard folded.isUppercase || folded.unicodeScalars.contains(where: { $0.properties.isUppercase })
        else { return folded }
        // ケース変換が grapheme を分割する場合は畳まない（添字の一対一対応を守る）。
        return single(String(folded).lowercased()) ?? folded
    }

    /// 全角半角の差だけを無視して 1 文字を比べる。
    /// NFC/NFD の差は Swift の `Character` 比較が正準等価で吸収する [実測]。
    @inlinable
    public static func equalIgnoringWidth(_ a: Character, _ b: Character) -> Bool {
        a == b || foldWidth(a) == foldWidth(b)
    }

    /// 1 つの `Character` に収まるときだけ返す。
    static func single(_ s: String) -> Character? {
        var it = s.makeIterator()
        guard let first = it.next(), it.next() == nil else { return nil }
        return first
    }
}
