//
//  巻数の照合 [5.2][SE-02][SE-21][SE-24][TY-01][VM2-01〜VM2-05]。
//
//  照合は `FoldedSubject`（全角を半角へ畳み NFC へ合成した射影）に対して行う。
//  `raw` は必ず原文から取るので、ユーザーのファイル名の表記は失われない。
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

    /// 指定位置から始まる候補を、**長い順（同長なら登録順が先のもの）**で返す。
    ///
    /// `@volume` の型付き照合で使う [TY-01][SE-24]。パーサは長い候補から順に試して
    /// バックトラックする。
    ///
    /// **区切り専用のパターンは候補にしない。** 巻数ではないので `@volume` の
    /// 型条件 [SE-24] を満たさない。
    public static func matches(in subject: FoldedSubject, at index: Int,
                               patterns: [CompiledVolumePattern],
                               includeBareDigits: Bool = true) -> [VolumeMatch] {
        var out: [VolumeMatch] = []
        for pattern in patterns where pattern.kind == .volume {
            guard !pattern.health.isAbandoned(pattern.id) else { continue }
            switch pattern.regex.match(anchoredAt: index, in: subject,
                                       budget: AppLimits.Format.regexMatchBudget) {
            case .abandoned:
                pattern.health.markAbandoned(pattern.id)
            case .found(let m):
                if let value = numericValue(of: m, pattern: pattern, in: subject) {
                    out.append(VolumeMatch(patternID: pattern.id, range: m.range, value: value))
                }
            case .none:
                break
            }
        }
        // `@volume` の型条件は「生の数字表記」＋「登録済み巻数フォーマット」の
        // 和集合 [SE-24][VM2-05]。
        if includeBareDigits, let bare = matchBareNumber(in: subject, at: index) {
            out.append(bare)
        }
        return out.enumerated()
            .sorted { ($0.element.length, -$0.offset) > ($1.element.length, -$1.offset) }
            .map(\.element)
    }

    /// タイトル末尾に限定した照合 [SE-02]。
    ///
    /// **末尾に届く一致のうち最長のものを採る。同じ長さなら登録順が先のもの** [SE-21][VM2-01]。
    ///
    /// 登録順だけで決めると `作品 第01巻` が `01巻` と読まれてシリーズ名が `作品 第`
    /// になる——実データの一般コミックは **94% が `第??巻`** なので実害が大きい。
    /// 長い方を採れば、ユーザーがパターンを追加した順番によらず正しく読める。
    ///
    /// **区切り専用のパターンもここでは候補になる。** シリーズ名を切るのが役目なので、
    /// 一致すれば範囲は返すが巻数は `.none` のままにする。
    public static func matchAtEnd(_ subject: FoldedSubject,
                                  patterns: [CompiledVolumePattern]) -> VolumeMatch? {
        guard !subject.isEmpty else { return nil }
        var best: VolumeMatch?
        for pattern in patterns {
            guard !pattern.health.isAbandoned(pattern.id) else { continue }
            switch pattern.regex.matchAtEnd(in: subject,
                                            budget: AppLimits.Format.regexMatchBudget) {
            case .abandoned:
                pattern.health.markAbandoned(pattern.id)
            case .found(let m):
                let value: VolumeValue?
                if pattern.kind == .separator {
                    // **`VolumeValue.none` と書き切ること。** 代入先が `VolumeValue?`
                    // なので、素の `.none` は `Optional.none`（＝ nil）に解決される。
                    // そうなると直後の `guard let` が必ず抜けて、区切り専用の
                    // パターンが一致しても捨てられる（実際にこれを踏んだ）。
                    // このコードベースで 3 度目の同じ罠 [CLAUDE.md 参照]。
                    value = VolumeValue.none           // 切るだけ。巻数は持たない
                } else {
                    value = numericValue(of: m, pattern: pattern, in: subject)
                }
                guard let value else { continue }
                // 同長なら先に入った方（登録順が先）を残す。
                if m.range.count > (best?.length ?? 0) {
                    best = VolumeMatch(patternID: pattern.id, range: m.range, value: value)
                }
            case .none:
                break
            }
        }
        return best
    }

    /// `[Character]` から呼ぶ入口。設定スナップショットを持たない経路（シリーズ抽出）用。
    public static func matchAtEnd(_ chars: [Character],
                                  patterns: [CompiledVolumePattern]) -> VolumeMatch? {
        matchAtEnd(FoldedSubject(chars), patterns: patterns)
    }

    /// `[Character]` から呼ぶ入口。`ParseInput` を持たない経路用。
    public static func matches(in chars: [Character], at index: Int,
                               patterns: [CompiledVolumePattern],
                               includeBareDigits: Bool = true) -> [VolumeMatch] {
        matches(in: FoldedSubject(chars), at: index,
                patterns: patterns, includeBareDigits: includeBareDigits)
    }

    // MARK: - 値の取り出し

    /// 巻数種別のパターンから数値を作る。
    ///
    /// 値は `(?<volume>…)` か唯一のキャプチャグループから取る。**キャプチャが数値
    /// として読めないパターンは候補にしない**——`第(一)巻` のようなものを巻数 0 と
    /// 誤って扱うより、一致しなかったことにするほうが害が小さい。
    static func numericValue(of match: RegexMatch, pattern: CompiledVolumePattern,
                             in subject: FoldedSubject) -> VolumeValue? {
        guard let capture = match.captureRange,
              let number = number(in: capture, of: subject) else { return nil }
        return .numeric(number, raw: subject.originalText(in: match.range))
    }

    /// 畳んだ文字の範囲を数値として読む。全体が数字（と小数点 1 個）でなければ `nil`。
    static func number(in range: Range<Int>, of subject: FoldedSubject) -> Double? {
        var digits = ""
        var sawPoint = false
        for c in subject.foldedChars[range] {
            if c.isASCII, c >= "0", c <= "9" { digits.append(c); continue }
            if c == ".", !sawPoint, !digits.isEmpty { sawPoint = true; digits.append(c); continue }
            // 先頭の空白だけは読み飛ばす（`vol\s*(\d+)` を `vol (\d+)` と書いた場合）。
            if Whitespace.isWhitespace(c), digits.isEmpty { continue }
            return nil
        }
        guard !digits.isEmpty, !digits.hasSuffix(".") else { return nil }
        return Double(digits)
    }

    /// 生の数字表記（`01` `3` `3.5`）[SE-24][VM2-05]。
    ///
    /// これだけは正規表現を通さない。型条件の一部として常に必要で、
    /// ユーザーが書き換えられるものでもないため。
    static func matchBareNumber(in subject: FoldedSubject, at index: Int) -> VolumeMatch? {
        guard let d = readNumber(subject.foldedChars, at: index) else { return nil }
        let range = index..<d.end
        return VolumeMatch(patternID: nil, range: range,
                           value: .numeric(d.value, raw: subject.originalText(in: range)))
    }

    /// 数字列を読む。`3.5` のように「数字 + `.` + 数字」が続く場合は小数として読む。
    /// 入力は畳み済みなので、全角数字はここへ来る時点で半角になっている [SE-03][VM2-04]。
    static func readNumber(_ chars: [Character], at index: Int) -> (value: Double, end: Int)? {
        var i = index
        var digits = ""
        while i < chars.count, chars[i].isASCII, chars[i] >= "0", chars[i] <= "9" {
            digits.append(chars[i]); i += 1
        }
        guard !digits.isEmpty else { return nil }

        // 小数部（`.` の直後にも数字が続くときだけ）
        if i < chars.count, chars[i] == ".", i + 1 < chars.count,
           chars[i + 1].isASCII, chars[i + 1] >= "0", chars[i + 1] <= "9" {
            digits.append(".")
            i += 1
            while i < chars.count, chars[i].isASCII, chars[i] >= "0", chars[i] <= "9" {
                digits.append(chars[i]); i += 1
            }
        }
        guard let value = Double(digits) else { return nil }
        return (value, i)
    }
}
