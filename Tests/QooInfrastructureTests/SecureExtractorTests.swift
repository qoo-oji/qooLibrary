import Foundation
import Testing

@testable import QooInfrastructure
@testable import QooKit

/// `SecureExtractor` はステージングを実際のアプリコンテナ配下（既定の
/// `SecureExtractor.defaultStagingRoot()`）に作るが、テストでは各テストが
/// 自分専用の一時ディレクトリを `stagingRoot` として注入する。共有の実
/// ディレクトリを使うと、他のテストスイート（`ArchiveCompressorTests` 等）
/// と並行実行された際に「実行前後の件数比較」が競合して不安定になる
/// （CI で実際に発生した）。
@Suite struct SecureExtractorTests {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("qoo-secure-extractor-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func extractPromotesEntriesToDestination() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let archiveURL = root.appendingPathComponent("book.zip")
        try ArchiveFixtureBuilder.makeZip(at: archiveURL, entries: [
            .file("page001.jpg", contents: Data("first".utf8)),
            .file("page002.jpg", contents: Data("second".utf8)),
        ])
        let destination = root.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let stagingRoot = root.appendingPathComponent("staging", isDirectory: true)

        let extractor = SecureExtractor(stagingRoot: stagingRoot)
        let result = try await extractor.extract(archiveURL, options: ExtractOptions(destination: destination))

        #expect(result.extractedCount == 2)
        #expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent("page001.jpg").path))
        #expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent("page002.jpg").path))
    }

    @Test func extractDoesNotLeaveResidualStagingOnSuccess() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let archiveURL = root.appendingPathComponent("book.zip")
        try ArchiveFixtureBuilder.makeZip(at: archiveURL, entries: [.file("a.txt", contents: Data("x".utf8))])
        let destination = root.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let stagingRoot = root.appendingPathComponent("staging", isDirectory: true)

        _ = try await SecureExtractor(stagingRoot: stagingRoot).extract(
            archiveURL, options: ExtractOptions(destination: destination)
        )

        let remaining = (try? FileManager.default.contentsOfDirectory(
            at: stagingRoot, includingPropertiesForKeys: nil
        ).count) ?? 0
        #expect(remaining == 0) // 昇格が成功したのでステージングは残らない
    }

    @Test func extractCleansUpStagingWhenLimitExceeded() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let archiveURL = root.appendingPathComponent("big.zip")
        try ArchiveFixtureBuilder.makeZip(at: archiveURL, entries: [
            .file("big.bin", contents: Data(repeating: 0x41, count: 10_000)),
        ])
        let destination = root.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let stagingRoot = root.appendingPathComponent("staging", isDirectory: true)

        var options = ExtractOptions(destination: destination)
        options.limits.maxUncompressedBytes = 1_000

        await #expect(throws: ExtractError.expansionLimitExceeded(limit: 1_000)) {
            try await SecureExtractor(stagingRoot: stagingRoot).extract(archiveURL, options: options)
        }

        let remaining = (try? FileManager.default.contentsOfDirectory(
            at: stagingRoot, includingPropertiesForKeys: nil
        ).count) ?? 0
        #expect(remaining == 0) // 失敗時にステージングを残さない [EX-24]
        // 展開先にも中途半端な書き込みが残っていないこと。
        #expect((try? FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty) == true)
    }

    @Test func extractRejectsUnsupportedFormat() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let notAnArchive = root.appendingPathComponent("notes.txt")
        try "hello".write(to: notAnArchive, atomically: true, encoding: .utf8)
        let destination = root.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let stagingRoot = root.appendingPathComponent("staging", isDirectory: true)

        await #expect(throws: ExtractError.unsupportedFormat) {
            try await SecureExtractor(stagingRoot: stagingRoot).extract(
                notAnArchive, options: ExtractOptions(destination: destination)
            )
        }
    }

    /// `cleanupResidualStaging()` は常に実際のアプリコンテナ配下
    /// （`defaultStagingRoot()`）を対象にする、唯一この振る舞いを検証する
    /// テスト。特定の UUID 名のディレクトリの有無だけを見るため、他の
    /// テストと共有ディレクトリを取り合っても競合しない。
    @Test func cleanupResidualStagingRemovesLeftoverDirectories() async throws {
        let leftover = SecureExtractor.defaultStagingRoot().appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: leftover, withIntermediateDirectories: true)
        try "leftover".write(to: leftover.appendingPathComponent("stale.txt"), atomically: true, encoding: .utf8)

        await SecureExtractor.cleanupResidualStaging()

        #expect(!FileManager.default.fileExists(atPath: leftover.path))
    }
}
