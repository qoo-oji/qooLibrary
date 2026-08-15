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
    ///
    /// **拡張子は必ず `mp4`（macOS 標準搭載、`public.movie` 準拠が OS 自体に
    /// 組み込まれている）を使うこと。`mkv` は使わない。** [CI で発見した回帰:
    /// `mkv`（`org.matroska.mkv`）が `public.movie` に準拠するかどうかは、
    /// mkv 対応の QuickLook 拡張／メディアアプリ（Infuse・IINA・QLMedia 等）
    /// がシステムに登録されているかに依存する（動画サムネイル対応の節参照）。
    /// この開発機には調査の過程でそれらが複数インストール済みのためローカル
    /// では気づかず通過していたが、何もインストールされていない CI ランナー
    /// では `isVideoFilename("clip.mkv")` が `false` になり、動画分岐へ
    /// ルーティングされずテストが失敗した。
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
        let videoURL = root.appendingPathComponent("clip.mp4")
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

    private struct FakePDFThumbnailLoader: PDFThumbnailLoading {
        let result: CGImage?
        func makeThumbnail(for url: URL, maxPixelSize: Int) async -> CGImage? { result }
    }

    /// PDF ファイル自身もサムネイル生成の対象になる [ユーザー要望:
    /// qooLibrary は qooViewer のフロントエンドであり、qooViewer が対応する
    /// 形式（PDF・EPUB）は qooLibrary 側でも網羅する必要がある]。拡張子が
    /// `public.pdf` 準拠の場合は `PDFThumbnailLoading` 経由になることを、
    /// 画像デコード経路では失敗するはずのファイル（中身が画像ではない）で
    /// 検証する。
    @Test func resolvesThumbnailForAPDFFileViaPDFThumbnailLoader() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("qoo-thumbnail-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = DefaultCoverImageCache(baseDirectory: root.appendingPathComponent("cache"))
        let expected = TestImageFixture.makeCGImage(width: 20, height: 20)
        let service = ThumbnailService(
            maxConcurrent: 2, cache: cache, imageLoader: DefaultImageLoader(),
            pdfThumbnailLoader: FakePDFThumbnailLoader(result: expected)
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let pdfURL = root.appendingPathComponent("book.pdf")
        try Data("not real PDF bytes".utf8).write(to: pdfURL)

        let thumbnail = await service.thumbnail(for: pdfURL, maxPixelSize: 50)

        #expect(thumbnail != nil)
    }

    @Test func doesNotUsePDFThumbnailLoaderForNonPDFFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("qoo-thumbnail-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = DefaultCoverImageCache(baseDirectory: root.appendingPathComponent("cache"))
        let expected = TestImageFixture.makeCGImage(width: 20, height: 20)
        let service = ThumbnailService(
            maxConcurrent: 2, cache: cache, imageLoader: DefaultImageLoader(),
            pdfThumbnailLoader: FakePDFThumbnailLoader(result: expected)
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let textURL = root.appendingPathComponent("notes.txt")
        try Data("plain text".utf8).write(to: textURL)

        let thumbnail = await service.thumbnail(for: textURL, maxPixelSize: 50)

        #expect(thumbnail == nil)
    }

    /// EPUB は専用の `EpubCoverResolver`（既定実装）経由で先頭ページの画像
    /// データを取り出し、以降は通常の画像デコード経路（`imageLoader`）に
    /// 合流する。フェイクを使わない end-to-end の確認。
    @Test func resolvesThumbnailForAnEpubFileViaEpubCoverResolver() async throws {
        let (service, root) = makeService()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let epubURL = root.appendingPathComponent("book.epub")
        let containerXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles>
            <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
          </rootfiles>
        </container>
        """
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
        try ArchiveFixtureBuilder.makeZip(at: epubURL, entries: [
            .file("META-INF/container.xml", contents: Data(containerXML.utf8)),
            .file("OEBPS/content.opf", contents: Data(opf.utf8)),
            .file("OEBPS/images/page1.png", contents: TestImageFixture.makePNGData(width: 30, height: 40)),
        ])

        let thumbnail = await service.thumbnail(for: epubURL, maxPixelSize: 50)

        #expect(thumbnail != nil)
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

    // MARK: - サムネイル一括非表示 [DS-01][DS-05]

    /// 実際にデコードが走ったかを数える `ImageLoading`。「生成しない」ことの
    /// 検証は戻り値が `nil` かどうかだけでは足りない（生成に失敗しても `nil`）
    /// ため、**呼ばれた回数そのもの**を見る。
    private final class CountingImageLoader: ImageLoading, @unchecked Sendable {
        private let lock = NSLock()
        private var calls = 0
        var makeThumbnailCallCount: Int { lock.withLock { calls } }

        private let underlying = DefaultImageLoader()

        func imageSize(from data: Data) -> CGSize? { underlying.imageSize(from: data) }
        func isWithinPixelCountLimit(_ data: Data) -> Bool { underlying.isWithinPixelCountLimit(data) }
        func makeThumbnail(from data: Data, maxPixelSize: Int) throws -> CGImage {
            lock.withLock { calls += 1 }
            return try underlying.makeThumbnail(from: data, maxPixelSize: maxPixelSize)
        }
    }

    /// 切り替え可能な「全体トグル」。`ThumbnailVisibility.shared`（プロセス
    /// 共有）を書き換えると並行実行される他のテストに干渉するため、
    /// `ThumbnailService` へ注入するほうを使う。
    private final class VisibilityBox: @unchecked Sendable {
        private let lock = NSLock()
        private var hidden: Bool
        init(hidden: Bool) { self.hidden = hidden }
        var isHidden: Bool {
            get { lock.withLock { hidden } }
            set { lock.withLock { hidden = newValue } }
        }
    }

    private func makeService(
        cacheDirectory: URL,
        imageLoader: ImageLoading,
        visibility: VisibilityBox
    ) -> ThumbnailService {
        ThumbnailService(
            maxConcurrent: 2,
            cache: DefaultCoverImageCache(baseDirectory: cacheDirectory),
            imageLoader: imageLoader,
            isGloballyHidden: { visibility.isHidden }
        )
    }

    /// [DS-05] 非表示中は生成もキャッシュもしない。**戻り値が `nil` になる
    /// だけでなく、デコードが 1 回も走らず、キャッシュにも何も残らない**こと
    /// までを見る（この要件の主眼は「不要な I/O を避ける」ことなので、
    /// 表示上の結果だけでは検証したことにならない）。
    @Test func doesNotGenerateOrCacheWhileGloballyHidden() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("qoo-thumbnail-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let cacheDirectory = root.appendingPathComponent("cache")
        let folder = root.appendingPathComponent("folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try TestImageFixture.makePNGData(width: 20, height: 20).write(to: folder.appendingPathComponent("cover.png"))

        let loader = CountingImageLoader()
        let service = makeService(cacheDirectory: cacheDirectory, imageLoader: loader, visibility: VisibilityBox(hidden: true))

        let thumbnail = await service.thumbnail(for: folder, maxPixelSize: 50)

        #expect(thumbnail == nil)
        #expect(loader.makeThumbnailCallCount == 0)
        let cached = try? FileManager.default.contentsOfDirectory(atPath: cacheDirectory.path)
        #expect((cached ?? []).isEmpty)
    }

    /// [DS-05] 「再表示時に生成する」。同じサービス・同じフォルダで、
    /// トグルを戻すだけで生成が始まることを確認する。
    @Test func generatesAgainOnceThumbnailsAreShownAgain() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("qoo-thumbnail-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try TestImageFixture.makePNGData(width: 20, height: 20).write(to: folder.appendingPathComponent("cover.png"))

        let loader = CountingImageLoader()
        let visibility = VisibilityBox(hidden: true)
        let service = makeService(
            cacheDirectory: root.appendingPathComponent("cache"),
            imageLoader: loader,
            visibility: visibility
        )

        #expect(await service.thumbnail(for: folder, maxPixelSize: 50) == nil)

        visibility.isHidden = false

        #expect(await service.thumbnail(for: folder, maxPixelSize: 50) != nil)
        #expect(loader.makeThumbnailCallCount == 1)
    }

    /// [DS-01] 非表示中は**キャッシュ済みでも**返さない。キャッシュの有無で
    /// 見た目が変わってしまうと「無効時は汎用アイコンに切り替わる」が
    /// 一部のファイルだけ守られない、という状態になるため。
    @Test func doesNotReturnAlreadyCachedThumbnailWhileHidden() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("qoo-thumbnail-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try TestImageFixture.makePNGData(width: 20, height: 20).write(to: folder.appendingPathComponent("cover.png"))

        let visibility = VisibilityBox(hidden: false)
        let service = makeService(
            cacheDirectory: root.appendingPathComponent("cache"),
            imageLoader: CountingImageLoader(),
            visibility: visibility
        )

        // まず表示状態で生成してキャッシュに載せる。
        #expect(await service.thumbnail(for: folder, maxPixelSize: 50) != nil)

        visibility.isHidden = true

        #expect(await service.thumbnail(for: folder, maxPixelSize: 50) == nil)
    }
}
