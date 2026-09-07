//
//  T-10 「両端アンカー方式の曖昧性の洗い出し」の掃引 [16章 §16.5][17章 DoD]。
//
//  **通常のテスト実行では何もしない。** `QOO_AMBIGUITY_SWEEP=1` を渡したときだけ
//  走り、標準エラーへ報告を書く。ここは「洗い出す道具」であって、洗い出した結果を
//  固定するのは `AmbiguityRegressionTests`（永続的なテスト）の役目。
//
//  ## なぜ列挙器を書くのか
//
//  曖昧性とは「同じ入力に複数の解釈がある」こと。本番の `FormatMatcher.match` は
//  **最初の解で止まる**ので、解が 2 つ以上あるかどうかを答えられない。有界の
//  全数列挙（AMBER 方式）で数える。
//
//  ## 乖離の自動検出
//
//  列挙器は本番の探索順を写したものなので、**第 1 解は本番の答えと一致するはず**
//  ——メモ化は失敗しかキャッシュしないため、本番の答えは「探索順で最初の解」に
//  等しい。掃引は全件でこれを突き合わせ、食い違ったら `divergence` として報告する。
//  写し間違いも、本番側の取りこぼしも、同じ網に掛かる。
//
import Foundation
import Testing
@testable import QooKit

// MARK: - 全解列挙器

/// 1 つのフォーマットについて、入力全体を満たす**すべての解釈**を探索順に返す。
enum ParseEnumerator {

    struct Binding {
        let field: FieldRef
        let range: Range<Int>
        let volume: VolumeValue?
    }

    struct Outcome {
        /// 探索順に並んだ解。フィールド値が同じものは畳んである。
        var solutions: [ParseResult]
        /// 上限に当たって打ち切ったか。打ち切ったら「解の数」は下限でしかない。
        var truncated: Bool
    }

    final class Budget {
        var steps = 0
        let stepLimit: Int
        var exhausted: Bool { steps > stepLimit }
        init(stepLimit: Int) { self.stepLimit = stepLimit }
    }

    static func enumerate(_ format: CompiledFormat,
                          input: ParseInput,
                          volumePatterns: [CompiledVolumePattern],
                          stepLimit: Int = 2_000_000,
                          solutionLimit: Int = 5_000) -> Outcome {
        let budget = Budget(stepLimit: stepLimit)
        let raw = solutions(format.nodes, 0, 0, input.count,
                            input, volumePatterns, budget, solutionLimit)
        // 束縛の並びを結果へ組み立て、フィールド値が同じものは畳む。
        // （空白の取り方だけが違う導出は、利用者から見れば同じ解釈である。）
        var seen = Set<String>()
        var out: [ParseResult] = []
        for bindings in raw {
            let result = assemble(format, bindings, input)
            let key = result.fields
                .map { FormatCompileError.label($0.key) + "=" + $0.value.text }
                .sorted().joined(separator: "\u{1F}")
            if seen.insert(key).inserted { out.append(result) }
        }
        // **`truncated` は「導出が上限に当たった」という意味**。相異なる解の数は
        // そのとき下限でしかない——数えたつもりで取りこぼす形を残さないため、
        // 上限に当たったこと自体を報告へ出す。
        return Outcome(solutions: out, truncated: budget.exhausted || raw.count >= solutionLimit)
    }

