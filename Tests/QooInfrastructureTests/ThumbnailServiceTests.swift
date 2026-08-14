import CoreGraphics
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

    /// 動画ファイル用フェイク。`VideoThumbnailLoading` の実装差し替えだけで
    /// `ThumbnailService` が動画ファイルを別経路（画像デコードではなく
    /// `QLThumbnailGenerator` 相当）で処理することを検証する。実際の
    /// `QLThumbnailGenerator` はサードパーティ QuickLook 拡張の有無に依存し
    /// CI では再現できないため（`QLVideoThumbnailLoader` のコメント参照）、
    /// 自動テストはこのフェイクで分岐ロジックのみを検証する。
    private struct FakeVideoThumbnailLoader: VideoThumbnailLoading {
        let result: CGImage?
        func makeThumbnail(for url: URL, maxPixelSize: Int) async -> CGImage? { result }
    }

    /// 動画ファイル自身も（画像ファイルと同様に）サムネイル生成の対象になる
    /// [ユーザー要望、動画ライブラリとしての利用を見据えた拡張]。拡張子が
    /// 動画形式（`public.movie` 準拠）の場合は `VideoThumbnailLoading` 経由に
    /// なることを、画像デコード経路では失敗するはずのファイル（中身が画像
    /// ではない）で検証する。
    @Test func resolvesThumbnailForAVideoFileViaVideoThumbnailLoader() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("qoo-thumbnail-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = DefaultCoverImageCache(baseDirectory: root.appendingPathComponent("cache"))
        let expected = TestImageFixture.makeCGImage(width: 20, height: 20)
        let service = ThumbnailService(
            maxConcurrent: 2, cache: cache, imageLoader: DefaultImageLoader(),
            videoThumbnailLoader: FakeVideoThumbnailLoader(result: expected)
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let videoURL = root.appendingPathComponent("clip.mkv")
        try Data("not real video bytes".utf8).write(to: videoURL)

        let thumbnail = await service.thumbnail(for: videoURL, maxPixelSize: 50)

        #expect(thumbnail != nil)
    }

    /// 動画サムネイル生成が失敗した場合（拡張が無い等）は `nil` を返し、
    /// 呼び出し側の既定アイコンへのフォールバックに委ねる [IM-04 と同じ方針]。
    @Test func returnsNilWhenVideoThumbnailLoaderFails() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("qoo-thumbnail-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = DefaultCoverImageCache(baseDirectory: root.appendingPathComponent("cache"))
        let service = ThumbnailService(
            maxConcurrent: 2, cache: cache, imageLoader: DefaultImageLoader(),
            videoThumbnailLoader: FakeVideoThumbnailLoader(result: nil)
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let videoURL = root.appendingPathComponent("clip.mp4")
        try Data("not real video bytes".utf8).write(to: videoURL)

        let thumbnail = await service.thumbnail(for: videoURL, maxPixelSize: 50)

        #expect(thumbnail == nil)
    }

    /// 動画以外の拡張子では `VideoThumbnailLoading` 側へルーティングされない
    /// ことの確認（フェイクが値を返せる状態でも、非動画ファイルでは使われず
    /// 結果は `nil` のままになる）。
    @Test func doesNotUseVideoThumbnailLoaderForNonVideoFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("qoo-thumbnail-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = DefaultCoverImageCache(baseDirectory: root.appendingPathComponent("cache"))
        let expected = TestImageFixture.makeCGImage(width: 20, height: 20)
        let service = ThumbnailService(
            maxConcurrent: 2, cache: cache, imageLoader: DefaultImageLoader(),
            videoThumbnailLoader: FakeVideoThumbnailLoader(result: expected)
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let textURL = root.appendingPathComponent("notes.txt")
        try Data("plain text".utf8).write(to: textURL)

        let thumbnail = await service.thumbnail(for: textURL, maxPixelSize: 50)

        #expect(thumbnail == nil)
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
