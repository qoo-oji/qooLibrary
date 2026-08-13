import Foundation
import Testing

@testable import QooApplication

@MainActor
@Suite struct CompositeCommandTests {
    @Test func executeRunsChildrenInOrder() async throws {
        let recorder = CallRecorder()
        let first = FakeCommand(displayName: "A", recorder: recorder, label: "A")
        let second = FakeCommand(displayName: "B", recorder: recorder, label: "B")
        let composite = CompositeCommand(displayName: "複合操作", children: [first, second])

        _ = try await composite.execute()

        #expect(recorder.calls == ["A.execute", "B.execute"])
    }

    /// [UD-07] undo は children を逆順に実行する。
    @Test func undoRunsChildrenInReverseOrder() async throws {
        let recorder = CallRecorder()
        let first = FakeCommand(displayName: "A", recorder: recorder, label: "A")
        let second = FakeCommand(displayName: "B", recorder: recorder, label: "B")
        let composite = CompositeCommand(displayName: "複合操作", children: [first, second])

        _ = try await composite.undo()

        #expect(recorder.calls == ["B.undo", "A.undo"])
    }

    @Test func isUndoableIsFalseIfAnyChildIsNotUndoable() {
        let undoable = FakeCommand(displayName: "A", isUndoable: true)
        let notUndoable = FakeCommand(displayName: "B", isUndoable: false)
        let composite = CompositeCommand(displayName: "複合操作", children: [undoable, notUndoable])

        #expect(!composite.isUndoable)
    }

    /// [UD-07] 失敗した子は部分取り消しとして記録する。
    @Test func undoAggregatesPartialFailuresAcrossChildren() async throws {
        let succeeding = FakeCommand(displayName: "A")
        let failing = FakeCommand(displayName: "B")
        failing.undoResult = .impossible(reason: "対象が見つかりません")
        let composite = CompositeCommand(displayName: "複合操作", children: [succeeding, failing])

        let result = try await composite.undo()

        guard case .partial(let succeeded, let failed) = result else {
            Issue.record("expected .partial, got \(result)")
            return
        }
        #expect(succeeded == 1)
        #expect(failed.count == 1)
        #expect(failed[0].item == "B")
        #expect(failed[0].reason == "対象が見つかりません")
    }

    @Test func undoReturnsCompleteWhenAllChildrenSucceed() async throws {
        let first = FakeCommand(displayName: "A")
        let second = FakeCommand(displayName: "B")
        let composite = CompositeCommand(displayName: "複合操作", children: [first, second])

        let result = try await composite.undo()

        guard case .complete = result else {
            Issue.record("expected .complete, got \(result)")
            return
        }
    }
}