    /// `nodes[ni...]` を `input[ii..<hi]` へ**完全一致**させる方法をすべて返す。
    ///
    /// 分岐の試行順は `FormatMatcher.matchSeq` と 1 対 1 に対応させてある——
    /// ここが崩れると「第 1 解＝本番の答え」という不変条件が壊れ、掃引が嘘をつく。
    private static func solutions(_ nodes: [FormatNode], _ ni: Int, _ ii: Int, _ hi: Int,
                                  _ input: ParseInput,
                                  _ patterns: [CompiledVolumePattern],
                                  _ budget: Budget,
                                  _ limit: Int) -> [[Binding]] {
        budget.steps += 1
        if budget.exhausted { return [] }

        if ni == nodes.count { return ii == hi ? [[]] : [] }

        func canonical(_ i: Int) -> Character { input.canonicalChars[i] }
        func masked(_ i: Int) -> Character { input.maskedChars[i] }

        func rest(_ nextII: Int, prefix: [Binding]) -> [[Binding]] {
            solutions(nodes, ni + 1, nextII, hi, input, patterns, budget, limit)
                .map { prefix + $0 }
        }

        var out: [[Binding]] = []
        let node = nodes[ni]
        switch node {

        case .literal(let s):
            let lit = Array(s)
            if matchLiteral(lit, at: ii, hi, input) {
                out += rest(ii + lit.count, prefix: [])
            }

        case .whitespace:
            var run = 0
            while ii + run < hi, Whitespace.isWhitespace(masked(ii + run)) { run += 1 }
            var k = run
            while k >= 0, out.count < limit {
                out += rest(ii + k, prefix: [])
                k -= 1
            }

        case .separator(let sep):
            for consumed in FormatMatcher.separatorConsumptions(
                sep, at: ii, hi, contextFor(input, patterns)) where out.count < limit {
                out += rest(ii + consumed, prefix: [])
            }

        case .group(let pair, let children):
            if ii < hi, masked(ii) == pair.open,
               let closeIdx = FormatMatcher.findMatchingClose(
                    pair, from: ii, hi, contextFor(input, patterns)) {
                // **本番は内部の第 1 解しか使わない**（後続が失敗しても選び直さない）。
                // 列挙器は全部試す——その差そのものが T-10 の観測対象なので、
                // 「本番が見つけられない解」を出したら掃引が divergence として報告する。
                let interiors = solutions(children, 0, ii + 1, closeIdx,
                                          input, patterns, budget, limit)
                for interior in interiors where out.count < limit {
                    out += rest(closeIdx + 1, prefix: interior)
                }
            }

        case .field(let ref, .volume):
            for candidate in VolumeMatcher.matches(in: input.folded, at: ii, patterns: patterns)
            where candidate.range.upperBound <= hi && out.count < limit {
                out += rest(candidate.range.upperBound,
                            prefix: [Binding(field: ref, range: candidate.range,
                                             volume: candidate.value)])
            }

        case .field(let ref, .enumerated(let values)):
            for value in values.sorted(by: { ($0.count, $0) > ($1.count, $1) })
            where out.count < limit {
                let cand = Array(value).map { CharacterCanonicalization.canonical($0) }
                guard matchLiteral(cand, at: ii, hi, input) else { continue }
                out += rest(ii + cand.count,
                            prefix: [Binding(field: ref, range: ii..<(ii + cand.count),
                                             volume: nil)])
            }

        case .field(let ref, .free):
            let allowsEmpty = ref.allowsDuplicates
            var sawNonSpace = false
            var len = 0
            if allowsEmpty { out += rest(ii, prefix: []) }
            while ii + len < hi, out.count < limit {
                if !Whitespace.isWhitespace(masked(ii + len)) { sawNonSpace = true }
                len += 1
                guard sawNonSpace || allowsEmpty else { continue }
                out += rest(ii + len,
                            prefix: [Binding(field: ref, range: ii..<(ii + len), volume: nil)])
            }
        }
        _ = canonical
        return out
    }

    private static func matchLiteral(_ lit: [Character], at i: Int, _ hi: Int,
                                     _ input: ParseInput) -> Bool {
        guard i + lit.count <= hi else { return false }
        for k in 0..<lit.count where input.canonicalChars[i + k] != lit[k] { return false }
        return true
    }

    private static func contextFor(_ input: ParseInput,
                                   _ patterns: [CompiledVolumePattern]) -> FormatMatcher.Context {
        FormatMatcher.Context(input: input, volumePatterns: patterns, stepLimit: .max)
    }

    private static func assemble(_ format: CompiledFormat, _ bindings: [Binding],
                                 _ input: ParseInput) -> ParseResult {
        var fields: [FieldRef: FieldValue] = [:]
        var spans: [FieldSpan] = []
        for binding in bindings {
            let originalRange = input.originalRange(of: binding.range)
            let raw = String(input.originalChars[originalRange])
            let trimmed = TextNormalizer.trimWhitespace(raw)
            fields[binding.field] = FieldValue(text: trimmed,
                                               normalized: TextNormalizer.normalize(trimmed),
                                               volume: binding.volume)
            spans.append(FieldSpan(field: binding.field, range: originalRange))
        }
        return ParseResult(matchedFormatID: format.id, fields: fields, spans: spans)
    }
}

