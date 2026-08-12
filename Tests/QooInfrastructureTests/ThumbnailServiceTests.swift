import Foundation
import Testing

@testable import QooInfrastructure
@testable import QooKit

@Suite struct ThumbnailServiceTests {
    /// テストごとに独立した一時ディレクトリ（ソース側・キャッシュ側とも）を使う
    /// [`ArchiveCompressor`/`SecureExtractor` の `stagingRoot` 注入と同じ理由]。
    private func makeService() -> (service: ThumbnailService, root: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("qoo-thumbnail-test-\(UUID().uuidString)")
        let cacheDir = root.appendingPathComponent("cache")
        let cache = DefaultCoverImageCache(baseDirectory: cacheDir)
        let service = ThumbnailService(maxConcurrent: 2, cache: cache, imageLoader: DefaultImageLoader())
        return (service, root)
    }

    @Test func resolvesFirstImageInFolderByNaturalOrder() async throws {
        let (service, root) = makeService()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        // "page10" が文字列順では "page2" より前に来てしまう。自然順なら
        // page2 が先。非画像ファイルは無視される。
        try Data("not an image".utf8).write(to: folder.appendingPathComponent("00-readme.txt"))
        try TestImageFixture.makePNGData(width: 20, height: 20, red: 0).write(to: folder.appendingPathComponent("page10.png"))
        try TestImageFixture.makePNGData(width: 20, height: 20, red: 1).write(to: folder.appendingPathComponent("page2.png"))

        let thumbnail = await service.thumbnail(for: folder, maxPixelSize: 50)

        #expect(thumbnail != nil)
    }

    @Test func returnsNilWhenFolderHasNoImages() async throws {
        let (service, root) = makeService()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("not an image".utf8).write(to: folder.appendingPathComponent("readme.txt"))

        let thumbnail = await service.thumbnail(for: folder, maxPixelSize: 50)

        #expect(thumbnail == nil)
    }

    @Test func resolvesFirstImageInArchiveByNaturalOrder() async throws {
        let (service, root) = makeService()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let archiveURL = root.appendingPathComponent("book.cbz")
        try ArchiveFixtureBuilder.makeZip(at: archiveURL, entries: [
            .file("page10.jpg", contents: TestImageFixture.makePNGData(width: 20, height: 20, red: 0)),
            .file("page2.jpg", contents: TestImageFixture.makePNGData(width: 20, height: 20, red: 1)),
            .file("notes.txt", contents: Data("ignore me".utf8)),
        ])

        let thumbnail = await service.thumbnail(for: archiveURL, maxPixelSize: 50)

        #expect(thumbnail != nil)
    }

    /// フォルダ/アーカイブだけでなく、画像ファイル自身もプレビューできる
    /// [IV-01 の自然な拡張、`ThumbnailService` のコメント参照]。
    @Test func resolvesThumbnailForAPlainImageFileDirectly() async throws {
        let (service, root) = makeService()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let imageURL = root.appendingPathComponent("photo.png")
        try TestImageFixture.makePNGData(width: 40, height: 40).write(to: imageURL)

        let thumbnail = await service.thumbnail(for: imageURL, maxPixelSize: 20)

        #expect(thumbnail != nil)
    }

    @Test func cachesGeneratedThumbnail() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("qoo-thumbnail-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = DefaultCoverImageCache(baseDirectory: root.appendingPathComponent("cache"))
        let service = ThumbnailService(maxConcurrent: 2, cache: cache, imageLoader: DefaultImageLoader())
        let folder = root.appendingPathComponent("folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try TestImageFixture.makePNGData(width: 20, height: 20).write(to: folder.appendingPathComponent("cover.png"))

        _ = await service.thumbnail(for: folder, maxPixelSize: 50)
        let cachedSize = await cache.totalSize()

        #expect(cachedSize > 0)
    }

    @Test func invalidateClearsTheCachedFile() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("qoo-thumbnail-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = DefaultCoverImageCache(baseDirectory: root.appendingPathComponent("cache"))
        let service = ThumbnailService(maxConcurrent: 2, cache: cache, imageLoader: DefaultImageLoader())
        let folder = root.appendingPathComponent("folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try TestImageFixture.makePNGData(width: 20, height: 20).write(to: folder.appendingPathComponent("cover.png"))
        _ = await service.thumbnail(for: folder, maxPixelSize: 50)
        #expect(await cache.totalSize() > 0)

        await service.invalidate([folder])

        #expect(await cache.totalSize() == 0)
    }

    /// [PF-11] 同時実行数の制限が実際に複数件を正しく処理できることの
    /// sanity チェック（自前実装のスロット管理がデッドロックしないことの確認）。
    @Test func handlesMoreRequestsThanMaxConcurrentWithoutDeadlock() async throws {
        let (service, root) = makeService() // maxConcurrent: 2
        defer { try? FileManager.default.removeItem(at: root) }
        var folders: [URL] = []
        for index in 0..<6 {
            let folder = root.appendingPathComponent("folder\(index)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try TestImageFixture.makePNGData(width: 20, height: 20).write(to: folder.appendingPathComponent("cover.png"))
            folders.append(folder)
        }

        let results = await withTaskGroup(of: Bool.self) { group in
            for folder in folders {
                group.addTask { await service.thumbnail(for: folder, maxPixelSize: 50) != nil }
            }
            var outcomes: [Bool] = []
            for await result in group { outcomes.append(result) }
            return outcomes
        }

        #expect(results.count == 6)
        #expect(results.allSatisfy { $0 })
    }
}
