import Foundation
import Testing

@testable import QooInfrastructure
@testable import QooKit

/// キャッシュの鍵に使う「内容の版」[`FileContentStamp`]。
@Suite struct FileMetadataTests {
    private func makeFile(_ contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("qoo-stamp-test-\(UUID().uuidString).txt")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test func stampIsStableForAnUnchangedFile() throws {
        let url = try makeFile("hello")
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(try FileMetadata.stamp(of: url) == FileMetadata.stamp(of: url))
    }

    /// 中身を書き換えたら別の鍵になる。ここが成り立たないと、外部で差し替えた
    /// ファイルに古いサムネイルが出続ける。
    @Test func stampChangesWhenTheContentChanges() throws {
        let url = try makeFile("hello")
        defer { try? FileManager.default.removeItem(at: url) }
        let before = try FileMetadata.stamp(of: url)

        try "hello, world".write(to: url, atomically: false, encoding: .utf8)
        let after = try FileMetadata.stamp(of: url)

        #expect(before != after)
        #expect(before.cacheKey != after.cacheKey)
    }

    /// 一方で `FileIdentity`（DB の同一性キー [ID-01]）は中身が変わっても
    /// 不変であるべき — だからこそキャッシュの鍵には使えない。
    @Test func identityIsUnchangedWhenOnlyTheContentChanges() throws {
        let url = try makeFile("hello")
        defer { try? FileManager.default.removeItem(at: url) }
        let before = try FileMetadata.identity(of: url)

        try "hello, world".write(to: url, atomically: false, encoding: .utf8)

        #expect(try FileMetadata.identity(of: url) == before)
    }

    @Test func differentFilesGetDifferentCacheKeys() throws {
        let first = try makeFile("a")
        let second = try makeFile("b")
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }

        #expect(try FileMetadata.stamp(of: first).cacheKey != FileMetadata.stamp(of: second).cacheKey)
    }

    @Test func stampFailsForAMissingFile() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("qoo-stamp-missing-\(UUID().uuidString)")
        #expect(throws: (any Error).self) { try FileMetadata.stamp(of: missing) }
    }
}