// MARK: - 掃引

/// 敵対的な値の族。**ゴールデンの生成器が意図的に除外している性質**を、
/// 1 つずつ自由文字列フィールドへ差し込む [C1〜C7]。
enum Adversary: String, CaseIterable {
    case baseline      = "基準（区切りを含まない）"
    case separator     = "区切り文字を含む"
    case pairInside    = "括弧の対を含む"
    case unbalanced    = "開き括弧だけを含む"
    case closeOnly     = "閉じ括弧だけを含む"
    case volumeLike    = "巻数に見える語を含む"
    case bookTypeLike  = "列挙値そのもの"
    case doubledSpace  = "空白が連続する"
    /// 既定の保護文字列に当たる形 [PT-01]。`(仮)` と違い**守られるはず**——
    /// この 2 つの対比が、保護文字列が曖昧性の逃げ道として効いていることの実証になる。
    case protectedPair = "保護文字列の対を含む"

    func value(base: String, bookType: String) -> String {
        switch self {
        case .baseline:     return base
        case .separator:    return "\(base) - 続編"
        case .pairInside:   return "\(base) (仮)"
        case .unbalanced:   return "\(base) (未完"
        case .closeOnly:    return "\(base)) 続き"
        case .volumeLike:   return "\(base) 第02巻"
        case .bookTypeLike: return bookType
        case .doubledSpace: return "\(base)  空白"
        case .protectedPair: return "\(base) (完全版)"
        }
    }
}

/// 1 件の入力についての観測。
struct SweepObservation {
    let preset: String
    let formatIndex: Int
    let formatSource: String
    let adversary: Adversary
    let targetField: String?
    let input: String
    /// 本番が選んだフォーマットの添字（`nil` なら不一致）。
    let chosenFormat: Int?
    /// 本番が返したフィールド値。
    let chosenFields: [String: String]
    /// 差し込んだ値（意図した解釈）。
    let intended: [String: String]
    /// このフォーマット単体で数えた解の数。
    let solutionCount: Int
    let solutionsTruncated: Bool
    /// 入力に一致したフォーマットの本数（`parseAll`）。
    let matchingFormats: Int
    /// 列挙器の第 1 解と本番の答えが食い違ったか。
    let divergence: String?
}

enum AmbiguitySweep {

    static func run() throws -> [SweepObservation] {
        let volumeSets = try BuiltInTemplates.volumeSets()
        let presets = try BuiltInTemplates.libraryTypes()
        let typeNames = Array(Set(presets.map(\.libraryTypeName))).sorted()
        let parser = FilenameParser()
        var out: [SweepObservation] = []

        for preset in presets {
            let settings = try TemplateInstantiation.snapshot(
                from: preset, volumeSets: volumeSets, libraryID: LibraryID(rawValue: 1),
                bookTypeVocabulary: typeNames)

            for (index, compiled) in settings.filenameFormats.enumerated() {
                let source = preset.filenameFormats[index]
                let freeFields = compiled.fieldOrder.filter { ref in
                    compiled.nodes.contains { hasFreeField($0, ref) }
                }

                // 基準 1 件 ＋ 自由文字列フィールドごとに敵対的な値を 1 つずつ。
                var plans: [(Adversary, FieldRef?)] = [(.baseline, nil)]
                for ref in freeFields {
                    for adversary in Adversary.allCases where adversary != .baseline {
                        plans.append((adversary, ref))
                    }
                }

                for (adversary, target) in plans {
                    let intendedValues = values(for: compiled, preset: preset,
                                                adversary: adversary, target: target)
                    let input: String
                    do {
                        input = try GoldenGenerator.synthesize(
                            format: source, delimiters: settings.delimiters,
                            value: { intendedValues[$0] ?? "値" })
                    } catch { continue }

                    let all = parser.parseAll(input, settings: settings)
                    let chosen = parser.parse(input, settings: settings)
                    let chosenIndex = chosen.flatMap { r in
                        settings.filenameFormats.firstIndex { $0.id == r.matchedFormatID }
                    }

                    let parseInput = makeInput(input, settings: settings)
                    let outcome = ParseEnumerator.enumerate(
                        compiled, input: parseInput, volumePatterns: settings.volumeFormats)

                    // このフォーマット単体での本番の答えと、列挙器の第 1 解を突き合わせる。
                    let single = FormatMatcher.match(compiled, input: parseInput,
                                                     volumePatterns: settings.volumeFormats).result
                    let divergence = compare(production: single, enumerated: outcome.solutions.first)

                    out.append(SweepObservation(
                        preset: preset.displayName,
                        formatIndex: index,
                        formatSource: source,
                        adversary: adversary,
                        targetField: target.map { FormatCompileError.label($0) },
                        input: input,
                        chosenFormat: chosenIndex,
                        chosenFields: fieldMap(chosen),
                        intended: Dictionary(uniqueKeysWithValues: intendedValues.map {
                            (FormatCompileError.label($0.key),
                             TextNormalizer.trimWhitespace($0.value))
                        }),
                        solutionCount: outcome.solutions.count,
                        solutionsTruncated: outcome.truncated,
                        matchingFormats: all.count,
                        divergence: divergence))
                }
            }
        }
        return out
    }

