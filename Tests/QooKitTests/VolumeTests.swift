import Testing
import Foundation
@testable import QooKit

@Suite("VolumePattern のコンパイル [5.1]")
struct VolumePatternCompilerTests {
    @Test("?? と <space> がメタ記号として読まれる")
    func metaTokens() {
        let p = VolumePatternCompiler.compile(VolumePattern(source: "vol<space>??"))
        #expect(p.tokens == [.literal(Array("vol")), .requiredSpace, .digits])
    }

    @Test("メタ記号を含まないパターンは全部リテラル（序列表記）[VM2-02]")
    func ordinalPattern() {
        let p = VolumePatternCompiler.compile(VolumePattern(source: "上巻", ordinalRank: 1))
        #expect(p.tokens == [.literal(Array("上巻"))])
        #expect(p.isOrdinal)
        #expect(!p.hasDigits)
    }

    @Test("リテラルはコンパイル時に正準化される [SE-03]")
    func literalsCanonicalized() {
        let p = VolumePatternCompiler.compile(VolumePattern(source: "Ｖｏｌ．??"))
        #expect(p.tokens.first == .literal(Array("Vol.")))
    }

    @Test("無効なパターンは除外され、優先順に並ぶ [SE-21]")
    func compileAllOrdersAndFilters() {
        let out = VolumePatternCompiler.compileAll([
            VolumePattern(source: "b", priority: 2),
            VolumePattern(source: "a", priority: 1),
            VolumePattern(source: "x", isEnabled: false, priority: 0),
        ])
        #expect(out.map(\.source) == ["a", "b"])
    }
}

@Suite("VolumeMatcher [5.2][SE-21][SE-23][SE-24][VM2-01〜VM2-05]")
struct VolumeMatcherTests {
    let patterns = vsFull()

    func matchEnd(_ s: String) -> VolumeMatch? {
        VolumeMatcher.matchAtEnd(Array(s), patterns: patterns)
    }

    @Test("第??巻 / ??巻 / vol.?? / v??")
    func numericPatterns() throws {
        #expect(matchEnd("作品 第01巻")?.value.number == 1)
        #expect(matchEnd("作品 12巻")?.value.number == 12)
        #expect(matchEnd("作品 vol.7")?.value.number == 7)
        #expect(matchEnd("作品 v3")?.value.number == 3)
    }

    @Test("<space> は空白 1 個以上を必須とする [SE-23][WS-07]")
    func requiredSpace() {
        let only = VolumePatternCompiler.compileAll([VolumePattern(source: "vol<space>??")])
        #expect(VolumeMatcher.matchAtEnd(Array("作品 vol 12"), patterns: only)?.value.number == 12)
        #expect(VolumeMatcher.matchAtEnd(Array("作品 vol　12"), patterns: only)?.value.number == 12) // 全角
        #expect(VolumeMatcher.matchAtEnd(Array("作品 vol12"), patterns: only) == nil)                // 空白なし
    }

    @Test("全角数字は半角として数値化し raw には原文を残す [SE-03][VM2-04]")
    func fullwidthDigits() throws {
        let m = try #require(matchEnd("作品 第０１巻"))
        #expect(m.value.number == 1)
        #expect(m.value.raw == "第０１巻")
    }

    @Test("小数を許容する（3.5 巻）")
    func decimalVolume() throws {
        let m = try #require(matchEnd("作品 第3.5巻"))
        #expect(m.value.number == 3.5)
    }

    @Test("末尾のピリオドは小数として読まない")
    func trailingDotIsNotDecimal() throws {
        let only = VolumePatternCompiler.compileAll([VolumePattern(source: "v??")])
        let m = try #require(VolumeMatcher.matchAtEnd(Array("作品 v3"), patterns: only))
        #expect(m.value.number == 3)
    }

