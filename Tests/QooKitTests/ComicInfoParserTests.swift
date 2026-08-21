import Foundation
import Testing

@testable import QooKit

/// `ComicInfo.xml` の解釈 [EM-20〜EM-28][05章 §5.7]。
///
/// **標本は実物の形にする。**名前空間宣言・`Pages` の入れ子・空要素は実際の
/// ファイルに普通に現れるので、それを含む形で固定する（CLAUDE.md の教訓:
/// きれいな例だけを標本にすると、その分野で最も普通の入力を取りこぼす）。
@Suite struct ComicInfoParserTests {

    /// 実際のタグ付けツールが書き出す形。
    private func document(title: String = "作品名A",
                          series: String = "シリーズA",
                          number: String? = "3",
                          volume: String? = nil,
                          writer: String = "著者値A",
                          extra: String = "") -> Data {
        var body = """
        <?xml version="1.0" encoding="utf-8"?>
        <ComicInfo xmlns:xsd="http://www.w3.org/2001/XMLSchema" \
        xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
          <Title>\(title)</Title>
          <Series>\(series)</Series>
        """
        if let number { body += "\n  <Number>\(number)</Number>" }
        if let volume { body += "\n  <Volume>\(volume)</Volume>" }
        body += """

          <Writer>\(writer)</Writer>
          <Manga>YesAndRightToLeft</Manga>
          <PageCount>200</PageCount>\(extra)
          <Pages>
            <Page Image="0" ImageSize="123456" Type="FrontCover" />
            <Page Image="1" ImageSize="123456" />
          </Pages>
        </ComicInfo>
        """
        return Data(body.utf8)
    }

    // MARK: - 基本

    @Test func readsTheFourFieldsWeCareAbout() throws {
        let m = try #require(ComicInfoParser.parse(document()))
        #expect(m.source == .comicInfo)
        #expect(m.title == "作品名A")
        #expect(m.series == "シリーズA")
        #expect(m.volume == 3)
        #expect(m.volumeRaw == "3")
        #expect(m.authors == ["著者値A"])
        #expect(m.volumeConflict == nil)
    }

    @Test func ignoresElementsNestedInsidePages() throws {
        // `Pages > Page` の中に同名の要素があってもルート直下だけを見る。
        let doc = Data("""
        <?xml version="1.0"?>
        <ComicInfo>
          <Series>本物のシリーズ</Series>
          <Pages><Page Image="0"><Series>まぎらわしい入れ子</Series></Page></Pages>
        </ComicInfo>
        """.utf8)
        let m = try #require(ComicInfoParser.parse(doc))
        #expect(m.series == "本物のシリーズ")
    }

    @Test func acceptsADefaultNamespaceOnTheRoot() throws {
        let doc = Data("""
        <?xml version="1.0"?>
        <ComicInfo xmlns="http://example.invalid/comicinfo">
          <Series>シリーズA</Series><Number>2</Number>
        </ComicInfo>
        """.utf8)
        let m = try #require(ComicInfoParser.parse(doc))
        #expect(m.series == "シリーズA")
        #expect(m.volume == 2)
    }

    // MARK: - 巻数の決着 [EM-23〜EM-26]

    @Test func usesWhicheverSideIsPresentWhenOnlyOneIs() throws {
        let onlyNumber = try #require(ComicInfoParser.parse(document(number: "5", volume: nil)))
        #expect(onlyNumber.volume == 5)
        let onlyVolume = try #require(ComicInfoParser.parse(document(number: nil, volume: "7")))
        #expect(onlyVolume.volume == 7)
    }

    @Test func agreementIsNotAConflict() throws {
        let m = try #require(ComicInfoParser.parse(document(number: "4", volume: "4")))
        #expect(m.volume == 4)
        #expect(m.volumeConflict == nil)
    }

    @Test func disagreementLeavesTheVolumeUndecided() throws {
        let m = try #require(ComicInfoParser.parse(document(number: "12", volume: "2")))
        // [VM3-03] 未確定のままにする。ファイル名由来の値のほうが確からしい。
        #expect(m.volume == nil)
        #expect(m.volumeRaw == nil)
        let conflict = try #require(m.volumeConflict)
        #expect(conflict.number == 12)
        #expect(conflict.volume == 2)
        #expect(conflict.numberRaw == "12")
        #expect(conflict.volumeRaw == "2")
    }