    /// プリセットに**存在しない形**を補う。利用者は任意のフォーマットを書けるので、
    /// プリセットの 27 種だけを掃いても掃引にならない——区切りで自由文字列を挟む形
    /// [A3]、`@volume` を境界に使う形 [A4]、同じ括弧の入れ子 [A6]、空を許す `@ignore` は
    /// プリセットに 1 つも無い。
    static let syntheticShapes: [String] = [
        "@series - @title",
        "@title - @author - @keyword",
        "@series @volume",
        "@title @volume [@keyword]",
        "[@circle] @title @volume",
        "@ignore - @title",
        "[@circle [@author]] @title",
        "(@booktype) @title",
        "@title (@genre) (@keyword)",
        "[@circle] - @title",
        "@title _ @author",
        "[@circle] @title (@genre)",
    ]

    static func runSynthetic() throws -> [SweepObservation] {
        let volumeSets = try BuiltInTemplates.volumeSets()
        let presets = try BuiltInTemplates.libraryTypes()
        let typeNames = Array(Set(presets.map(\.libraryTypeName))).sorted()
        // 巻数パターンは一番豊富なセットを使う（`@volume` の候補が複数出る条件）。
        let richest = volumeSets.sets.max { $0.value.count < $1.value.count }?.key
        let patterns = richest.flatMap { volumeSets.patterns(named: $0) } ?? []
        let compiledPatterns = VolumePatternCompiler.compileAll(patterns)
        let context = FormatCompilationContext(delimiters: .default, maxFields: 10,
                                               bookTypeVocabulary: typeNames,
                                               semanticBindings: [:])
        guard let preset = presets.first else { return [] }
        var out: [SweepObservation] = []

        for (index, source) in syntheticShapes.enumerated() {
            let compiled: CompiledFormat
            do { compiled = try FormatCompiler.compile(source, context: context) }
            catch {
                FileHandle.standardError.write(Data("[sweep] 合成形が通らない: \(source) — \(error)\n".utf8))
                continue
            }
            let freeFields = compiled.fieldOrder.filter { ref in
                compiled.nodes.contains { hasFreeField($0, ref) }
            }
            var plans: [(Adversary, FieldRef?)] = [(.baseline, nil)]
            for ref in freeFields {
                for adversary in Adversary.allCases where adversary != .baseline {
                    plans.append((adversary, ref))
                }
            }
            for (adversary, target) in plans {
                let intendedValues = values(for: compiled, preset: preset,
                                            adversary: adversary, target: target)
                let input: String
                do {
                    input = try GoldenGenerator.synthesize(
                        format: source, delimiters: .default,
                        value: { intendedValues[$0] ?? "値" })
                } catch { continue }

                let parseInput = ParseInput(input)
                let outcome = ParseEnumerator.enumerate(compiled, input: parseInput,
                                                        volumePatterns: compiledPatterns)
                let production = FormatMatcher.match(compiled, input: parseInput,
                                                     volumePatterns: compiledPatterns).result
                out.append(SweepObservation(
                    preset: "合成",
                    formatIndex: index,
                    formatSource: source,
                    adversary: adversary,
                    targetField: target.map { FormatCompileError.label($0) },
                    input: input,
                    chosenFormat: production == nil ? nil : index,
                    chosenFields: fieldMap(production),
                    intended: Dictionary(uniqueKeysWithValues: intendedValues.map {
                        (FormatCompileError.label($0.key), TextNormalizer.trimWhitespace($0.value))
                    }),
                    solutionCount: outcome.solutions.count,
                    solutionsTruncated: outcome.truncated,
                    matchingFormats: production == nil ? 0 : 1,
                    divergence: compare(production: production,
                                        enumerated: outcome.solutions.first)))
            }
        }
        return out
    }

