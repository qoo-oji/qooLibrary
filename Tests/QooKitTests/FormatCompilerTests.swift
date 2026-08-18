import Testing
import Foundation
@testable import QooKit

private func ctx(maxGroups: Int = 10,
                 types: [String] = [],
                 names: [String] = [],
                 semantic: [SemanticKeyword: Int] = [:],
                 delimiters: DelimiterSet = .default) -> FormatCompilationContext {
    FormatCompilationContext(delimiters: delimiters, maxLabelGroups: maxGroups,
                             allLibraryTypeNames: types, allLibraryDisplayNames: names,
                             semanticBindings: semantic)
}

// MARK: - 字句解析 [4.3]

@Suite("FormatLexer [LX-01〜LX-04]")
struct FormatLexerTests {
    @Test("予約語は最長一致で読む。@labelgroup12 は @labelgroup1 + 2 ではない [LX-01][MT-12]")
    func longestMatchOnLabelGroup() throws {
        let t = try FormatLexer.lex("@labelgroup12", delimiters: .default)
        #expect(t == [.reservedWord(.labelGroup(12), sourceRange: 0..<13)])
    }

    @Test("@labelgroup は任意桁を受け付ける [LX-02]")
    func multiDigitLabelGroup() throws {
        for n in [1, 9, 10, 12, 99, 100] {
            let t = try FormatLexer.lex("@labelgroup\(n)", delimiters: .default)
            #expect(t.first == .reservedWord(.labelGroup(n), sourceRange: 0..<(11 + "\(n)".count)))
        }
    }

    @Test("番号の無い @labelgroup は予約語として認めない")
    func labelGroupWithoutNumber() {
        #expect(throws: FormatCompileError.unknownReservedWord("@labelgroup", at: 0)) {
            try FormatLexer.lex("@labelgroup", delimiters: .default)
        }
    }

    @Test("連続する空白は 1 つの whitespace に畳む [LX-04]")
    func whitespaceRunCollapses() throws {
        // lex は生の文字列を受ける（正規化は compile 側の責務）
        let t = try FormatLexer.lex("a   b", delimiters: .default)
        #expect(t == [.literal("a", sourceRange: 0..<1),
                      .whitespace(at: 1),
                      .literal("b", sourceRange: 4..<5)])
    }

    @Test("ペア型の開き・閉じを認識する")
    func pairDelimiters() throws {
        let t = try FormatLexer.lex("[@title]", delimiters: .default)
        guard case .pairOpen(let open, at: 0) = t[0], case .pairClose(let close, at: 7) = t[2] else {
            Issue.record("期待した字句ではない: \(t)"); return
        }
        #expect(open.open == "[")
        #expect(close.close == "]")
    }

    @Test("無効なペア型はただのリテラルとして扱う [DLI-02][DL-16]")
    func disabledPairIsLiteral() throws {
        let onlyBrackets = DelimiterSet(pairs: [PairDelimiter(open: "[", close: "]")])
        let t = try FormatLexer.lex("(@title)", delimiters: onlyBrackets)
        #expect(t == [.literal("(", sourceRange: 0..<1),
                      .reservedWord(.title, sourceRange: 1..<7),
                      .literal(")", sourceRange: 7..<8)])
    }

    @Test("セパレータ型は最長一致で読む [DL-15]")
    func separatorLongestMatch() throws {
        var sep = SeparatorDelimiter(canonical: "-", variants: ["-", "--", "－"])
        sep.isEnabled = true
        let t = try FormatLexer.lex("a--b", delimiters: DelimiterSet(separators: [sep]))
        #expect(t.count == 3)
        if case .separator(_, let range) = t[1] { #expect(range == 1..<3) } else { Issue.record("\(t)") }
    }

    @Test("未知の予約語は位置つきで拒否する")
    func unknownReservedWord() {
        #expect(throws: FormatCompileError.unknownReservedWord("@titel", at: 4)) {
            try FormatLexer.lex("abc @titel", delimiters: .default)
        }
    }
}

// MARK: - 構文解析と検証 [4.4][4.5]

@Suite("FormatCompiler — 構文解析")
struct FormatParseTests {
    @Test("ネストしたペア型を構文木にする [FF-11][MT2-04]")
    func nestedGroups() throws {
        let f = try FormatCompiler.compile("[@labelgroup1 (@labelgroup2)] @title", context: ctx())
        guard case .group(_, let children) = f.nodes[0] else {
            Issue.record("先頭がグループでない: \(f.nodes)"); return
        }
        #expect(children.count == 3)                                  // field, ws, group
        #expect(children[0] == .field(.labelGroup(1), kind: .free))
        guard case .group(_, let inner) = children[2] else {
            Issue.record("入れ子のグループがない: \(children)"); return
        }
        #expect(inner == [.field(.labelGroup(2), kind: .free)])
        #expect(f.fieldOrder == [.labelGroup(1), .labelGroup(2), .title])
    }

