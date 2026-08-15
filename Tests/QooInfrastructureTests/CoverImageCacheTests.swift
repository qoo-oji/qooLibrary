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

    /// キャッシュの鍵は `FileIdentity` ではなく `FileContentStamp`
    /// （更新日時とサイズを含む）[`FileContentStamp` のコメント参照]。
    private func makeStamp(_ inode: UInt64 = 1, modifiedSeconds: Int64 = 1_000, size: Int64 = 42) -> FileContentStamp {
        FileContentStamp(
            identity: FileIdentity(volumeUUID: "TEST-VOLUME", inode: inode),
            modifiedSeconds: modifiedSeconds,
            modifiedNanoseconds: 0,
            size: size
        )
    }

    @Test func storeAndLoadRoundTrips() throws {
        let (cache, root) = makeCache()
        defer { try? FileManager.default.removeItem(at: root) }
        let stamp = makeStamp()

        try cache.store(makeImage(), for: stamp)
        let loaded = cache.loadCachedImage(for: stamp)

        #expect(loaded != nil)
        #expect(loaded?.width == 10)
    }

    @Test func loadCachedImageReturnsNilWhenNotStored() {
        let (cache, root) = makeCache()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(cache.loadCachedImage(for: makeStamp()) == nil)
    }

    @Test func urlIsDeterministicForTheSameStamp() {
        let (cache, root) = makeCache()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(cache.url(for: makeStamp()) == cache.url(for: makeStamp()))
        #expect(cache.url(for: makeStamp(1)) != cache.url(for: makeStamp(2)))
    }

    /// **同じファイル（同じ inode）でも、内容が変われば別のキャッシュになる。**
    /// これが無いと、外部でファイルを差し替えても古いサムネイルが出続ける。
    @Test func sameFileWithDifferentContentUsesADifferentEntry() throws {
        let (cache, root) = makeCache()
        defer { try? FileManager.default.removeItem(at: root) }

        try cache.store(makeImage(), for: makeStamp(1, modifiedSeconds: 1_000, size: 42))

        #expect(cache.loadCachedImage(for: makeStamp(1, modifiedSeconds: 2_000, size: 42)) == nil)
        #expect(cache.loadCachedImage(for: makeStamp(1, modifiedSeconds: 1_000, size: 99)) == nil)
        #expect(cache.loadCachedImage(for: makeStamp(1, modifiedSeconds: 1_000, size: 42)) != nil)
    }

    /// 削除 → 新規作成で inode が再利用されても、無関係なファイルの
    /// サムネイルを引き当てない（更新日時とサイズが違うため）。
    @Test func recycledInodeDoesNotInheritTheOldThumbnail() throws {
        let (cache, root) = makeCache()
        defer { try? FileManager.default.removeItem(at: root) }

        try cache.store(makeImage(), for: makeStamp(7, modifiedSeconds: 1_000, size: 42))
        let recycled = makeStamp(7, modifiedSeconds: 5_000, size: 4_096)

        #expect(cache.loadCachedImage(for: recycled) == nil)
    }

    @Test func totalSizeSumsStoredFiles() async throws {
        let (cache, root) = makeCache()
        defer { try? FileManager.default.removeItem(at: root) }
        try cache.store(makeImage(), for: makeStamp(1))
        try cache.store(makeImage(), for: makeStamp(2))

        let total = await cache.totalSize()

        #expect(total > 0)
    }

    @Test func pruneRemovesOldestFilesUntilUnderLimit() async throws {
        let (cache, root) = makeCache()
        defer { try? FileManager.default.removeItem(at: root) }
        try cache.store(makeImage(), for: makeStamp(1))
        try cache.store(makeImage(), for: makeStamp(2))
        try cache.store(makeImage(), for: makeStamp(3))
        let fullSize = await cache.totalSize()

        await cache.prune(toMaxSize: 1) // 実質すべて削除されるはずの極小上限

        let prunedSize = await cache.totalSize()
        #expect(prunedSize < fullSize)
        #expect(prunedSize <= 1 || cache.loadCachedImage(for: makeStamp(1)) == nil)
    }

    @Test func clearRemovesEverything() async throws {
        let (cache, root) = makeCache()
        defer { try? FileManager.default.removeItem(at: root) }
        try cache.store(makeImage(), for: makeStamp())

        await cache.clear()

        #expect(cache.loadCachedImage(for: makeStamp()) == nil)
        #expect(await cache.totalSize() == 0)
    }
}

/// 「サムネイルを再生成」のように URL でしか対象を指定できない経路のための、
/// 版をまたいだ削除 [レビューで指摘]。
@Suite struct CoverImageCacheInvalidationTests {
    private func makeCache() -> (cache: DefaultCoverImageCache, root: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("qoo-cover-invalidate-\(UUID().uuidString)")
        return (DefaultCoverImageCache(baseDirectory: root), root)
    }

    private func makeImage() -> CGImage {
        let data = TestImageFixture.makePNGData(width: 10, height: 10)
        let source = CGImageSourceCreateWithData(data as CFData, nil)!
        return CGImageSourceCreateImageAtIndex(source, 0, nil)!
    }

    private func stamp(inode: UInt64, modified: Int64) -> FileContentStamp {
        FileContentStamp(
            identity: FileIdentity(volumeUUID: "TEST-VOLUME", inode: inode),
            modifiedSeconds: modified, modifiedNanoseconds: 0, size: 1
        )
    }

    @Test func removingEntriesForAnIdentityDropsEveryContentVersion() async throws {
        let (cache, root) = makeCache()
        defer { try? FileManager.default.removeItem(at: root) }
        let old = stamp(inode: 42, modified: 1_000)
        let new = stamp(inode: 42, modified: 2_000)
        try cache.store(makeImage(), for: old)
        try cache.store(makeImage(), for: new)

        await cache.removeEntries(for: FileIdentity(volumeUUID: "TEST-VOLUME", inode: 42))

        #expect(cache.loadCachedImage(for: old) == nil)
        #expect(cache.loadCachedImage(for: new) == nil)
    }

    /// inode 42 の削除で inode 421 を巻き込まない（鍵の接頭辞の末尾に
    /// ハイフンを入れてある理由）。
    @Test func removingEntriesDoesNotAffectAnInodeThatMerelySharesAPrefix() async throws {
        let (cache, root) = makeCache()
        defer { try? FileManager.default.removeItem(at: root) }
        let neighbour = stamp(inode: 421, modified: 1_000)
        try cache.store(makeImage(), for: stamp(inode: 42, modified: 1_000))
        try cache.store(makeImage(), for: neighbour)

        await cache.removeEntries(for: FileIdentity(volumeUUID: "TEST-VOLUME", inode: 42))

        #expect(cache.loadCachedImage(for: neighbour) != nil)
    }
}