    // MARK: - 部品

    static func hasFreeField(_ node: FormatNode, _ ref: FieldRef) -> Bool {
        switch node {
        case .field(let r, .free): return r == ref
        case .group(_, let children): return children.contains { hasFreeField($0, ref) }
        default: return false
        }
    }

    static func values(for format: CompiledFormat, preset: LibraryTypeTemplate,
                       adversary: Adversary, target: FieldRef?) -> [FieldRef: String] {
        var out: [FieldRef: String] = [:]
        for ref in format.fieldOrder {
            let base = baseValue(ref, preset: preset)
            if ref == target {
                out[ref] = adversary.value(base: base, bookType: preset.libraryTypeName)
            } else {
                out[ref] = base
            }
        }
        return out
    }

    /// 基準の値。**フィールドごとに違う文字列**にして、取り違えを見分けられるようにする。
    static func baseValue(_ ref: FieldRef, preset: LibraryTypeTemplate) -> String {
        switch ref {
        case .title:    return "題名"
        case .series:   return "叢書"
        case .author:   return "著者"
        case .circle:   return "集団"
        case .event:    return "催事"
        case .genre:    return "分野"
        case .keyword:  return "鍵語"
        case .bookType: return preset.libraryTypeName
        case .volume:   return "01"
        case .ignore:   return "無視"
        }
    }

    static func fieldMap(_ result: ParseResult?) -> [String: String] {
        guard let result else { return [:] }
        return Dictionary(uniqueKeysWithValues: result.fields.map {
            (FormatCompileError.label($0.key), $0.value.text)
        })
    }

    static func makeInput(_ name: String, settings: LibrarySettingsSnapshot) -> ParseInput {
        settings.protectedTokens.isEmpty
            ? ParseInput(name)
            : ProtectedTokenMasker.mask(name, tokens: settings.protectedTokens)
    }

    static func compare(production: ParseResult?, enumerated: ParseResult?) -> String? {
        switch (production, enumerated) {
        case (nil, nil): return nil
        case (nil, .some): return "本番は不一致だが列挙器は解を見つけた"
        case (.some, nil): return "本番は一致したが列挙器は解を見つけられなかった"
        case (.some(let p), .some(let e)):
            let a = fieldMap(p).sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
            let b = fieldMap(e).sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
            return a == b ? nil : "第 1 解が食い違う: 本番 \(a) / 列挙 \(b)"
        }
    }
}

