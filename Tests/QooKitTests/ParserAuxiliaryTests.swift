import Testing
import Foundation
@testable import QooKit

@Suite("parseAll — 編集画面のプレビュー用 [FF-06][HP-05]")
struct ParseAllTests {
    let parser = FilenameParser()

    @Test("一致したフォーマットすべての結果を返す")
    func returnsEveryMatch() throws {
        let s = try settings(formats: ["[@circle] @title (@keyword)",
                                       "[@circle] @title",
                                       "(@circle) @title"])
        let all = parser.parseAll("[著者] タイトル (タグ)", settings: s)
        #expect(all.count == 2)                      // 3 番目は丸括弧始まりなので不一致
        #expect(all[0].fields[.keyword]?.text == "タグ")
        #expect(all[1].fields[.title]?.text == "タイトル (タグ)")
    }

    @Test("どれにも一致しなければ空を返す")
    func noMatches() throws {
        let s = try settings(formats: ["[@circle] @title"])
        #expect(parser.parseAll("括弧のない名前", settings: s).isEmpty)
    }
}

@Suite("nearestFormat — 最も近いフォーマットの推定 [UR2-05][AL-32]")
struct NearestFormatTests {
    let parser = FilenameParser()

    @Test("照合が最も進んだフォーマットを返す")
    func picksFurthest() throws {
        let s = try settings(formats: [
            "(@event) [@circle] @title",   // 先頭で落ちる
            "[@circle] @title (@keyword)",   // 末尾まで進むが最後で落ちる
        ])
        let near = try #require(parser.nearestFormat("[著者] タイトル", settings: s))
        #expect(near.formatID == s.filenameFormats[1].id)
        #expect(near.reachedIndex > 0)
    }

    @Test("フォーマットが 1 本も無ければ nil")
    func noFormats() throws {
        let s = try settings(formats: [])
        #expect(parser.nearestFormat("何か", settings: s) == nil)
    }

    /// **入力位置だけでは決められない**（実測、2026-09-01）。自由文字列
    /// フィールドに入った時点で走査位置が末尾へ届くので、両方とも「16/16 まで
    /// 到達」で同点になる——要素数を第一キーにして初めて構造の近いほうを選べる。
    @Test("要素数が第一キー: 自由文字列で始まるフォーマットに引きずられない [UR2-05]")
    func satisfiedNodesBeatSaturatedReach() throws {
        let s = try settings(formats: ["@title (@genre)",              // 先頭が自由文字列
                                       "[@circle] @title (@genre)"])  // 構造が深く進む
        // 閉じ括弧が欠けた名前（実コーパスに実在する形）。どちらも最後で落ちる。
        let input = "[サークル] 作品名 (ジャンル"
        // 前提: どちらも一致しない。
        #expect(parser.parse(input, settings: s) == nil)
        // 前提: 入力位置だけでは同点になる（この検査が意味を持つ条件）。
        let masked = ProtectedTokenMasker.mask(input, tokens: s.protectedTokens)
        let reaches = s.filenameFormats.map {
            FormatMatcher.match($0, input: masked, volumePatterns: s.volumeFormats).furthestIndex
        }
        #expect(reaches[0] == reaches[1])

        let near = try #require(parser.nearestFormat(input, settings: s))
        #expect(near.formatID == s.filenameFormats[1].id)
    }

    @Test("1 要素も満たさないフォーマットは候補にしない [UR2-05]")
    func formatsThatMatchNothingAreNotCandidates() throws {
        let s = try settings(formats: ["(@booktype) @title", "[@circle] @title"])
        // どちらも先頭の括弧すら合わない。**登録順の先頭を無条件に選ばない。**
        #expect(parser.nearestFormat("作品名だけ", settings: s) == nil)
    }

    /// 入れ子の添字を最上位の添字と混ぜると、深い括弧を持つフォーマットが
    /// 不当に有利になる（要素数が実際より多く数えられる）。
    @Test("括弧の中は数えない（グループ全体で 1 要素）[UR2-05]")
    func nestedNodesDoNotInflateTheCount() throws {
        // 括弧の**中**のほうが要素数が多い形にする——数えてしまえば 3 を超える。
        let s = try settings(formats: ["[@circle (@author) @keyword] @title"])
        let format = s.filenameFormats[0]
        #expect(format.nodes.count == 3)          // group / 空白 / @title
        let outcome = FormatMatcher.match(
            format,
            input: ProtectedTokenMasker.mask("[サークル (著者) キーワード] 作品名",
                                             tokens: []),
            volumePatterns: [])
        #expect(outcome.matched)
        #expect(outcome.satisfiedNodes == 3)
    }