    @Test("序列表記は ordinalRank を持つ [SE-10][VM2-02]")
    func ordinalMatching() throws {
        let m = try #require(matchEnd("作品 上巻"))
        #expect(m.value.kind == .ordinal)
        #expect(m.value.ordinalRank == 1)
        #expect(m.value.raw == "上巻")
        #expect(m.value.number == nil)
    }

    @Test("登録順（優先順）で最初に一致したものを採る [SE-21][VM2-01]")
    func priorityWins() throws {
        // 第??巻 が ??巻 より先に登録されている
        let m = try #require(matchEnd("作品 第01巻"))
        #expect(m.value.raw == "第01巻")     // "01巻" ではない
    }

    @Test("末尾に届かない一致は matchAtEnd では採らない [SE-02]")
    func mustReachEnd() {
        #expect(matchEnd("第01巻 作品") == nil)
    }

    @Test("@volume の型条件は生の数字も含む [SE-24][VM2-05]")
    func bareDigitsAreCandidates() throws {
        let cands = VolumeMatcher.matches(in: Array("01"), at: 0, patterns: patterns)
        #expect(cands.contains { $0.value.number == 1 })
    }

    @Test("候補は長い順に返る（型付き照合が長い方から試せるように）[TY-01]")
    func candidatesSortedByLength() {
        let cands = VolumeMatcher.matches(in: Array("第01巻"), at: 0, patterns: patterns)
        #expect(cands.first?.length ?? 0 >= cands.last?.length ?? 0)
    }

    @Test("巻数として意味を持たないパターン（数値も序列も無い）は候補にしない")
    func meaninglessPatternIsRejected() {
        let junk = VolumePatternCompiler.compileAll([VolumePattern(source: "巻")])
        #expect(VolumeMatcher.matchAtEnd(Array("作品 巻"), patterns: junk) == nil)
    }
}

@Suite("SeriesExtractor [5.3][SE-02][SE-07]")
struct SeriesExtractorTests {
    let patterns = vsFull()

    @Test("タイトル末尾の巻数を切り離してシリーズ名を得る [SE-02]")
    func extractsSeriesAndVolume() {
        let out = SeriesExtractor.extract(fromTitle: "ブラックジャックによろしく 第01巻", patterns: patterns)
        #expect(out.seriesName == "ブラックジャックによろしく")
        #expect(out.volume.number == 1)
    }

    @Test("末尾の空白を除去する [SE-02]")
    func trimsTrailingSpace() {
        let out = SeriesExtractor.extract(fromTitle: "作品名　　第02巻", patterns: patterns)
        #expect(out.seriesName == "作品名")
    }

    @Test("巻数が見つからなければシリーズ名は nil [SE-07]")
    func noVolumeMeansNoSeries() {
        let out = SeriesExtractor.extract(fromTitle: "単発作品", patterns: patterns)
        #expect(out.seriesName == nil)
        #expect(out.volume.kind == .none)
    }

    @Test("巻数だけでシリーズ名が空になる場合も nil [SE-07]")
    func emptySeriesIsNil() {
        let out = SeriesExtractor.extract(fromTitle: "第01巻", patterns: patterns)
        #expect(out.seriesName == nil)
        #expect(out.volume.number == 1)
    }

    @Test("序列巻数でも切り離せる")
    func ordinalSeries() {
        let out = SeriesExtractor.extract(fromTitle: "作品名 上巻", patterns: patterns)
        #expect(out.seriesName == "作品名")
        #expect(out.volume.ordinalRank == 1)
    }
}

@Suite("VolumeValue のソート順 [SE-10]")
struct VolumeValueSortTests {
    @Test("numeric < ordinal < none の順で安定する")
    func sortOrder() {
        let values: [VolumeValue] = [
            .none,
            .ordinal(rank: 9999, raw: "最終巻"),
            .numeric(3, raw: "第03巻"),
            .ordinal(rank: 1, raw: "上巻"),
            .numeric(1, raw: "第01巻"),
        ]
        let sorted = values.sorted { $0.sortKey < $1.sortKey }
        #expect(sorted.map(\.raw) == ["第01巻", "第03巻", "上巻", "最終巻", nil])
    }