@Suite("T-10 曖昧性の掃引（QOO_AMBIGUITY_SWEEP=1 のときだけ走る）")
struct AmbiguitySweepTests {
    @Test("掃引して報告を書く")
    func sweep() throws {
        guard ProcessInfo.processInfo.environment["QOO_AMBIGUITY_SWEEP"] == "1" else { return }
        let observations = try AmbiguitySweep.run() + AmbiguitySweep.runSynthetic()

        var lines: [String] = []
        func emit(_ s: String) { lines.append(s) }

        emit("# T-10 曖昧性の掃引")
        emit("観測 \(observations.count) 件")
        emit("")

        // 乖離（列挙器 vs 本番）
        let divergent = observations.filter { $0.divergence != nil }
        emit("## 乖離: \(divergent.count) 件")
        for o in divergent.prefix(40) {
            emit("- [\(o.preset) #\(o.formatIndex) \(o.adversary.rawValue)] \(o.input)")
            emit("    \(o.divergence!)")
            emit("    format: \(o.formatSource)")
        }
        emit("")

        // S3: 同一フォーマット内で解が複数
        let multi = observations.filter { $0.solutionCount > 1 }
        emit("## 同一フォーマット内で解が複数: \(multi.count) 件")
        var byShape: [String: Int] = [:]
        for o in multi { byShape["\(o.preset) #\(o.formatIndex) \(o.adversary.rawValue)", default: 0] += 1 }
        for (k, v) in byShape.sorted(by: { $0.value > $1.value }).prefix(30) {
            emit("- \(v) 件: \(k)")
        }
        emit("")

        // S1: フォーマット間の重複一致
        let crossed = observations.filter { $0.matchingFormats > 1 }
        emit("## 複数のフォーマットが一致: \(crossed.count) 件")
        var byPreset: [String: Int] = [:]
        for o in crossed { byPreset[o.preset, default: 0] += 1 }
        for (k, v) in byPreset.sorted(by: { $0.value > $1.value }) { emit("- \(k): \(v) 件") }
        emit("")

        // S2: 差し込んだ値と出力の食い違い
        let wrong = observations.filter { o in
            guard o.chosenFormat != nil else { return false }
            return o.intended.contains { key, want in (o.chosenFields[key] ?? "") != want }
        }
        emit("## 差し込んだ値と出力が食い違う: \(wrong.count) 件")
        var byAdversary: [String: Int] = [:]
        for o in wrong { byAdversary[o.adversary.rawValue, default: 0] += 1 }
        for (k, v) in byAdversary.sorted(by: { $0.value > $1.value }) { emit("- \(k): \(v) 件") }
        emit("")
        for o in wrong.prefix(60) {
            emit("- [\(o.preset) #\(o.formatIndex) \(o.adversary.rawValue) → \(o.targetField ?? "-")]")
            emit("    入力  : \(o.input)")
            emit("    形式  : \(o.formatSource)  → 選ばれた形式 #\(o.chosenFormat.map(String.init) ?? "なし")")
            let diffs = o.intended.filter { (o.chosenFields[$0.key] ?? "") != $0.value }
                .sorted { $0.key < $1.key }
            for (k, want) in diffs {
                emit("    \(k): 意図「\(want)」 実際「\(o.chosenFields[k] ?? "（なし）")」")
            }
        }
        emit("")

        // 生成元と違うフォーマットが選ばれた件数（A7 の判定材料）
        let presetOnly = observations.filter { $0.preset != "合成" }
        let switched = presetOnly.filter { $0.chosenFormat != nil && $0.chosenFormat != $0.formatIndex }
        let switchedBaseline = switched.filter { $0.adversary == .baseline }
        emit("## 生成元と違うフォーマットが選ばれた: \(switched.count) 件"
             + "（うち基準値 \(switchedBaseline.count) 件）")
        var switchByAdv: [String: Int] = [:]
        for o in switched { switchByAdv[o.adversary.rawValue, default: 0] += 1 }
        for (k, v) in switchByAdv.sorted(by: { $0.value > $1.value }) { emit("- \(k): \(v) 件") }
        for o in switchedBaseline.prefix(20) {
            emit("- [基準] \(o.preset) #\(o.formatIndex) → #\(o.chosenFormat!)")
            emit("    入力: \(o.input)")
            emit("    生成: \(o.formatSource)")
        }
        emit("")

        // 基準値で意図どおりに読めた割合（対照）
        let baseline = presetOnly.filter { $0.adversary == .baseline }
        let baselineOK = baseline.filter { o in
            o.chosenFormat != nil && !o.intended.contains { (o.chosenFields[$0.key] ?? "") != $0.value }
        }
        emit("## 対照: 基準値 \(baseline.count) 件のうち意図どおり \(baselineOK.count) 件")
        emit("")

        // 合成形（プリセットに無い形）の詳細
        emit("## 合成形の詳細")
        for o in observations where o.preset == "合成" {
            let mismatched = o.intended.filter { (o.chosenFields[$0.key] ?? "") != $0.value }
            guard o.solutionCount != 1 || !mismatched.isEmpty || o.divergence != nil else { continue }
            emit("- #\(o.formatIndex) \(o.formatSource)  [\(o.adversary.rawValue) → \(o.targetField ?? "-")]")
            emit("    入力: \(o.input)")
            emit("    解の数: \(o.solutionCount)\(o.solutionsTruncated ? "（打ち切り）" : "")")
            for (k, want) in mismatched.sorted(by: { $0.key < $1.key }) {
                emit("    \(k): 意図「\(want)」 実際「\(o.chosenFields[k] ?? "（なし）")」")
            }
            if let d = o.divergence { emit("    乖離: \(d)") }
        }
        emit("")

        // 一致しなかったもの
        let unmatched = observations.filter { $0.chosenFormat == nil }
        emit("## どのフォーマットにも一致しない: \(unmatched.count) 件")
        var byAdv2: [String: Int] = [:]
        for o in unmatched { byAdv2[o.adversary.rawValue, default: 0] += 1 }
        for (k, v) in byAdv2.sorted(by: { $0.value > $1.value }) { emit("- \(k): \(v) 件") }

        let text = lines.joined(separator: "\n") + "\n"
        let path = ProcessInfo.processInfo.environment["QOO_AMBIGUITY_REPORT"]
            ?? NSTemporaryDirectory() + "ambiguity-report.txt"
        try text.write(toFile: path, atomically: true, encoding: .utf8)
        FileHandle.standardError.write(Data("[sweep] 報告: \(path)\n".utf8))
    }
}