    /// **先に候補を拾ってから一致した場合**でも `nil` にする。1 本目が
    /// 「惜しかった」フォーマットで 2 本目が当たる、という順序でないと、
    /// この検査は空振りする（変異検証で判明）。
    @Test("一致したときは推定しない")
    func noNearestWhenMatched() throws {
        let s = try settings(formats: ["[@circle] @title (@genre)",  // 惜しいが落ちる
                                       "[@circle] @title"])          // 当たる
        // 前提: 1 本目は候補として拾われる形である。
        #expect(parser.nearestFormat("[サークル]", settings: s) != nil)

        let attempt = parser.attempt("[サークル] 作品名", settings: s)
        #expect(attempt.result != nil)
        #expect(attempt.nearest == nil)
    }

    /// 空マッチしうる先頭ノード（弾力的空白 [WS-01]。0 個以上に一致する）は、
    /// 入力を 1 文字も消費しないまま要素数を 1 進める——要素数だけで判定すると、
    /// そういうフォーマットが 1 本あるだけで全部の「最も近い」になる
    /// ［code-review の指摘、実測で確認］。
    @Test("1 文字も進んでいないものは候補にしない [UR2-05]")
    func zeroWidthProgressIsNotACandidate() throws {
        let s = try settings(formats: [" [@circle] @title"])   // 先頭が弾力的空白
        let format = s.filenameFormats[0]
        let outcome = FormatMatcher.match(
            format, input: ProtectedTokenMasker.mask("zzz", tokens: []),
            volumePatterns: [])
        // 前提: 要素数だけは進む（この検査が意味を持つ条件）。
        #expect(outcome.satisfiedNodes > 0)
        #expect(outcome.furthestIndex == 0)

        #expect(parser.nearestFormat("zzz", settings: s) == nil)
    }

    /// 途中で止めた走査の到達点は「どこまで筋が通ったか」を表さない [MT2-02]。
    @Test("探索を打ち切ったフォーマットは候補にしない [UR2-05][MT2-02]")
    func abandonedSearchIsNotACandidate() throws {
        let s = try settings(formats: ["[@circle] @title"])
        let format = s.filenameFormats[0]
        let input = ProtectedTokenMasker.mask("[サークル] 作品名", tokens: [])
        let abandoned = MatchOutcome(result: nil, furthestIndex: 9, satisfiedNodes: 3,
                                     exceededStepLimit: true, steps: 1)
        #expect(parser.closer(nil, than: abandoned, of: format, input: input) == nil)
        // 打ち切っていなければ候補になる（この検査が空振りしていないことの対照）。
        let finished = MatchOutcome(result: nil, furthestIndex: 9, satisfiedNodes: 3,
                                    exceededStepLimit: false, steps: 1)
        #expect(parser.closer(nil, than: finished, of: format, input: input) != nil)
    }

    /// 保存先（`unresolvedFile.nearestFormatReach`）と表示側がマスクを知らずに
    /// 使えるように、**原文へ写してから返す** [PT-03]。
    @Test("到達位置は原文の添字で返る（保護文字列でマスクしても）[UR2-05][PT-03]")
    func reachIsInOriginalCoordinates() throws {
        let token = ProtectedToken(pattern: #"\(完全版\)"#)
        let s = try settings(formats: ["[@circle] @title (@genre)"],
                             protectedTokens: [token])
        // `(完全版)` は 5 文字だがマスク後は 1 文字。原文で数えれば 15 文字目まで進む。
        let near = try #require(parser.nearestFormat("[サークル] 作品名(完全版)",
                                                     settings: s))
        #expect(near.reachedIndex == 15)
    }
}

