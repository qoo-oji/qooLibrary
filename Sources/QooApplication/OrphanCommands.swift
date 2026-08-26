//
//  孤立ファイルを整理するコマンド [OR-02][OR-03][OR-04][UD-03]。
//
//  `LabelEditCommands` の「行が消えるもの」と同じ形——**写しを控えて、同じ
//  行 ID で作り直す**。`managedFile.id` も AUTOINCREMENT なので削除された ID は
//  再利用されず、元の ID をそのまま取り戻せる［実測］。
//
//  ## どちらも「1 回の `restore` で全部戻す」
//  再紐づけは孤立側と候補側の 2 行を同時に動かすので、片方ずつ戻すと
//  「孤立は戻ったが候補が消えたまま」というどちらでもない状態が残る。
//  リポジトリが 1 トランザクションで書くので、写しをまとめて渡す。
//
import Foundation
import QooInfrastructure
import QooKit

/// 孤立レコードを実ファイルへ結び直す [OR-02][OR-03][ID-04]。
///
/// 候補一覧からのワンクリック [OR-02] と手動選択 [OR-03] は**同じこのコマンド**
/// を通る——観測結果（`FileSnapshot`）を誰が作ったかだけが違う。同じ操作に
/// 独立した経路を 2 つ作らない（1-12 のアプリ関連付けで実際に取り残した形）。
@MainActor
public final class ReattachOrphanCommand: Command {
    private let orphanID: FileID
    private let orphanName: String
    private let snapshot: FileSnapshot
    private let services: LibraryServices
    /// `execute()` が控える。`undo()` はこれを戻す。
    private var before: [ManagedFileSnapshot] = []

    public init(orphanID: FileID, orphanName: String,
                to snapshot: FileSnapshot, services: LibraryServices) {
        self.orphanID = orphanID
        self.orphanName = orphanName
        self.snapshot = snapshot
        self.services = services
    }

    public var displayName: String { "「\(orphanName)」の記録の紐づけ" }
    /// **ファイル名は利用者由来の語なので、そのまま診断ログへ書かない** [LG2-06]
    /// ——ここで持っているのは相対パスとファイル名だけで、絶対パスではないため
    /// 匿名化の対象にならない。`Log.redactable(_:)` の印で包む。
    public var logDescription: String {
        "reattachOrphan: \(Log.redactable(orphanName)) → \(Log.redactable(snapshot.relativePath))"
    }
    public let isUndoable = true

    public func execute() async throws -> CommandResult {
        // **写しは実行の直前に取る**（`DeleteLabelsCommand` と同じ理由）。
        // 組み立ててから実行するまでの間に、走査や右ペインが値を変えうる。
        var targets = [orphanID]
        // **消される側を、消える前に控える。** `reattachOrphan` は消した ID を
        // 返すが、そのときにはもう写しを取れない。
        if let duplicate = try await services.findFile(identity: snapshot.identity),
           duplicate != orphanID {
            targets.append(duplicate)
        }
        before = try await services.fileSnapshots(ids: targets)
        try await services.reattachOrphan(orphanID, to: snapshot)
        return .success
    }

    public func undo() async throws -> UndoResult {
        guard !before.isEmpty else { return .impossible(reason: "元に戻す対象がありません") }
        do {
            try await services.restoreFiles(before)
            return .complete
        } catch {
            return .impossible(reason: error.localizedDescription)
        }
    }
}

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