// MARK: - 列挙器そのものの検証

//  掃引が「解は 1 つだけ」と報告し続けるとき、それが**構造的に一意だから**なのか
//  **列挙器が壊れているから**なのかは、報告からは区別できない。確実に曖昧な形を
//  1 つ用意して、多重解を数えられることを実証しておく [空振りの検証]。

@Suite("T-10 列挙器の検証")
struct AmbiguityEnumeratorTests {

    private func context(semantic: [SemanticKeyword: Int] = [:]) -> FormatCompilationContext {
        FormatCompilationContext(delimiters: .default, maxFields: 10,
                                 bookTypeVocabulary: [], semanticBindings: semantic)
    }

    @Test("区切りで挟んだ自由文字列は多重解になり、列挙器はそれを数える")
    func separatorBoundedFreeFieldsAreAmbiguous() throws {
        let format = try FormatCompiler.compile("@series - @title", context: context())
        let input = ParseInput("作品 - 続編 - 著者")

        let outcome = ParseEnumerator.enumerate(format, input: input, volumePatterns: [])
        // 「作品 / 続編 - 著者」と「作品 - 続編 / 著者」の 2 通り。
        #expect(outcome.solutions.count == 2)

        let series = outcome.solutions.map { $0.fields[.series]?.text }
        #expect(series == ["作品", "作品 - 続編"])
    }

    @Test("本番は非貪欲なので、多重解のうち最初のものを選ぶ [FF-13]")
    func productionPicksTheShortestFreeField() throws {
        let format = try FormatCompiler.compile("@series - @title", context: context())
        let input = ParseInput("作品 - 続編 - 著者")

        let result = FormatMatcher.match(format, input: input, volumePatterns: []).result
        #expect(result?.fields[.series]?.text == "作品")
        #expect(result?.fields[.title]?.text == "続編 - 著者")
    }

    @Test("列挙器の第 1 解は本番の答えと一致する（掃引の不変条件）")
    func firstSolutionEqualsProduction() throws {
        let format = try FormatCompiler.compile("@series - @title", context: context())
        for text in ["作品 - 続編 - 著者", "作品 - 続編", "作品", "- 続編", "作品 -"] {
            let input = ParseInput(text)
            let production = FormatMatcher.match(format, input: input, volumePatterns: []).result
            let first = ParseEnumerator.enumerate(format, input: input, volumePatterns: []).solutions.first
            #expect(AmbiguitySweep.compare(production: production, enumerated: first) == nil,
                    "\(text) で第 1 解が食い違った")
        }
    }
}
