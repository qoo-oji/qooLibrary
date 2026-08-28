//
//  マッチャ [4.7][TY-03][TY-04][FF-13][MT2-01〜MT2-05]。
//
//  メモ化付きのバックトラッキング。仕様書 §4.7.1 は「前方アンカー → 後方アンカー →
//  中央のバックトラッキング」の 3 段構成を挙げているが、**検証器が「自由文字列
//  フィールドの隣は必ず境界」を保証している** [FF-18][VD-02] ため、素直な再帰でも
//  自由文字列の走査は「次の境界を探す」だけになり、アンカー段を分けなくても
//  探索量は O(ノード数 × 入力長) に収まる。実測（T-05）で目標を満たすことを
//  確認したうえで、段を分けない構成にしている [設計判断]。
//
import Foundation

public enum FormatMatcher {

    /// 1 つのフォーマットを入力全体に照合する。
    public static func match(_ format: CompiledFormat,
                             input: ParseInput,
                             volumePatterns: [CompiledVolumePattern] = [],
                             stepLimit: Int = AppLimits.Format.maxMatchSteps) -> MatchOutcome {
        let ctx = Context(input: input, volumePatterns: volumePatterns,
                          stepLimit: stepLimit)
        let ok = matchAll(format.nodes, 0, input.count, ctx)
        guard ok, !ctx.exceededStepLimit else {
            return MatchOutcome(result: nil, furthestIndex: ctx.furthest,
                                exceededStepLimit: ctx.exceededStepLimit, steps: ctx.steps)
        }
        return MatchOutcome(result: assemble(format, ctx),
                            furthestIndex: ctx.furthest,
                            exceededStepLimit: false, steps: ctx.steps)
    }

    // MARK: - 探索の状態

    final class Context {
        let input: ParseInput
        let volumePatterns: [CompiledVolumePattern]
        let stepLimit: Int

        var steps = 0
        var exceededStepLimit = false
        var furthest = 0
        /// フィールド → マスク後の範囲。出現順を保つため配列で持つ。
        var bindings: [(field: FieldRef, range: Range<Int>, volume: VolumeValue?)] = []

        init(input: ParseInput, volumePatterns: [CompiledVolumePattern],
             stepLimit: Int) {
            self.input = input
            self.volumePatterns = volumePatterns
            self.stepLimit = stepLimit
        }

        @inline(__always) func canonical(_ i: Int) -> Character { input.canonicalChars[i] }
        @inline(__always) func masked(_ i: Int) -> Character { input.maskedChars[i] }
    }

    // MARK: - 照合

    /// `nodes` を `input[lo..<hi]` に**完全一致**させる [MT2-04]。
    static func matchAll(_ nodes: [FormatNode], _ lo: Int, _ hi: Int, _ ctx: Context) -> Bool {
        var memo = Set<Int>()
        return matchSeq(nodes, 0, lo, hi, &memo, ctx)
    }

    static func matchSeq(_ nodes: [FormatNode], _ ni: Int, _ ii: Int, _ hi: Int,
                         _ memo: inout Set<Int>, _ ctx: Context) -> Bool {
        ctx.steps += 1
        if ctx.steps > ctx.stepLimit { ctx.exceededStepLimit = true; return false }
        if ii > ctx.furthest { ctx.furthest = ii }

        if ni == nodes.count { return ii == hi }

        // 失敗した (ノード, 位置) の組を覚えて再探索を避ける [T-05 対策]。
        // 捕捉した値は「その先の照合の可否」に影響しないため、失敗のメモ化は健全。
        let key = ni &* (ctx.input.count &+ 1) &+ ii
        if memo.contains(key) { return false }

        let node = nodes[ni]
        switch node {

        case .literal(let s):
            let lit = Array(s)
            if matchLiteral(lit, at: ii, hi, ctx),
               matchSeq(nodes, ni + 1, ii + lit.count, hi, &memo, ctx) { return true }

        case .whitespace:
            // 0 個以上。貪欲に取ってから減らす [WS-01]。
            var run = 0
            while ii + run < hi, Whitespace.isWhitespace(ctx.masked(ii + run)) { run += 1 }
            var k = run
            while k >= 0 {
                if matchSeq(nodes, ni + 1, ii + k, hi, &memo, ctx) { return true }
                k -= 1
            }

        case .separator(let sep):
            for consumed in separatorConsumptions(sep, at: ii, hi, ctx) {
                if matchSeq(nodes, ni + 1, ii + consumed, hi, &memo, ctx) { return true }
            }

        case .group(let pair, let children):
            if ii < hi, ctx.masked(ii) == pair.open,
               let closeIdx = findMatchingClose(pair, from: ii, hi, ctx) {
                let saved = ctx.bindings.count
                if matchAll(children, ii + 1, closeIdx, ctx),
                   matchSeq(nodes, ni + 1, closeIdx + 1, hi, &memo, ctx) { return true }
                ctx.bindings.removeLast(ctx.bindings.count - saved)
            }

        case .field(let ref, .volume):
            // 型付き照合: 巻数フォーマットにマッチする候補を長い順に試す [TY-01][SE-24]。
            for candidate in VolumeMatcher.matches(in: ctx.input.folded, at: ii,
                                                   patterns: ctx.volumePatterns)
            where candidate.range.upperBound <= hi {
                ctx.bindings.append((ref, candidate.range, candidate.value))
                if matchSeq(nodes, ni + 1, candidate.range.upperBound, hi, &memo, ctx) { return true }
                ctx.bindings.removeLast()
            }

        case .field(let ref, .enumerated(let values)):
            for value in values.sorted(by: { ($0.count, $0) > ($1.count, $1) }) {
                let cand = Array(value).map {
                    CharacterCanonicalization.canonical($0)
                }
                guard matchLiteral(cand, at: ii, hi, ctx) else { continue }
                ctx.bindings.append((ref, ii..<(ii + cand.count), nil))
                if matchSeq(nodes, ni + 1, ii + cand.count, hi, &memo, ctx) { return true }
                ctx.bindings.removeLast()
            }

        case .field(let ref, .free):
            // 非貪欲: 短い方から伸ばす [FF-13]。
            // 空マッチは許さない（`@ignore` のみ許す）。加えて、空白だけの捕捉も
            // 許さない——トリム後に空になり、意味のないラベルを作るため [WS-05]。
            let allowsEmpty = ref.allowsDuplicates      // `.ignore` のみ true
            var sawNonSpace = false
            var len = 0
            if allowsEmpty, matchSeq(nodes, ni + 1, ii, hi, &memo, ctx) { return true }
            while ii + len < hi {
                if !Whitespace.isWhitespace(ctx.masked(ii + len)) { sawNonSpace = true }
                len += 1
                guard sawNonSpace || allowsEmpty else { continue }
                ctx.bindings.append((ref, ii..<(ii + len), nil))
                if matchSeq(nodes, ni + 1, ii + len, hi, &memo, ctx) { return true }
                ctx.bindings.removeLast()
            }
        }

        memo.insert(key)
        return false
    }

