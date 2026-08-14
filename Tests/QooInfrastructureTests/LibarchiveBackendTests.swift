import Foundation
import Testing

@testable import QooInfrastructure
@testable import QooKit

@Suite struct LibarchiveBackendTests {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("qoo-archive-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func canReadRecognizesSupportedExtensions() async {
        let backend = LibarchiveBackend.shared
        #expect(await backend.canRead(URL(fileURLWithPath: "/tmp/book.zip")))
        #expect(await backend.canRead(URL(fileURLWithPath: "/tmp/book.cbz")))
        #expect(await backend.canRead(URL(fileURLWithPath: "/tmp/book.7z")))
        #expect(await !backend.canRead(URL(fileURLWithPath: "/tmp/book.txt")))
    }

    /// 実機検証で発見した回帰: UTF-8 フラグの立っていない zip 内の
    /// Shift_JIS（CP932）ファイル名が、libarchive の生バイト列をそのまま
    /// `String(cString:)` していたせいで U+FFFD の連続に化けていた。
    @Test func listEntriesDecodesShiftJISNamesWithoutUTF8Flag() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let archiveURL = root.appendingPathComponent("manga.zip")

        let japaneseName = "第1巻 サンプル.jpg"
        guard let shiftJISBytes = japaneseName.data(using: .shiftJIS) else {
            Issue.record("Shift_JIS へのエンコードに失敗した")
            return
        }
        try ArchiveFixtureBuilder.makeZip(at: archiveURL, entries: [
            .fileWithRawPathname(shiftJISBytes, contents: Data("cover".utf8)),
        ])

        let listing = try await LibarchiveBackend.shared.listEntries(archiveURL)