@Suite("ParseResult / FieldRef の補助")
struct ParseResultHelpersTests {
    @Test("意味予約語で切り出した値が取り出せる [RWI-02]")
    func semanticFieldValues() throws {
        let s = try settings(formats: ["[@circle] @title (@keyword)"])
        let r = try #require(FilenameParser().parse("[サークル] タイトル (タグ)",
                                                     settings: s))
        #expect(r.fields[.circle]?.text == "サークル")
        #expect(r.fields[.keyword]?.text == "タグ")
        #expect(r.fields[.title]?.text == "タイトル")
    }

    @Test("FieldRef の性質")
    func fieldRefProperties() {
        #expect(FieldRef.title.isFreeText)
        #expect(FieldRef.series.isFreeText)
        #expect(FieldRef.author.isFreeText)
        #expect(FieldRef.circle.isFreeText)
        #expect(FieldRef.ignore(0).isFreeText)
        #expect(!FieldRef.volume.isFreeText)
        #expect(!FieldRef.bookType.isFreeText)

        // 抽出値を捨てるもの [RW-02][RW-04]
        #expect(FieldRef.ignore(0).discardsValue)
        // **`@booktype` は捨てない** [TY-01、2026-09-04]——照合した値は
        // 「本の種別」フィールドのラベルになり、次回以降の照合語彙にもなる。
        #expect(!FieldRef.bookType.discardsValue)
        #expect(!FieldRef.title.discardsValue)
        #expect(!FieldRef.volume.discardsValue)

        // 重複を許すのは @ignore のみ [RW-03]
        #expect(FieldRef.ignore(3).allowsDuplicates)
        #expect(!FieldRef.title.allowsDuplicates)
        #expect(!FieldRef.circle.allowsDuplicates)
    }

    @Test("SemanticKeyword は FieldRef に対応する [RW-13]")
    func semanticKeywordMapping() {
        #expect(SemanticKeyword.series.fieldRef == .series)
        #expect(SemanticKeyword.author.fieldRef == .author)
        #expect(SemanticKeyword.circle.fieldRef == .circle)
        #expect(SemanticKeyword.event.fieldRef == .event)
        #expect(SemanticKeyword.genre.fieldRef == .genre)
        #expect(SemanticKeyword.keyword.fieldRef == .keyword)
        #expect(SemanticKeyword.bookType.fieldRef == .bookType)
        #expect(SemanticKeyword.allCases.count == 7)        // [RWI-02] 4 種 ＋ @booktype
        #expect(SemanticKeyword(rawValue: "@series") == .series)

        // **綴りは `ReservedWordTable` から導出する。** 2 箇所に書くと、case を
        // 足しても字句解析が読めない（＝書いても「不明な予約語」になる）。
        let words = Set(ReservedWordTable.entries.map(\.word))
        for keyword in SemanticKeyword.allCases {
            #expect(words.contains(keyword.rawValue), "\(keyword.rawValue) が対応表に無い")
        }

        // 既定フィールド 6 種 [§19.2]。`@series` は含まない——シリーズは
        // 構造化列であってフィールドではない。`@booktype` は**末尾に足す**
        // ——既定 1〜5 の番号を動かさないため。
        #expect(SemanticKeyword.defaultFields
                == [.author, .circle, .genre, .event, .keyword, .bookType])
        #expect(!SemanticKeyword.defaultFields.contains(.series))
    }

    @Test("FormatNode の境界判定 [VD-02][VD-03]")
    func nodeBoundaries() {
        #expect(FormatNode.literal("-").isBoundary)
        #expect(!FormatNode.literal("").isBoundary)
        #expect(!FormatNode.whitespace.isBoundary)          // 弾力的空白は境界にならない
        #expect(FormatNode.field(.volume, kind: .volume).isBoundary)
        #expect(FormatNode.field(.bookType, kind: .enumerated(["A"])).isBoundary)
        #expect(!FormatNode.field(.title, kind: .free).isBoundary)
        #expect(FormatNode.separator(SeparatorDelimiter(canonical: "-")).isBoundary)
        #expect(FormatNode.group(PairDelimiter(open: "[", close: "]"), children: []).isBoundary)

        #expect(FormatNode.field(.title, kind: .free).freeFieldRef == .title)
        #expect(FormatNode.field(.volume, kind: .volume).freeFieldRef == nil)
        #expect(FormatNode.whitespace.freeFieldRef == nil)
    }
}

@Suite("DelimiterSet [DL-01〜DL-16]")
struct DelimiterSetTests {
    @Test("既定は角括弧と丸括弧のみ。セパレータ型は空 [DL-01][DL-10][DL-11]")
    func defaults() {
        let d = DelimiterSet.default
        #expect(d.enabledPairs.count == 2)
        #expect(d.enabledPairs.map(\.open) == ["[", "("])
        #expect(d.separators.isEmpty)
        #expect(d.enabledSeparators.isEmpty)
    }

