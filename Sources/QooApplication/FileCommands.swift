import Foundation
import QooInfrastructure

/// [UD-03] 逆方向へ move。移動先が変化していれば部分取り消し [UD-07]。
public final class MoveFilesCommand: Command {
    private let items: [URL]
    private let destination: URL
    private let options: OpOptions
    private let fileOps: FileOperationService
    private var receipts: [OpReceipt] = []

    /// 既定は `.keepBoth`（D&D と同じ規則、`DropHandling` 参照）。
    public init(
        items: [URL], destination: URL, options: OpOptions = OpOptions(conflictPolicy: .keepBoth),
        fileOps: FileOperationService = .shared
    ) {
        self.items = items
        self.destination = destination
        self.options = options
        self.fileOps = fileOps
    }

    public var displayName: String {
        items.count == 1 ? "「\(items[0].lastPathComponent)」を移動" : "\(items.count) 件のファイルを移動"
    }
    public let isUndoable = true

    public func execute() async throws -> CommandResult {
        receipts = try await fileOps.move(items, to: destination, options: options)
        return receipts.count == items.count ? .success : .partial(succeeded: receipts.count, failed: [])
    }

    public func undo() async throws -> UndoResult {
        guard !receipts.isEmpty else { return .impossible(reason: "元に戻す対象がありません") }
        var succeeded = 0
        var failed: [FailedItem] = []
        for receipt in receipts {
            do {
                // 衝突時は `.keepBoth`（移動先に何か新しくできていても壊さない）。
                // 元の名前と異なる名前で戻ることがあり、その場合は部分取り消し
                // として報告する [UD-07]。
                _ = try await fileOps.move(
                    [receipt.toURL], to: receipt.fromURL.deletingLastPathComponent(),
                    options: OpOptions(conflictPolicy: .keepBoth)
                )
                succeeded += 1
            } catch {
                failed.append(FailedItem(item: receipt.toURL.lastPathComponent, reason: error.localizedDescription))
            }
        }
        if failed.isEmpty { return .complete }
        return succeeded == 0 ? .impossible(reason: failed[0].reason) : .partial(succeeded: succeeded, failed: failed)
    }
}

/// [UD-03] Undo は生成物を削除する。復元可能性を保つため完全削除ではなく
/// ゴミ箱へ送る（Undo 操作自体が新たなデータ喪失リスクを持ち込まないため）。
public final class CopyFilesCommand: Command {
    private let items: [URL]
    private let destination: URL
    private let options: OpOptions
    private let fileOps: FileOperationService
    private var receipts: [OpReceipt] = []

    public init(
        items: [URL], destination: URL, options: OpOptions = OpOptions(conflictPolicy: .keepBoth),
        fileOps: FileOperationService = .shared
    ) {
        self.items = items
        self.destination = destination
        self.options = options
        self.fileOps = fileOps
    }

    public var displayName: String {
        items.count == 1 ? "「\(items[0].lastPathComponent)」を複製" : "\(items.count) 件のファイルを複製"
    }
    public let isUndoable = true

    public func execute() async throws -> CommandResult {
        receipts = try await fileOps.copy(items, to: destination, options: options)
        return receipts.count == items.count ? .success : .partial(succeeded: receipts.count, failed: [])
    }

    public func undo() async throws -> UndoResult {
        guard !receipts.isEmpty else { return .impossible(reason: "元に戻す対象がありません") }
        do {
            _ = try await fileOps.trash(receipts.map(\.toURL))
            return .complete
        } catch {
            return .impossible(reason: error.localizedDescription)
        }
    }
}

/// [UD-03] 逆リネーム。
public final class RenameCommand: Command {
    private let item: URL
    private let newName: String
    private let fileOps: FileOperationService
    private var receipt: OpReceipt?

    public init(item: URL, newName: String, fileOps: FileOperationService = .shared) {
        self.item = item
        self.newName = newName
        self.fileOps = fileOps
    }

    public var displayName: String { "「\(item.lastPathComponent)」の名前を変更" }
    public let isUndoable = true

    public func execute() async throws -> CommandResult {
        receipt = try await fileOps.rename(item, to: newName)
        return .success
    }

    public func undo() async throws -> UndoResult {
        guard let receipt else { return .impossible(reason: "元に戻す対象がありません") }
        do {
            _ = try await fileOps.rename(receipt.toURL, to: receipt.fromURL.lastPathComponent)
            return .complete
        } catch {
            return .impossible(reason: error.localizedDescription)
        }
    }
}