    @Test("括弧の不一致を位置つきで拒否する")
    func unbalanced() {
        #expect(throws: FormatCompileError.unbalancedDelimiter(at: 0)) {
            try FormatCompiler.compile("[@title", context: ctx())
        }
        #expect(throws: FormatCompileError.unbalancedDelimiter(at: 6)) {
            try FormatCompiler.compile("@title]", context: ctx())
        }
        // 別の種類の括弧で閉じようとした
        #expect(throws: FormatCompileError.unbalancedDelimiter(at: 7)) {
            try FormatCompiler.compile("[@title)", context: ctx())
        }
    }

    @Test("@ignore には出現順の連番が振られる [LX-03][RW-03]")
    func ignoreNumbering() throws {
        let f = try FormatCompiler.compile("[@ignore] @title [@ignore]", context: ctx())
        #expect(f.fieldOrder == [.ignore(0), .title, .ignore(1)])
    }

    @Test("フィールドの照合方法が設定から決まる [TY-01][TY-06]")
    func fieldKinds() throws {
        let f = try FormatCompiler.compile("(@librarytype) @title (@volume)",
                                           context: ctx(types: ["一般コミック", "同人誌"]))
        guard case .group(_, let g1) = f.nodes[0], case .group(_, let g3) = f.nodes[4] else {
            Issue.record("\(f.nodes)"); return
        }
        #expect(g1 == [.field(.libraryType, kind: .enumerated(["一般コミック", "同人誌"]))])
        #expect(g3 == [.field(.volume, kind: .volume)])
    }

    @Test("保存時に空白が正規化される [WS-03][WS-04][WSI-02]")
    func whitespaceNormalizedOnSave() throws {
        let a = try FormatCompiler.compile("[@labelgroup1]　@title", context: ctx())  // 全角
        let b = try FormatCompiler.compile("[@labelgroup1]   @title", context: ctx())
        #expect(a.source == "[@labelgroup1] @title")
        #expect(a.source == b.source)
        #expect(a.nodes == b.nodes)
    }
}

