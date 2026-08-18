//
//  全角 → 半角の畳み込み [N-02][NM-01][NM-02]。
//
import Foundation

/// 全角英数記号と全角スペースだけを半角へ畳む。
///
/// **`CFStringTransform(_:_:kCFStringTransformFullwidthHalfwidth, false)` を使っては
/// ならない** [NM-01]。実測すると、長音「ー」を半角カナの `ｰ` へ、カタカナ全体を
/// 半角カナへ変換してしまう:
///
/// ```
/// CFStringTransform("ロングーバケーション") -> "ﾛﾝｸﾞｰﾊﾞｹｰｼｮﾝ"
/// CFStringTransform("ー")                   -> "ｰ"
/// ```
///
/// 実コーパス（2,953 件）では長音「ー」が **26.3%** のファイル名に現れるため、
/// これを使っていれば 778 件を壊していた。
///
/// 対象は U+FF01〜U+FF5E（`！`〜`～`。`０-９` `Ａ-Ｚ` `ａ-ｚ` を含む）と
/// U+3000（全角スペース）のみ。**半角カナ（U+FF61〜U+FF9F）は変換しない** [NM-02]。
public enum WidthFolding {
    /// 全角英数記号の始点。半角との差は常に 0xFEE0。
    @usableFromInline static let fullwidthASCIIStart: UInt32 = 0xFF01
    @usableFromInline static let fullwidthASCIIEnd: UInt32 = 0xFF5E
    @usableFromInline static let asciiOffset: UInt32 = 0xFEE0

    /// 1 スカラーを畳む。**畳んでもスカラー数は必ず 1 のまま**なので、
    /// 文字列の長さも grapheme の区切りも変わらない。この性質が
    /// パーサの「原文と正準形で添字が一対一に対応する」前提を支えている。
    @inlinable
    public static func fold(_ scalar: Unicode.Scalar) -> Unicode.Scalar {
        let v = scalar.value
        if v >= fullwidthASCIIStart, v <= fullwidthASCIIEnd {
            // 0xFF01...0xFF5E − 0xFEE0 = 0x21...0x7E。UInt8 に必ず収まるので
            // 失敗しうる初期化子を使わずに済む（到達不能な分岐を作らない）。
            return Unicode.Scalar(UInt8(truncatingIfNeeded: v - asciiOffset))
        }
        if v == 0x3000 { return " " }          // 全角スペース → 半角スペース
        return scalar
    }

    /// 畳む必要があるスカラーを含むか。無ければ元の文字列をそのまま使える。
    @inlinable
    public static func needsFolding(_ s: String) -> Bool {
        s.unicodeScalars.contains { fold($0) != $0 }
    }

    /// 文字列全体を畳む。長さ（grapheme 数）は変わらない。
    public static func fold(_ s: String) -> String {
        guard needsFolding(s) else { return s }
        var out = String.UnicodeScalarView()
        out.reserveCapacity(s.unicodeScalars.count)
        for scalar in s.unicodeScalars { out.append(fold(scalar)) }
        return String(out)
    }
}
