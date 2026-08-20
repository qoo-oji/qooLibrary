//
//  ユーザーが書いた正規表現の安全性検査。
//
//  ICU は指数時間になりうる（実測: `(a+)+$` は 2 文字ごとに約 4 倍）。実行時は
//  `SafeRegex` のウォッチドッグが必ず打ち切るので**アプリが固まることはない**が、
//  打ち切られたパターンはそのライブラリで使えなくなる。だから**書いた時点で気づける**
//  ようにする。
//
//  三層防御のうちの ② と ③ を担う（① は `SafeRegex` の実行時ウォッチドッグ）。
//
//  | 層 | この層はどんな実条件で落ちるか |
//  |---|---|
//  | ② 構造検査 | 経験則。安全なものを警告することも、危険なものを見逃すこともある |
//  | ③ 実測 | 破裂させる文字列が標本に無いパターンを見逃す |
//
//  **どちらも「拒否」ではなく「警告」にとどめる。** ① が時間の上限を保証している
//  以上、表現力を削る理由が無い。
//
import Foundation

public struct RegexSafetyFinding: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        /// 正規表現として読めない。これだけはエラー。
        case invalidSyntax(String)
        /// 量指定子の付いたグループが、中に量指定子か選択肢を含む。指数時間の必要条件。
        case quantifiedGroup
        /// 後方参照。指数時間になりうるうえ、この用途では使い道が無い。
        case backreference
        /// 先読み・後読み。量指定子と組み合わさると急激に遅くなることがある。
        case lookaround
        /// 全角文字が書かれている。照合は半角へ畳んだ後に行うので**決して一致しない**。
        case fullWidthLiteral(String)
        /// 実測で時間の上限を超えた標本があった。
        case tooSlow(sample: String)
    }

    public let kind: Kind

    public init(kind: Kind) { self.kind = kind }

    /// 構文エラーだけがエラー。ほかは警告。
    public var isError: Bool {
        if case .invalidSyntax = kind { return true }
        return false
    }

    public var message: String {
        switch kind {
        case .invalidSyntax(let reason):
            return "正規表現として読めません: \(reason)"
        case .quantifiedGroup:
            return "量指定子の付いたグループが、中にも量指定子や選択肢を含んでいます"
                + "（`(a+)+` のような形）。入力によっては照合が極端に遅くなり、"
                + "時間の上限で打ち切られることがあります。"
        case .backreference:
            return "後方参照（`\\1` や `\\k<名前>`）が含まれています。照合が極端に遅く"
                + "なることがあり、ファイル名の照合では通常必要ありません。"
        case .lookaround:
            return "先読み・後読み（`(?=` `(?!` `(?<=` `(?<!`）が含まれています。"
                + "量指定子と組み合わさると照合が遅くなることがあります。"
        case .fullWidthLiteral(let characters):
            return "全角の文字 \(characters) が含まれています。照合は全角を半角へ"
                + "畳んでから行うため、この文字は決して一致しません。半角で書いてください"
                + "（記号をそのまま照合したい場合は `\\(` のようにエスケープします）。"
        case .tooSlow(let sample):
            return "この正規表現は入力によっては極端に遅くなります（\(sample) で"
                + "時間の上限に達しました）。走査中に打ち切られ、このフォーマットは"
                + "無効化されます。"
        }
    }
}

public enum RegexSafety {

    /// 実際に走らせずに分かることだけを見る。**入力のたびに呼んでよい。**
    ///
    /// `validate()` は設定画面の描画のたびに（セクションの数だけ）呼ばれるので、
    /// ここに実測を混ぜてはならない——**危険な正規表現を直そうとしている最中に
    /// こそ画面が重くなる**という、いちばん困る形になる。
    public static func staticFindings(_ source: String) -> [RegexSafetyFinding] {
        do {
            _ = try SafeRegex(source)
        } catch {
            // ICU のエラー文言をそのまま見せる。原因の位置まで書いてあることが多い。
            return [RegexSafetyFinding(kind: .invalidSyntax(shortReason(from: error)))]
        }
        var findings = structuralFindings(source)
        if let offenders = fullWidthOffenders(source) {
            findings.append(RegexSafetyFinding(kind: .fullWidthLiteral(offenders)))
        }
        return findings
    }

    /// 実際に走らせて時間を測る。**保存時など、明示的な区切りでだけ呼ぶ。**
    ///
    /// - Parameters:
    ///   - source: ユーザーが書いた正規表現。
    ///   - samples: そのライブラリの実ファイル名。あれば実測の標本に加える。
    public static func measuredFindings(_ source: String,
                                        samples: [String] = []) -> [RegexSafetyFinding] {
        guard let compiled = try? SafeRegex(source) else { return [] }   // 構文エラーは静的検査の担当
        guard let slow = slowestSample(compiled, source: source, samples: samples) else { return [] }
        return [RegexSafetyFinding(kind: .tooSlow(sample: slow))]
    }