@Suite("FormatCompiler — 検証 [FF-15〜FF-19][TY-05]")
struct FormatValidationTests {
    @Test("@title の重複を拒否する")
    func duplicateTitle() {
        #expect(throws: FormatCompileError.duplicateTitle) {
            try FormatCompiler.compile("@title - @title", context: ctx())
        }
    }

    @Test("同じラベルグループの重複を拒否する [FF-16]")
    func duplicateLabelGroup() {
        #expect(throws: FormatCompileError.duplicateLabelGroup(index: 2)) {
            try FormatCompiler.compile("[@labelgroup2] (@labelgroup2)", context: ctx())
        }
    }

    @Test("範囲外のラベルグループを拒否する [LG-01][MT-11]")
    func labelGroupOutOfRange() {
        #expect(throws: FormatCompileError.labelGroupOutOfRange(index: 11, max: 10)) {
            try FormatCompiler.compile("[@labelgroup11] @title", context: ctx())
        }
        #expect(throws: FormatCompileError.labelGroupOutOfRange(index: 0, max: 10)) {
            try FormatCompiler.compile("[@labelgroup0] @title", context: ctx())
        }
    }

    /// **上限値に依存する実装をしてはならない** [MT-10]。定数を上げるだけで通ること。
    @Test("ラベルグループ上限は定数を変えるだけで引き上げられる [MT-10][MT-13]")
    func labelGroupLimitIsNotHardcoded() throws {
        let f = try FormatCompiler.compile("[@labelgroup12] @title", context: ctx(maxGroups: 12))
        #expect(f.usedFields.contains(.labelGroup(12)))
        let g = try FormatCompiler.compile("[@labelgroup120] @title", context: ctx(maxGroups: 200))
        #expect(g.usedFields.contains(.labelGroup(120)))
    }

    @Test("@ignore の重複は許す [RW-03]")
    func ignoreMayRepeat() throws {
        let f = try FormatCompiler.compile("[@ignore] @title (@ignore)", context: ctx())
        #expect(f.fieldOrder.count == 3)
    }

    @Test("セマンティック予約語と @labelgroup# の衝突を拒否する [RW-15]")
    func semanticConflict() {
        #expect(throws: FormatCompileError.semanticConflict(keyword: .author, labelGroup: 1)) {
            try FormatCompiler.compile("[@labelgroup1] [@author] @title",
                                       context: ctx(semantic: [.author: 1]))
        }
    }

    @Test("紐づいていないラベルグループとの併用は許す")
    func semanticNoConflictWhenUnbound() throws {
        // `@author @title` は自由文字列の隣接になるので括弧で隔てる [VD-02]
        let f = try FormatCompiler.compile("[@labelgroup2] [@author] @title",
                                           context: ctx(semantic: [.author: 1]))
        #expect(f.usedFields.contains(.author))
    }

    @Test("自由文字列フィールドの隣接を拒否する [FF-18][TY-05]")
    func adjacentFreeFields() {
        #expect(throws: FormatCompileError.adjacentFreeFields(first: .labelGroup(1), second: .title)) {
            try FormatCompiler.compile("@labelgroup1@title", context: ctx())
        }
    }

    /// 弾力的空白は 0 個でもよいので、境目を決められない [VD-02]。
    @Test("空白だけで隔てた自由文字列も拒否する [VD-02]")
    func whitespaceIsNotABoundary() {
        #expect(throws: FormatCompileError.adjacentFreeFields(first: .title, second: .labelGroup(1))) {
            try FormatCompiler.compile("@title @labelgroup1", context: ctx())
        }
    }

    @Test("型付きフィールドは境界になるので隣接してよい [VD-03][TY-02]")
    func typedFieldsAreBoundaries() throws {
        _ = try FormatCompiler.compile("@series@volume", context: ctx())
        _ = try FormatCompiler.compile("@librarytype @title", context: ctx(types: ["A"]))
    }

    @Test("括弧の境界を挟めば自由文字列を並べてよい")
    func groupBoundarySeparatesFreeFields() throws {
        let f = try FormatCompiler.compile("[@labelgroup1] @title", context: ctx())
        #expect(f.fieldOrder == [.labelGroup(1), .title])
    }

    @Test("リテラルを挟めば自由文字列を並べてよい")
    func literalSeparatesFreeFields() throws {
        _ = try FormatCompiler.compile("@labelgroup1 - @title", context: ctx())
    }

    @Test("空のフォーマットを拒否する")
    func emptyFormat() {
        #expect(throws: FormatCompileError.emptyFormat) { try FormatCompiler.compile("", context: ctx()) }
        #expect(throws: FormatCompileError.emptyFormat) { try FormatCompiler.compile("   ", context: ctx()) }
    }

    @Test("何も抽出できないフォーマットを拒否する")
    func noExtractableField() {
        #expect(throws: FormatCompileError.noFieldAtAll) {
            try FormatCompiler.compile("固定文字列のみ", context: ctx())
        }
        #expect(throws: FormatCompileError.noFieldAtAll) {
            try FormatCompiler.compile("@ignore", context: ctx())
        }
        // @librarytype だけでは照合はできても抽出できない
        #expect(throws: FormatCompileError.noFieldAtAll) {
            try FormatCompiler.compile("(@librarytype)", context: ctx(types: ["A"]))
        }
    }

    /// @series か @volume を直接書いていれば @title は要らない [FF-19][RW-09]。
    @Test("@title を省略できる [FF-19][RW-09]")
    func titleMayBeOmitted() throws {
        _ = try FormatCompiler.compile("@series (@volume)", context: ctx())
        _ = try FormatCompiler.compile("[@labelgroup1] @series", context: ctx())
    }

    @Test("エラーはすべて三要素の文言を持つ [ER-03]")
    func errorsArePresentable() {
        let all: [FormatCompileError] = [
            .unbalancedDelimiter(at: 3), .duplicateTitle, .duplicateField(.series),
            .duplicateLabelGroup(index: 2), .labelGroupOutOfRange(index: 11, max: 10),
            .semanticConflict(keyword: .series, labelGroup: 3),
            .adjacentFreeFields(first: .title, second: .author),
            .unknownReservedWord("@x", at: 0), .emptyFormat, .noFieldAtAll,
        ]
        for e in all {
            #expect(!e.whatHappened.isEmpty)
            #expect(!e.whyItHappened.isEmpty)
            #expect(e.recoveryHint?.isEmpty == false)
            #expect(e.severity == .inline)
        }
    }
}
