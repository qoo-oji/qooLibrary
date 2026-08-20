//
//  時間の上限を持つ正規表現照合。
//
//  巻数フォーマットと保護文字列はユーザーが正規表現で書く。ICU（`NSRegularExpression`）
//  は素直なバックトラッキング実装なので、`(a+)+$` のようなパターンは**指数時間**に
//  なる。実測では 2 文字増えるごとに約 4 倍で、a×26 が 2.75 秒、a×40 なら数時間規模。
//  1 ライブラリ 5 万ファイルの走査でこれを踏むとアプリは実質ハングする。
//
//  **`.reportProgress` を付けると、ICU は長時間の照合中にも定期的にブロックを呼ぶ**
//  （実測: 50ms の間に約 500 回＝およそ 0.1ms 間隔）。そこで `stop.pointee = true` を
//  立てれば照合を打ち切れる。a×34（無制限なら約 700 秒）が正確に 0.050 秒で止まる
//  ことを実測で確認した。`.anchored` と併用しても効く。
//
//  この仕組みのおかげで **ブロックしたスレッドを殺す必要がない** [NV6-03 の制約を回避]。
//  オーバーヘッドは実測 0.0016 → 0.0028 ms/件（一致件数は完全に同一）で、全体パース
//  0.078 ms/件 に対して無視できる。
//
//  なお Swift 標準の `Regex` は同じパターンで a×20 に **60 秒**（ICU の約 1,500 倍）
//  かかるうえ打ち切る手段が無い。**エンジンは ICU 一択** [実測]。
//
import Foundation

/// 巻数を取り出す名前付きグループ。書かれていなければ唯一のキャプチャを使う。
public let volumeCaptureGroupName = "volume"

public enum RegexMatchResult: Sendable, Equatable {
    case none
    case found(RegexMatch)
    /// 時間の上限に達して打ち切った。**「一致しなかった」とは区別する**——
    /// 呼び出し側はこのパターンを無効化してユーザーへ知らせる責任がある [ER-02]。
    case abandoned
}

public struct RegexMatch: Sendable, Equatable {
    /// 一致した範囲（文字添字）。
    public let range: Range<Int>
    /// 巻数を取り出すグループの範囲（文字添字）。無ければ `nil`。
    public let captureRange: Range<Int>?
}

/// 走査の途中でウォッチドッグに打ち切られたパターンを覚えておく箱。
///
/// 打ち切られたパターンを使い続けると、**1 ファイルごとに時間の上限ぶんだけ待つ**
/// ことになる（5 万ファイルなら 20ms × 5 万 = 17 分）。一度打ち切られたら、その
/// 設定スナップショットが生きている間は二度と試さない。
///
/// 呼び出し側は `abandonedIDs` を見て、理由付きで 1 度だけユーザーへ知らせること [ER-02]。
public final class RegexPatternHealth: @unchecked Sendable {
    private let lock = NSLock()
    private var abandoned: Set<UUID> = []

    public init() {}

    func markAbandoned(_ id: UUID) {
        lock.lock(); defer { lock.unlock() }
        abandoned.insert(id)
    }

    func isAbandoned(_ id: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return abandoned.contains(id)
    }

    /// 打ち切られたパターンの識別子。空なら何も起きていない。
    public var abandonedIDs: Set<UUID> {
        lock.lock(); defer { lock.unlock() }
        return abandoned
    }
}

/// immutable で thread safe だと Apple が明記している型のみを保持する。
public struct SafeRegex: @unchecked Sendable {
    public let source: String
    /// 位置アンカー照合に使う。
    private let regex: NSRegularExpression
    /// 末尾アンカー照合（`matchAtEnd` 相当）に使う `(?:…)\z`。
    private let endAnchored: NSRegularExpression
    /// `(?<volume>…)` が書かれているか。
    public let hasNamedVolumeGroup: Bool
    /// キャプチャグループの数。
    public let captureGroupCount: Int

    public init(_ source: String, caseInsensitive: Bool = false) throws {
        // パターン側も入力と同じ形へ揃える。入力は NFC へ合成した射影に対して
        // 照合するので、NFD で書かれたパターンをそのまま使うと一致しない
        // [FoldedSubject の説明を参照]。**全角は畳まない**——`（仮）` のような
        // 全角括弧を畳むと、リテラルのつもりの括弧が正規表現のグループに化ける。
        let normalized = source.precomposedStringWithCanonicalMapping
        var options: NSRegularExpression.Options = []
        if caseInsensitive { options.insert(.caseInsensitive) }

        self.source = source
        regex = try NSRegularExpression(pattern: normalized, options: options)
        // `(?:` は非キャプチャなのでグループ番号はずれない。
        endAnchored = try NSRegularExpression(pattern: "(?:\(normalized))\\z", options: options)
        captureGroupCount = regex.numberOfCaptureGroups
        // グループ名を列挙する API が無いので綴りで判定する。`(?<=` `(?<!` は
        // 後読みなので除く。
        hasNamedVolumeGroup = normalized.contains("(?<\(volumeCaptureGroupName)>")
    }