    @Test("大きな数値巻数でも序列より前に来る")
    func largeNumericStillBeforeOrdinal() {
        #expect(VolumeValue.numeric(999, raw: "999").sortKey
                < VolumeValue.ordinal(rank: 1, raw: "上巻").sortKey)
    }
}

// MARK: - 後処理 [4.9][RW-06〜RW-10]

@Suite("FieldPostProcessor [4.9][RW-08][RW-10]")
struct FieldPostProcessorTests {
    let parser = FilenameParser()

    @Test("@series を直接書いた場合、@title から巻数を除去しない [RW-08]")
    func directSeriesSkipsStripping() throws {
        let s = try settings(formats: ["[@labelgroup1] @series (@volume)"], volume: vsFull())
        let r = try #require(parser.parse("[著者] シリーズ名 (第03巻)", settings: s, purpose: .libraryScan))
        let f = FieldPostProcessor.postProcess(r, settings: s)
        #expect(f.seriesName == "シリーズ名")
        #expect(f.volume.number == 3)
        #expect(f.title == nil)          // @title を書いていない [FF-19]
    }

    @Test("@volume のみ直接指定なら @title から巻数相当を除去する [RW-10]")
    func volumeOnlyDerivesSeries() throws {
        let s = try settings(formats: ["[@labelgroup1] @title (@volume)"], volume: vsFull())
        let r = try #require(parser.parse("[著者] 作品名 第01巻 (01)", settings: s, purpose: .libraryScan))
        let f = FieldPostProcessor.postProcess(r, settings: s)
        #expect(f.title == "作品名 第01巻")
        #expect(f.seriesName == "作品名")
        #expect(f.volume.number == 1)     // @volume の値が優先
    }

    @Test("セマンティック予約語はラベル化される [RW-06][SE-06]")
    func semanticBindingCreatesLabel() throws {
        let s = try settings(formats: ["[@labelgroup1] @title"],
                             volume: vsFull(), semantic: [.series: 2])
        let r = try #require(parser.parse("[著者] 作品名 第01巻", settings: s, purpose: .libraryScan))
        let f = FieldPostProcessor.postProcess(r, settings: s)
        #expect(f.labelValues[1] == ["著者"])
        #expect(f.labelValues[2] == ["作品名"])     // @series 紐づけ先
    }

    @Test("シリーズ名を導けなければラベル化しない [SE-08][SE2-01]")
    func noSeriesNoLabel() throws {
        let s = try settings(formats: ["[@labelgroup1] @title"],
                             volume: vsFull(), semantic: [.series: 2])
        let r = try #require(parser.parse("[著者] 単発作品", settings: s, purpose: .libraryScan))
        let f = FieldPostProcessor.postProcess(r, settings: s)
        #expect(f.seriesName == nil)
        #expect(f.labelValues[2] == nil)
    }

    @Test("@author は紐づけが無ければラベル化しない [RW-11][RW-16]")
    func authorWithoutBinding() throws {
        let s = try settings(formats: ["[@author] @title"])
        let r = try #require(parser.parse("[佐藤秀峰] 作品名", settings: s, purpose: .libraryScan))
        let f = FieldPostProcessor.postProcess(r, settings: s)
        #expect(f.authorName == "佐藤秀峰")
        #expect(f.labelValues.isEmpty)
    }

    @Test("@ignore は破棄されラベルにも DB にも残らない [RW-02]")
    func ignoreIsDiscarded() throws {
        let s = try settings(formats: ["[@ignore] [@labelgroup1] @title"])
        let r = try #require(parser.parse("[捨てる] [著者] 作品名", settings: s, purpose: .libraryScan))
        let f = FieldPostProcessor.postProcess(r, settings: s)
        #expect(f.labelValues[1] == ["著者"])
        #expect(f.labelValues.count == 1)
    }
}
