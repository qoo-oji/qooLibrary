import Foundation
import Testing

@testable import QooInfrastructure
@testable import QooKit

/// 各テストが自分専用の一時ディレクトリを `stagingRoot` として注入する
/// （`SecureExtractorTests` と同じ理由 — 実際のアプリコンテナ配下の共有
/// ディレクトリを直接使うと、他のテストスイートと並行実行された際に
/// 競合して不安定になる）。
@Suite struct ArchiveCompressorTests {
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
        let stagingRoot = root.appendingPathComponent("staging", isDirectory: true)

        let zipURL = try await ArchiveCompressor(stagingRoot: stagingRoot).compress(
            [source], destinationName: "page001", in: destinationFolder
        )

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
        let stagingRoot = root.appendingPathComponent("staging", isDirectory: true)

        let zipURL = try await ArchiveCompressor(stagingRoot: stagingRoot).compress(
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
        let stagingRoot = root.appendingPathComponent("staging", isDirectory: true)

        let zipURL = try await ArchiveCompressor(stagingRoot: stagingRoot).compress(
            [source], destinationName: "book", in: destinationFolder
        )

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
        let stagingRoot = root.appendingPathComponent("staging", isDirectory: true)

        let zipURL = try await ArchiveCompressor(stagingRoot: stagingRoot).compress(
            [source], destinationName: "a", in: destinationFolder
        )

        #expect(zipURL.lastPathComponent == "a 2.zip")
        #expect(try String(contentsOf: destinationFolder.appendingPathComponent("a.zip"), encoding: .utf8) == "existing")
    }

    /// [ユーザー要望] Windows で展開したときに `.DS_Store`/`._*`（AppleDouble
    /// サイドカー、リソースフォーク等の Mac 固有メタデータを別ファイルとして
    /// 保持する形式）がゴミとして残らないようにしたい、という要望への対応。
    /// `addRecursively`（`LibarchiveBackend.swift`）が `FileManager.contentsOfDirectory`
    /// を `.skipsHiddenFiles` 付きで呼んでおり、`.` で始まるこれらのファイルは
    /// そもそも列挙されず zip に入らない。また実際に含まれるファイルも
    /// `FileHandle` でデータフォークの中身だけを読んでおり（`copyfile`/xattr
    /// 保持系 API は使っていない）、APFS 上のファイルが持つリソースフォーク
    /// （`com.apple.ResourceFork` xattr）自体も最初から zip に含まれない。
    /// 実装済みの既存動作を明示的にロックするための回帰テスト。
    @Test func compressExcludesDSStoreAndAppleDoubleSidecarFiles() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceFolder = root.appendingPathComponent("MyBook")
        try FileManager.default.createDirectory(at: sourceFolder, withIntermediateDirectories: true)
        try Data("a".utf8).write(to: sourceFolder.appendingPathComponent("a.jpg"))
        try Data("ds-store".utf8).write(to: sourceFolder.appendingPathComponent(".DS_Store"))
        try Data("apple-double".utf8).write(to: sourceFolder.appendingPathComponent("._a.jpg"))
        let destinationFolder = root.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: destinationFolder, withIntermediateDirectories: true)
        let stagingRoot = root.appendingPathComponent("staging", isDirectory: true)

        let zipURL = try await ArchiveCompressor(stagingRoot: stagingRoot).compress(
            [sourceFolder], destinationName: "MyBook", in: destinationFolder
        )

        let listing = try await LibarchiveBackend.shared.listEntries(zipURL)
        let names = Set(listing.entries.map(\.pathname))
        #expect(names == ["MyBook/", "MyBook/a.jpg"])
    }

    @Test func compressDoesNotLeaveResidualStaging() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("a.txt")
        try Data("x".utf8).write(to: source)
        let destinationFolder = root.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: destinationFolder, withIntermediateDirectories: true)
        let stagingRoot = root.appendingPathComponent("staging", isDirectory: true)

        _ = try await ArchiveCompressor(stagingRoot: stagingRoot).compress(
            [source], destinationName: "a", in: destinationFolder
        )

        let remaining = (try? FileManager.default.contentsOfDirectory(
            at: stagingRoot, includingPropertiesForKeys: nil
        ).count) ?? 0
        #expect(remaining == 0)
    }
}
