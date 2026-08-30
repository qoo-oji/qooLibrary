//
//  構文解析と検証 [4.4][4.5][FF-15〜FF-19][TY-05][VD-01〜VD-04]。
//
import Foundation

/// コンパイルに必要な設定だけを切り出したもの。
///
/// `LibrarySettingsSnapshot` は `CompiledFormat` を**含む**ため、そのまま
/// コンパイルの入力にすると循環する。ここには「フォーマットを構文木へ落とすのに
/// 要るもの」だけを置く。
public struct FormatCompilationContext: Sendable {
    public var delimiters: DelimiterSet
    public var maxLabelGroups: Int
    /// `@booktype` の照合候補 [TY-01][9.2.2]。
    public var allLibraryTypeNames: [String]
    /// セマンティック予約語 → フィールド番号 [RW-13]。
    ///
    /// 仕様書 03章はここを `UUID` としていたが、`QooKit` は DB の識別子を
    /// 知らない [A-01]。番号（`labelGroup.groupIndex`）はライブラリ内で一意なので
    /// 同じ役割を果たす。[設計判断]
    public var semanticBindings: [SemanticKeyword: Int]

    public init(delimiters: DelimiterSet = .default,
                maxLabelGroups: Int = AppLimits.Format.maxLabelGroups,
                allLibraryTypeNames: [String] = [],
                semanticBindings: [SemanticKeyword: Int] = [:]) {
        self.delimiters = delimiters
        self.maxLabelGroups = maxLabelGroups
        self.allLibraryTypeNames = allLibraryTypeNames
        self.semanticBindings = semanticBindings
    }
}

public enum FormatCompiler {

    /// フォーマット文字列を検証済みの `CompiledFormat` にする。
    ///
    /// 保存時に空白を正規化してから解析する [WS-03][WS-04]。テンプレート JSON に
    /// 全角スペースが混入していても実害が無いのはこのため [WSI-02]。
    public static func compile(_ source: String,
                               context: FormatCompilationContext,
                               id: UUID = UUID(),
                               isEnabled: Bool = true,
                               priority: Int = 0) throws(FormatCompileError) -> CompiledFormat {
        let normalizedSource = Whitespace.normalizeLiteral(source)
        guard !TextNormalizer.trimWhitespace(normalizedSource).isEmpty else {
            throw FormatCompileError.emptyFormat
        }

        let tokens = try FormatLexer.lex(normalizedSource, delimiters: context.delimiters)
        var nodes = try parse(tokens)
        nodes = assignIgnoreNumbers(nodes)
        nodes = resolveFieldKinds(nodes, context: context)
        try validate(nodes, context: context)
        nodes = canonicalizeLiterals(nodes)

        let order = nodes.flatMap { $0.fieldsInOrder() }
        return CompiledFormat(id: id, source: normalizedSource, nodes: nodes,
                              isEnabled: isEnabled, priority: priority,
                              usedFields: Set(order), fieldOrder: order)
    }

    // MARK: - 構文解析

    /// 字句列を構文木へ。ペア型はネストできる [FF-11][DL-12]。
    static func parse(_ tokens: [FormatToken]) throws(FormatCompileError) -> [FormatNode] {
        /// (開いた区切り, その開き位置, ここまでに積んだ子)
        var stack: [(pair: PairDelimiter, at: Int, children: [FormatNode])] = []
        var top: [FormatNode] = []

        func append(_ node: FormatNode) {
            if stack.isEmpty { top.append(node) } else { stack[stack.count - 1].children.append(node) }
        }

        for token in tokens {
            switch token {
            case .literal(let s, _):            append(.literal(s))
            case .whitespace:                   append(.whitespace)
            case .separator(let sep, _):        append(.separator(sep))
            case .reservedWord(let field, _):   append(.field(field, kind: .free))
            case .pairOpen(let pair, let at):
                stack.append((pair, at, []))
            case .pairClose(let pair, let at):
                guard let opened = stack.last else {
                    throw FormatCompileError.unbalancedDelimiter(at: at)
                }
                // 別の種類の括弧で閉じようとしている（`[…)` 等）
                guard opened.pair.id == pair.id else {
                    throw FormatCompileError.unbalancedDelimiter(at: at)
                }
                stack.removeLast()
                append(.group(pair, children: opened.children))
            }
        }
        if let unclosed = stack.last {
            throw FormatCompileError.unbalancedDelimiter(at: unclosed.at)
        }
        return top
    }

