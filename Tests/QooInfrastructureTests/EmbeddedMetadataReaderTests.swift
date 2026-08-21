import Foundation
import Testing

@testable import QooInfrastructure
@testable import QooKit

/// 実ファイルからのメタデータ読み取り [EM-01〜EM-09]。
///
/// **実際にアーカイブ・EPUB・PDF を組み立てて読む。**解釈の規則は
/// `QooKit` 側のテストが固めているので、ここで確かめるのは
/// 「正しいバイト列にたどり着けるか」だけ。
@Suite(.serialized) struct EmbeddedMetadataReaderTests {

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("qoo-meta-read-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func comicInfo(series: String = "シリーズA", number: String = "3",
                                  writer: String = "著者値A") -> Data {
        Data("""
        <?xml version="1.0" encoding="utf-8"?>
        <ComicInfo xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
          <Title>作品名A</Title><Series>\(series)</Series><Number>\(number)</Number>
          <Writer>\(writer)</Writer><PageCount>2</PageCount>
        </ComicInfo>
        """.utf8)
    }

    private func page(_ n: Int) -> ArchiveFixtureBuilder.Entry {
        .file(String(format: "%03d.jpg", n), contents: Data(repeating: UInt8(n), count: 512))
    }

    // MARK: - アーカイブ

