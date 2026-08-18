import Testing
import Foundation
@testable import QooKit

@Suite("parseAll — 編集画面のプレビュー用 [FF-06][HP-05]")
struct ParseAllTests {
    let parser = FilenameParser()

    @Test("一致したフォーマットすべての結果を返す")
    func returnsEveryMatch() throws {
        let s = try settings(formats: ["[@labelgroup1] @title (@labelgroup4)",
                                       "[@labelgroup1] @title",
                                       "(@labelgroup1) @title"])
        let all = parser.parseAll("[著者] タイトル (タグ)", settings: s)
        #expect(all.count == 2)                      // 3 番目は丸括弧始まりなので不一致
        #expect(all[0].fields[.labelGroup(4)]?.text == "タグ")
        #expect(all[1].fields[.title]?.text == "タイトル (タグ)")
    }

    @Test("どれにも一致しなければ空を返す")
    func noMatches() throws {
        let s = try settings(formats: ["[@labelgroup1] @title"])
        #expect(parser.parseAll("括弧のない名前", settings: s).isEmpty)
    }
}

@Suite("nearestFormat — 最も近いフォーマットの推定 [UR2-05][AL-32]")
struct NearestFormatTests {
    let parser = FilenameParser()

    @Test("照合が最も進んだフォーマットを返す")
    func picksFurthest() throws {
        let s = try settings(formats: [
            "(@labelgroup9) [@labelgroup1] @title",   // 先頭で落ちる
            "[@labelgroup1] @title (@labelgroup4)",   // 末尾まで進むが最後で落ちる
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
}

@Suite("ParseResult / FieldRef の補助")
struct ParseResultHelpersTests {
    @Test("labelGroupValues がラベルグループぶんだけ取り出す")
    func labelGroupValues() throws {
        let s = try settings(formats: ["[@labelgroup1] @title (@labelgroup4)"])
        let r = try #require(FilenameParser().parse("[著者] タイトル (タグ)",
                                                     settings: s, purpose: .libraryScan))
        let values = r.labelGroupValues
        #expect(values[1]?.text == "著者")
        #expect(values[4]?.text == "タグ")
        #expect(values.count == 2)          // @title は含まない
    }

    @Test("FieldRef の性質")
    func fieldRefProperties() {
        #expect(FieldRef.title.isFreeText)
        #expect(FieldRef.series.isFreeText)
        #expect(FieldRef.author.isFreeText)
        #expect(FieldRef.labelGroup(1).isFreeText)
        #expect(FieldRef.ignore(0).isFreeText)
        #expect(!FieldRef.volume.isFreeText)
        #expect(!FieldRef.libraryType.isFreeText)
        #expect(!FieldRef.libraryName.isFreeText)

        // 抽出値を捨てるもの [RW-02][RW-04]
        #expect(FieldRef.ignore(0).discardsValue)
        #expect(FieldRef.libraryName.discardsValue)
        #expect(FieldRef.libraryType.discardsValue)
        #expect(!FieldRef.title.discardsValue)
        #expect(!FieldRef.volume.discardsValue)

        // 重複を許すのは @ignore のみ [RW-03]
        #expect(FieldRef.ignore(3).allowsDuplicates)
        #expect(!FieldRef.title.allowsDuplicates)
        #expect(!FieldRef.labelGroup(1).allowsDuplicates)
    }

    @Test("SemanticKeyword は FieldRef に対応する [RW-13]")
    func semanticKeywordMapping() {
        #expect(SemanticKeyword.series.fieldRef == .series)
        #expect(SemanticKeyword.author.fieldRef == .author)
        #expect(SemanticKeyword.allCases.count == 2)
        #expect(SemanticKeyword(rawValue: "@series") == .series)
    }

    @Test("FormatNode の境界判定 [VD-02][VD-03]")
    func nodeBoundaries() {
        #expect(FormatNode.literal("-").isBoundary)
        #expect(!FormatNode.literal("").isBoundary)
        #expect(!FormatNode.whitespace.isBoundary)          // 弾力的空白は境界にならない
        #expect(FormatNode.field(.volume, kind: .volume).isBoundary)
        #expect(FormatNode.field(.libraryType, kind: .enumerated(["A"])).isBoundary)
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
        let s = try separatorSettings(["@series-@labelgroup1"])
        for input in ["シリーズ名-著者名", "シリーズ名 - 著者名", "シリーズ名　－　著者名"] {
            let r = try #require(parser.parse(input, settings: s, purpose: .libraryScan),
                                 "一致しない: \(input)")
            #expect(r.fields[.series]?.text == "シリーズ名")
            #expect(r.fields[.labelGroup(1)]?.text == "著者名")
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
        let s = try settings(formats: ["@series（@volume）-@labelgroup1"],
                             volume: volume, delimiters: d)
        let r = try #require(parser.parse("作品タイトル（１２） - 著者名",
                                          settings: s, purpose: .libraryScan))
        #expect(r.fields[.series]?.text == "作品タイトル")
        #expect(r.fields[.volume]?.volume?.number == 12)
        #expect(r.fields[.labelGroup(1)]?.text == "著者名")
    }
}
