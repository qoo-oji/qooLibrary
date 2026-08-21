import Foundation
import Testing

@testable import QooKit

/// PDF の XMP の解釈 [EM-51][EM-53]。標本は Calibre が実際に書き出す形。
@Suite struct XMPMetadataParserTests {

    private func packet(_ descriptions: String) -> Data {
        Data("""
        <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
        \(descriptions)
         </rdf:RDF>
        </x:xmpmeta>
        <?xpacket end="w"?>
        """.utf8)
    }

    private static let calibreNamespaces = """
    xmlns:calibre="http://calibre-ebook.com/xmp-namespace" \
    xmlns:calibreSI="http://calibre-ebook.com/xmp-namespace-series-index"
    """

    @Test func readsCalibreSeriesAndIndex() throws {
        let m = try #require(XMPMetadataParser.parse(packet("""
          <rdf:Description rdf:about="" \(Self.calibreNamespaces)>
           <calibre:series rdf:parseType="Resource">
            <rdf:value>シリーズA</rdf:value>
            <calibreSI:series_index>3.00</calibreSI:series_index>
           </calibre:series>
           <calibre:title_sort>さくひんめいA</calibre:title_sort>
          </rdf:Description>
        """)))
        #expect(m.source == .pdf)
        #expect(m.series == "シリーズA")
        #expect(m.volume == 3)
        // `3.00` をそのまま巻数表記に使うと「第3.00巻」になる。値から作り直す。
        #expect(m.volumeRaw == "3")
    }

    @Test func keepsFractionalIndexes() throws {
        let m = try #require(XMPMetadataParser.parse(packet("""
          <rdf:Description rdf:about="" \(Self.calibreNamespaces)>
           <calibre:series rdf:parseType="Resource">
            <rdf:value>シリーズA</rdf:value>
            <calibreSI:series_index>2.50</calibreSI:series_index>
           </calibre:series>
          </rdf:Description>
        """)))
        #expect(m.volume == 2.5)
        #expect(m.volumeRaw == "2.5")
    }

    /// `rdf:parseType="Resource"` を使わない長い形式。Calibre 以外のツールが書きうる。
    @Test func readsTheLongFormWithAnRdfDescription() throws {
        let m = try #require(XMPMetadataParser.parse(packet("""
          <rdf:Description rdf:about="" \(Self.calibreNamespaces)>
           <calibre:series>
            <rdf:Description>
             <rdf:value>シリーズA</rdf:value>
             <calibreSI:series_index>4</calibreSI:series_index>
            </rdf:Description>
           </calibre:series>
          </rdf:Description>
        """)))
        #expect(m.series == "シリーズA")
        #expect(m.volume == 4)
    }

    @Test func readsTitleFromAnAltAndCreatorsFromASeq() throws {
        let m = try #require(XMPMetadataParser.parse(packet("""
          <rdf:Description rdf:about="" xmlns:dc="http://purl.org/dc/elements/1.1/">
           <dc:title><rdf:Alt><rdf:li xml:lang="x-default">作品名A</rdf:li></rdf:Alt></dc:title>
           <dc:creator><rdf:Seq><rdf:li>著者値A</rdf:li><rdf:li>著者値B</rdf:li></rdf:Seq></dc:creator>
          </rdf:Description>
        """)))
        #expect(m.title == "作品名A")
        #expect(m.authors == ["著者値A", "著者値B"])
    }

    /// 包まずに直接書く簡略記法。
    @Test func readsTitleWrittenDirectly() throws {
        let m = try #require(XMPMetadataParser.parse(packet("""
          <rdf:Description rdf:about="" xmlns:dc="http://purl.org/dc/elements/1.1/">
           <dc:title>作品名A</dc:title>
           <dc:creator>著者値A</dc:creator>
          </rdf:Description>
        """)))
        #expect(m.title == "作品名A")
        #expect(m.authors == ["著者値A"])
    }

    /// **同じ localName の要素が別の名前空間にある。**名前空間で照合しないと
    /// `calibre:title_sort` や `dc:subject` を取り違える。
    @Test func distinguishesNamespacesWithTheSameLocalName() throws {
        let m = try #require(XMPMetadataParser.parse(packet("""
          <rdf:Description rdf:about="" xmlns:dc="http://purl.org/dc/elements/1.1/" \
        xmlns:other="http://example.invalid/ns">
           <other:title>まぎらわしい題</other:title>
           <other:series>まぎらわしいシリーズ</other:series>
           <dc:title>作品名A</dc:title>
          </rdf:Description>
        """)))
        #expect(m.title == "作品名A")
        #expect(m.series == nil)
    }

    @Test func indexWithoutASeriesNameIsDropped() throws {
        let m = try #require(XMPMetadataParser.parse(packet("""
          <rdf:Description rdf:about="" \(Self.calibreNamespaces) \
        xmlns:dc="http://purl.org/dc/elements/1.1/">
           <dc:title>作品名A</dc:title>
           <calibreSI:series_index>3</calibreSI:series_index>
          </rdf:Description>
        """)))
        #expect(m.series == nil)
        #expect(m.volume == nil)
        #expect(m.title == "作品名A")
    }

    @Test(arguments: ["", "<x:xmpmeta>", "これは XML ではない"])
    func rejectsMalformedInput(raw: String) {
        #expect(XMPMetadataParser.parse(Data(raw.utf8)) == nil)
    }

    @Test func formatsWholeNumbersWithoutADecimalPoint() {
        #expect(XMPMetadataParser.formatIndex(3.0) == "3")
        #expect(XMPMetadataParser.formatIndex(3.5) == "3.5")
        #expect(XMPMetadataParser.formatIndex(0.5) == "0.5")
    }
}

/// XMP と文書情報辞書の合成 [EM-50]。
@Suite struct PDFMetadataComposerTests {

    @Test func infoOnlyGivesTitleAndAuthor() throws {
        let m = try #require(PDFMetadataComposer.compose(
            xmp: nil, info: PDFInfoFields(title: "作品名A", author: "著者値A")))
        #expect(m.title == "作品名A")
        #expect(m.authors == ["著者値A"])
        #expect(m.series == nil)
    }

    @Test func emptyInfoAndNoXmpGivesNothing() {
        #expect(PDFMetadataComposer.compose(xmp: nil, info: PDFInfoFields()) == nil)
    }

    @Test func xmpWins() throws {
        let xmp = EmbeddedMetadata(source: .pdf, title: "XMP の題", series: "シリーズA",
                                   volume: 3, volumeRaw: "3", authors: ["XMP の著者"])
        let m = try #require(PDFMetadataComposer.compose(
            xmp: xmp, info: PDFInfoFields(title: "辞書の題", author: "辞書の著者")))
        #expect(m.title == "XMP の題")
        #expect(m.authors == ["XMP の著者"])
        #expect(m.series == "シリーズA")
    }

    /// **フィールド単位で補う。**XMP がタイトルだけ持つ PDF は実在し、
    /// 「XMP があるなら辞書は見ない」とすると著者を取り落とす。
    @Test func fillsFieldsTheXmpDoesNotHave() throws {
        let xmp = EmbeddedMetadata(source: .pdf, title: "XMP の題")
        let m = try #require(PDFMetadataComposer.compose(
            xmp: xmp, info: PDFInfoFields(title: "辞書の題", author: "辞書の著者A, 辞書の著者B")))
        #expect(m.title == "XMP の題")
        #expect(m.authors == ["辞書の著者A", "辞書の著者B"])
    }

    @Test func anXmpWithNothingUsefulStillFallsBackToTheInfoDictionary() throws {
        let xmp = EmbeddedMetadata(source: .pdf)
        let m = try #require(PDFMetadataComposer.compose(
            xmp: xmp, info: PDFInfoFields(title: "辞書の題")))
        #expect(m.title == "辞書の題")
    }
}
