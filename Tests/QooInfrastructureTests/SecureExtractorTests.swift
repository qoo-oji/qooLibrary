import Foundation
import Testing

@testable import QooInfrastructure
@testable import QooKit

/// `SecureExtractor` はステージングを ``SecureExtractor/stagingRoot()``
/// （アプリコンテナ配下）に作るため、実テンプディレクトリを直接指定できない。
/// ここではその制約を踏まえ、実際にアプリコンテナ配下へステージングを作り、
/// 展開先だけをテンプディレクトリにして検証する。
// `SecureExtractor.stagingRoot()` はアプリコンテナ配下の共有ディレクトリの
// ため、テストを並行実行すると互いのステージング作成/削除が干渉する。
// このスイートだけ直列実行にする。
@Suite(.serialized) struct SecureExtractorTests {
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

        let extractor = SecureExtractor()
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

        let before = (try? FileManager.default.contentsOfDirectory(
            at: SecureExtractor.stagingRoot(), includingPropertiesForKeys: nil
        ).count) ?? 0

        _ = try await SecureExtractor().extract(archiveURL, options: ExtractOptions(destination: destination))

        let after = (try? FileManager.default.contentsOfDirectory(
            at: SecureExtractor.stagingRoot(), includingPropertiesForKeys: nil
        ).count) ?? 0
        #expect(after == before) // 昇格が成功したのでステージングは残らない
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

        var options = ExtractOptions(destination: destination)
        options.limits.maxUncompressedBytes = 1_000

        let before = (try? FileManager.default.contentsOfDirectory(
            at: SecureExtractor.stagingRoot(), includingPropertiesForKeys: nil
        ).count) ?? 0

        await #expect(throws: ExtractError.expansionLimitExceeded(limit: 1_000)) {
            try await SecureExtractor().extract(archiveURL, options: options)
        }

        let after = (try? FileManager.default.contentsOfDirectory(
            at: SecureExtractor.stagingRoot(), includingPropertiesForKeys: nil
        ).count) ?? 0
        #expect(after == before) // 失敗時にステージングを残さない [EX-24]
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

        await #expect(throws: ExtractError.unsupportedFormat) {
            try await SecureExtractor().extract(notAnArchive, options: ExtractOptions(destination: destination))
        }
    }

    @Test func cleanupResidualStagingRemovesLeftoverDirectories() async throws {
        let leftover = SecureExtractor.stagingRoot().appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: leftover, withIntermediateDirectories: true)
        try "leftover".write(to: leftover.appendingPathComponent("stale.txt"), atomically: true, encoding: .utf8)

        await SecureExtractor.cleanupResidualStaging()

        #expect(!FileManager.default.fileExists(atPath: leftover.path))
    }
}
