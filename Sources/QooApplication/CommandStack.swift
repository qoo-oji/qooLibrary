import Foundation

/// Undo/Redo スタック本体 [11章 §11.2、UD-02][UD-05][UD-11]。アプリ全体で
/// 単一のインスタンスを使う想定（`FileOperationService.shared`/
/// `ThumbnailService.shared` と同じ方針、ウインドウ単位に分けない [ST-03]）。
/// テストでは `init()` で独立インスタンスを作れる
/// （`FileOperationService`/`SecureExtractor` と同じ理由）。
@MainActor
@Observable
public final class CommandStack {
    public static let shared = CommandStack()

    private var undoStack: [any Command] = []
    private var redoStack: [any Command] = []
    /// [UD-05] 既定 50。環境設定 UI（1-12）が無いフェーズ1では変更不可。
    public var depth = 50

    /// [HS-01 の簡易版] DB（`OperationLogRecord`、07章）がまだ無いフェーズ1
    /// では永続化しない、メモリのみの操作履歴。CSV エクスポート・保持期間・
    /// 専用の操作履歴ウインドウ（OH-01〜05、15章 §15.13）はフェーズ2
    /// （DB 導入時）の対象。アプリ終了で消える点は Undo スタック自体と同じ
    /// 「セッション一時状態」の扱い。
    public private(set) var operationHistory: [OperationHistoryEntry] = []
    private let historyLimit = 500

    public init() {}

    public var undoTitle: String? { undoStack.last?.displayName } // [UD-06]
    public var redoTitle: String? { redoStack.last?.displayName }
    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    /// コマンドを実行しスタックへ積む [UD-01][CS-05]。新しい操作を実行したら
    /// redo スタックは破棄する（一般的な Undo/Redo の規則: 分岐した「やり直し」
    /// 先は残さない）。
    @discardableResult
    public func run(_ command: any Command) async throws -> CommandResult {
        let result = try await command.execute()
        record(command.displayName, action: .executed)
        if command.isUndoable {
            undoStack.append(command)
            if undoStack.count > depth {
                undoStack.removeFirst() // [CS-01] スタックからは捨てるが操作履歴は残す
            }
        }
        redoStack.removeAll()
        return result
    }

    public func undo() async {
        guard let command = undoStack.popLast() else { return }
        do {
            let result = try await command.undo()
            switch result {
            case .complete:
                record(command.displayName, action: .undone)
                redoStack.append(command)
            case .partial(let succeeded, let failed):
                record(command.displayName, action: .undonePartially(succeeded: succeeded, failedCount: failed.count))
                redoStack.append(command)
            case .impossible(let reason):
                record(command.displayName, action: .undoFailed(reason: reason))
                // スタックへ戻さない（同じコマンドの Undo を再試行しても直らないため）。
            }
        } catch {
            record(command.displayName, action: .undoFailed(reason: error.localizedDescription))
        }
    }

    public func redo() async {
        guard let command = redoStack.popLast() else { return }
        do {
            _ = try await command.redo()
            record(command.displayName, action: .redone)
            undoStack.append(command)
        } catch {
            record(command.displayName, action: .redoFailed(reason: error.localizedDescription))
        }
    }

    private func record(_ displayName: String, action: OperationHistoryEntry.Action) {
        operationHistory.append(OperationHistoryEntry(date: Date(), displayName: displayName, action: action))
        if operationHistory.count > historyLimit {
            operationHistory.removeFirst()
        }
    }
}

public struct OperationHistoryEntry: Sendable, Identifiable {
    public enum Action: Sendable, Equatable {
        case executed
        case undone
        case undonePartially(succeeded: Int, failedCount: Int)
        case undoFailed(reason: String)
        case redone
        case redoFailed(reason: String)
    }

    public let id = UUID()
    public let date: Date
    public let displayName: String
    public let action: Action
}
