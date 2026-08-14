import Foundation
import Testing

@testable import QooInfrastructure
@testable import QooKit

/// Quick Look の独自カバープレビュー [QL-03][QL-08] が渡す実ファイルの生成。
@Suite struct QuickLookCoverStoreTests {
    private func makeStore(
        imageLoader: ImageLoading = DefaultImageLoader(),
        maxCacheSize: Int64 = AppLimits.QuickLook.defaultCoverCacheMaxSize
    ) -> (store: QuickLookCoverStore, root: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("qoo-quicklook-test-\(UUID().uuidString)")
        let store = QuickLookCoverStore(
            baseDirectory: root.appendingPathComponent("covers"),
            imageLoader: imageLoader,
            maxCacheSize: maxCacheSize
        )
        return (store, root)
    }

    private func makeSourceDirectory(_ root: URL) throws -> URL {
        let source = root.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        return source
    }

    @Test func writesTheFirstImageOfAnArchiveAsARealFile() async throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try makeSourceDirectory(root)
        let archiveURL = source.appendingPathComponent("book.cbz")
        let firstPage = TestImageFixture.makePNGData(width: 24, height: 40, red: 1)
        try ArchiveFixtureBuilder.makeZip(at: archiveURL, entries: [
            .file("page2.png", contents: firstPage),
            .file("page10.png", contents: TestImageFixture.makePNGData(width: 24, height: 40, red: 0)),
        ])

        let coverURL = try #require(await store.coverFileURL(for: archiveURL))

