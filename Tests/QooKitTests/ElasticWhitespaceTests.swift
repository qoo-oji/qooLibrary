import Testing
import Foundation
@testable import QooKit

//
//  弾力的空白とフィールド値のトリム [WS-01〜WS-07][WSI-01〜WSI-03]。
//
//  **ゴールデンデータセットではここを検査できない。**プリセットのフォーマットは
//  いずれも予約語の周りに明示的な空白を持つため、`.whitespace` 節が入力側の空白を
//  すべて食べてしまい、フィールド値の前後に空白が残らない。実際、フィールド値の
//  トリムを外す変異を当てても golden は 1 件も落ちなかった。ここで直接固定する。
//
@Suite("弾力的空白 [WS-01〜WS-07]")
struct ElasticWhitespaceTests {
    let parser = FilenameParser()

    func s(_ formats: [String]) throws -> LibrarySettingsSnapshot {
        try settings(formats: formats, volume: vsFull())
    }

    /// WSI-01: `] @title` `]@title` `]　@title` はいずれも同じ結果になる [WS-02]。
    @Test("フォーマット側の空白の有無・種類によらず同じ結果になる [WS-02][WSI-01]",
          arguments: ["[@circle] @title", "[@circle]@title", "[@circle]　@title"])
    func formatWhitespaceVariantsAgree(_ format: String) throws {
        let settings = try s([format])
        let r = try #require(parser.parse("[著者名] 作品タイトル", settings: settings, purpose: .libraryScan))
        #expect(r.fields[.circle]?.text == "著者名")
        #expect(r.fields[.title]?.text == "作品タイトル")
    }

    /// **空白なしのフォーマットで、入力側に空白があっても値に混ざらない** [WS-05]。
    /// トリムを外すと `" 作品タイトル"` になってここが落ちる。
    @Test("フォーマットに空白が無く入力にあるとき、値の前後の空白を落とす [WS-05]")
    func trimsLeadingSpaceWhenFormatHasNone() throws {
        let settings = try s(["[@circle]@title"])
        for input in ["[著者名] 作品タイトル", "[著者名]　作品タイトル", "[著者名]   作品タイトル"] {
            let r = try #require(parser.parse(input, settings: settings, purpose: .libraryScan),
                                 "\(input)")
            #expect(r.fields[.title]?.text == "作品タイトル", "\(input)")
        }
    }

    @Test("値の末尾の空白も落とす [WS-05]")
    func trimsTrailingSpace() throws {
        let settings = try s(["@title(@keyword)"])
        let r = try #require(parser.parse("作品タイトル (タグ)", settings: settings, purpose: .libraryScan))
        #expect(r.fields[.title]?.text == "作品タイトル")
        #expect(r.fields[.keyword]?.text == "タグ")
    }

    @Test("値の内部の空白は原文のまま残す [WS-05][WSI-03]")
    func keepsInnerWhitespace() throws {
        let settings = try s(["[@circle]@title"])
        let r = try #require(parser.parse("[著者名] 作品  タイトル",
                                          settings: settings, purpose: .libraryScan))
        #expect(r.fields[.title]?.text == "作品  タイトル")     // 2 つのまま
    }

    @Test("入力側に空白が無くても一致する（弾力的空白は 0 個でよい）[WS-01]")
    func zeroWhitespaceMatches() throws {
        let settings = try s(["[@circle] @title"])
        let r = try #require(parser.parse("[著者名]作品タイトル", settings: settings, purpose: .libraryScan))
        #expect(r.fields[.title]?.text == "作品タイトル")
    }

    @Test("全角スペース・タブも空白として扱う [NM-03]")
    func fullwidthAndTabAreWhitespace() throws {
        let settings = try s(["[@circle] @title"])
        for input in ["[著者名]　作品", "[著者名]\t作品", "[著者名] \u{00A0}作品"] {
            let r = try #require(parser.parse(input, settings: settings, purpose: .libraryScan),
                                 "\(input.debugDescription)")
            #expect(r.fields[.title]?.text == "作品", "\(input.debugDescription)")
        }
    }

    /// 巻数フォーマットの `\s+` は **1 個以上**を必須とする [SE-23][WS-07]。
    /// フォーマットのリテラル空白（0 個以上）とは別物であることを固定する。
    @Test("巻数の \\s+ だけは空白 1 個以上を必須とする [SE-23][WS-07]")
    func volumeRequiredSpaceIsNotElastic() throws {
        let only = VolumePatternCompiler.compileAll([VolumePattern(source: #"vol\s+([0-9]+)"#)])
        #expect(VolumeMatcher.matchAtEnd(Array("作品 vol 3"), patterns: only) != nil)
        #expect(VolumeMatcher.matchAtEnd(Array("作品 vol3"), patterns: only) == nil)
    }

    @Test("シリーズ抽出でも末尾の空白を落とす [SE-02]")
    func seriesTrimsTrailingSpace() throws {
        let settings = try s(["[@circle]@title"])
        let r = try #require(parser.parse("[著者名] 作品名　　第01巻",
                                          settings: settings, purpose: .libraryScan))
        let f = FieldPostProcessor.postProcess(r, settings: settings)
        #expect(f.title == "作品名　　第01巻")      // タイトルは原文のまま [WS-05]
        #expect(f.seriesName == "作品名")            // シリーズは末尾をトリム [SE-02]
    }

    @Test("フォーマットの保存時に空白が畳まれる [WS-03][WS-04]")
    func formatWhitespaceNormalizedOnSave() throws {
        let a = try FormatCompiler.compile("[@circle]  　\t@title",
                                            context: FormatCompilationContext())
        #expect(a.source == "[@circle] @title")
    }
}
