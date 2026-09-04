import Testing
import Foundation
@testable import QooKit

private func ctx(maxGroups: Int = 10,
                 types: [String] = [],
                 names: [String] = [],
                 semantic: [SemanticKeyword: Int] = [:],
                 delimiters: DelimiterSet = .default) -> FormatCompilationContext {
    FormatCompilationContext(delimiters: delimiters, maxFields: maxGroups,
                             bookTypeVocabulary: types,
                             semanticBindings: semantic)
}

// MARK: - 字句解析 [4.3]

@Suite("FormatLexer [LX-01〜LX-04]")
struct FormatLexerTests {
    @Test("番号の無い @labelgroup は予約語として認めない")
    func fieldWithoutNumber() {
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
        let f = try FormatCompiler.compile("[@circle (@genre)] @title", context: ctx())
        guard case .group(_, let children) = f.nodes[0] else {
            Issue.record("先頭がグループでない: \(f.nodes)"); return
        }
        #expect(children.count == 3)                                  // field, ws, group
        #expect(children[0] == .field(.circle, kind: .free))
        guard case .group(_, let inner) = children[2] else {
            Issue.record("入れ子のグループがない: \(children)"); return
        }
        #expect(inner == [.field(.genre, kind: .free)])
        #expect(f.fieldOrder == [.circle, .genre, .title])
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
        let f = try FormatCompiler.compile("(@booktype) @title (@volume)",
                                           context: ctx(types: ["一般コミック", "同人誌"]))
        guard case .group(_, let g1) = f.nodes[0], case .group(_, let g3) = f.nodes[4] else {
            Issue.record("\(f.nodes)"); return
        }
        #expect(g1 == [.field(.bookType, kind: .enumerated(["一般コミック", "同人誌"]))])
        #expect(g3 == [.field(.volume, kind: .volume)])
    }

    @Test("保存時に空白が正規化される [WS-03][WS-04][WSI-02]")
    func whitespaceNormalizedOnSave() throws {
        let a = try FormatCompiler.compile("[@circle]　@title", context: ctx())  // 全角
        let b = try FormatCompiler.compile("[@circle]   @title", context: ctx())
        #expect(a.source == "[@circle] @title")
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

    @Test("@ignore の重複は許す [RW-03]")
    func ignoreMayRepeat() throws {
        let f = try FormatCompiler.compile("[@ignore] @title (@ignore)", context: ctx())
        #expect(f.fieldOrder.count == 3)
    }

    /// 同じフィールドを 2 通りで書く道が無くなったので、`@labelgroupN` との
    /// 衝突検査 [旧 RW-15] は不要になった。束縛の有無に関わらず併用は許す。
    @Test("束縛された予約語と別の予約語は併用できる")
    func semanticNoConflictWhenUnbound() throws {
        // `@author @title` は自由文字列の隣接になるので括弧で隔てる [VD-02]
        let f = try FormatCompiler.compile("[@genre] [@author] @title",
                                           context: ctx(semantic: [.author: 1]))
        #expect(f.usedFields.contains(.author))
    }

    @Test("自由文字列フィールドの隣接を拒否する [FF-18][TY-05]")
    func adjacentFreeFields() {
        #expect(throws: FormatCompileError.adjacentFreeFields(first: .circle, second: .title)) {
            try FormatCompiler.compile("@circle@title", context: ctx())
        }
    }

    /// 弾力的空白は 0 個でもよいので、境目を決められない [VD-02]。
    @Test("空白だけで隔てた自由文字列も拒否する [VD-02]")
    func whitespaceIsNotABoundary() {
        #expect(throws: FormatCompileError.adjacentFreeFields(first: .title, second: .circle)) {
            try FormatCompiler.compile("@title @circle", context: ctx())
        }
    }

    @Test("型付きフィールドは境界になるので隣接してよい [VD-03][TY-02]")
    func typedFieldsAreBoundaries() throws {
        _ = try FormatCompiler.compile("@series@volume", context: ctx())
        _ = try FormatCompiler.compile("@booktype @title", context: ctx(types: ["A"]))
    }

    @Test("括弧の境界を挟めば自由文字列を並べてよい")
    func groupBoundarySeparatesFreeFields() throws {
        let f = try FormatCompiler.compile("[@circle] @title", context: ctx())
        #expect(f.fieldOrder == [.circle, .title])
    }

    @Test("リテラルを挟めば自由文字列を並べてよい")
    func literalSeparatesFreeFields() throws {
        _ = try FormatCompiler.compile("@circle - @title", context: ctx())
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
        // **`@booktype` だけなら通る** [TY-01、2026-09-04]——照合した値は
        // 捨てずに「本の種別」のラベルとして残るので、抽出できている。
        #expect(throws: Never.self) {
            try FormatCompiler.compile("(@booktype)", context: ctx(types: ["A"]))
        }
    }

    /// @series か @volume を直接書いていれば @title は要らない [FF-19][RW-09]。
    @Test("@title を省略できる [FF-19][RW-09]")
    func titleMayBeOmitted() throws {
        _ = try FormatCompiler.compile("@series (@volume)", context: ctx())
        _ = try FormatCompiler.compile("[@circle] @series", context: ctx())
    }

    @Test("エラーはすべて三要素の文言を持つ [ER-03]")
    func errorsArePresentable() {
        let all: [FormatCompileError] = [
            .unbalancedDelimiter(at: 3), .duplicateTitle, .duplicateField(.series),
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
