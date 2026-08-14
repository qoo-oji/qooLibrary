import Foundation
import QooInfrastructure

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
        let result: CommandResult
        do {
            result = try await command.execute()
        } catch {
            // 失敗したコマンドは `record` を通らないため、ここで明示的に残す
            // [LG2-01]。ユーザーには `NotificationRouter` 経由でエラーが
            // 提示されるが、ログには「どのコマンドが」失敗したかも要る。
            Log.command.error("実行に失敗: \(command.logDescription) — \(error.localizedDescription)")
            throw error
        }
        record(command, action: .executed)
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
                record(command, action: .undone)
                redoStack.append(command)
            case .partial(let succeeded, let failed):
                record(command, action: .undonePartially(succeeded: succeeded, failedCount: failed.count))
                redoStack.append(command)
            case .impossible(let reason):
                record(command, action: .undoFailed(reason: reason))
                // スタックへ戻さない（同じコマンドの Undo を再試行しても直らないため）。
            }
        } catch {
            record(command, action: .undoFailed(reason: error.localizedDescription))
        }
    }

    public func redo() async {
        guard let command = redoStack.popLast() else { return }
        do {
            _ = try await command.redo()
            record(command, action: .redone)
            undoStack.append(command)
        } catch {
            record(command, action: .redoFailed(reason: error.localizedDescription))
        }
    }

    /// 操作履歴への記録は必ずここを通る [CS-05]。診断ログへの記録も同じ
    /// 1 箇所で行うことで、経路（実行／取り消し／やり直し）が増えても
    /// 記録漏れが構造的に起きない [FO-03 と同じ考え方]。
    ///
    /// 操作履歴（ユーザー向け・メモリのみ）と診断ログ（開発者向け・ファイル）は
    /// **別のストア**であり相互参照しない [LG2-07][CB-25]。同じ事象を
    /// それぞれの粒度で記録しているだけ。
    /// **操作履歴には `displayName`、診断ログには `logDescription`** を使う。
    /// 前者はユーザー向けの文言（「12 件のファイルを移動」）、後者は対象を
    /// 絶対パスで表した診断用の文字列で、書き出し時の匿名化 [LG2-06] が
    /// 効くのは後者だけ（`Command.logDescription` のコメント参照）。
    private func record(_ command: any Command, action: OperationHistoryEntry.Action) {
        let detail = command.logDescription
        switch action {
        case .executed, .undone, .redone:
            Log.command.info("\(action.logLabel): \(detail)")
        case .undonePartially(let succeeded, let failedCount):
            Log.command.warning("\(action.logLabel): \(detail) — 成功 \(succeeded) 件 / 失敗 \(failedCount) 件")
        case .undoFailed(let reason), .redoFailed(let reason):
            Log.command.error("\(action.logLabel): \(detail) — \(reason)")
        }
        operationHistory.append(OperationHistoryEntry(date: Date(), displayName: command.displayName, action: action))
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

        /// 診断ログ用の安定した短い識別子 [LG2-01]。ユーザー向けの表示名では
        /// ない（ローカライズしない・バージョン間で変えない）。
        public var logLabel: String {
            switch self {
            case .executed: "実行"
            case .undone: "取り消し"
            case .undonePartially: "取り消し（部分）"
            case .undoFailed: "取り消しに失敗"
            case .redone: "やり直し"
            case .redoFailed: "やり直しに失敗"
            }
        }
    }

    public let id = UUID()
    public let date: Date
    public let displayName: String
    public let action: Action
}