    @Test(arguments: [(ComicInfoVolumeSource.number, 12.0), (.volume, 2.0)])
    func aSettledLibrarySettingResolvesTheDisagreement(source: ComicInfoVolumeSource,
                                                       expected: Double) throws {
        let m = try #require(ComicInfoParser.parse(document(number: "12", volume: "2"),
                                                   volumeSource: source))
        #expect(m.volume == expected)
        #expect(m.volumeConflict == nil)
    }

    /// `-1` は XSD の既定値そのもの。書き出したツールが埋めなかっただけである [EM-23]。
    @Test(arguments: ["-1", "0", "-5", " ", ""])
    func nonPositiveVolumeMeansUnset(raw: String) throws {
        let m = try #require(ComicInfoParser.parse(document(number: nil, volume: raw)))
        #expect(m.volume == nil)
        #expect(m.volumeConflict == nil)
    }

    @Test func aNonPositiveVolumeDoesNotConflictWithANumber() throws {
        let m = try #require(ComicInfoParser.parse(document(number: "3", volume: "-1")))
        #expect(m.volume == 3)
        #expect(m.volumeConflict == nil)
    }

    /// `Number` は `xs:string`。小数の話数を巻数として使う運用がある [EM-24]。
    @Test func fractionalNumbersAreKept() throws {
        let m = try #require(ComicInfoParser.parse(document(number: "3.5", volume: nil)))
        #expect(m.volume == 3.5)
        #expect(m.volumeRaw == "3.5")
    }

    /// 数として読めない値は**巻数として採らない**。0 に丸めると「第 0 巻」という嘘になる。
    @Test(arguments: ["Special", "One-Shot", "1-3", "第3巻", "", "  "])
    func unparsableNumbersAreNotTakenAsVolumes(raw: String) throws {
        let m = try #require(ComicInfoParser.parse(document(number: raw, volume: nil)))
        #expect(m.volume == nil)
    }

    @Test func infinityAndNaNAreRejected() {
        #expect(ComicInfoParser.numericNumber("inf") == nil)
        #expect(ComicInfoParser.numericNumber("nan") == nil)
        #expect(ComicInfoParser.numericVolume("inf") == nil)
    }

    // MARK: - 著者 [EM-27]

    @Test func splitsCommaSeparatedWriters() throws {
        let m = try #require(ComicInfoParser.parse(document(writer: "著者値A, 著者値B,著者値C")))
        #expect(m.authors == ["著者値A", "著者値B", "著者値C"])
    }

    @Test func dropsEmptyEntriesFromTheWriterList() throws {
        let m = try #require(ComicInfoParser.parse(document(writer: "著者値A, ,,著者値B,")))
        #expect(m.authors == ["著者値A", "著者値B"])
    }

    /// `Penciller` 等は v1 では読まない [EM-28]。読むようになったらこのテストを変える。
    @Test func otherCreditRolesAreNotReadYet() throws {
        let m = try #require(ComicInfoParser.parse(
            document(writer: "", extra: "\n  <Penciller>作画値A</Penciller>")))
        #expect(m.authors.isEmpty)
    }

    // MARK: - 壊れた入力・悪意ある入力

    @Test func rejectsDocumentsWhoseRootIsNotComicInfo() {
        let doc = Data("<?xml version=\"1.0\"?><Other><Series>X</Series></Other>".utf8)
        #expect(ComicInfoParser.parse(doc) == nil)
    }

    @Test(arguments: ["", "<ComicInfo><Series>閉じていない", "これは XML ではない",
                      "<?xml version=\"1.0\"?>"])
    func rejectsMalformedInput(raw: String) {
        #expect(ComicInfoParser.parse(Data(raw.utf8)) == nil)
    }

    /// 上限を超える文書は**切り詰めずに諦める** [EM-61]。途中まで読むと、
    /// 閉じタグの無い XML を部分的に解釈して誤った値を採る。
    @Test func rejectsDocumentsOverTheSizeLimit() {
        let padding = String(repeating: "あ", count: AppLimits.Metadata.maxDocumentBytes)
        let doc = Data("<ComicInfo><Series>シリーズA</Series><Notes>\(padding)</Notes></ComicInfo>".utf8)
        #expect(doc.count > AppLimits.Metadata.maxDocumentBytes)
        #expect(ComicInfoParser.parse(doc) == nil)
    }

    /// [EM-60] 外部実体を解決しない。**この検査が落ちたら、ローカルファイルの
    /// 中身がライブラリのシリーズ名として DB に入る経路が開いたということ。**
    @Test func doesNotResolveExternalEntities() throws {
        let secret = FileManager.default.temporaryDirectory
            .appendingPathComponent("qoo-xxe-\(UUID().uuidString).txt")
        try "TOPSECRET".write(to: secret, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: secret) }

        let doc = Data("""
        <?xml version="1.0"?>
        <!DOCTYPE ComicInfo [ <!ENTITY xxe SYSTEM "file://\(secret.path)"> ]>
        <ComicInfo><Series>&xxe;</Series></ComicInfo>
        """.utf8)
        let m = ComicInfoParser.parse(doc)
        #expect(m?.series?.contains("TOPSECRET") != true)
    }

    /// 実体展開の爆発（billion laughs）。libxml2 が拒否する。
    @Test func rejectsEntityExpansionBombs() {
        var doc = "<?xml version=\"1.0\"?>\n<!DOCTYPE ComicInfo [\n<!ENTITY a0 \"AAAAAAAAAA\">\n"
        for i in 1...10 {
            let prev = String(repeating: "&a\(i - 1);", count: 10)
            doc += "<!ENTITY a\(i) \"\(prev)\">\n"
        }
        doc += "]>\n<ComicInfo><Series>&a10;</Series></ComicInfo>"
        #expect(ComicInfoParser.parse(Data(doc.utf8)) == nil)
    }
}