    @Test func readsComicInfoFromACbz() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("作品名A.cbz")
        try ArchiveFixtureBuilder.makeZip(at: url, entries: [
            .file("ComicInfo.xml", contents: Self.comicInfo()), page(1), page(2),
        ])
        let m = try #require(await EmbeddedMetadataReader().read(url, kind: .archive(.zip),
                                                                 volumeSource: .ask))
        #expect(m.source == .comicInfo)
        #expect(m.title == "作品名A")
        #expect(m.series == "シリーズA")
        #expect(m.volume == 3)
        #expect(m.authors == ["著者値A"])
    }

    /// ComicInfo は末尾に追記されることが多い（タグ付けツールが後から足す）。
    @Test func readsComicInfoWhenItIsTheLastEntry() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("作品名A.cbz")
        try ArchiveFixtureBuilder.makeZip(at: url, entries: [
            page(1), page(2), .file("ComicInfo.xml", contents: Self.comicInfo(number: "7")),
        ])
        let m = try #require(await EmbeddedMetadataReader().read(url, kind: .archive(.zip)))
        #expect(m.volume == 7)
    }

    @Test func readsComicInfoFromInsideASingleTopLevelFolder() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("作品名A.cbz")
        try ArchiveFixtureBuilder.makeZip(at: url, entries: [
            .file("作品名A/ComicInfo.xml", contents: Self.comicInfo(number: "5")),
            .file("作品名A/001.jpg", contents: Data(repeating: 1, count: 512)),
        ])
        let m = try #require(await EmbeddedMetadataReader().read(url, kind: .archive(.zip)))
        #expect(m.volume == 5)
    }

    @Test func returnsNothingWhenTheArchiveHasNoComicInfo() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("作品名A.cbz")
        try ArchiveFixtureBuilder.makeZip(at: url, entries: [page(1), page(2)])
        #expect(await EmbeddedMetadataReader().read(url, kind: .archive(.zip)) == nil)
    }

    @Test func returnsNothingForABrokenArchive() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("壊れている.cbz")
        try Data("これは zip ではない".utf8).write(to: url)
        #expect(await EmbeddedMetadataReader().read(url, kind: .archive(.zip)) == nil)
    }

    /// 上限を超えるエントリは**開く前に**断る [EM-61]。
    @Test func refusesAnOversizedComicInfo() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("作品名A.cbz")
        let padding = String(repeating: "あ", count: AppLimits.Metadata.maxDocumentBytes)
        let huge = Data("<ComicInfo><Series>シリーズA</Series><Notes>\(padding)</Notes></ComicInfo>".utf8)
        try ArchiveFixtureBuilder.makeZip(at: url, entries: [.file("ComicInfo.xml", contents: huge)])
        #expect(await EmbeddedMetadataReader().read(url, kind: .archive(.zip)) == nil)
    }

    // MARK: - ブックフォルダ

    @Test func readsComicInfoFromABookFolder() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let folder = dir.appendingPathComponent("作品名A", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Self.comicInfo(number: "4").write(to: folder.appendingPathComponent("ComicInfo.xml"))
        try Data(repeating: 1, count: 512).write(to: folder.appendingPathComponent("001.jpg"))

        let m = try #require(await EmbeddedMetadataReader().read(folder, kind: .folder))
        #expect(m.volume == 4)
        #expect(m.series == "シリーズA")
    }

    @Test func matchesTheFolderFileCaseInsensitively() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let folder = dir.appendingPathComponent("作品名A", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Self.comicInfo(number: "6").write(to: folder.appendingPathComponent("comicinfo.xml"))
        let m = try #require(await EmbeddedMetadataReader().read(folder, kind: .folder))
        #expect(m.volume == 6)
    }

    @Test func returnsNothingForAFolderWithoutComicInfo() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(await EmbeddedMetadataReader().read(dir, kind: .folder) == nil)
    }

    // MARK: - EPUB

    @Test func readsMetadataFromAnEpub() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("作品名A.epub")
        let container = Data("""
        <?xml version="1.0"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
        <rootfiles><rootfile full-path="OEBPS/content.opf" \
        media-type="application/oebps-package+xml"/></rootfiles></container>
        """.utf8)
        let opf = Data("""
        <?xml version="1.0"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0">
        <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
        <dc:title>作品名A</dc:title>
        <dc:creator id="c1">著者値A</dc:creator>
        <meta refines="#c1" property="role" scheme="marc:relators">aut</meta>
        <meta property="belongs-to-collection" id="s1">シリーズA</meta>
        <meta refines="#s1" property="collection-type">series</meta>
        <meta refines="#s1" property="group-position">2</meta>
        </metadata><manifest/><spine/></package>
        """.utf8)
        try ArchiveFixtureBuilder.makeZip(at: url, entries: [
            .file("mimetype", contents: Data("application/epub+zip".utf8)),
            .file("META-INF/container.xml", contents: container),
            .file("OEBPS/content.opf", contents: opf),
        ])
        let m = try #require(await EmbeddedMetadataReader().read(url, kind: .epub))
        #expect(m.source == .epub)
        #expect(m.title == "作品名A")
        #expect(m.series == "シリーズA")
        #expect(m.volume == 2)
        #expect(m.authors == ["著者値A"])
    }

    @Test func returnsNothingForAnEpubWithoutAContainer() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("作品名A.epub")
        try ArchiveFixtureBuilder.makeZip(at: url, entries: [
            .file("mimetype", contents: Data("application/epub+zip".utf8)),
        ])
        #expect(await EmbeddedMetadataReader().read(url, kind: .epub) == nil)
    }

    // MARK: - PDF

    @Test func readsTitleAndAuthorFromThePdfInfoDictionary() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("作品名A.pdf")
        // 日本語は UTF-16BE + BOM で書かれる。正しくデコードできることの検証を兼ねる。
        try PDFFixtureBuilder.write(to: url, infoTitle: "作品名A",
                                    infoAuthor: "著者値A, 著者値B", xmp: nil)
        let m = try #require(await EmbeddedMetadataReader().read(url, kind: .pdf))
        #expect(m.source == .pdf)
        #expect(m.title == "作品名A")
        #expect(m.authors == ["著者値A", "著者値B"])
        #expect(m.series == nil)
    }

    /// **`CGContext` は XMP を書かない**ので、フィクスチャを手で組んで検証する。
    @Test func readsSeriesFromTheCalibreXmp() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("作品名A.pdf")
        try PDFFixtureBuilder.write(
            to: url, infoTitle: "辞書の題", infoAuthor: nil,
            xmp: PDFFixtureBuilder.calibreXMP(title: "XMP の題", author: "著者値A",
                                              series: "シリーズA", seriesIndex: "3.00"))
        let m = try #require(await EmbeddedMetadataReader().read(url, kind: .pdf))
        #expect(m.title == "XMP の題")        // XMP を優先 [EM-50]
        #expect(m.series == "シリーズA")
        #expect(m.volume == 3)
        #expect(m.volumeRaw == "3")           // `3.00` をそのまま巻数表記にしない
        #expect(m.authors == ["著者値A"])
    }

    @Test func returnsNothingForAPdfWithoutAnyMetadata() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("作品名A.pdf")
        try PDFFixtureBuilder.write(to: url, infoTitle: nil, infoAuthor: nil, xmp: nil)
        #expect(await EmbeddedMetadataReader().read(url, kind: .pdf) == nil)
    }

    @Test func returnsNothingForABrokenPdf() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("壊れている.pdf")
        try Data("%PDF-1.7\nこれは PDF ではない".utf8).write(to: url)
        #expect(await EmbeddedMetadataReader().read(url, kind: .pdf) == nil)
    }

    // MARK: - 対象外

    @Test(arguments: [PreviewableFileKind.image, .video, .other])
    func readsNothingForKindsThatCannotCarryMetadata(kind: PreviewableFileKind) async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("なにか.bin")
        try Data(repeating: 0, count: 16).write(to: url)
        #expect(await EmbeddedMetadataReader().read(url, kind: kind) == nil)
    }
}
