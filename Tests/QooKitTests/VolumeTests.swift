import Testing
import Foundation
@testable import QooKit

@Suite("VolumePattern のコンパイル [5.1]")
struct VolumePatternCompilerTests {
    @Test("正規表現としてコンパイルされる")
    func compilesRegex() throws {
        let health = RegexPatternHealth()
        let p = try #require(VolumePatternCompiler.compile(
            VolumePattern(source: #"vol\s+([0-9]+)"#), health: health))
        #expect(p.kind == .volume)
        #expect(p.regex.captureGroupCount == 1)
    }

    @Test("読めない正規表現は落とされる")
    func invalidRegexIsDropped() {
        let health = RegexPatternHealth()
        #expect(VolumePatternCompiler.compile(VolumePattern(source: "("), health: health) == nil)
        // 一括コンパイルでも同じ。ここで落とすのは最後の砦で、通常は保存時に弾かれる。
        #expect(VolumePatternCompiler.compileAll([VolumePattern(source: "(")]).isEmpty)
    }

    @Test("区切り専用の種別が保たれる")
    func separatorKindIsKept() throws {
        let out = VolumePatternCompiler.compileAll([
            VolumePattern(source: "上巻", kind: .separator),
        ])
        #expect(out.first?.kind == .separator)
        #expect(out.first?.isSeparator == true)
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

    @Test("`\\s+` は空白 1 個以上を必須とする [SE-23][WS-07]")
    func requiredSpace() {
        let only = VolumePatternCompiler.compileAll([VolumePattern(source: #"vol\s+([0-9]+)"#)])
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
        let only = VolumePatternCompiler.compileAll([VolumePattern(source: #"v([0-9]+)"#)])
        let m = try #require(VolumeMatcher.matchAtEnd(Array("作品 v3"), patterns: only))
        #expect(m.value.number == 3)
    }

    /// 区切り専用は**範囲は返すが巻数は持たない** [2026-08 の仕様変更で序列巻数を廃止]。
    @Test("区切り専用のパターンは巻数を持たない")
    func separatorHasNoVolume() throws {
        let m = try #require(matchEnd("作品 上巻"))
        #expect(m.value.kind == VolumeValue.Kind.none)
        #expect(m.value.number == nil)
        #expect(m.range.count == 2)          // 「上巻」の 2 文字ぶんを切る
    }

    @Test("末尾に届く一致のうち最長を採る [SE-21 の解釈、2026-08]")
    func longestMatchWins() throws {
        let m = try #require(matchEnd("作品 第01巻"))
        #expect(m.value.raw == "第01巻")     // "01巻" ではない
    }

    /// **登録順に対して頑健であること。**仕様書 §5.4 の既定セットは `??巻` を
    /// `第??巻` より先に列挙しており、登録順で決める実装だと `作品 第01巻` が
    /// `01巻` と読まれてシリーズ名が `作品 第` になる。実データの一般コミックは
    /// 94% が `第??巻` なので実害が大きい。
    @Test("パターンの登録順が逆でも同じ結果になる")
    func robustAgainstRegistrationOrder() throws {
        let specOrder = VolumePatternCompiler.compileAll([
            VolumePattern(source: #"([0-9]+)巻"#, priority: 0),
            VolumePattern(source: #"第([0-9]+)巻"#, priority: 1),
        ])
        let reversed = VolumePatternCompiler.compileAll([
            VolumePattern(source: #"第([0-9]+)巻"#, priority: 0),
            VolumePattern(source: #"([0-9]+)巻"#, priority: 1),
        ])
        for patterns in [specOrder, reversed] {
            let out = SeriesExtractor.extract(fromTitle: "作品 第01巻", patterns: patterns)
            #expect(out.seriesName == "作品")
            #expect(out.volume.raw == "第01巻")
        }
    }

    @Test("同じ長さなら登録順が先のものを採る [SE-21]")
    func tieBreakByRegistrationOrder() throws {
        let p = VolumePatternCompiler.compileAll([
            VolumePattern(source: #"v([0-9]+)"#, priority: 0),
            VolumePattern(source: #"V([0-9]+)"#, priority: 1),
        ])
        let m = try #require(VolumeMatcher.matchAtEnd(Array("作品 v3"), patterns: p))
        #expect(m.value.number == 3)
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

    /// キャプチャグループが無い巻数パターンは、値をどこから取るか決まらない。
    /// **巻数 0 と誤って扱うより、一致しなかったことにするほうが害が小さい。**
    @Test("キャプチャの無い巻数パターンは候補にしない")
    func patternWithoutCaptureIsRejected() {
        let junk = VolumePatternCompiler.compileAll([VolumePattern(source: "巻")])
        #expect(VolumeMatcher.matchAtEnd(Array("作品 巻"), patterns: junk) == nil)
    }

    /// キャプチャが数値として読めない場合も同じ。
    @Test("数値にならないキャプチャは候補にしない")
    func nonNumericCaptureIsRejected() {
        let junk = VolumePatternCompiler.compileAll([VolumePattern(source: "第(.)巻")])
        #expect(VolumeMatcher.matchAtEnd(Array("作品 第一巻"), patterns: junk) == nil)
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

    /// 区切り専用の役目はこれ——**巻数は持たないがシリーズ名は切れる**。
    @Test("区切り専用のパターンでもシリーズ名を切り離せる")
    func separatorSeries() {
        let out = SeriesExtractor.extract(fromTitle: "作品名 上巻", patterns: patterns)
        #expect(out.seriesName == "作品名")
        #expect(out.volume.kind == VolumeValue.Kind.none)
    }
}

@Suite("VolumeValue のソート順 [VM-15]")
struct VolumeValueSortTests {
    /// 序列巻数を廃止したので numeric と none の 2 段だけになる。
    @Test("numeric < none の順で安定する")
    func sortOrder() {
        let values: [VolumeValue] = [
            .none,
            .numeric(3, raw: "第03巻"),
            .numeric(1, raw: "第01巻"),
        ]
        let sorted = values.sorted { $0.sortKey < $1.sortKey }
        #expect(sorted.map(\.raw) == ["第01巻", "第03巻", nil])
    }

    @Test("巻数を持たないものは必ず末尾へ")
    func noneSortsLast() {
        #expect(VolumeValue.numeric(999, raw: "999").sortKey < VolumeValue.none.sortKey)
    }
}

// MARK: - 後処理 [4.9][RW-06〜RW-10]

@Suite("FieldPostProcessor [4.9][RW-08][RW-10]")
struct FieldPostProcessorTests {
    let parser = FilenameParser()

    @Test("@series を直接書いた場合、@title から巻数を除去しない [RW-08]")
    func directSeriesSkipsStripping() throws {
        let s = try settings(formats: ["[@circle] @series (@volume)"], volume: vsFull())
        let r = try #require(parser.parse("[著者] シリーズ名 (第03巻)", settings: s))
        let f = FieldPostProcessor.postProcess(r, settings: s)
        #expect(f.seriesName == "シリーズ名")
        #expect(f.volume.number == 3)
        #expect(f.title == nil)          // @title を書いていない [FF-19]
    }

    @Test("@volume のみ直接指定なら @title から巻数相当を除去する [RW-10]")
    func volumeOnlyDerivesSeries() throws {
        let s = try settings(formats: ["[@circle] @title (@volume)"], volume: vsFull())
        let r = try #require(parser.parse("[著者] 作品名 第01巻 (01)", settings: s))
        let f = FieldPostProcessor.postProcess(r, settings: s)
        #expect(f.title == "作品名 第01巻")
        #expect(f.seriesName == "作品名")
        #expect(f.volume.number == 1)     // @volume の値が優先
    }

    @Test("セマンティック予約語はラベル化される [RW-06][SE-06]")
    func semanticBindingCreatesLabel() throws {
        let s = try settings(formats: ["[@circle] @title"],
                             volume: vsFull(), semantic: [.circle: 1, .series: 2])
        let r = try #require(parser.parse("[著者] 作品名 第01巻", settings: s))
        let f = FieldPostProcessor.postProcess(r, settings: s)
        #expect(f.labelValues[1] == ["著者"])
        #expect(f.labelValues[2] == ["作品名"])     // @series 紐づけ先
    }

    @Test("シリーズ名を導けなければラベル化しない [SE-08][SE2-01]")
    func noSeriesNoLabel() throws {
        let s = try settings(formats: ["[@circle] @title"],
                             volume: vsFull(), semantic: [.circle: 1, .series: 2])
        let r = try #require(parser.parse("[著者] 単発作品", settings: s))
        let f = FieldPostProcessor.postProcess(r, settings: s)
        #expect(f.seriesName == nil)
        #expect(f.labelValues[2] == nil)
    }

    @Test("@author は紐づけが無ければラベル化しない [RW-11][RW-16]")
    func authorWithoutBinding() throws {
        // **束縛を空にして呼ぶ**——ヘルパの既定は 5 種を束縛するので、
        // 「束縛が無い」という前提をここで明示しないと検査にならない。
        let s = try settings(formats: ["[@author] @title"], semantic: [:])
        let r = try #require(parser.parse("[佐藤秀峰] 作品名", settings: s))
        let f = FieldPostProcessor.postProcess(r, settings: s)
        #expect(f.authorName == "佐藤秀峰")
        #expect(f.labelValues.isEmpty)
    }

    @Test("@ignore は破棄されラベルにも DB にも残らない [RW-02]")
    func ignoreIsDiscarded() throws {
        let s = try settings(formats: ["[@ignore] [@circle] @title"])
        let r = try #require(parser.parse("[捨てる] [著者] 作品名", settings: s))
        let f = FieldPostProcessor.postProcess(r, settings: s)
        #expect(f.labelValues[1] == ["著者"])
        #expect(f.labelValues.count == 1)
    }
}
