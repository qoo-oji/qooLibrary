import Foundation
import Testing

@testable import QooKit

/// EPUB の package document（OPF）の解釈 [EM-40〜EM-46]。
@Suite struct OPFMetadataParserTests {

    private func package(_ metadata: String, version: String = "3.0") -> Data {
        Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="\(version)" \
        unique-identifier="pub-id" xml:lang="ja">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:identifier id="pub-id">urn:uuid:00000000-0000-0000-0000-000000000000</dc:identifier>
            <dc:language>ja</dc:language>
        \(metadata)
          </metadata>
          <manifest><item id="i1" href="p001.xhtml" media-type="application/xhtml+xml"/></manifest>
          <spine page-progression-direction="rtl"><itemref idref="i1"/></spine>
        </package>
        """.utf8)
    }

    // MARK: - EPUB 3 [EM-41][EM-43][EM-44]

    @Test func readsEpub3CollectionAndPosition() throws {
        let m = try #require(OPFMetadataParser.parse(package("""
            <dc:title id="t1">作品名A</dc:title>
            <dc:creator id="c1">著者値A</dc:creator>
            <meta refines="#c1" property="role" scheme="marc:relators">aut</meta>
            <meta property="belongs-to-collection" id="s1">シリーズA</meta>
            <meta refines="#s1" property="collection-type">series</meta>
            <meta refines="#s1" property="group-position">3</meta>
        """)))
        #expect(m.source == .epub)
        #expect(m.title == "作品名A")
        #expect(m.series == "シリーズA")
        #expect(m.volume == 3)
        #expect(m.volumeRaw == "3")
        #expect(m.authors == ["著者値A"])
    }

    /// 副題や叢書名も `dc:title` として並ぶ。**最初のものが本題とは限らない** [EM-41]。
    @Test func prefersTheTitleMarkedAsMain() throws {
        let m = try #require(OPFMetadataParser.parse(package("""
            <dc:title id="t1">副題B</dc:title>
            <meta refines="#t1" property="title-type">subtitle</meta>
            <dc:title id="t2">作品名A</dc:title>
            <meta refines="#t2" property="title-type">main</meta>
        """)))
        #expect(m.title == "作品名A")
    }

    @Test func fallsBackToTheFirstTitleWhenNoneIsMarkedMain() throws {
        let m = try #require(OPFMetadataParser.parse(package("""
            <dc:title>作品名A</dc:title>
            <dc:title>作品名B</dc:title>
        """)))
        #expect(m.title == "作品名A")
    }

    /// `collection-type` の指定が無いものは `series` と見なす [EM-44]。実際の EPUB では省かれる。
    @Test func treatsAnUntypedCollectionAsASeries() throws {
        let m = try #require(OPFMetadataParser.parse(package("""
            <meta property="belongs-to-collection" id="s1">シリーズA</meta>
            <meta refines="#s1" property="group-position">2</meta>
        """)))
        #expect(m.series == "シリーズA")
        #expect(m.volume == 2)
    }

    /// `set`（作品集）をシリーズ名として採ると、別の作品どうしが同じシリーズに見える [EM-44]。
    @Test func doesNotTakeASetAsASeries() throws {
        let m = try #require(OPFMetadataParser.parse(package("""
            <meta property="belongs-to-collection" id="s1">全集A</meta>
            <meta refines="#s1" property="collection-type">set</meta>
            <meta refines="#s1" property="group-position">4</meta>
        """)))
        #expect(m.series == nil)
        #expect(m.volume == nil)
    }

    @Test func picksTheSeriesCollectionWhenBothKindsArePresent() throws {
        let m = try #require(OPFMetadataParser.parse(package("""
            <meta property="belongs-to-collection" id="s0">全集A</meta>
            <meta refines="#s0" property="collection-type">set</meta>
            <meta refines="#s0" property="group-position">9</meta>
            <meta property="belongs-to-collection" id="s1">シリーズA</meta>
            <meta refines="#s1" property="collection-type">series</meta>
            <meta refines="#s1" property="group-position">3</meta>
        """)))
        #expect(m.series == "シリーズA")
        #expect(m.volume == 3)
    }

    // MARK: - 著者 [EM-42]

    @Test func readsTheLegacyOpfRoleAttribute() throws {
        let m = try #require(OPFMetadataParser.parse(package("""
            <dc:creator opf:role="aut" opf:file-as="チョシャアタイ" \
        xmlns:opf="http://www.idpf.org/2007/opf">著者値A</dc:creator>
        """, version: "2.0")))
        #expect(m.authors == ["著者値A"])
    }

    /// 役割を書かない EPUB が多い。そこで諦めると大半で著者が取れない [EM-42]。
    @Test func treatsUnroledCreatorsAsAuthors() throws {
        let m = try #require(OPFMetadataParser.parse(package("""
            <dc:creator>著者値A</dc:creator>
            <dc:creator>著者値B</dc:creator>
        """)))
        #expect(m.authors == ["著者値A", "著者値B"])
    }

    /// 他の役割が明示されているものは著者にしない。
    @Test func excludesCreatorsWithANonAuthorRole() throws {
        let m = try #require(OPFMetadataParser.parse(package("""
            <dc:creator id="c1">著者値A</dc:creator>
            <meta refines="#c1" property="role" scheme="marc:relators">aut</meta>
            <dc:creator id="c2">挿絵値A</dc:creator>
            <meta refines="#c2" property="role" scheme="marc:relators">ill</meta>
        """)))
        #expect(m.authors == ["著者値A"])
    }

    @Test func whenNoAuthorIsMarkedOnlyUnroledCreatorsAreUsed() throws {
        let m = try #require(OPFMetadataParser.parse(package("""
            <dc:creator id="c1">挿絵値A</dc:creator>
            <meta refines="#c1" property="role" scheme="marc:relators">ill</meta>
            <dc:creator>著者値A</dc:creator>
        """)))
        #expect(m.authors == ["著者値A"])
    }

    /// `scheme` が別の語彙を指すなら、その `role` は marc の役割コードではない。
    @Test func ignoresRolesFromAnotherVocabulary() throws {
        let m = try #require(OPFMetadataParser.parse(package("""
            <dc:creator id="c1">著者値A</dc:creator>
            <meta refines="#c1" property="role" scheme="onix:codelist17">A01</meta>
        """)))
        #expect(m.authors == ["著者値A"])   // 役割不明 → 著者として扱う
    }

    // MARK: - Calibre 独自拡張 [EM-45][EM-46]

    @Test func readsCalibreSeriesFromLegacyMeta() throws {
        let m = try #require(OPFMetadataParser.parse(package("""
            <dc:title>作品名A</dc:title>
            <meta name="calibre:series" content="シリーズA"/>
            <meta name="calibre:series_index" content="3"/>
        """, version: "2.0")))
        #expect(m.series == "シリーズA")
        #expect(m.volume == 3)
    }

    @Test func prefersEpub3OverCalibreWhenBothArePresent() throws {
        let m = try #require(OPFMetadataParser.parse(package("""
            <meta property="belongs-to-collection" id="s1">標準のシリーズ</meta>
            <meta refines="#s1" property="group-position">3</meta>
            <meta name="calibre:series" content="Calibre のシリーズ"/>
            <meta name="calibre:series_index" content="9"/>
        """)))
        #expect(m.series == "標準のシリーズ")
        #expect(m.volume == 3)
    }

    @Test func fractionalCalibreIndexIsKept() throws {
        let m = try #require(OPFMetadataParser.parse(package("""
            <meta name="calibre:series" content="シリーズA"/>
            <meta name="calibre:series_index" content="2.5"/>
        """)))
        #expect(m.volume == 2.5)
    }

    /// シリーズ名が無ければ巻数だけ持っていても意味を成さない。
    @Test func indexWithoutASeriesNameIsDropped() throws {
        let m = try #require(OPFMetadataParser.parse(package("""
            <dc:title>作品名A</dc:title>
            <meta name="calibre:series_index" content="3"/>
        """)))
        #expect(m.series == nil)
        #expect(m.volume == nil)
        #expect(m.title == "作品名A")
    }

    @Test func aPositionThatIsNotANumberIsDropped() throws {
        let m = try #require(OPFMetadataParser.parse(package("""
            <meta property="belongs-to-collection" id="s1">シリーズA</meta>
            <meta refines="#s1" property="group-position">上巻</meta>
        """)))
        #expect(m.series == "シリーズA")
        #expect(m.volume == nil)
    }

    // MARK: - 壊れた入力

    @Test func rejectsDocumentsWithoutAMetadataElement() {
        let doc = Data("<?xml version=\"1.0\"?><package><manifest/></package>".utf8)
        #expect(OPFMetadataParser.parse(doc) == nil)
    }

    @Test(arguments: ["", "<package><metadata>", "これは XML ではない"])
    func rejectsMalformedInput(raw: String) {
        #expect(OPFMetadataParser.parse(Data(raw.utf8)) == nil)
    }

    @Test func emptyMetadataYieldsAnEmptyResultRatherThanNil() throws {
        // 「読んだが中身が無かった」は `nil`（読めなかった）とは別。
        // キャッシュに残さないと毎回開き直すことになる [SE3-25]。
        let m = try #require(OPFMetadataParser.parse(package("")))
        #expect(m.isEmpty)
    }
}
