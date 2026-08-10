import Foundation
import Testing

@testable import QooInfrastructure

/// `trash()`/`restoreFromTrash()` は `NSWorkspace.shared.recycle` を呼び、
/// 実行環境の実際の Finder ゴミ箱に触れてしまうため、自動テストの対象外とする。
/// 実サンドボックスアプリでの手動検証で確認する（README/コミットログ参照）。
@Suite struct FileOperationServiceTests {
    let service = FileOperationService()

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("qoo-fileops-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func write(_ text: String, to url: URL) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    @Test func createDirectoryMakesAFolder() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let newDir = root.appendingPathComponent("child")
        let receipt = try await service.createDirectory(at: newDir)

        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: newDir.path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
        #expect(receipt.kind == .createDirectory)
        #expect(receipt.after != nil)
    }

    @Test func copyDuplicatesTheFile() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let destDir = root.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)

        let source = root.appendingPathComponent("a.txt")
        try write("hello", to: source)

        let receipts = try await service.copy([source], to: destDir)

        #expect(receipts.count == 1)
        #expect(FileManager.default.fileExists(atPath: source.path)) // 元ファイルは残る
        let copied = destDir.appendingPathComponent("a.txt")
        #expect(FileManager.default.fileExists(atPath: copied.path))
        #expect(try String(contentsOf: copied, encoding: .utf8) == "hello")
    }

    @Test func moveRelocatesTheFile() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let destDir = root.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)

        let source = root.appendingPathComponent("a.txt")
        try write("hello", to: source)

        let receipts = try await service.move([source], to: destDir)

        #expect(receipts.count == 1)
        #expect(!FileManager.default.fileExists(atPath: source.path)) // 元の位置には無い
        #expect(FileManager.default.fileExists(atPath: destDir.appendingPathComponent("a.txt").path))
    }

    @Test func promoteFromStagingMovesTopLevelChildrenOnly() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let staging = root.appendingPathComponent("staging")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let destDir = root.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)

        try write("page1", to: staging.appendingPathComponent("page001.jpg"))
        try FileManager.default.createDirectory(at: staging.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try write("page2", to: staging.appendingPathComponent("sub/page002.jpg"))

        let receipts = try await service.promoteFromStaging(staging, to: destDir)

        #expect(receipts.count == 2) // ステージング直下の2項目（page001.jpg, sub/）
        #expect(FileManager.default.fileExists(atPath: destDir.appendingPathComponent("page001.jpg").path))
        #expect(FileManager.default.fileExists(atPath: destDir.appendingPathComponent("sub/page002.jpg").path))
    }

    @Test func renameChangesTheFileName() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let source = root.appendingPathComponent("old.txt")
        try write("hello", to: source)

        let receipt = try await service.rename(source, to: "new.txt")

        #expect(receipt.toURL.lastPathComponent == "new.txt")
        #expect(!FileManager.default.fileExists(atPath: source.path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("new.txt").path))
    }

    @Test func deletePermanentlyRemovesTheFile() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let target = root.appendingPathComponent("a.txt")
        try write("hello", to: target)

        _ = try await service.deletePermanently([target])

        #expect(!FileManager.default.fileExists(atPath: target.path))
    }

    // MARK: - 衝突処理 [FM-11〜FM-13]

    @Test func conflictSkipLeavesDestinationUntouched() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let destDir = root.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)

        let source = root.appendingPathComponent("a.txt")
        try write("new", to: source)
        let existing = destDir.appendingPathComponent("a.txt")
        try write("original", to: existing)

        let receipts = try await service.copy([source], to: destDir, options: OpOptions(conflictPolicy: .skip))

        #expect(receipts.isEmpty)
        #expect(try String(contentsOf: existing, encoding: .utf8) == "original")
    }

    @Test func conflictReplaceOverwritesDestination() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let destDir = root.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)

        let source = root.appendingPathComponent("a.txt")
        try write("new", to: source)
        let existing = destDir.appendingPathComponent("a.txt")
        try write("original", to: existing)

        let receipts = try await service.copy([source], to: destDir, options: OpOptions(conflictPolicy: .replace))

        #expect(receipts.count == 1)
        #expect(try String(contentsOf: existing, encoding: .utf8) == "new")
    }

    @Test func conflictKeepBothUsesFinderStyleSuffix() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let destDir = root.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)

        let source = root.appendingPathComponent("a.txt")
        try write("new", to: source)
        try write("original", to: destDir.appendingPathComponent("a.txt"))

        let receipts = try await service.copy([source], to: destDir, options: OpOptions(conflictPolicy: .keepBoth))

        #expect(receipts.count == 1)
        #expect(receipts[0].toURL.lastPathComponent == "a 2.txt") // [CF-01]
        #expect(FileManager.default.fileExists(atPath: destDir.appendingPathComponent("a.txt").path))
        #expect(FileManager.default.fileExists(atPath: destDir.appendingPathComponent("a 2.txt").path))
    }

    @Test func conflictKeepBothIncrementsExistingSuffixInsteadOfStacking() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let destDir = root.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)

        // 移動先に「a 2.txt」が既にある状態で、同名の「a 2.txt」をコピーしようとした場合、
        // 「a 2 2.txt」ではなく「a 3.txt」になるべき [CF-01]。
        let source = root.appendingPathComponent("a 2.txt")
        try write("new", to: source)
        try write("original", to: destDir.appendingPathComponent("a 2.txt"))

        let receipts = try await service.copy([source], to: destDir, options: OpOptions(conflictPolicy: .keepBoth))

        #expect(receipts.count == 1)
        #expect(receipts[0].toURL.lastPathComponent == "a 3.txt")
        #expect(FileManager.default.fileExists(atPath: destDir.appendingPathComponent("a 2.txt").path))
        #expect(FileManager.default.fileExists(atPath: destDir.appendingPathComponent("a 3.txt").path))
    }

    @Test func conflictAskWithoutResolverThrows() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let destDir = root.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)

        let source = root.appendingPathComponent("a.txt")
        try write("new", to: source)
        try write("original", to: destDir.appendingPathComponent("a.txt"))

        await #expect(throws: FileOperationError.self) {
            try await service.copy([source], to: destDir, options: OpOptions(conflictPolicy: .ask))
        }
    }

    @Test func conflictAskDelegatesToResolver() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let destDir = root.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)

        let source = root.appendingPathComponent("a.txt")
        try write("new", to: source)
        try write("original", to: destDir.appendingPathComponent("a.txt"))

        let options = OpOptions(conflictPolicy: .ask, conflictResolver: { _, _ in .keepBoth })
        let receipts = try await service.copy([source], to: destDir, options: options)

        #expect(receipts[0].toURL.lastPathComponent == "a 2.txt")
    }
}