        #expect(FileManager.default.fileExists(atPath: coverURL.path))
        // 再エンコードせず原画像のバイト列をそのまま書き出す（Quick Look の
        // 大きな表示でぼやけないように）。自然順で先頭の page2 が選ばれる。
        #expect(try Data(contentsOf: coverURL) == firstPage)
    }

    /// 拡張子はエントリ名ではなく**実データ**から決める。Quick Look は拡張子で
    /// 描画方法を選ぶため、エントリ名が実体と食い違っていても正しく開けること。
    @Test func derivesTheFileExtensionFromTheImageDataNotTheEntryName() async throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try makeSourceDirectory(root)
        let archiveURL = source.appendingPathComponent("book.cbz")
        try ArchiveFixtureBuilder.makeZip(at: archiveURL, entries: [
            // 中身は PNG だが、エントリ名は .jpg を名乗っている。
            .file("cover.jpg", contents: TestImageFixture.makePNGData(width: 8, height: 8)),
        ])

        let coverURL = try #require(await store.coverFileURL(for: archiveURL))

        #expect(coverURL.pathExtension == "png")
    }

    @Test func resolvesFolderCoverFromItsFirstImage() async throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try makeSourceDirectory(root)
        let folder = source.appendingPathComponent("book", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("readme".utf8).write(to: folder.appendingPathComponent("00.txt"))
        try TestImageFixture.makePNGData(width: 6, height: 6).write(to: folder.appendingPathComponent("page1.png"))

        let coverURL = try #require(await store.coverFileURL(for: folder))

        #expect(FileManager.default.fileExists(atPath: coverURL.path))
    }

    @Test func returnsNilWhenNoImageCanBeResolved() async throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try makeSourceDirectory(root)
        let archiveURL = source.appendingPathComponent("docs.zip")
        try ArchiveFixtureBuilder.makeZip(at: archiveURL, entries: [
            .file("notes.txt", contents: Data("no images here".utf8)),
        ])

        #expect(await store.coverFileURL(for: archiveURL) == nil)
    }

    /// 2 回目は書き出し済みのファイルをそのまま返す（アーカイブを再走査しない）。
    @Test func reusesTheAlreadyWrittenCoverOnTheSecondRequest() async throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try makeSourceDirectory(root)
        let archiveURL = source.appendingPathComponent("book.cbz")
        try ArchiveFixtureBuilder.makeZip(at: archiveURL, entries: [
            .file("page1.png", contents: TestImageFixture.makePNGData(width: 8, height: 8)),
        ])

        let first = try #require(await store.coverFileURL(for: archiveURL))
        let second = try #require(await store.coverFileURL(for: archiveURL))

        #expect(first == second)
    }

    /// [QL-10][IM-05] Quick Look 用の読み込みにも画像の安全上限を適用する。
    /// 上限超過は縮小せずに諦め、呼び出し側が標準 Quick Look へ委ねる。
    @Test func skipsImagesThatExceedThePixelCountLimit() async throws {
        let (store, root) = makeStore(imageLoader: DefaultImageLoader(maxPixelCount: 10))
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try makeSourceDirectory(root)
        let archiveURL = source.appendingPathComponent("book.cbz")
        try ArchiveFixtureBuilder.makeZip(at: archiveURL, entries: [
            .file("page1.png", contents: TestImageFixture.makePNGData(width: 40, height: 40)), // 1,600 画素
        ])

        #expect(await store.coverFileURL(for: archiveURL) == nil)
    }

    /// このキャッシュはセッション限り。異常終了しても次回起動で片付くよう、
    /// アプリ起動時に丸ごと捨てる。
    @Test func purgeAllRemovesEverythingWrittenSoFar() async throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try makeSourceDirectory(root)
        let archiveURL = source.appendingPathComponent("book.cbz")
        try ArchiveFixtureBuilder.makeZip(at: archiveURL, entries: [
            .file("page1.png", contents: TestImageFixture.makePNGData(width: 8, height: 8)),
        ])
        let coverURL = try #require(await store.coverFileURL(for: archiveURL))

        await store.purgeAll()

        #expect(!FileManager.default.fileExists(atPath: coverURL.path))
        // 索引も捨てられているので、次の要求では実際に書き出し直される。
        let regenerated = try #require(await store.coverFileURL(for: archiveURL))
        #expect(FileManager.default.fileExists(atPath: regenerated.path))
    }

    /// 1 セッション中に大量のアーカイブをプレビューしても、上限を超えたぶんは
    /// 古いものから捨てられる。書き出したばかりのカバー（これから Quick Look へ
    /// 渡すもの）は刈り取りの対象外。
    @Test func prunesOldestCoversWhenExceedingTheSizeLimit() async throws {
        // カバーは原画像のバイト列をそのまま書き出すため、書き出し後のサイズは
        // ここで作る PNG のサイズと一致する。1 件は入るが 2 件は入らない上限にする。
        let page = TestImageFixture.makePNGData(width: 32, height: 32)
        let (store, root) = makeStore(maxCacheSize: Int64(page.count) + 16)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try makeSourceDirectory(root)

        let olderArchive = source.appendingPathComponent("older.cbz")
        let newerArchive = source.appendingPathComponent("newer.cbz")
        try ArchiveFixtureBuilder.makeZip(at: olderArchive, entries: [.file("page1.png", contents: page)])
        try ArchiveFixtureBuilder.makeZip(at: newerArchive, entries: [.file("page1.png", contents: page)])

        let olderCover = try #require(await store.coverFileURL(for: olderArchive))
        #expect(FileManager.default.fileExists(atPath: olderCover.path))

        let newerCover = try #require(await store.coverFileURL(for: newerArchive))

        #expect(FileManager.default.fileExists(atPath: newerCover.path))
        #expect(!FileManager.default.fileExists(atPath: olderCover.path))
        // 刈られたことが索引にも反映されており、再要求では実体のある URL が返る
        // （実体の無い URL を「キャッシュ済み」として返してしまわないこと）。
        let regenerated = try #require(await store.coverFileURL(for: olderArchive))
        #expect(FileManager.default.fileExists(atPath: regenerated.path))
    }

    /// キーに更新日時を含めているため、アーカイブを差し替えると古いカバーを
    /// 返さない（`CoverImageCache` は identity のみのキーで同種の課題がある）。
    @Test func regeneratesTheCoverAfterTheSourceArchiveChanges() async throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try makeSourceDirectory(root)
        let archiveURL = source.appendingPathComponent("book.cbz")
        let oldPage = TestImageFixture.makePNGData(width: 8, height: 8, red: 1)
        try ArchiveFixtureBuilder.makeZip(at: archiveURL, entries: [.file("page1.png", contents: oldPage)])
        let firstCover = try #require(await store.coverFileURL(for: archiveURL))
        #expect(try Data(contentsOf: firstCover) == oldPage)

        // 更新日時の粒度（秒）を跨ぐよう、明示的に未来の日時を設定する。
        let newPage = TestImageFixture.makePNGData(width: 16, height: 16, red: 0, green: 1)
        try FileManager.default.removeItem(at: archiveURL)
        try ArchiveFixtureBuilder.makeZip(at: archiveURL, entries: [.file("page1.png", contents: newPage)])
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: archiveURL.path
        )

        let secondCover = try #require(await store.coverFileURL(for: archiveURL))

        #expect(secondCover != firstCover)
        #expect(try Data(contentsOf: secondCover) == newPage)
    }
}