    @Test("設定画面の候補が揃っている [DL-02]")
    func availableChoices() {
        #expect(DelimiterSet.availablePairs.contains { $0.open == "【" && $0.close == "】" })
        #expect(DelimiterSet.availablePairs.contains { $0.open == "（" && $0.close == "）" })
        // セパレータ型の候補はいずれも既定で無効 [DL-11][R-10]
        for sep in DelimiterSet.availableSeparators() {
            #expect(sep.isEnabled == false, "\(sep.canonical) が既定で有効になっている")
        }
    }

    @Test("variants には canonical が必ず含まれる [DL-15]")
    func variantsIncludeCanonical() {
        let sep = SeparatorDelimiter(canonical: "-", variants: ["－", "‐"])
        #expect(sep.variants.contains("-"))
        #expect(sep.variantsByLengthDesc.count == 3)
    }

    @Test("無効なペア型は enabledPairs に出ない")
    func disabledPairsFiltered() {
        let d = DelimiterSet(pairs: [PairDelimiter(open: "[", close: "]", isEnabled: false),
                                     PairDelimiter(open: "(", close: ")")])
        #expect(d.enabledPairs.count == 1)
    }

    @Test("JSON で往復できる（区切り文字は 1 文字の文字列として持つ）")
    func codableRoundTrip() throws {
        let d = DelimiterSet.default
        let data = try JSONEncoder().encode(d)
        let back = try JSONDecoder().decode(DelimiterSet.self, from: data)
        #expect(back.pairs.map(\.open) == d.pairs.map(\.open))
        #expect(back.pairs.map(\.close) == d.pairs.map(\.close))
        // JSON では 1 文字の文字列
        let text = String(data: data, encoding: .utf8) ?? ""
        #expect(text.contains("\"open\":\"[\"") || text.contains("\"open\" : \"[\""))
    }

    @Test("2 文字以上の区切り文字はデコードで拒否する")
    func rejectsMultiCharacterDelimiter() {
        let json = """
        {"pairs":[{"id":"\(UUID().uuidString)","open":"[[","close":"]]","isEnabled":true}],"separators":[]}
        """
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(DelimiterSet.self, from: Data(json.utf8))
        }
    }
}

@Suite("セパレータ型区切り文字での照合 [DL-14][DLI-03]")
struct SeparatorMatchingTests {
    let parser = FilenameParser()

    func separatorSettings(_ formats: [String]) throws -> LibrarySettingsSnapshot {
        var sep = SeparatorDelimiter(canonical: "-", variants: ["-", "－", "‐", "–", "—"])
        sep.isEnabled = true
        let d = DelimiterSet(pairs: DelimiterSet.default.pairs, separators: [sep])
        return try settings(formats: formats, volume: vsFull(), delimiters: d)
    }

    @Test("elastic空白 + variant + elastic空白 を 1 トークンとして消費する [DL-14]")
    func separatorConsumesSurroundingSpace() throws {
        let s = try separatorSettings(["@series-@circle"])
        for input in ["シリーズ名-著者名", "シリーズ名 - 著者名", "シリーズ名　－　著者名"] {
            let r = try #require(parser.parse(input, settings: s),
                                 "一致しない: \(input)")
            #expect(r.fields[.series]?.text == "シリーズ名")
            #expect(r.fields[.circle]?.text == "著者名")
        }
    }

    @Test("実データの形: シリーズ名（巻数） - 著者名 [1.7 の追加要件]")
    func realWorldSeparatorShape() throws {
        var sep = SeparatorDelimiter(canonical: "-", variants: ["-", "－"])
        sep.isEnabled = true
        let d = DelimiterSet(pairs: [PairDelimiter(open: "（", close: "）"),
                                     PairDelimiter(open: "(", close: ")")],
                             separators: [sep])
        let volume = VolumePatternCompiler.compileAll([VolumePattern(source: "??")])
        let s = try settings(formats: ["@series（@volume）-@circle"],
                             volume: volume, delimiters: d)
        let r = try #require(parser.parse("作品タイトル（１２） - 著者名",
                                          settings: s))
        #expect(r.fields[.series]?.text == "作品タイトル")
        #expect(r.fields[.volume]?.volume?.number == 12)
        #expect(r.fields[.circle]?.text == "著者名")
    }
}
