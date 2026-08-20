//
//  正規表現照合のための「畳んだ射影」。
//
//  巻数フォーマットと保護文字列は `NSRegularExpression`（ICU）で照合する。ICU は
//  **コードポイント単位**で比較するため、Swift の `Character` 比較が無償で吸収して
//  いた 2 つの差を、こちらで先に潰しておく必要がある。
//
//  1. **全角と半角**。実ファイル名の 10.8% が全角英数記号を含む。`vol` を `ｖｏｌ`
//     と書いたものも拾いたい。`CharacterCanonicalization.foldWidth` を使う。
//  2. **NFC と NFD**。実ファイル名の **75.5% が NFD**。NFC で書かれたパターン
//     `(完全版)` を NFD の入力に当てると、ICU では一致しない（`Character` の `==`
//     なら正準等価で一致する）。1 文字ずつ NFC へ合成して揃える。
//
//  どちらの変換も **`Character` の個数を変えない**。これが `CharacterCanonicalization`
//  の不変条件（「文字数を変えないこと」）そのもので、原文の文字添字と畳んだ文字列の
//  文字添字を一対一に保つ。`raw` として保存する値は必ず `original` から取るので、
//  ユーザーのファイル名の表記（全角のままか、NFD のままか）は失われない。
//
//  `NSRegularExpression` は UTF-16 の `NSRange` を扱うので、文字添字と UTF-16
//  オフセットの対応表も併せて持つ。**絵文字のような非 BMP 文字を含むファイル名で
//  添字がずれるのを防ぐのがこの表の役目**。
//
import Foundation

public struct FoldedSubject: Sendable {
    /// 原文の文字（畳む前）。`raw` はここから取る。
    public let original: [Character]
    /// 全角を半角へ畳み、NFC へ合成した文字列。正規表現の照合はこれに対して行う。
    public let text: String
    /// `text` を文字単位で見たもの。`original` と要素数が一致する。
    /// 生の数字表記の走査のように、添字で辿りたい場面で使う。
    let foldedChars: [Character]
    /// 文字添字 → UTF-16 オフセット。要素数は `original.count + 1`。
    let utf16ByChar: [Int]
    /// UTF-16 オフセット → 文字添字。要素数は UTF-16 長 + 1。
    let charByUTF16: [Int]

    public var count: Int { original.count }
    public var isEmpty: Bool { original.isEmpty }
    var utf16Length: Int { utf16ByChar[utf16ByChar.count - 1] }

    public init(_ chars: [Character]) {
        original = chars
        var folded = String()
        folded.reserveCapacity(chars.count)
        var foldedList: [Character] = []
        foldedList.reserveCapacity(chars.count)
        var byChar: [Int] = []
        byChar.reserveCapacity(chars.count + 1)
        var byUTF16: [Int] = []
        var offset = 0

        for (index, character) in chars.enumerated() {
            byChar.append(offset)
            let normalized = Self.fold(character)
            folded.append(normalized)
            foldedList.append(normalized)
            // 1 文字が占める UTF-16 単位ぶんだけ、同じ文字添字を書き込む。
            for _ in 0..<normalized.utf16.count { byUTF16.append(index) }
            offset += normalized.utf16.count
        }
        byChar.append(offset)
        byUTF16.append(chars.count)

        text = folded
        foldedChars = foldedList
        utf16ByChar = byChar
        charByUTF16 = byUTF16
    }

    public init(_ string: String) { self.init(Array(string)) }

    /// 全角を畳み、NFC へ合成する。**1 文字に収まらなければ畳まない**
    /// （文字数の一対一対応を守るため。`CharacterCanonicalization` と同じ判断）。
    static func fold(_ c: Character) -> Character {
        let widthFolded = CharacterCanonicalization.foldWidth(c)
        let composed = String(widthFolded).precomposedStringWithCanonicalMapping
        guard let single = CharacterCanonicalization.single(composed) else { return widthFolded }
        return single
    }

    // MARK: - 添字の変換

    /// 文字添字 `i` から末尾までを表す `NSRange`。
    ///
    /// **長さは常に「文字列の末尾まで」にする。** 途中で切ると、その位置が
    /// `\z` や `$` の意味する「末尾」になってしまい、ユーザーの書いた末尾アンカーが
    /// 途中で成立する。範囲を絞りたい呼び出し側は、得られたマッチの上端で弾くこと。
    func rangeFromCharacter(_ i: Int) -> NSRange {
        let start = utf16ByChar[min(max(i, 0), original.count)]
        return NSRange(location: start, length: utf16Length - start)
    }

    /// マッチの `NSRange` を文字添字の範囲へ写す。
    ///
    /// ICU はコードポイント単位で切るので、上端が書記素の途中に落ちることがある
    /// （NFD の「か」＋濁点のうち「か」だけに一致した場合など）。**そのときは
    /// 書記素の切れ目まで切り上げる**——半端な位置で切ると、原文へ写し戻したときに
    /// 濁点だけが取り残される。
    func characterRange(of range: NSRange) -> Range<Int>? {
        guard range.location != NSNotFound else { return nil }
        let lowerUTF16 = min(range.location, utf16Length)
        let upperUTF16 = min(range.location + range.length, utf16Length)
        let lower = charByUTF16[lowerUTF16]
        var upper = charByUTF16[upperUTF16]
        // 上端が文字の途中を指しているなら、その文字を含めるところまで進める。
        if upperUTF16 > lowerUTF16, upperUTF16 < utf16Length, utf16ByChar[upper] != upperUTF16 {
            upper += 1
        }
        guard lower <= upper else { return nil }
        return lower..<upper
    }

    /// 文字添字の範囲に対応する**原文**（畳む前）を返す。
    public func originalText(in range: Range<Int>) -> String {
        let lower = min(max(range.lowerBound, 0), original.count)
        let upper = min(max(range.upperBound, lower), original.count)
        return String(original[lower..<upper])
    }
}
