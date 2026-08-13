import Foundation

/// Undo/Redo 可能な操作の単位 [11章 §11.1、A-03][UD-01]。
///
/// 仕様書は `Command: Sendable` としているが、実際にコマンドを生成・実行・
/// 保持するのは `CommandStack`（`@MainActor`）とそれを呼ぶ SwiftUI 層のみで、
/// 複数の actor をまたいで受け渡す必要が無い。プロトコル自体に `@MainActor`
/// を付けることで、`Sendable`/`@unchecked Sendable` 対応（可変な捕捉状態を
/// 持つ参照型のため本来は面倒になる）を避けつつ同じ安全性を得られるため、
/// この点は意図的に仕様書と異なる実装にしている [設計判断]。
///
/// 仕様書の `CommandContext`（`fileOps`/`repositories`/`history`/
/// `notifications`/`progress` を束ねる）は、フェーズ1には `fileOps` 以外の
/// 実体が無い（`RepositoryBundle`/`OperationHistoryStore`（本実装）/
/// `NotificationRouter`/`ProgressReporter` はいずれも未実装）ため導入しない。
/// 代わりに、このコードベース全体で既に使われている DI パターン
/// （`ArchiveCompressor(fileOps:stagingRoot:)` 等）に合わせ、各コマンドが
/// 自身の `init` で必要な依存（既定は `.shared`）を直接受け取る。
///
/// `affectedFolderIDs`（`LockManager` 用、LK-10）も未実装。`LockManager`
/// （11章 §11.3）はライブラリ／テンポラリフォルダの一括処理を排他制御する
/// ためのもので、対象になる登録フォルダ自体（SwiftData の
/// `Library`/`TemporaryFolder`）がフェーズ1にまだ無く、ロードマップ上も
/// `LK-*` はどのフェーズ1項目にも割り当てられていない。
@MainActor
public protocol Command: AnyObject {
    /// Undo/Redo メニュー・操作履歴に出す説明。「12 件のファイルを移動」[UD-06]
    var displayName: String { get }
    /// `false` の場合は `CommandStack.run` がスタックに積まない
    /// （完全削除等、Undo 不可能な操作用）[UD-10]。
    var isUndoable: Bool { get }

    func execute() async throws -> CommandResult
    func undo() async throws -> UndoResult
    /// 多くのコマンドでは `execute()` の再実行と同じ（`undo()` が完全に元の
    /// 状態へ戻すことを前提にできるため）。個別の実装が異なる挙動を必要と
    /// する場合のみオーバーライドする。
    func redo() async throws -> CommandResult
}

extension Command {
    public func redo() async throws -> CommandResult {
        try await execute()
    }
}

public enum CommandResult: Sendable {
    case success
    case partial(succeeded: Int, failed: [FailedItem])
}

public enum UndoResult: Sendable {
    case complete
    case partial(succeeded: Int, failed: [FailedItem])
    case impossible(reason: String)
}

public struct FailedItem: Sendable, Equatable {
    public let item: String
    public let reason: String

    public init(item: String, reason: String) {
        self.item = item
        self.reason = reason
    }
}

/// 複数の `Command` をまとめて 1 つの Undo 単位にする [UD-04]。
public final class CompositeCommand: Command {
    public let children: [any Command]
    private let name: String

    public init(displayName: String, children: [any Command]) {
        self.name = displayName
        self.children = children
    }

    public var displayName: String { name }
    public var isUndoable: Bool { children.allSatisfy(\.isUndoable) }

    public func execute() async throws -> CommandResult {
        for child in children {
            _ = try await child.execute()
        }
        return .success
    }

    /// [UD-07] children を逆順に実行する。失敗した子は部分取り消しとして記録する。
    public func undo() async throws -> UndoResult {
        var failedItems: [FailedItem] = []
        var succeededCount = 0
        for child in children.reversed() {
            do {
                switch try await child.undo() {
                case .complete:
                    succeededCount += 1
                case .partial(let succeeded, let failed):
                    succeededCount += succeeded
                    failedItems.append(contentsOf: failed)
                case .impossible(let reason):
                    failedItems.append(FailedItem(item: child.displayName, reason: reason))
                }
            } catch {
                failedItems.append(FailedItem(item: child.displayName, reason: error.localizedDescription))
            }
        }
        return failedItems.isEmpty ? .complete : .partial(succeeded: succeededCount, failed: failedItems)
    }
}
