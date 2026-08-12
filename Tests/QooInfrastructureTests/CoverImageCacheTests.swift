import CoreGraphics
import Foundation
import ImageIO
import Testing

@testable import QooInfrastructure
@testable import QooKit

@Suite struct CoverImageCacheTests {
    /// テストごとに独立した一時ディレクトリを使う（`SecureExtractor`/
    /// `ArchiveCompressor` の `stagingRoot` 注入と同じ理由、CI 並列実行時の
    /// 競合を避ける）。
    private func makeCache() -> (cache: DefaultCoverImageCache, root: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("qoo-cover-cache-test-\(UUID().uuidString)")
        return (DefaultCoverImageCache(baseDirectory: root), root)
    }

    private func makeImage() -> CGImage {
        let data = TestImageFixture.makePNGData(width: 10, height: 10)
        let source = CGImageSourceCreateWithData(data as CFData, nil)!
        return CGImageSourceCreateImageAtIndex(source, 0, nil)!
    }

    private func makeIdentity(_ inode: UInt64 = 1) -> FileIdentity {
        FileIdentity(volumeUUID: "TEST-VOLUME", inode: inode)
    }

    @Test func storeAndLoadRoundTrips() throws {
        let (cache, root) = makeCache()
        defer { try? FileManager.default.removeItem(at: root) }
        let identity = makeIdentity()

        try cache.store(makeImage(), for: identity)
        let loaded = cache.loadCachedImage(for: identity)

        #expect(loaded != nil)
        #expect(loaded?.width == 10)
    }

    @Test func loadCachedImageReturnsNilWhenNotStored() {
        let (cache, root) = makeCache()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(cache.loadCachedImage(for: makeIdentity()) == nil)
    }

    @Test func urlIsDeterministicForTheSameIdentity() {
        let (cache, root) = makeCache()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(cache.url(for: makeIdentity()) == cache.url(for: makeIdentity()))
        #expect(cache.url(for: makeIdentity(1)) != cache.url(for: makeIdentity(2)))
    }

    @Test func totalSizeSumsStoredFiles() async throws {
        let (cache, root) = makeCache()
        defer { try? FileManager.default.removeItem(at: root) }
        try cache.store(makeImage(), for: makeIdentity(1))
        try cache.store(makeImage(), for: makeIdentity(2))

        let total = await cache.totalSize()

        #expect(total > 0)
    }

    @Test func pruneRemovesOldestFilesUntilUnderLimit() async throws {
        let (cache, root) = makeCache()
        defer { try? FileManager.default.removeItem(at: root) }
        try cache.store(makeImage(), for: makeIdentity(1))
        try cache.store(makeImage(), for: makeIdentity(2))
        try cache.store(makeImage(), for: makeIdentity(3))
        let fullSize = await cache.totalSize()

        await cache.prune(toMaxSize: 1) // 実質すべて削除されるはずの極小上限

        let prunedSize = await cache.totalSize()
        #expect(prunedSize < fullSize)
        #expect(prunedSize <= 1 || cache.loadCachedImage(for: makeIdentity(1)) == nil)
    }

    @Test func clearRemovesEverything() async throws {
        let (cache, root) = makeCache()
        defer { try? FileManager.default.removeItem(at: root) }
        try cache.store(makeImage(), for: makeIdentity())

        await cache.clear()

        #expect(cache.loadCachedImage(for: makeIdentity()) == nil)
        #expect(await cache.totalSize() == 0)
    }
}