    // MARK: - 部品

    /// リテラル比較は正準形どうしで行う [MT2-05][N-02][N-04]。
    /// `lit` は**コンパイル済みフォーマット側の正準形**であることを前提とする。
    static func matchLiteral(_ lit: [Character], at i: Int, _ hi: Int, _ ctx: Context) -> Bool {
        guard i + lit.count <= hi else { return false }
        for k in 0..<lit.count where ctx.canonical(i + k) != lit[k] { return false }
        return true
    }

    /// セパレータ型は `elastic空白 + variant + elastic空白` を 1 トークンとして消費する
    /// [DL-14][DLI-03]。末尾の空白は 0 個以上なので、長い順に候補を返す。
    static func separatorConsumptions(_ sep: SeparatorDelimiter, at i: Int,
                                      _ hi: Int, _ ctx: Context) -> [Int] {
        var lead = 0
        while i + lead < hi, Whitespace.isWhitespace(ctx.masked(i + lead)) { lead += 1 }

        for variant in sep.variantsByLengthDesc {
            let v = Array(variant).map {
                CharacterCanonicalization.canonical($0)
            }
            guard matchLiteral(v, at: i + lead, hi, ctx) else { continue }
            var trail = 0
            let afterVariant = i + lead + v.count
            while afterVariant + trail < hi, Whitespace.isWhitespace(ctx.masked(afterVariant + trail)) {
                trail += 1
            }
            let base = lead + v.count
            return (0...trail).reversed().map { base + $0 }
        }
        return []
    }

    /// ネストを数えて対応する閉じ括弧を探す [FF-11]。
    ///
    /// 実データには**閉じ括弧が欠けたファイル名が実在する**（実コーパス 2,953 件で
    /// `(` 5,953 対 `)` 5,950）。見つからなければ `nil` を返し、照合の失敗として
    /// 扱う——例外を投げてはならない。
    static func findMatchingClose(_ pair: PairDelimiter, from open: Int,
                                  _ hi: Int, _ ctx: Context) -> Int? {
        var depth = 0
        var i = open
        while i < hi {
            let c = ctx.masked(i)
            if c == pair.open { depth += 1 }
            else if c == pair.close {
                depth -= 1
                if depth == 0 { return i }
            }
            i += 1
        }
        return nil
    }

    // MARK: - 結果の組み立て

    static func assemble(_ format: CompiledFormat, _ ctx: Context) -> ParseResult {
        var fields: [FieldRef: FieldValue] = [:]
        var spans: [FieldSpan] = []
        for binding in ctx.bindings {
            // 原文へ写す（保護文字列はここで復元される）[PT-03][PTI-02]
            let originalRange = ctx.input.originalRange(of: binding.range)
            let raw = String(ctx.input.originalChars[originalRange])
            let trimmed = TextNormalizer.trimWhitespace(raw)
            fields[binding.field] = FieldValue(
                text: trimmed,
                normalized: TextNormalizer.normalize(trimmed),
                volume: binding.volume)
            spans.append(FieldSpan(field: binding.field, range: originalRange))
        }
        return ParseResult(matchedFormatID: format.id, fields: fields, spans: spans)
    }
}
