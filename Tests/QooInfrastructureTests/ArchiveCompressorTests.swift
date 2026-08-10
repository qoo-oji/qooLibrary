import Foundation
import Testing

@testable import QooInfrastructure
@testable import QooKit

// `SecureExtractor.stagingRoot()` を共有するため直列実行する
// （`SecureExtractorTests` と同じ理由）。
@Suite(.serialized) struct ArchiveCompressorTests {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("qoo-compressor-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func compressSingleFileProducesReadableZip() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("page001.jpg")
        try Data("hello".utf8).write(to: source)
        let destinationFolder = root.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: destinationFolder, withIntermediateDirectories: true)

        let zipURL = try await ArchiveCompressor().compress([source], destinationName: "page001", in: destinationFolder)

        #expect(zipURL.lastPathComponent == "page001.zip")
        #expect(FileManager.default.fileExists(atPath: zipURL.path))

        let listing = try await LibarchiveBackend.shared.listEntries(zipURL)
        #expect(listing.entries.map(\.pathname) == ["page001.jpg"])
    }

    @Test func compressFolderPreservesStructure() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceFolder = root.appendingPathComponent("MyBook")
        try FileManager.default.createDirectory(at: sourceFolder, withIntermediateDirectories: true)
        try Data("a".utf8).write(to: sourceFolder.appendingPathComponent("a.jpg"))
        try FileManager.default.createDirectory(
            at: sourceFolder.appendingPathComponent("sub"), withIntermediateDirectories: true
        )
        try Data("b".utf8).write(to: sourceFolder.appendingPathComponent("sub/b.jpg"))
        let destinationFolder = root.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: destinationFolder, withIntermediateDirectories: true)

        let zipURL = try await ArchiveCompressor().compress(
            [sourceFolder], destinationName: "MyBook", in: destinationFolder
        )

        let listing = try await LibarchiveBackend.shared.listEntries(zipURL)
        let names = Set(listing.entries.map(\.pathname))
        #expect(names.contains("MyBook/"))
        #expect(names.contains("MyBook/a.jpg"))
        #expect(names.contains("MyBook/sub/"))
        #expect(names.contains("MyBook/sub/b.jpg"))
    }

    @Test func compressNormalizesEntryNamesToNFC() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        // が = NFC（U+304C）を、あえて NFD（か U+304B + 濁点 U+3099）へ分解して
        // ファイルを作る。macOS の FS はこの手の分解形を返すことがある。
        // 注意: Swift の `String` の `==` は正準等価（NFC と NFD を同一視）で
        // 比較するため、正規化が効いているかどうかは UTF-8 バイト列の長さで
        // 検証する必要がある（分解形は結合文字の分だけバイト数が多い）。
        let nfcName = "らくがき"
        let nfdName = nfcName.decomposedStringWithCanonicalMapping
        #expect(Array(nfcName.utf8) != Array(nfdName.utf8)) // 前提: 実際に分解形になっている

        let source = root.appendingPathComponent("\(nfdName).jpg")
        try Data("x".utf8).write(to: source)
        let destinationFolder = root.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: destinationFolder, withIntermediateDirectories: true)

        let zipURL = try await ArchiveCompressor().compress([source], destinationName: "book", in: destinationFolder)

        let listing = try await LibarchiveBackend.shared.listEntries(zipURL)
        let decodedPathname = listing.entries.first?.pathname ?? ""
        #expect(Array(decodedPathname.utf8) == Array("\(nfcName).jpg".utf8)) // NFC のバイト列になっている
        #expect(Array(decodedPathname.utf8) != Array("\(nfdName).jpg".utf8)) // NFD のバイト列のままではない
    }

    @Test func compressWithConflictKeepsBothByDefault() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("a.txt")
        try Data("x".utf8).write(to: source)
        let destinationFolder = root.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: destinationFolder, withIntermediateDirectories: true)
        try Data("existing".utf8).write(to: destinationFolder.appendingPathComponent("a.zip"))

        let zipURL = try await ArchiveCompressor().compress([source], destinationName: "a", in: destinationFolder)

        #expect(zipURL.lastPathComponent == "a 2.zip")
        #expect(try String(contentsOf: destinationFolder.appendingPathComponent("a.zip"), encoding: .utf8) == "existing")
    }

    @Test func compressDoesNotLeaveResidualStaging() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("a.txt")
        try Data("x".utf8).write(to: source)
        let destinationFolder = root.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: destinationFolder, withIntermediateDirectories: true)

        let before = (try? FileManager.default.contentsOfDirectory(
            at: SecureExtractor.stagingRoot(), includingPropertiesForKeys: nil
        ).count) ?? 0

        _ = try await ArchiveCompressor().compress([source], destinationName: "a", in: destinationFolder)

        let after = (try? FileManager.default.contentsOfDirectory(
            at: SecureExtractor.stagingRoot(), includingPropertiesForKeys: nil
        ).count) ?? 0
        #expect(after == before)
    }
}