    /// `@ignore` に出現順の連番を振る [LX-03][RW-03]。
    static func assignIgnoreNumbers(_ nodes: [FormatNode]) -> [FormatNode] {
        var counter = 0
        func walk(_ ns: [FormatNode]) -> [FormatNode] {
            ns.map { node in
                switch node {
                case .field(.ignore, let kind):
                    defer { counter += 1 }
                    return .field(.ignore(counter), kind: kind)
                case .group(let pair, let children):
                    return .group(pair, children: walk(children))
                default:
                    return node
                }
            }
        }
        return walk(nodes)
    }

    /// フィールドの照合方法を設定から決める [TY-01][TY-06]。
    static func resolveFieldKinds(_ nodes: [FormatNode],
                                  context: FormatCompilationContext) -> [FormatNode] {
        func kind(for ref: FieldRef) -> FieldKind {
            switch ref {
            case .volume:      return .volume
            case .bookType:    return .enumerated(context.allLibraryTypeNames)
            default:           return .free
            }
        }
        func walk(_ ns: [FormatNode]) -> [FormatNode] {
            ns.map { node in
                switch node {
                case .field(let ref, _): return .field(ref, kind: kind(for: ref))
                case .group(let pair, let children): return .group(pair, children: walk(children))
                default: return node
                }
            }
        }
        return walk(nodes)
    }

    /// リテラルを照合用の正準形へ畳んでおく [MT2-05]。
    ///
    /// 照合のたびに変換すると、1 ファイル名 × 50 フォーマットの走査で無駄が積み上がる。
    /// 表示用の原文は `CompiledFormat.source` が保持しているので情報は失われない。
    /// **`ParseInput` も同じ正準化で作られる**——片方だけ小文字化すると
    /// 照合が静かに壊れる（正準化は `CharacterCanonicalization.canonical` の
    /// 1 箇所だけが持つ）。
    static func canonicalizeLiterals(_ nodes: [FormatNode]) -> [FormatNode] {
        nodes.map { node in
            switch node {
            case .literal(let s):
                return .literal(String(s.map {
                    CharacterCanonicalization.canonical($0)
                }))
            case .group(let pair, let children):
                return .group(pair, children: canonicalizeLiterals(children))
            default:
                return node
            }
        }
    }

    // MARK: - 検証 [4.5]

    static func validate(_ nodes: [FormatNode],
                         context: FormatCompilationContext) throws(FormatCompileError) {
        let fields = nodes.flatMap { $0.fieldsInOrder() }

        // ① フィールドの重複 [FF-16]。`@ignore` は対象外 [RW-03]。
        var seen = Set<FieldRef>()
        for f in fields {
            guard !f.allowsDuplicates else { continue }
            if seen.contains(f) {
                switch f {
                case .title: throw FormatCompileError.duplicateTitle
                default: throw FormatCompileError.duplicateField(f)
                }
            }
            seen.insert(f)
        }

        // ② `@labelgroupN` の撤去（v3 ステージ 5）で、番号の範囲検査と
        //    「予約語と番号の衝突」[旧 RW-15] は不要になった——フィールドを
        //    指す道が意味予約語 1 本になり、同じ軸を 2 通りで書けなくなった。

        // ③ 自由文字列フィールドの隣接 [FF-18][TY-05][VD-02]
        //    弾力的空白は境界にならない——0 個でもよいので終端が決まらない。
        let flat = flatten(nodes)
        for i in flat.indices {
            guard case .free(let a) = flat[i] else { continue }
            var j = i + 1
            while j < flat.count, case .whitespace = flat[j] { j += 1 }
            if j < flat.count, case .free(let b) = flat[j] {
                throw FormatCompileError.adjacentFreeFields(first: a, second: b)
            }
        }

        // ④ 何も抽出できないフォーマットを拒む。
        //    `@title` は省略してよい——`@series` か `@volume` があれば足りる [FF-19][RW-09]。
        guard fields.contains(where: { !$0.discardsValue }) else {
            throw FormatCompileError.noFieldAtAll
        }
    }

    enum Flat {
        case free(FieldRef)
        case boundary
        case whitespace
    }

    static func flatten(_ nodes: [FormatNode]) -> [Flat] {
        var out: [Flat] = []
        for node in nodes {
            switch node {
            case .group(_, let children):
                out.append(.boundary)                       // 開き括弧
                out.append(contentsOf: flatten(children))
                out.append(.boundary)                       // 閉じ括弧
            case .whitespace:
                out.append(.whitespace)
            case .field(let ref, .free):
                out.append(.free(ref))
            default:
                out.append(.boundary)
            }
        }
        return out
    }
}