    /// 静的検査と実測の両方。テストと、時間をかけてよい経路から使う。
    public static func analyze(_ source: String, samples: [String] = []) -> [RegexSafetyFinding] {
        let findings = staticFindings(source)
        // 構文エラーなら実測しても意味が無い。
        if findings.contains(where: \.isError) { return findings }
        return findings + measuredFindings(source, samples: samples)
    }

    static func shortReason(from error: Error) -> String {
        let text = (error as NSError).localizedDescription
        return text.isEmpty ? "\(error)" : text
    }

    // MARK: - ② 構造検査

    /// グループの入れ子を追い、「中に量指定子か選択肢を含むグループ」に無制限の
    /// 量指定子が付いている形を探す。これが指数時間の必要条件。
    ///
    /// **「原子を 1 つ読み、その直後の量指定子を読む」形で走る。** 文字クラスや
    /// エスケープを読み飛ばしたあとに量指定子の確認を忘れると、`(?:[0-9]+)+` や
    /// `(\d+)+` のような**いちばん典型的な危険形**を取りこぼす（実際に踏んだ）。
    static func structuralFindings(_ source: String) -> [RegexSafetyFinding] {
        struct Frame { var hasUnbounded = false; var hasAlternation = false }

        var findings: Set<RegexSafetyFinding.Kind> = []
        var stack: [Frame] = [Frame()]
        let chars = Array(source)
        var i = 0

        /// 現在の枠に「無制限の量指定子があった」と記録する。
        func markUnbounded() {
            if !stack.isEmpty { stack[stack.count - 1].hasUnbounded = true }
        }

        while i < chars.count {
            let c = chars[i]
            let atomEnd: Int

            switch c {
            case "(":
                if isLookaround(chars, at: i) { findings.insert(.lookaround) }
                stack.append(Frame())
                i += 1
                continue

            case ")":
                let closed = stack.count > 1 ? stack.removeLast() : Frame()
                let (kind, width) = quantifier(chars, at: i + 1)
                if kind == .unbounded, closed.hasUnbounded || closed.hasAlternation {
                    findings.insert(.quantifiedGroup)
                }
                // 中の量指定子は外側から見ても「曖昧さの種」なので持ち上げる。
                if closed.hasUnbounded || kind == .unbounded { markUnbounded() }
                i += 1 + width
                continue

            case "|":
                if !stack.isEmpty { stack[stack.count - 1].hasAlternation = true }
                i += 1
                continue

            case "\\":
                if i + 1 < chars.count {
                    let next = chars[i + 1]
                    if next.isNumber, next != "0" { findings.insert(.backreference) }
                    if next == "k", i + 2 < chars.count, chars[i + 2] == "<" {
                        findings.insert(.backreference)
                    }
                }
                atomEnd = min(i + 2, chars.count)

            case "[":
                var j = i + 1
                if j < chars.count, chars[j] == "^" { j += 1 }
                if j < chars.count, chars[j] == "]" { j += 1 }   // 先頭の `]` はリテラル
                while j < chars.count, chars[j] != "]" {
                    if chars[j] == "\\" { j += 1 }
                    j += 1
                }
                atomEnd = min(j + 1, chars.count)

            default:
                atomEnd = i + 1
            }

            // 原子の**直後**の量指定子を読む。
            let (kind, width) = quantifier(chars, at: atomEnd)
            if kind == .unbounded { markUnbounded() }
            i = atomEnd + width
        }

        return findings.sorted { "\($0)" < "\($1)" }.map(RegexSafetyFinding.init(kind:))
    }

    static func isLookaround(_ chars: [Character], at i: Int) -> Bool {
        guard i + 2 < chars.count, chars[i + 1] == "?" else { return false }
        let third = chars[i + 2]
        if third == "=" || third == "!" { return true }
        guard third == "<", i + 3 < chars.count else { return false }
        return chars[i + 3] == "=" || chars[i + 3] == "!"
    }

    enum Quantifier { case none, bounded, unbounded }

