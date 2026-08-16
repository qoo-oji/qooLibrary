import Foundation
import Testing

@testable import QooInfrastructure
@testable import QooKit

/// 「中の先頭画像 1 枚」の解決。`ThumbnailService`（アイコン表示）と
/// `QuickLookCoverStore`（Quick Look の独自プレビュー）が共有する唯一の
/// 解決点なので、種別ごとの振る舞いを直接押さえておく。
///
/// 生成結果（デコード済みサムネイル）まで含めた経路は `ThumbnailServiceTests`
/// が、実ファイルとしての書き出しは `QuickLookCoverStoreTests` が見ているため、
/// ここでは「どのバイト列を返すか／返さないか」だけに絞る。
@Suite struct CoverImageSourceResolverTests {
    // MARK: - フォルダのカバー元（複数）[ユーザー要望]

    @Test func coverSourceChildrenTakesPreviewableFilesInNaturalOrder() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("qoo-coversources-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        // 対象になるもの（画像・アーカイブ・PDF・EPUB）と、ならないもの。
        for name in ["book10.cbz", "book2.cbz", "cover.png", "notes.txt", "doc.pdf", "e.epub"] {
            try Data("x".utf8).write(to: root.appendingPathComponent(name))
        }
        // サブフォルダは対象外（ユーザー指定: 「直下に」）。
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("subfolder", isDirectory: true), withIntermediateDirectories: true
        )

        let picked = await CoverImageSourceResolver.coverSourceChildren(for: root, limit: 10)
            .map(\.lastPathComponent)

        // 自然順: book2 が book10 より前。txt とサブフォルダは含まれない。
        #expect(picked == ["book2.cbz", "book10.cbz", "cover.png", "doc.pdf", "e.epub"])
    }

    @Test func coverSourceChildrenRespectsTheLimit() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("qoo-coversources-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for index in 1...6 {
            try Data("x".utf8).write(to: root.appendingPathComponent("p\(index).png"))
        }

        #expect(await CoverImageSourceResolver.coverSourceChildren(for: root, limit: 3).count == 3)
        #expect(await CoverImageSourceResolver.coverSourceChildren(for: root, limit: 0).isEmpty)
    }

    @Test func coverSourceChildrenIsEmptyForAFolderOfOnlySubfolders() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("qoo-coversources-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("child", isDirectory: true), withIntermediateDirectories: true
        )

        #expect(await CoverImageSourceResolver.coverSourceChildren(for: root).isEmpty)
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("qoo-cover-source-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func picksTheNaturalOrderFirstImageInAFolder() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        // 文字列順では "page10" が "page2" より前に来るが、自然順では page2 が先。
        let expected = TestImageFixture.makePNGData(width: 10, height: 10, red: 1)
        try Data("readme".utf8).write(to: root.appendingPathComponent("00-readme.txt"))
        try TestImageFixture.makePNGData(width: 10, height: 10, red: 0).write(to: root.appendingPathComponent("page10.png"))
        try expected.write(to: root.appendingPathComponent("page2.png"))

        #expect(await CoverImageSourceResolver.firstImageData(for: root) == expected)
    }

    @Test func picksTheNaturalOrderFirstImageEntryInAnArchive() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let archiveURL = root.appendingPathComponent("book.cbz")
        let expected = TestImageFixture.makePNGData(width: 10, height: 10, red: 1)
        try ArchiveFixtureBuilder.makeZip(at: archiveURL, entries: [
            .file("page10.png", contents: TestImageFixture.makePNGData(width: 10, height: 10, red: 0)),
            .file("page2.png", contents: expected),
            .file("notes.txt", contents: Data("ignore me".utf8)),
        ])

        #expect(await CoverImageSourceResolver.firstImageData(for: archiveURL) == expected)
    }

    @Test func returnsTheFileItselfForAPlainImage() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let expected = TestImageFixture.makePNGData(width: 5, height: 5)
        let imageURL = root.appendingPathComponent("photo.png")
        try expected.write(to: imageURL)

        #expect(await CoverImageSourceResolver.firstImageData(for: imageURL) == expected)
    }

    /// 動画・PDF は「中から画像バイト列を取り出す」対象ではなく、専用の
    /// レンダラ（`VideoThumbnailLoading`/`PDFThumbnailLoading`）を通す。
    /// この解決器はそれらを扱わないことを明示しておく。
    @Test func returnsNilForKindsThatHaveTheirOwnRenderer() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let videoURL = root.appendingPathComponent("clip.mp4")
        let pdfURL = root.appendingPathComponent("doc.pdf")
        let textURL = root.appendingPathComponent("notes.txt")
        for url in [videoURL, pdfURL, textURL] {
            try Data("placeholder".utf8).write(to: url)
        }

        #expect(await CoverImageSourceResolver.firstImageData(for: videoURL) == nil)
        #expect(await CoverImageSourceResolver.firstImageData(for: pdfURL) == nil)
        #expect(await CoverImageSourceResolver.firstImageData(for: textURL) == nil)
    }

    /// [2026-08 全体点検 F1] 素の画像ファイルにも読み込み上限が効くこと。
    /// アーカイブ内・EPUB は `maxEntryReadBytes` で守られているのに素の画像
    /// だけ無上限だと、誤った拡張子の巨大ファイル（動画を .jpg にした等）で
    /// 全量が RAM へ載る。関門（`readImageFileWithinLimit`）を外すと
    /// この 2 件はどちらも「データが返ってきてしまう」形で落ちる。
    @Test func refusesAPlainImageFileLargerThanTheReadLimit() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let imageURL = root.appendingPathComponent("huge.png")
        let contents = TestImageFixture.makePNGData(width: 10, height: 10)
        try contents.write(to: imageURL)

        #expect(await CoverImageSourceResolver.firstImageData(for: imageURL, maxEntryReadBytes: 10) == nil)
        // 上限内なら従来どおり返る（境界: ちょうど上限のときは許す）。
        #expect(await CoverImageSourceResolver.firstImageData(for: imageURL, maxEntryReadBytes: contents.count) == contents)
    }

    @Test func refusesTheFolderFirstImageLargerThanTheReadLimit() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try TestImageFixture.makePNGData(width: 10, height: 10)
            .write(to: root.appendingPathComponent("page1.png"))

        #expect(await CoverImageSourceResolver.firstImageData(for: root, maxEntryReadBytes: 10) == nil)
    }

    @Test func returnsNilWhenNothingCanBeResolved() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let emptyFolder = root.appendingPathComponent("empty", isDirectory: true)
        try FileManager.default.createDirectory(at: emptyFolder, withIntermediateDirectories: true)

        #expect(await CoverImageSourceResolver.firstImageData(for: emptyFolder) == nil)
        #expect(await CoverImageSourceResolver.firstImageData(for: root.appendingPathComponent("missing.cbz")) == nil)
    }
}