    // MARK: - 照合

    /// 指定した文字位置から始まる一致を探す [TY-01][SE-24]。
    public func match(anchoredAt index: Int, in subject: FoldedSubject,
                      budget: TimeInterval) -> RegexMatchResult {
        run(regex, in: subject, range: subject.rangeFromCharacter(index),
            anchored: true, budget: budget)
    }

    /// 文字列の**末尾にちょうど届く**一致を探す [SE-02]。
    ///
    /// 左端一致なので、そのパターンで末尾に届くもののうち最長が得られる。
    public func matchAtEnd(in subject: FoldedSubject, budget: TimeInterval) -> RegexMatchResult {
        run(endAnchored, in: subject, range: subject.rangeFromCharacter(0),
            anchored: false, budget: budget)
    }

    /// 文字列のどこでもよいので最初の一致を探す（保護文字列のマスク用）。
    public func firstMatch(from index: Int, in subject: FoldedSubject,
                           budget: TimeInterval) -> RegexMatchResult {
        run(regex, in: subject, range: subject.rangeFromCharacter(index),
            anchored: false, budget: budget)
    }

    /// 重ならない全ての一致を左から集める（保護文字列のマスク用）。
    ///
    /// 位置ごとにアンカー照合を繰り返すより桁で速い。時間の上限は**列挙全体**に効く。
    public func allMatches(in subject: FoldedSubject,
                           budget: TimeInterval) -> (matches: [RegexMatch], abandoned: Bool) {
        let range = subject.rangeFromCharacter(0)
        guard range.location != NSNotFound else { return ([], false) }

        let started = DispatchTime.now().uptimeNanoseconds
        let limit = UInt64(max(budget, 0) * 1_000_000_000)
        var found: [RegexMatch] = []
        var abandoned = false

        regex.enumerateMatches(in: subject.text, options: [.reportProgress], range: range) { result, flags, stop in
            if flags.contains(.progress) {
                if DispatchTime.now().uptimeNanoseconds &- started > limit {
                    abandoned = true
                    stop.pointee = true
                }
                return
            }
            guard let result, let charRange = subject.characterRange(of: result.range) else { return }
            // 長さ 0 の一致は無視する。`x*` のようなパターンが至る所で空に一致し、
            // マスクが無限に増えるのを防ぐ。
            guard !charRange.isEmpty else { return }
            found.append(RegexMatch(range: charRange,
                                    captureRange: captureRange(of: result, in: subject)))
        }
        return (abandoned ? [] : found, abandoned)
    }

    private func run(_ expression: NSRegularExpression, in subject: FoldedSubject,
                     range: NSRange, anchored: Bool, budget: TimeInterval) -> RegexMatchResult {
        guard range.location != NSNotFound else { return .none }
        var options: NSRegularExpression.MatchingOptions = [.reportProgress]
        if anchored { options.insert(.anchored) }

        // 単調増加する時計を使う。`Date` は時刻の飛びで上限が効かなくなりうる。
        let started = DispatchTime.now().uptimeNanoseconds
        let limit = UInt64(max(budget, 0) * 1_000_000_000)
        var found: NSTextCheckingResult?
        var abandoned = false

        expression.enumerateMatches(in: subject.text, options: options, range: range) { result, flags, stop in
            if flags.contains(.progress) {
                if DispatchTime.now().uptimeNanoseconds &- started > limit {
                    abandoned = true
                    stop.pointee = true
                }
                return
            }
            if let result {
                found = result
                stop.pointee = true
            }
        }

        if abandoned { return .abandoned }
        guard let found, let charRange = subject.characterRange(of: found.range) else { return .none }
        return .found(RegexMatch(range: charRange,
                                 captureRange: captureRange(of: found, in: subject)))
    }

    /// 巻数の値を取り出す範囲。`(?<volume>…)` があればそれ、無ければ第 1 グループ。
    private func captureRange(of result: NSTextCheckingResult,
                              in subject: FoldedSubject) -> Range<Int>? {
        if hasNamedVolumeGroup {
            let named = result.range(withName: volumeCaptureGroupName)
            if named.location != NSNotFound { return subject.characterRange(of: named) }
        }
        guard result.numberOfRanges > 1 else { return nil }
        let first = result.range(at: 1)
        guard first.location != NSNotFound else { return nil }
        return subject.characterRange(of: first)
    }
}
