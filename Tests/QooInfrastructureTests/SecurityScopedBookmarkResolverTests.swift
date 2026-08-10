import Foundation
import Testing

@testable import QooInfrastructure

@Suite struct SecurityScopedBookmarkResolverTests {
    let resolver = SecurityScopedBookmarkResolver()

    /// アプリのサンドボックス外（プレーンな `swift test` プロセス）では
    /// security-scope の権限強制そのものは働かないが、生成・解決の往復と
    /// URL の一致は検証できる [SB-02]。実サンドボックス下での動作確認は
    /// qooLibraryApp 側の手動検証手順で別途行う（README 参照）。
    @Test func bookmarkRoundTripsToTheSameURL() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("qoo-bookmark-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let data = try resolver.makeBookmark(for: tempDir)
        let resolution = resolver.resolve(data)

        guard case .resolved(let url, let isStale) = resolution else {
            Issue.record("expected .resolved, got \(resolution)")
            return
        }
        #expect(url.standardizedFileURL.path == tempDir.standardizedFileURL.path)
        #expect(isStale == false)
    }

    @Test func resolveReturnsOfflineForGarbageData() {
        let garbage = Data([0x00, 0x01, 0x02, 0x03])
        let resolution = resolver.resolve(garbage)
        guard case .offline = resolution else {
            Issue.record("expected .offline for malformed bookmark data, got \(resolution)")
            return
        }
    }

    @Test func withAccessRunsBodyAndScopesAccess() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("qoo-bookmark-access-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let data = try resolver.makeBookmark(for: tempDir)
        let observedPath = try await resolver.withAccess(data) { url in
            url.standardizedFileURL.path
        }
        #expect(observedPath == tempDir.standardizedFileURL.path)
    }

    @Test func withAccessThrowsOfflineForGarbageData() async {
        let garbage = Data([0x00, 0x01, 0x02, 0x03])
        await #expect(throws: BookmarkAccessError.self) {
            try await resolver.withAccess(garbage) { _ in }
        }
    }
}
