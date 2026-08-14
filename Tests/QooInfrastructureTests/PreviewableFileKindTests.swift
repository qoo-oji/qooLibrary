import Foundation
import Testing

@testable import QooInfrastructure
@testable import QooKit

/// `PreviewableFileKind` はサムネイル生成と Quick Look の両方が「この項目の
/// 中身をどう見せるか」を決める唯一の判定点なので、分類そのものを直接検証する。
@Suite struct PreviewableFileKindTests {
    @Test(arguments: [
        ("book.cbz", ArchiveFormat.zip),
        ("book.zip", ArchiveFormat.zip),
        ("book.cb7", ArchiveFormat.sevenZip),
        ("book.7z", ArchiveFormat.sevenZip),
        ("book.cbr", ArchiveFormat.rar),
        ("book.rar", ArchiveFormat.rar),
        ("bundle.tar.gz", ArchiveFormat.tarGz),
    ])
    func classifiesArchives(name: String, expected: ArchiveFormat) {
        #expect(PreviewableFileKind.of(filename: name, isDirectory: false) == .archive(expected))
    }

    @Test(arguments: ["page.png", "page.jpg", "page.jpeg", "page.webp"])
    func classifiesImages(name: String) {
        #expect(PreviewableFileKind.of(filename: name, isDirectory: false) == .image)
    }

    /// `mkv` のように「対応が環境（インストール済みアプリ）に依存する」拡張子は
    /// 使わない——開発機では通り、まっさらな CI で落ちる
    /// [`ThumbnailServiceTests` で実際に踏んだ CI 障害と同じ理由]。
    @Test(arguments: ["clip.mp4", "clip.mov"])
    func classifiesVideos(name: String) {
        #expect(PreviewableFileKind.of(filename: name, isDirectory: false) == .video)
    }

    @Test func classifiesPDFAndEpubAndOther() {
        #expect(PreviewableFileKind.of(filename: "doc.pdf", isDirectory: false) == .pdf)
        #expect(PreviewableFileKind.of(filename: "book.epub", isDirectory: false) == .epub)
        #expect(PreviewableFileKind.of(filename: "BOOK.EPUB", isDirectory: false) == .epub)
        #expect(PreviewableFileKind.of(filename: "notes.txt", isDirectory: false) == .other)
        #expect(PreviewableFileKind.of(filename: "no-extension", isDirectory: false) == .other)
    }

    @Test func directoryAlwaysClassifiesAsFolderRegardlessOfExtension() {
        // `.zip` という名前のフォルダを作ることもできる。実体が優先される。
        #expect(PreviewableFileKind.of(filename: "weird.zip", isDirectory: true) == .folder)
    }

    /// Quick Look で独自のカバープレビューへ差し替える対象 [QL-03][QL-08]。
    /// 標準 Quick Look が中身を見せられる種別は委ねる [QL-02]。
    @Test func onlyFoldersAndArchivesNeedTheCustomCoverPreview() {
        #expect(PreviewableFileKind.folder.needsCustomCoverPreview)
        #expect(PreviewableFileKind.archive(.zip).needsCustomCoverPreview)
        #expect(PreviewableFileKind.archive(.rar).needsCustomCoverPreview)
        #expect(!PreviewableFileKind.image.needsCustomCoverPreview)
        #expect(!PreviewableFileKind.video.needsCustomCoverPreview)
        #expect(!PreviewableFileKind.pdf.needsCustomCoverPreview)
        #expect(!PreviewableFileKind.epub.needsCustomCoverPreview)
        #expect(!PreviewableFileKind.other.needsCustomCoverPreview)
    }

    @Test func classifiesRealFilesystemEntries() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("qoo-kind-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let imageURL = root.appendingPathComponent("page.png")
        try TestImageFixture.makePNGData(width: 4, height: 4).write(to: imageURL)

        #expect(PreviewableFileKind.of(root) == .folder)
        #expect(PreviewableFileKind.of(imageURL) == .image)
        // 存在しないパスは分類できない（呼び出し側は `.other` として素通しする）。
        #expect(PreviewableFileKind.of(root.appendingPathComponent("missing.png")) == .other)
    }
}
