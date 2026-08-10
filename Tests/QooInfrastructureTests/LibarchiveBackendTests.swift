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
}
