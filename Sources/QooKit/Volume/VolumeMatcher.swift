//
//  巻数の照合 [5.2][SE-02][SE-21][SE-24][TY-01][VM2-01〜VM2-05]。
//
import Foundation

public struct VolumeMatch: Sendable, Equatable {
    public let patternID: UUID?
    /// 入力（文字配列）における範囲。
    public let range: Range<Int>
    public let value: VolumeValue

    public var length: Int { range.count }
}

public enum VolumeMatcher {

    /// 指定位置から、パターン集合のいずれかに一致する候補を返す。
    ///
    /// 評価は登録順（優先順）に行い、**最初にマッチしたものを採用する** [SE-21][VM2-01]。
    /// ただし `@volume` の型付き照合では長さの違う候補を順に試したいので、
    /// ここでは候補を**長い順**に並べて返す [TY-01][SE-24]。
    public static func matches(in chars: [Character], at index: Int,
                               patterns: [CompiledVolumePattern],
                               includeBareDigits: Bool = true) -> [VolumeMatch] {
        var out: [VolumeMatch] = []
        for pattern in patterns {
            if let m = match(pattern, in: chars, at: index) { out.append(m) }
        }
        // `@volume` の型条件は「生の数字表記」＋「登録済み巻数フォーマット」の
        // 和集合 [SE-24][VM2-05]。
        if includeBareDigits, let bare = matchBareNumber(in: chars, at: index) {
            out.append(bare)
        }
        // 長い順（同長なら登録順が先のもの）。
        return out.enumerated()
            .sorted { ($0.element.length, -$0.offset) > ($1.element.length, -$1.offset) }
            .map(\.element)
    }

    /// タイトル末尾に限定した照合 [SE-02]。
    ///
    /// **末尾に届く一致のうち最長のものを採る。同じ長さなら登録順が先のもの** [SE-21]。
    ///
    /// 仕様書 §5.2 VM2-01 は「登録順に評価し最初にマッチしたものを採用する」と
    /// していたが、それだけでは登録順に対して脆い [設計判断、2026-08]。
    /// §5.4 の既定セットは `??巻` を `第??巻` より先に列挙しており、その順だと
    /// `作品 第01巻` が `01巻` と読まれてシリーズ名が `作品 第` になる——実データの
    /// 一般コミックは **94% が `第??巻`** なので実害が大きい。長い方を採れば、
    /// ユーザーがパターンを追加した順番によらず正しく読める。登録順は同点の
    /// 決着にのみ使う（SE-21 の趣旨はそこにある）。
    public static func matchAtEnd(_ chars: [Character],
                                  patterns: [CompiledVolumePattern]) -> VolumeMatch? {
        guard !chars.isEmpty else { return nil }
        var best: VolumeMatch?
        for pattern in patterns {
            // 開始位置は**左から**探す。右から探すと `??` が最短の数字列を掴んで
            // しまう——`作品 12巻` が `2巻`（巻数 2）と読まれる。左から探して
            // 最初に末尾へ届いたものが、そのパターンでの最長一致になる。
            for start in 0..<chars.count {
                guard let m = match(pattern, in: chars, at: start),
                      m.range.upperBound == chars.count else { continue }
                if m.length > (best?.length ?? 0) { best = m }   // 同長なら先に入った方を残す
                break                                            // このパターンの最長は 1 つ
            }
        }
        return best
    }

    // MARK: - 1 パターンの照合

    static func match(_ pattern: CompiledVolumePattern,
                      in chars: [Character], at index: Int) -> VolumeMatch? {
        var i = index
        var captured: Double?
        var capturedRaw: String?

        for token in pattern.tokens {
            switch token {
            case .literal(let lit):
                guard matchLiteral(lit, in: chars, at: i) else { return nil }
                i += lit.count
            case .requiredSpace:
                // **1 個以上**。空白なしにはマッチしない [SE-23][WS-07]
                var n = 0
                while i + n < chars.count, Whitespace.isWhitespace(chars[i + n]) { n += 1 }
                guard n > 0 else { return nil }
                i += n
            case .digits:
                guard let d = readNumber(chars, at: i) else { return nil }
                captured = d.value
                capturedRaw = d.text
                i = d.end
            }
        }

        let range = index..<i
        guard !range.isEmpty else { return nil }
        let raw = String(chars[range])

        // 序列 + 数値の混在（`総集編??`）は `.ordinal` として扱い、数値は raw に
        // 含めるだけにする [VM2-03]。種別を 1 つに定めないと出力書式が破綻する [CR-23]。
        if let rank = pattern.ordinalRank {
            return VolumeMatch(patternID: pattern.id, range: range,
                               value: .ordinal(rank: rank, raw: raw))
        }
        guard let n = captured else {
            // 数値も序列も持たないパターン（純粋なリテラル）。巻数として意味を持たない。
            return nil
        }
        _ = capturedRaw
        return VolumeMatch(patternID: pattern.id, range: range, value: .numeric(n, raw: raw))
    }

    /// リテラルの比較は正準化した形どうしで行う [SE-03][MT2-05]。
    static func matchLiteral(_ lit: [Character], in chars: [Character], at i: Int) -> Bool {
        guard i + lit.count <= chars.count else { return false }
        for k in 0..<lit.count {
            // `lit` はコンパイル時に正準化済み。入力側はここで畳む。
            guard CharacterCanonicalization.equalIgnoringWidth(chars[i + k], lit[k]) else { return false }
        }
        return true
    }

    /// 生の数字表記（`01` `3` `3.5`）[SE-24][VM2-05]。
    static func matchBareNumber(in chars: [Character], at index: Int) -> VolumeMatch? {
        guard let d = readNumber(chars, at: index) else { return nil }
        return VolumeMatch(patternID: nil, range: index..<d.end,
                           value: .numeric(d.value, raw: String(chars[index..<d.end])))
    }

    /// 数字列を読む。全角数字は半角として数値化し、`raw` には原文を残す [SE-03][VM2-04]。
    /// `3.5` のように「数字 + `.` + 数字」が続く場合は小数として読む。
    static func readNumber(_ chars: [Character], at index: Int) -> (value: Double, text: String, end: Int)? {
        var i = index
        var digits = ""
        while i < chars.count, let d = asciiDigit(chars[i]) { digits.append(d); i += 1 }
        guard !digits.isEmpty else { return nil }

        // 小数部（`.` の直後にも数字が続くときだけ）
        if i < chars.count, isDecimalPoint(chars[i]), i + 1 < chars.count, asciiDigit(chars[i + 1]) != nil {
            digits.append(".")
            i += 1
            while i < chars.count, let d = asciiDigit(chars[i]) { digits.append(d); i += 1 }
        }
        guard let value = Double(digits) else { return nil }
        return (value, digits, i)
    }

    /// 半角・全角の数字を半角の `Character` として返す。
    static func asciiDigit(_ c: Character) -> Character? {
        guard c.unicodeScalars.count == 1, let s = c.unicodeScalars.first else { return nil }
        let folded = WidthFolding.fold(s)
        guard folded.value >= 0x30, folded.value <= 0x39 else { return nil }
        return Character(folded)
    }

    static func isDecimalPoint(_ c: Character) -> Bool {
        guard c.unicodeScalars.count == 1, let s = c.unicodeScalars.first else { return false }
        return WidthFolding.fold(s) == "."
    }
}
