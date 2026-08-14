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

/// ゴミ箱を経由しない完全削除 [FM-14][8章 §8.5]。
///
/// **このコマンドだけが `isUndoable == false`** [UD-10][PD-05]。`CommandStack`
/// は Undo スタックへ積まないが、`run` 経由で実行することで操作履歴 [HS-01]
/// には残る。取り消せないこと自体は実行前の確認ダイアログで明示する
/// [FM-15][PD-02]（提示は UI 層の責務、`PermanentDeleteConfirmationSheet`）。
///
/// `isUndoable == false` のため `CommandStack` が Undo スタックへ積まず、
/// 結果として `redo()`（既定実装は `execute()` の再実行）も到達しない。
///
/// 削除で実体を失うライブラリ／テンポラリ登録は、ここで強制的に解除する
/// [ユーザー要望]。**対象の照合は削除の前に行い、解除は削除の後に行う** —
/// 照合は Security-Scoped Bookmark の解決に依存するため実体が消えた後では
/// 判定できず、逆に先に解除するとアクセススコープが閉じて削除自体が
/// 権限エラーになるため（`RegisteredFolderStore.unregisterAll(ids:)` 参照）。
public final class DeletePermanentlyCommand: Command {
    private let items: [URL]
    private let options: DeletePermanentlyOptions
    private let fileOps: FileOperationService
    private let registeredFolders: RegisteredFolderStore

    /// 実行結果。呼び出し側が結果サマリ [ER-14] を出すために読む。
    public private(set) var outcome: DeletionOutcome?
    /// 実際に強制解除した登録フォルダ（表示名を結果サマリに出すため）。
    public private(set) var unregisteredFolders: [RegisteredFolder] = []

    public init(
        items: [URL],
        options: DeletePermanentlyOptions = .init(),
        fileOps: FileOperationService = .shared,
        registeredFolders: RegisteredFolderStore = .shared
    ) {
        self.items = items
        self.options = options
        self.fileOps = fileOps
        self.registeredFolders = registeredFolders
    }

    public var displayName: String {
        items.count == 1 ? "「\(items[0].lastPathComponent)」を完全に削除" : "\(items.count) 件を完全に削除"
    }
    /// [UD-10][PD-05] 取り消せない。
    public let isUndoable = false

    public func execute() async throws -> CommandResult {
        // ① 削除前に、実体を失う登録フォルダを特定しておく。
        let doomed = await registeredFolders.registrationsInvalidated(byDeleting: items)
        // 正規化も**削除前に**済ませる。`resolvingSymlinksInPath()` は実体が
        // 無いパスに対しては途中までしか解決できず、削除後に計算すると
        // `doomed` 側（削除前に解決したもの）と文字列が食い違い得るため。
        var normalizedByItem: [URL: String] = [:]
        for item in items {
            normalizedByItem[item] = item.resolvingSymlinksInPath().standardizedFileURL.path
        }

        // ② 削除本体。1 件の失敗で中断しない [ER-13]。
        let result = try await fileOps.deletePermanently(items, options: options)
        outcome = result

        // ③ 実際に消えたものだけを対象に登録を強制解除する。削除に失敗した
        //    項目の登録まで巻き添えで消さないよう、成功した URL で絞り込む。
        let deletedPaths = result.receipts.compactMap { normalizedByItem[$0.fromURL] }
        let actuallyGone = doomed.filter { candidate in
            deletedPaths.contains { candidate.resolvedPath == $0 || candidate.resolvedPath.hasPrefix($0 + "/") }
        }
        await registeredFolders.unregisterAll(ids: actuallyGone.map(\.folder.id))
        unregisteredFolders = actuallyGone.map(\.folder)

        if result.failures.isEmpty && result.skipped.isEmpty { return .success }
        return .partial(
            succeeded: result.succeededCount,
            failed: result.failures.map { FailedItem(item: $0.url.lastPathComponent, reason: $0.reason) }
        )
    }

    /// [UD-10] 取り消せない。`isUndoable == false` のため `CommandStack` は
    /// この経路に到達しないが、将来 `isUndoable` を取り違えて変更した場合に
    /// 黙って何かが起きるより明示的に不能を返すほうが安全。
    public func undo() async throws -> UndoResult {
        .impossible(reason: "完全に削除された項目は元に戻せません")
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
