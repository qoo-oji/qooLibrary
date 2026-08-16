import Foundation
import Testing

@testable import QooInfrastructure

@Suite struct EpubCoverResolverTests {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("qoo-epub-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static let containerXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
      <rootfiles>
        <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
      </rootfiles>
    </container>
    """

    /// spine の先頭項目が画像そのものを直接指す、最も単純なケース。
    @Test func resolvesCoverWhenSpineItemIsAnImageDirectly() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let epubURL = root.appendingPathComponent("book.epub")

        let opf = """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0">
          <manifest>
            <item id="page1" href="images/page1.png" media-type="image/png"/>
          </manifest>
          <spine>
            <itemref idref="page1"/>
          </spine>
        </package>
        """
        let imageData = TestImageFixture.makePNGData(width: 30, height: 40, red: 0, green: 1, blue: 0)

        try ArchiveFixtureBuilder.makeZip(at: epubURL, entries: [
            .file("META-INF/container.xml", contents: Data(Self.containerXML.utf8)),
            .file("OEBPS/content.opf", contents: Data(opf.utf8)),
            .file("OEBPS/images/page1.png", contents: imageData),
        ])

        let result = await EpubCoverResolver.firstPageImageData(for: epubURL, maxBytes: 10_000_000)

        #expect(result == imageData)
    }

    /// [2026-08 全体点検] 同名エントリを 2 つ持つ zip でクラッシュしないこと。
    /// 以前は `Dictionary(uniqueKeysWithValues:)` がキー重複で fatalError して
    /// おり、更新エントリを追記した形の zip（現実にあり得る）のサムネイル生成で
    /// アプリごと落ちていた。重複時は先頭側が読まれる（`readEntry` が先頭から
    /// 走査して最初の一致を返すため。実装コメント参照）。
    @Test func survivesDuplicateEntryNamesAndReadsTheFirstOne() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let epubURL = root.appendingPathComponent("book.epub")

        let opf = """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0">
          <manifest>
            <item id="page1" href="images/page1.png" media-type="image/png"/>
          </manifest>
          <spine>
            <itemref idref="page1"/>
          </spine>
        </package>
        """
        let older = TestImageFixture.makePNGData(width: 10, height: 10, red: 1, green: 0, blue: 0)
        let newer = TestImageFixture.makePNGData(width: 10, height: 10, red: 0, green: 0, blue: 1)

        try ArchiveFixtureBuilder.makeZip(at: epubURL, entries: [
            .file("META-INF/container.xml", contents: Data(Self.containerXML.utf8)),
            .file("OEBPS/content.opf", contents: Data(opf.utf8)),
            .file("OEBPS/images/page1.png", contents: older),
            .file("OEBPS/images/page1.png", contents: newer),
        ])

        let result = await EpubCoverResolver.firstPageImageData(for: epubURL, maxBytes: 10_000_000)

        #expect(result == older)
        #expect(result != newer)
    }

    /// spine の先頭項目が XHTML ラッパーで、その中の最初の <img> を辿って
    /// 画像を特定する必要があるケース [qooViewer の resolveImagePath と
    /// 同じフォールバック規則]。
    @Test func resolvesCoverThroughXHTMLWrapper() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let epubURL = root.appendingPathComponent("book.epub")

        let opf = """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0">
          <manifest>
            <item id="page1" href="text/page1.xhtml" media-type="application/xhtml+xml"/>
            <item id="img1" href="images/page1.png" media-type="image/png"/>
          </manifest>
          <spine>
            <itemref idref="page1"/>
          </spine>
        </package>
        """
        let xhtml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml"><body><img src="../images/page1.png"/></body></html>
        """
        let imageData = TestImageFixture.makePNGData(width: 30, height: 40, red: 0, green: 0, blue: 1)

        try ArchiveFixtureBuilder.makeZip(at: epubURL, entries: [
            .file("META-INF/container.xml", contents: Data(Self.containerXML.utf8)),
            .file("OEBPS/content.opf", contents: Data(opf.utf8)),
            .file("OEBPS/text/page1.xhtml", contents: Data(xhtml.utf8)),
            .file("OEBPS/images/page1.png", contents: imageData),
        ])

        let result = await EpubCoverResolver.firstPageImageData(for: epubURL, maxBytes: 10_000_000)

        #expect(result == imageData)
    }

    @Test func returnsNilWhenContainerXMLIsMissing() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let epubURL = root.appendingPathComponent("notAnEpub.epub")
        try ArchiveFixtureBuilder.makeZip(at: epubURL, entries: [
            .file("readme.txt", contents: Data("hello".utf8)),
        ])

        let result = await EpubCoverResolver.firstPageImageData(for: epubURL, maxBytes: 10_000_000)

        #expect(result == nil)
    }

    @Test func returnsNilWhenSpineHasNoResolvableImage() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let epubURL = root.appendingPathComponent("textOnly.epub")

        let opf = """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0">
          <manifest>
            <item id="page1" href="text/page1.xhtml" media-type="application/xhtml+xml"/>
          </manifest>
          <spine>
            <itemref idref="page1"/>
          </spine>
        </package>
        """
        let xhtml = "<html xmlns=\"http://www.w3.org/1999/xhtml\"><body><p>No images here.</p></body></html>"

        try ArchiveFixtureBuilder.makeZip(at: epubURL, entries: [
            .file("META-INF/container.xml", contents: Data(Self.containerXML.utf8)),
            .file("OEBPS/content.opf", contents: Data(opf.utf8)),
            .file("OEBPS/text/page1.xhtml", contents: Data(xhtml.utf8)),
        ])

        let result = await EpubCoverResolver.firstPageImageData(for: epubURL, maxBytes: 10_000_000)

        #expect(result == nil)
    }
}