        #expect(listing.detectedEncoding == .shiftJIS)
        #expect(listing.entries.first?.pathname == japaneseName)
    }

    @Test func extractDecodesShiftJISNamesOnDisk() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let archiveURL = root.appendingPathComponent("manga.zip")

        let japaneseName = "第1巻 サンプル.jpg"
        guard let shiftJISBytes = japaneseName.data(using: .shiftJIS) else {
            Issue.record("Shift_JIS へのエンコードに失敗した")
            return
        }
        try ArchiveFixtureBuilder.makeZip(at: archiveURL, entries: [
            .fileWithRawPathname(shiftJISBytes, contents: Data("cover".utf8)),
        ])

        // `SecureExtractor` を経由せず `LibarchiveBackend` 単体で確認する
        // ため、`listEntries` の判定結果を手動で `options.encoding` に渡す
        // （`SecureExtractor` が普段代行している配線）。
        let listing = try await LibarchiveBackend.shared.listEntries(archiveURL)
        let staging = root.appendingPathComponent("staging", isDirectory: true)
        var options = ExtractOptions(destination: staging)
        options.encoding = listing.detectedEncoding

        _ = try await LibarchiveBackend.shared.extract(archiveURL, to: staging, options: options)

        #expect(FileManager.default.fileExists(atPath: staging.appendingPathComponent(japaneseName).path))
    }

    @Test func listEntriesReturnsAllEntries() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let archiveURL = root.appendingPathComponent("book.zip")
        try ArchiveFixtureBuilder.makeZip(at: archiveURL, entries: [
            .file("page001.jpg", contents: Data(repeating: 0xFF, count: 100)),
            .file("page002.jpg", contents: Data(repeating: 0xEE, count: 200)),
            .file("info/meta.txt", contents: Data("hello".utf8)),
        ])

        let listing = try await LibarchiveBackend.shared.listEntries(archiveURL)

        #expect(listing.entries.count == 3)
        #expect(listing.entries.map(\.pathname).sorted() == ["info/meta.txt", "page001.jpg", "page002.jpg"])
        #expect(listing.entries.first { $0.pathname == "page002.jpg" }?.uncompressedSize == 200)
    }

    @Test func extractWritesFilesToStagingWithCorrectContents() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let archiveURL = root.appendingPathComponent("book.zip")
        try ArchiveFixtureBuilder.makeZip(at: archiveURL, entries: [
            .file("page001.jpg", contents: Data("first page".utf8)),
            .file("sub/page002.jpg", contents: Data("second page".utf8)),
        ])

        let staging = root.appendingPathComponent("staging", isDirectory: true)
        let options = ExtractOptions(destination: staging)
        let result = try await LibarchiveBackend.shared.extract(archiveURL, to: staging, options: options)

        #expect(result.extractedCount == 2)
        #expect(result.rejected.isEmpty)
        let page1 = try String(contentsOf: staging.appendingPathComponent("page001.jpg"), encoding: .utf8)
        #expect(page1 == "first page")
        let page2 = try String(contentsOf: staging.appendingPathComponent("sub/page002.jpg"), encoding: .utf8)
        #expect(page2 == "second page")
    }

    /// [フェーズ1完了時の監査で発見した回帰] `FileOperationService.nextAvailableName`
    /// では「衝突先の名前に既に連番サフィックスが付いていれば剥がしてから
    /// 採番する」という修正が既に適用済みだったが、EX-15（大文字小文字のみ
    /// 異なるエントリの衝突）で使われるこちらの同名ヘルパーには反映されて
    /// おらず、`photo 2.txt` の衝突が `photo 2 2.txt` に積み重なってしまう
    /// 同種のバグが再発していた。
    @Test func extractRenumbersInsteadOfStackingWhenColliderAlreadyHasACopyNumberSuffix() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let archiveURL = root.appendingPathComponent("collide.zip")
        try ArchiveFixtureBuilder.makeZip(at: archiveURL, entries: [
            .file("photo 2.txt", contents: Data("first".utf8)),
            .file("photo 2.txt", contents: Data("second".utf8)),
        ])

        let staging = root.appendingPathComponent("staging", isDirectory: true)
        let options = ExtractOptions(destination: staging)
        let result = try await LibarchiveBackend.shared.extract(archiveURL, to: staging, options: options)

        #expect(result.extractedCount == 2)
        #expect(result.renamedForCaseCollision == [ExtractRename(from: "photo 2.txt", to: "photo 3.txt")])
        #expect(FileManager.default.fileExists(atPath: staging.appendingPathComponent("photo 3.txt").path))
        #expect(!FileManager.default.fileExists(atPath: staging.appendingPathComponent("photo 2 2.txt").path))
    }

    @Test func extractRejectsPathTraversalEntries() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let archiveURL = root.appendingPathComponent("evil.zip")
        try ArchiveFixtureBuilder.makeZip(at: archiveURL, entries: [
            .file("../../etc/evil.txt", contents: Data("pwned".utf8)),
            .file("ok.txt", contents: Data("fine".utf8)),
        ])

        let staging = root.appendingPathComponent("staging", isDirectory: true)
        let result = try await LibarchiveBackend.shared.extract(archiveURL, to: staging, options: ExtractOptions(destination: staging))

        #expect(result.extractedCount == 1)
        #expect(result.rejected.count == 1)
        #expect(result.rejected.first?.reason == .parentTraversal)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("../etc/evil.txt").standardizedFileURL.path))
    }

    @Test func extractRejectsAbsolutePathEntries() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let archiveURL = root.appendingPathComponent("evil.zip")
        try ArchiveFixtureBuilder.makeZip(at: archiveURL, entries: [
            .file("/etc/evil.txt", contents: Data("pwned".utf8)),
        ])

        let staging = root.appendingPathComponent("staging", isDirectory: true)
        let result = try await LibarchiveBackend.shared.extract(archiveURL, to: staging, options: ExtractOptions(destination: staging))

        #expect(result.extractedCount == 0)
        #expect(result.rejected.first?.reason == .absolutePath)
    }

    @Test func extractSkipsSymlinksByDefault() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let archiveURL = root.appendingPathComponent("withlink.zip")
        try ArchiveFixtureBuilder.makeZip(at: archiveURL, entries: [
            .symlink("link.txt", target: "/etc/passwd"),
            .file("ok.txt", contents: Data("fine".utf8)),
        ])

        let staging = root.appendingPathComponent("staging", isDirectory: true)
        let result = try await LibarchiveBackend.shared.extract(archiveURL, to: staging, options: ExtractOptions(destination: staging))

        #expect(result.extractedCount == 1)
        #expect(result.rejected.first?.reason == .symlinkSkipped)
        #expect(!FileManager.default.fileExists(atPath: staging.appendingPathComponent("link.txt").path))
    }

    @Test func extractThrowsWhenEntryCountExceedsLimit() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let archiveURL = root.appendingPathComponent("many.zip")
        try ArchiveFixtureBuilder.makeZip(at: archiveURL, entries: (1...5).map {
            .file("file\($0).txt", contents: Data("x".utf8))
        })

        let staging = root.appendingPathComponent("staging", isDirectory: true)
        var options = ExtractOptions(destination: staging)
        options.limits.maxEntries = 3

        await #expect(throws: ExtractError.tooManyEntries(limit: 3)) {
            try await LibarchiveBackend.shared.extract(archiveURL, to: staging, options: options)
        }
    }

    @Test func extractThrowsWhenUncompressedSizeExceedsLimit() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let archiveURL = root.appendingPathComponent("big.zip")
        try ArchiveFixtureBuilder.makeZip(at: archiveURL, entries: [
            .file("big.bin", contents: Data(repeating: 0x41, count: 10_000)),
        ])

        let staging = root.appendingPathComponent("staging", isDirectory: true)
        var options = ExtractOptions(destination: staging)
        options.limits.maxUncompressedBytes = 1_000

        await #expect(throws: ExtractError.expansionLimitExceeded(limit: 1_000)) {
            try await LibarchiveBackend.shared.extract(archiveURL, to: staging, options: options)
        }
    }

    @Test func extractThrowsWhenCompressionRatioExceedsLimit() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let archiveURL = root.appendingPathComponent("bomb.zip")
        // 高圧縮率になるよう、同じバイトの繰り返しで大きな非圧縮データを作る。
        try ArchiveFixtureBuilder.makeZip(at: archiveURL, entries: [
            .file("bomb.bin", contents: Data(repeating: 0x00, count: 5_000_000)),
        ])

        let staging = root.appendingPathComponent("staging", isDirectory: true)
        var options = ExtractOptions(destination: staging)
        options.limits.maxUncompressedBytes = 1_000_000_000 // 総量では引っかからないようにする
        options.limits.ratioAbort = 10 // 圧縮ファイル自体のサイズの10倍を超えたら中断

        await #expect(throws: ExtractError.self) {
            try await LibarchiveBackend.shared.extract(archiveURL, to: staging, options: options)
        }
    }

    // MARK: - readEntry [9.6 節、サムネイル生成用の単一エントリ読み込み]

    @Test func readEntryReturnsTheMatchingEntrysContents() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let archiveURL = root.appendingPathComponent("book.cbz")
        try ArchiveFixtureBuilder.makeZip(at: archiveURL, entries: [
            .file("page001.jpg", contents: Data("first page".utf8)),
            .file("page002.jpg", contents: Data("second page".utf8)),
        ])

        let listing = try await LibarchiveBackend.shared.listEntries(archiveURL)
        let target = try #require(listing.entries.first { $0.pathname == "page002.jpg" })

        let data = try await LibarchiveBackend.shared.readEntry(
            archiveURL, entry: target, encoding: listing.detectedEncoding, maxBytes: 1_000
        )

        #expect(String(data: data, encoding: .utf8) == "second page")
    }

    @Test func readEntryThrowsEntryNotFoundForUnknownPathname() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let archiveURL = root.appendingPathComponent("book.cbz")
        try ArchiveFixtureBuilder.makeZip(at: archiveURL, entries: [
            .file("page001.jpg", contents: Data("first page".utf8)),
        ])
        let bogusEntry = ArchiveEntry(pathname: "does-not-exist.jpg", uncompressedSize: 0, isDirectory: false, isSymlink: false, isSpecialEntry: false)

        await #expect(throws: ExtractError.entryNotFound("does-not-exist.jpg")) {
            try await LibarchiveBackend.shared.readEntry(archiveURL, entry: bogusEntry, encoding: .utf8, maxBytes: 1_000)
        }
    }

    @Test func readEntryThrowsWhenEntryExceedsMaxBytes() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let archiveURL = root.appendingPathComponent("big.cbz")
        try ArchiveFixtureBuilder.makeZip(at: archiveURL, entries: [
            .file("page001.jpg", contents: Data(repeating: 0x00, count: 10_000)),
        ])

        let listing = try await LibarchiveBackend.shared.listEntries(archiveURL)
        let target = try #require(listing.entries.first)

        await #expect(throws: ExtractError.entryReadLimitExceeded(limit: 100)) {
            try await LibarchiveBackend.shared.readEntry(archiveURL, entry: target, encoding: listing.detectedEncoding, maxBytes: 100)
        }
    }

    // MARK: - compress [環境設定「圧縮／展開」タブ、AR-10/AR-11 の拡張]

    @Test func compressWritesReadableZipAtEachLevel() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceFile = root.appendingPathComponent("page.txt")
        try Data("hello".utf8).write(to: sourceFile)

        for level in ZipCompressionLevel.allCases {
            let archiveURL = root.appendingPathComponent("book-\(level.rawValue).zip")
            let options = CompressionOptions(format: .zip, zipLevel: level)
            try await LibarchiveBackend.shared.compress([sourceFile], to: archiveURL, options: options)

            let listing = try await LibarchiveBackend.shared.listEntries(archiveURL)
            #expect(listing.entries.map(\.pathname) == ["page.txt"])
        }
    }

    @Test(arguments: [SevenZipCodec.ppmd, .bzip2, .deflate, .copy])
    func compressWritesReadableSevenZipWithEachCodec(_ codec: SevenZipCodec) async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceFile = root.appendingPathComponent("page.txt")
        try Data("hello 7z".utf8).write(to: sourceFile)
        let archiveURL = root.appendingPathComponent("book.7z")

        let options = CompressionOptions(format: .sevenZip, sevenZipCodec: codec)
        try await LibarchiveBackend.shared.compress([sourceFile], to: archiveURL, options: options)

        let staging = root.appendingPathComponent("staging-\(codec.rawValue)", isDirectory: true)
        let result = try await LibarchiveBackend.shared.extract(archiveURL, to: staging, options: ExtractOptions(destination: staging))
        #expect(result.extractedCount == 1)
        let content = try String(contentsOf: staging.appendingPathComponent("page.txt"), encoding: .utf8)
        #expect(content == "hello 7z")
    }

    @Test(arguments: [ArchiveEncryptionMethod.zipTraditional, .aes128, .aes256])
    func compressWithEncryptionRequiresCorrectPassphraseToExtract(_ encryption: ArchiveEncryptionMethod) async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceFile = root.appendingPathComponent("secret.txt")
        try Data("classified".utf8).write(to: sourceFile)
        let archiveURL = root.appendingPathComponent("secret.zip")

        let options = CompressionOptions(format: .zip, encryption: encryption)
        try await LibarchiveBackend.shared.compress([sourceFile], to: archiveURL, options: options, passphrase: "sesame")

        // パスワード無しでは中身を正しく読めない [ExtractError.passwordProtected]。
        let stagingNoPassword = root.appendingPathComponent("staging-none", isDirectory: true)
        await #expect(throws: ExtractError.passwordProtected) {
            try await LibarchiveBackend.shared.extract(
                archiveURL, to: stagingNoPassword, options: ExtractOptions(destination: stagingNoPassword)
            )
        }

        // 誤ったパスワードでは復号に失敗する [ExtractError.incorrectPassphrase]。
        let stagingWrongPassword = root.appendingPathComponent("staging-wrong", isDirectory: true)
        await #expect(throws: ExtractError.incorrectPassphrase) {
            try await LibarchiveBackend.shared.extract(
                archiveURL, to: stagingWrongPassword,
                options: ExtractOptions(destination: stagingWrongPassword, passphrase: "wrong")
            )
        }

        // 正しいパスワードでは展開できる。
        let stagingCorrect = root.appendingPathComponent("staging-correct", isDirectory: true)
        let result = try await LibarchiveBackend.shared.extract(
            archiveURL, to: stagingCorrect,
            options: ExtractOptions(destination: stagingCorrect, passphrase: "sesame")
        )
        #expect(result.extractedCount == 1)
        let content = try String(contentsOf: stagingCorrect.appendingPathComponent("secret.txt"), encoding: .utf8)
        #expect(content == "classified")
    }

    @Test func compressWithEncryptionButNoPassphraseThrows() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceFile = root.appendingPathComponent("secret.txt")
        try Data("classified".utf8).write(to: sourceFile)
        let archiveURL = root.appendingPathComponent("secret.zip")

        await #expect(throws: ExtractError.passwordProtected) {
            try await LibarchiveBackend.shared.compress(
                [sourceFile], to: archiveURL, options: CompressionOptions(format: .zip, encryption: .aes256)
            )
        }
    }

    /// 7z は libarchive の書き込み側に暗号化オプションが存在しないため、
    /// `options.encryption` が設定されていても無視される
    /// （防御的な設計、CLAUDE.md 参照）。
    @Test func compressIgnoresEncryptionForSevenZip() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceFile = root.appendingPathComponent("page.txt")
        try Data("hello".utf8).write(to: sourceFile)
        let archiveURL = root.appendingPathComponent("book.7z")

        let options = CompressionOptions(format: .sevenZip, encryption: .aes256)
        try await LibarchiveBackend.shared.compress([sourceFile], to: archiveURL, options: options)

        let listing = try await LibarchiveBackend.shared.listEntries(archiveURL)
        #expect(listing.entries.map(\.pathname) == ["page.txt"])
    }
}