    /// 位置 `i` から始まる量指定子を読み、種類と消費した文字数を返す。
    static func quantifier(_ chars: [Character], at i: Int) -> (Quantifier, Int) {
        guard i < chars.count else { return (.none, 0) }
        switch chars[i] {
        case "*", "+":
            // 直後の `?`（非貪欲）や `+`（所有）も量指定子の一部として読む。
            let lazy = i + 1 < chars.count && (chars[i + 1] == "?" || chars[i + 1] == "+")
            return (.unbounded, lazy ? 2 : 1)
        case "?":
            let lazy = i + 1 < chars.count && (chars[i + 1] == "?" || chars[i + 1] == "+")
            return (.bounded, lazy ? 2 : 1)
        case "{":
            var j = i + 1
            var body = ""
            while j < chars.count, chars[j] != "}" { body.append(chars[j]); j += 1 }
            guard j < chars.count else { return (.none, 0) }        // 閉じていない＝リテラル
            let width = j - i + 1
            // `{n,}` だけが無制限。`{n}` `{n,m}` は有界。
            if body.hasSuffix(","), body.dropLast().allSatisfy(\.isNumber), !body.dropLast().isEmpty {
                return (.unbounded, width)
            }
            return (.bounded, width)
        default:
            return (.none, 0)
        }
    }

    // MARK: - 全角の検出

    /// 全角のまま書かれた文字を集める。**NFC/NFD の差は対象外**——そちらは
    /// `SafeRegex` が黙って揃えるので、ユーザーが気にする必要がない。
    static func fullWidthOffenders(_ source: String) -> String? {
        var seen: [Character] = []
        for c in source where CharacterCanonicalization.foldWidth(c) != c {
            if !seen.contains(c) { seen.append(c) }
        }
        guard !seen.isEmpty else { return nil }
        return seen.map { "`\($0)`" }.joined(separator: " ")
    }

    // MARK: - ③ 保存時の実測

    /// 敵対的な標本と実ファイル名を当てて、上限に達するものがあれば返す。
    ///
    /// **① と同じウォッチドッグの下で走るので、この検査自体は決して固まらない。**
    static func slowestSample(_ regex: SafeRegex, source: String,
                              samples: [String]) -> String? {
        let started = DispatchTime.now().uptimeNanoseconds
        let totalLimit = UInt64(AppLimits.Format.regexProbeTotalBudget * 1_000_000_000)

        for sample in probeSamples(source: source, samples: samples) {
            let subject = FoldedSubject(sample)
            // 末尾アンカー（`(?:…)\z`）が最も破裂しやすい形なので先に当てる。
            if regex.matchAtEnd(in: subject, budget: AppLimits.Format.regexProbeBudget) == .abandoned {
                return describe(sample)
            }
            if regex.match(anchoredAt: 0, in: subject,
                           budget: AppLimits.Format.regexProbeBudget) == .abandoned {
                return describe(sample)
            }
            // 打ち切られはしないが遅いパターンで、検査そのものが重くならないように。
            if DispatchTime.now().uptimeNanoseconds &- started > totalLimit { return describe(sample) }
        }
        return nil
    }

    /// パターン自身が受け付けそうな文字を繰り返した文字列を作る。
    ///
    /// 破裂は「パターンが食べられる文字が長く続き、最後に一致を失敗させる文字が来る」
    /// ときに起きるので、種文字はパターンから採るのが素直。
    static func probeSamples(source: String, samples: [String]) -> [String] {
        var seeds: [Character] = []
        func addSeed(_ c: Character) {
            guard seeds.count < 8, !seeds.contains(c) else { return }
            seeds.append(c)
        }

        let chars = Array(source)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\\", i + 1 < chars.count {
                switch chars[i + 1] {
                case "d", "w": addSeed("0")
                case "s": addSeed(" ")
                default: addSeed(chars[i + 1])          // エスケープされたリテラル
                }
                i += 2
                continue
            }
            if !"()[]{}|^$*+?.".contains(c) { addSeed(c) }
            i += 1
        }
        if seeds.isEmpty { addSeed("a") }

        var out: [String] = []
        for seed in seeds {
            for length in [24, 32, 40] {
                let run = String(repeating: String(seed), count: length)
                out.append(run)
                // 一致を失敗させる終端。これが付くと総当たりが最後まで走る。
                out.append(run + "\u{0001}")
                if out.count >= AppLimits.Format.maxRegexProbeSamples { break }
            }
            if out.count >= AppLimits.Format.maxRegexProbeSamples { break }
        }
        return out + samples.prefix(AppLimits.Format.maxRegexProbeSamples)
    }

    static func describe(_ sample: String) -> String {
        let visible = sample.replacingOccurrences(of: "\u{0001}", with: "")
        guard let first = visible.first else { return "空の文字列" }
        if visible.allSatisfy({ $0 == first }) {
            return "`\(first)` を \(visible.count) 個並べた文字列"
        }
        return "「\(visible.prefix(24))…」"
    }
}
