import Foundation
import Testing

@testable import QooApplication
@testable import QooInfrastructure

/// `trash`/`restoreFromTrash` を経由する Undo（`CopyFilesCommand`/
/// `CreateFolderCommand`/`CreateAliasCommand`/`CompressCommand`/
/// `ExtractCommand`/`TrashCommand` のいずれも）は実 Finder ゴミ箱に触れるため
/// 自動テスト対象外にする [`FileOperationServiceTests`/`ArchiveCompressorTests`
/// と同じ方針]。それらは `execute()` の結果（ファイルが正しく作られたか）
/// までを検証し、`undo()` 自体は実機検証で確認する。`move`/`rename`/
/// `setLocked` は実 Trash に触れないため、Undo まで含めて自動テストする。
@MainActor
@Suite struct FileCommandsTests {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("qoo-filecommands-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func moveFilesCommandExecuteAndUndo() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source", isDirectory: true)
        let dest = root.appendingPathComponent("dest", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let file = source.appendingPathComponent("a.txt")
        try Data("x".utf8).write(to: file)

        let command = MoveFilesCommand(items: [file], destination: dest)
        _ = try await command.execute()
        #expect(FileManager.default.fileExists(atPath: dest.appendingPathComponent("a.txt").path))
        #expect(!FileManager.default.fileExists(atPath: file.path))

        let undoResult = try await command.undo()
        guard case .complete = undoResult else {
            Issue.record("expected .complete, got \(undoResult)")
            return
        }
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(!FileManager.default.fileExists(atPath: dest.appendingPathComponent("a.txt").path))
    }

    @Test func renameCommandExecuteAndUndo() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("original.txt")
        try Data("x".utf8).write(to: original)

        let command = RenameCommand(item: original, newName: "renamed.txt")
        _ = try await command.execute()
        let renamed = root.appendingPathComponent("renamed.txt")
        #expect(FileManager.default.fileExists(atPath: renamed.path))
        #expect(!FileManager.default.fileExists(atPath: original.path))

        let undoResult = try await command.undo()
        guard case .complete = undoResult else {
            Issue.record("expected .complete, got \(undoResult)")
            return
        }
        #expect(FileManager.default.fileExists(atPath: original.path))
    }

    @Test func setLockedCommandExecuteAndUndoTogglesLockState() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("a.txt")
        try Data("x".utf8).write(to: file)

        let command = SetLockedCommand(items: [file], locked: true)
        _ = try await command.execute()
        #expect(try file.resourceValues(forKeys: [.isUserImmutableKey]).isUserImmutable == true)

        let undoResult = try await command.undo()
        guard case .complete = undoResult else {
            Issue.record("expected .complete, got \(undoResult)")
            return
        }
        #expect(try file.resourceValues(forKeys: [.isUserImmutableKey]).isUserImmutable == false)
    }

    @Test func copyFilesCommandExecuteCreatesCopy() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("a.txt")
        try Data("x".utf8).write(to: source)
        let dest = root.appendingPathComponent("dest", isDirectory: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)

        let command = CopyFilesCommand(items: [source], destination: dest)
        let result = try await command.execute()

        guard case .success = result else {
            Issue.record("expected .success, got \(result)")
            return
        }
        #expect(FileManager.default.fileExists(atPath: dest.appendingPathComponent("a.txt").path))
        #expect(FileManager.default.fileExists(atPath: source.path)) // 元ファイルは残る
    }

    @Test func createFolderCommandExecuteCreatesDirectory() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let folderURL = root.appendingPathComponent("NewFolder")

        let command = CreateFolderCommand(url: folderURL)
        _ = try await command.execute()

        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: folderURL.path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
    }

    /// [UD-03] 「空でなければ削除を拒否する」判定は Trash を呼ぶ前の
    /// ガード節のため、実 Trash に触れずに検証できる。
    @Test func createFolderCommandUndoRefusesWhenNotEmpty() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let folderURL = root.appendingPathComponent("NewFolder")
        let command = CreateFolderCommand(url: folderURL)
        _ = try await command.execute()
        try Data("x".utf8).write(to: folderURL.appendingPathComponent("unexpected.txt"))

        let undoResult = try await command.undo()

        guard case .impossible(let reason) = undoResult else {
            Issue.record("expected .impossible, got \(undoResult)")
            return
        }
        #expect(reason.contains("空ではありません"))
        #expect(FileManager.default.fileExists(atPath: folderURL.path)) // 削除されていない
    }

    @Test func createAliasCommandExecuteCreatesAliasFile() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("a.txt")
        try Data("x".utf8).write(to: source)
        let dest = root.appendingPathComponent("dest", isDirectory: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)

        let command = CreateAliasCommand(source: source, destinationFolder: dest)
        _ = try await command.execute()

        let aliasURL = dest.appendingPathComponent("a.txt のエイリアス")
        #expect(FileManager.default.fileExists(atPath: aliasURL.path))
    }

    @Test func compressCommandExecuteCreatesReadableZip() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("page.jpg")
        try Data("x".utf8).write(to: source)
        let dest = root.appendingPathComponent("dest", isDirectory: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let stagingRoot = root.appendingPathComponent("staging", isDirectory: true)

        let command = CompressCommand(
            items: [source], destinationName: "book", destinationFolder: dest,
            compressor: ArchiveCompressor(stagingRoot: stagingRoot)
        )
        _ = try await command.execute()

        let zipURL = dest.appendingPathComponent("book.zip")
        #expect(FileManager.default.fileExists(atPath: zipURL.path))
        let listing = try await LibarchiveBackend.shared.listEntries(zipURL)
        #expect(listing.entries.map(\.pathname) == ["page.jpg"])
    }

    @Test func extractCommandExecuteWritesFilesToDestination() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("page.jpg")
        try Data("x".utf8).write(to: source)
        let archiveFolder = root.appendingPathComponent("archiveDest", isDirectory: true)
        try FileManager.default.createDirectory(at: archiveFolder, withIntermediateDirectories: true)
        let stagingRoot = root.appendingPathComponent("staging", isDirectory: true)
        let zipURL = try await ArchiveCompressor(stagingRoot: stagingRoot).compress(
            [source], destinationName: "book", in: archiveFolder
        )
        let extractDestination = root.appendingPathComponent("extracted", isDirectory: true)
        try FileManager.default.createDirectory(at: extractDestination, withIntermediateDirectories: true)

        let command = ExtractCommand(
            archiveURL: zipURL, destination: extractDestination,
            extractor: SecureExtractor(stagingRoot: stagingRoot)
        )
        _ = try await command.execute()

        #expect(FileManager.default.fileExists(atPath: extractDestination.appendingPathComponent("page.jpg").path))
    }
}