/// [UD-03] `TrashReceipt` から復元 [UD-08]。復元自体が失敗した場合（ゴミ箱が
/// 空にされた等）は `.partial`/`.impossible` を返し、呼び出し側（UI 層）が
/// 「ゴミ箱を開いて手動復元してください」等の案内を出す想定 [TR-09]。
public final class TrashCommand: Command {
    private let items: [URL]
    private let fileOps: FileOperationService
    private var receipts: [TrashReceipt] = []

    public init(items: [URL], fileOps: FileOperationService = .shared) {
        self.items = items
        self.fileOps = fileOps
    }

    public var displayName: String {
        items.count == 1 ? "「\(items[0].lastPathComponent)」をゴミ箱に入れる" : "\(items.count) 件のファイルをゴミ箱に入れる"
    }
    public let isUndoable = true

    public func execute() async throws -> CommandResult {
        receipts = try await fileOps.trash(items)
        return receipts.count == items.count ? .success : .partial(succeeded: receipts.count, failed: [])
    }

    public func undo() async throws -> UndoResult {
        guard !receipts.isEmpty else { return .impossible(reason: "元に戻す対象がありません") }
        let restored = try await fileOps.restoreFromTrash(receipts)
        if restored.count == receipts.count { return .complete }
        let restoredURLs = Set(restored.map(\.toURL))
        let failed = receipts
            .filter { !restoredURLs.contains($0.originalURL) }
            .map { FailedItem(item: $0.originalURL.lastPathComponent, reason: "ゴミ箱からの復元に失敗しました") }
        return .partial(succeeded: restored.count, failed: failed)
    }
}

/// [UD-03] 空でなければ削除を拒否する（ユーザーが中身を追加していた場合に
/// 誤って消さないため）。
public final class CreateFolderCommand: Command {
    private let url: URL
    private let fileOps: FileOperationService

    public init(url: URL, fileOps: FileOperationService = .shared) {
        self.url = url
        self.fileOps = fileOps
    }

    public var displayName: String { "「\(url.lastPathComponent)」を作成" }
    public let isUndoable = true

    public func execute() async throws -> CommandResult {
        _ = try await fileOps.createDirectory(at: url)
        return .success
    }

    public func undo() async throws -> UndoResult {
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        guard contents.isEmpty else {
            return .impossible(reason: "フォルダの中身が空ではありません")
        }
        do {
            _ = try await fileOps.trash([url])
            return .complete
        } catch {
            return .impossible(reason: error.localizedDescription)
        }
    }
}

/// Finder の「エイリアスを作成」の Undo。仕様書のコマンド一覧（11章表）には
/// 無いが、`FileOperationService.createAlias` は既に UI から呼ばれている
/// 変更操作のため、Undo 対象から漏らさないよう追加した [設計判断]。
public final class CreateAliasCommand: Command {
    private let source: URL
    private let destinationFolder: URL
    private let fileOps: FileOperationService
    private var receipt: OpReceipt?

    public init(source: URL, destinationFolder: URL, fileOps: FileOperationService = .shared) {
        self.source = source
        self.destinationFolder = destinationFolder
        self.fileOps = fileOps
    }

    public var displayName: String { "「\(source.lastPathComponent)」のエイリアスを作成" }
    public let isUndoable = true

    public func execute() async throws -> CommandResult {
        receipt = try await fileOps.createAlias(for: source, in: destinationFolder)
        return .success
    }

    public func undo() async throws -> UndoResult {
        guard let receipt else { return .impossible(reason: "元に戻す対象がありません") }
        do {
            _ = try await fileOps.trash([receipt.toURL])
            return .complete
        } catch {
            return .impossible(reason: error.localizedDescription)
        }
    }
}

/// Finder の「ロック」/「ロック解除」の Undo。`CreateAliasCommand` と同じ理由
/// （仕様書のコマンド一覧には無いが UI から呼ばれる変更操作）で追加した。
public final class SetLockedCommand: Command {
    private let items: [URL]
    private let locked: Bool
    private let fileOps: FileOperationService

    public init(items: [URL], locked: Bool, fileOps: FileOperationService = .shared) {
        self.items = items
        self.locked = locked
        self.fileOps = fileOps
    }

    public var displayName: String {
        let action = locked ? "ロック" : "ロック解除"
        return items.count == 1 ? "「\(items[0].lastPathComponent)」を\(action)" : "\(items.count) 件を\(action)"
    }
    public let isUndoable = true

    public func execute() async throws -> CommandResult {
        _ = try await fileOps.setLocked(items, locked: locked)
        return .success
    }

    public func undo() async throws -> UndoResult {
        do {
            _ = try await fileOps.setLocked(items, locked: !locked)
            return .complete
        } catch {
            return .impossible(reason: error.localizedDescription)
        }
    }
}
