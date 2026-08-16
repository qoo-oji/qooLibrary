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

    /// [2026-08 既知の不具合の一掃] 一括の途中で失敗しても、変えられた分の
    /// 受領書を保持して `.partial` を返し、Undo は**実際に変えられた分だけ**を
    /// 対象にすること。以前は受領書を捨てており（`_ = try await`）、Undo は
    /// `items` 全体へ適用されていた。
    @Test func setLockedCommandKeepsPartialReceiptsAndUndoesOnlyThem() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let good = root.appendingPathComponent("good.txt")
        try Data("x".utf8).write(to: good)
        let missing = root.appendingPathComponent("missing.txt")

        let command = SetLockedCommand(items: [good, missing], locked: true)
        let result = try await command.execute()
        guard case .partial(let succeeded, let failed) = result else {
            Issue.record("expected .partial, got \(result)")
            return
        }
        #expect(succeeded == 1)
        #expect(!failed.isEmpty)
        #expect(try good.resourceValues(forKeys: [.isUserImmutableKey]).isUserImmutable == true)

        // Undo は受領書のある 1 件だけを対象にするので、missing に触れず完了する。
        let undoResult = try await command.undo()
        guard case .complete = undoResult else {
            Issue.record("expected .complete, got \(undoResult)")
            return
        }
        #expect(try good.resourceValues(forKeys: [.isUserImmutableKey]).isUserImmutable == false)
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
    // MARK: - 完全削除 [FM-14〜FM-18]

    /// [UD-10][PD-05] 完全削除は Undo できない。**このコマンドだけが
    /// `isUndoable == false`。**
    @Test func deletePermanentlyCommandIsNotUndoable() async throws {
        let command = DeletePermanentlyCommand(items: [])
        #expect(command.isUndoable == false)
        let undo = try await command.undo()
        guard case .impossible = undo else {
            Issue.record("完全削除の undo は .impossible でなければならない")
            return
        }
    }

    /// [PD-05] `CommandStack` は Undo スタックへ積まない。積んでしまうと
    /// ⌘Z が「取り消せるように見えて実際には何も戻せない」状態になる。
    @Test func commandStackDoesNotPushDeletePermanentlyOntoTheUndoStack() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("gone.txt")
        try Data("bye".utf8).write(to: target)

        let stack = CommandStack()
        // 登録フォルダを一切持たない独立ストアを使い、実際の登録に触れない。
        let store = RegisteredFolderStore(storageURL: root.appendingPathComponent("registered.json"))
        _ = try await stack.run(DeletePermanentlyCommand(
            items: [target], options: .unattended, registeredFolders: store
        ))

        #expect(!FileManager.default.fileExists(atPath: target.path))
        #expect(stack.canUndo == false)
        #expect(stack.undoTitle == nil)
        // [HS-01] 履歴には残る（Undo できないことと、記録が残らないことは別）。
        #expect(stack.operationHistory.count == 1)
    }

    /// [ER-13][ER-14] 一部が失敗しても中断せず、結果を `.partial` で返す。
    @Test func deletePermanentlyCommandReportsPartialResultWithoutAborting() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let present = root.appendingPathComponent("present.txt")
        try Data("x".utf8).write(to: present)
        let missing = root.appendingPathComponent("missing.txt")

        let store = RegisteredFolderStore(storageURL: root.appendingPathComponent("registered.json"))
        let command = DeletePermanentlyCommand(
            items: [missing, present], options: .unattended, registeredFolders: store
        )
        let result = try await command.execute()

        #expect(!FileManager.default.fileExists(atPath: present.path))
        guard case .partial(let succeeded, let failed) = result else {
            Issue.record("一部失敗は .partial で返るべき")
            return
        }
        #expect(succeeded == 1)
        #expect(failed.count == 1)
        #expect(command.outcome?.succeededCount == 1)
    }

    /// [ユーザー要望] 完全削除で実体を失ったライブラリ／テンポラリ登録は
    /// 強制的に解除する。
    @Test func deletePermanentlyForciblyUnregistersDeletedRegisteredFolders() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = root.appendingPathComponent("MyLibrary", isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)

        let store = RegisteredFolderStore(storageURL: root.appendingPathComponent("registered.json"))
        _ = try await store.register(url: library, kind: .library, displayName: "マイライブラリ")
        #expect(await store.folders(kind: .library).count == 1)

        let command = DeletePermanentlyCommand(
            items: [library], options: .unattended, registeredFolders: store
        )
        _ = try await command.execute()

        #expect(!FileManager.default.fileExists(atPath: library.path))
        #expect(await store.folders(kind: .library).isEmpty)
        #expect(command.unregisteredFolders.map(\.displayName) == ["マイライブラリ"])
    }

    /// 削除に**失敗した**登録フォルダの登録は残す（巻き添えで解除しない）。
    @Test func deletePermanentlyKeepsRegistrationWhenTheDeletionItselfFailed() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = root.appendingPathComponent("MyLibrary", isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)

        let store = RegisteredFolderStore(storageURL: root.appendingPathComponent("registered.json"))
        _ = try await store.register(url: library, kind: .library, displayName: "マイライブラリ")

        // resolver が `.skip` を返す＝削除されない（ロック済み扱い）。
        try setLocked(library, true)
        defer { try? setLocked(library, false) }
        let command = DeletePermanentlyCommand(
            items: [library],
            options: DeletePermanentlyOptions(lockedItemResolver: { _ in .skip }),
            registeredFolders: store
        )
        _ = try await command.execute()

        #expect(FileManager.default.fileExists(atPath: library.path))
        #expect(await store.folders(kind: .library).count == 1)
        #expect(command.unregisteredFolders.isEmpty)
    }

    private func setLocked(_ url: URL, _ locked: Bool) throws {
        var mutable = url
        var values = URLResourceValues()
        values.isUserImmutable = locked
        try mutable.setResourceValues(values)
    }

}
