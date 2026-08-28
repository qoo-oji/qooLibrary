//
//  孤立ファイルを整理するコマンド [OR-04][UD-03]。
//
//  `LabelEditCommands` の「行が消えるもの」と同じ形——**写しを控えて、同じ
//  行 ID で作り直す**。`managedFile.id` も AUTOINCREMENT なので削除された ID は
//  再利用されず、元の ID をそのまま取り戻せる［実測］。
//
import Foundation
import QooInfrastructure
import QooKit

/// 不要になった孤立レコードを消す [OR-04]。
///
/// **実体はもう無いので、消えるのはラベル・評価・手動タイトルといった
/// 「その本について覚えていたこと」だけ。** だからこそ ⌘Z で戻せるように
/// してある［ユーザー判断］——`DeletePermanentlyCommand`（実ファイルを消す、
/// `isUndoable = false`）とは性質が違う。
@MainActor
public final class DeleteOrphanedFilesCommand: Command {
    private let fileIDs: [FileID]
    private let names: [String]
    private let services: LibraryServices
    private var snapshots: [ManagedFileSnapshot] = []

    public init(fileIDs: [FileID], names: [String], services: LibraryServices) {
        self.fileIDs = fileIDs
        self.names = names
        self.services = services
    }

    /// **名詞句にする。** Undo メニューは「〜を取り消す」を後ろに付けるので、
    /// 「記録を削除」だと「記録を削除を取り消す」と助詞が重なる。
    public var displayName: String {
        names.count == 1
            ? "「\(names[0])」の記録の削除"
            : "\(names.count) 件のファイルの記録の削除"
    }
    public var logDescription: String {
        "deleteOrphans: " + names.map { Log.redactable($0) }.joined(separator: ", ")
    }
    public let isUndoable = true

    public func execute() async throws -> CommandResult {
        guard !fileIDs.isEmpty else { return .success }
        snapshots = try await services.fileSnapshots(ids: fileIDs)
        try await services.deleteFiles(fileIDs)
        return .success
    }

    public func undo() async throws -> UndoResult {
        guard !snapshots.isEmpty else { return .impossible(reason: "元に戻す対象がありません") }
        do {
            try await services.restoreFiles(snapshots)
            return .complete
        } catch {
            return .impossible(reason: error.localizedDescription)
        }
    }
}
