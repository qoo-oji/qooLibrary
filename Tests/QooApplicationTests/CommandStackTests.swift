import Foundation
import QooInfrastructure
import Testing

@testable import QooApplication

@MainActor
@Suite struct CommandStackTests {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("qoo-commandstack-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func runPushesUndoableCommandOntoStack() async throws {
        let stack = CommandStack()
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let folderURL = root.appendingPathComponent("NewFolder")

        try await stack.run(CreateFolderCommand(url: folderURL))

        #expect(stack.canUndo)
        #expect(stack.undoTitle == "「NewFolder」を作成")
        #expect(FileManager.default.fileExists(atPath: folderURL.path))
    }

    @Test func undoReversesCreateFolderAndPushesRedo() async throws {
        let stack = CommandStack()
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let folderURL = root.appendingPathComponent("NewFolder")
        try await stack.run(CreateFolderCommand(url: folderURL))

        await stack.undo()

        #expect(!stack.canUndo)
        #expect(stack.canRedo)
        #expect(stack.redoTitle == "「NewFolder」を作成")
    }

    @Test func redoReappliesCommand() async throws {
        let stack = CommandStack()
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let folderURL = root.appendingPathComponent("NewFolder")
        try await stack.run(CreateFolderCommand(url: folderURL))
        await stack.undo()

        await stack.redo()

        #expect(stack.canUndo)
        #expect(!stack.canRedo)
        #expect(FileManager.default.fileExists(atPath: folderURL.path))
    }

    /// [一般的な Undo/Redo の規則] 新しい操作を実行したら、分岐した
    /// 「やり直し」先は破棄される。
    @Test func newRunClearsRedoStack() async throws {
        let stack = CommandStack()
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try await stack.run(CreateFolderCommand(url: root.appendingPathComponent("A")))
        await stack.undo()
        #expect(stack.canRedo)

        try await stack.run(CreateFolderCommand(url: root.appendingPathComponent("B")))

        #expect(!stack.canRedo)
    }

    /// [CS-01] 深さ超過時は最も古いコマンドを捨てる。
    @Test func exceedingDepthDropsOldestCommand() async throws {
        let stack = CommandStack()
        stack.depth = 2
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["A", "B", "C"] {
            try await stack.run(CreateFolderCommand(url: root.appendingPathComponent(name)))
        }

        await stack.undo() // C
        await stack.undo() // B
        #expect(!stack.canUndo) // A was dropped when the stack exceeded depth 2

        // A は Undo スタックからは捨てられているだけで、実際に作られたフォルダは残る。
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("A").path))
    }

    /// [CS-05][HS-01 の簡易版] `run`/`undo`/`redo` は必ず操作履歴を記録する。
    @Test func recordsOperationHistoryForRunUndoRedo() async throws {
        let stack = CommandStack()
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let folderURL = root.appendingPathComponent("A")

        try await stack.run(CreateFolderCommand(url: folderURL))
        await stack.undo()
        await stack.redo()

        #expect(stack.operationHistory.map(\.action) == [.executed, .undone, .redone])
    }

    /// 非 Undoable なコマンド（`isUndoable == false`）はスタックへ積まれない
    /// が、実行と操作履歴の記録は行われる。
    @Test func nonUndoableCommandIsNotPushedToStack() async throws {
        let stack = CommandStack()
        let command = FakeCommand(displayName: "取り消せない操作", isUndoable: false)

        try await stack.run(command)

        #expect(command.executeCallCount == 1)
        #expect(!stack.canUndo)
        #expect(stack.operationHistory.count == 1)
    }
}

/// 呼び出し順序を記録する小さなヘルパー。複数の `FakeCommand` が同じ
/// インスタンスを共有することで、実行/取り消しの順序を検証できる
/// （`CompositeCommand` のテスト参照）。
@MainActor
final class CallRecorder {
    private(set) var calls: [String] = []
    func record(_ label: String) { calls.append(label) }
}

/// テスト用の Undo 呼び出し記録付きコマンド。
@MainActor
final class FakeCommand: Command {
    let displayName: String
    let isUndoable: Bool
    private(set) var executeCallCount = 0
    private(set) var undoCallCount = 0
    var undoResult: UndoResult = .complete
    var undoError: Error?
    var completionSound: SystemSoundEffect?
    var executeResult: CommandResult = .success
    var executeError: Error?
    private let recorder: CallRecorder?
    private let label: String

    init(
        displayName: String, isUndoable: Bool = true,
        completionSound: SystemSoundEffect? = nil,
        recorder: CallRecorder? = nil, label: String = ""
    ) {
        self.displayName = displayName
        self.isUndoable = isUndoable
        self.completionSound = completionSound
        self.recorder = recorder
        self.label = label.isEmpty ? displayName : label
    }

    func execute() async throws -> CommandResult {
        executeCallCount += 1
        recorder?.record("\(label).execute")
        if let executeError { throw executeError }
        return executeResult
    }

    func undo() async throws -> UndoResult {
        undoCallCount += 1
        recorder?.record("\(label).undo")
        if let error = undoError { throw error }
        return undoResult
    }
}
