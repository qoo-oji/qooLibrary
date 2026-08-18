//
//  照合の入力表現。
//
//  原文・マスク後・正準形を **同じ添字体系** で保持する。正準化は 1 文字 → 1 文字
//  なので `maskedChars` と `canonicalChars` の添字は一対一で対応し、`originRanges`
//  がマスク後の添字を原文の範囲へ写す。
//
//  仕様書 04章 §4.6 の擬似コードは `canonicalWidth(input)` という**並行した文字列**を
//  作って位置 i で比較していたが、その方式は NFC 化で長さが変わる場合に破綻しうる。
//  実測すると Swift の `Character` は grapheme 単位なので NFC/NFD で個数が変わらず、
//  かつ `==` が正準等価で比較するため、**並行文字列を作らずに 1 文字ずつ畳んで比べる**
//  ほうが安全で速い [設計判断、Spikes の正規化プローブで確認]。
//
import Foundation

public struct ParseInput: Sendable {
    /// 原文（マスク前）。フィールド値と `FieldSpan` はここを指す [WS-05][N-03]。
    public let originalChars: [Character]
    /// マスク後の文字。保護文字列は PUA 1 文字に置き換わっている [PT-02]。
    public let maskedChars: [Character]
    /// `maskedChars` の正準形。長さは `maskedChars` と等しい。
    public let canonicalChars: [Character]
    /// `maskedChars[i]` が `originalChars` のどの範囲に対応するか。
    public let originRanges: [Range<Int>]
    /// マスクが上限（PUA 256 個）を超えて打ち切られたか [PTI-05]。
    public let maskTruncated: Bool

    public var count: Int { maskedChars.count }
    public var isEmpty: Bool { maskedChars.isEmpty }

    public init(originalChars: [Character], maskedChars: [Character],
                canonicalChars: [Character], originRanges: [Range<Int>],
                maskTruncated: Bool = false) {
        precondition(maskedChars.count == canonicalChars.count)
        precondition(maskedChars.count == originRanges.count)
        self.originalChars = originalChars
        self.maskedChars = maskedChars
        self.canonicalChars = canonicalChars
        self.originRanges = originRanges
        self.maskTruncated = maskTruncated
    }

    /// マスクを行わない入力（保護文字列が 1 つも無い場合の速い経路）。
    public init(_ text: String, caseSensitive: Bool = false) {
        let chars = Array(text)
        self.init(originalChars: chars,
                  maskedChars: chars,
                  canonicalChars: chars.map { CharacterCanonicalization.canonical($0, caseSensitive: caseSensitive) },
                  originRanges: chars.indices.map { $0..<($0 + 1) })
    }

    /// マスク後の範囲を原文の範囲へ写す [PT-03][PTI-02]。
    public func originalRange(of maskedRange: Range<Int>) -> Range<Int> {
        guard !maskedRange.isEmpty else {
            let at = maskedRange.lowerBound
            let pos = at < originRanges.count ? originRanges[at].lowerBound : originalChars.count
            return pos..<pos
        }
        let lower = originRanges[maskedRange.lowerBound].lowerBound
        let upper = originRanges[maskedRange.upperBound - 1].upperBound
        return lower..<upper
    }

    /// マスク後の範囲に対応する**原文**を返す（保護文字列は復元済み）[PT-03]。
    public func originalText(of maskedRange: Range<Int>) -> String {
        String(originalChars[originalRange(of: maskedRange)])
    }
}
