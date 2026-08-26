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

/// 同一性の確認の結果をまとめて適用する [ID-05][ID-11]。
///
/// **1 回の「適用」が 1 つの Undo 単位** [UD-04]。承認と却下を同じコマンドに
/// 入れてあるのは、利用者から見て 1 度の操作だから——分けると、⌘Z を 2 回
/// 押さないと元に戻らない画面になる。
///
/// 却下も戻せるようにしてあるのが要点。**一度「別物」と答えると以後聞かれ
/// なくなる** [ID-11] ので、間違えたときに取り消せないと行き止まりになる。
@MainActor
public final class ApplyIdentityDecisionsCommand: Command {
    private let accepted: [IdentityMatch]
    private let rejected: [IdentityMatch]
    private let services: LibraryServices
    /// `execute()` が控える。`undo()` はこれを戻す。
    private var before: [ManagedFileSnapshot] = []

    public init(accepted: [IdentityMatch], rejected: [IdentityMatch],
                services: LibraryServices) {
        self.accepted = accepted
        self.rejected = rejected
        self.services = services
    }

    public var displayName: String {
        accepted.count == 1 && rejected.isEmpty
            ? "1 件のファイルの記録の引き継ぎ"
            : "\(accepted.count + rejected.count) 件のファイルの同一性の判断"
    }
    /// **ファイル名は書かない**——ここで持っているのは行 ID だけなので、
    /// そもそも利用者由来の語が入らない [LG2-06]。
    public var logDescription: String {
        "applyIdentityDecisions: 承認 \(accepted.count) / 却下 \(rejected.count)"
    }
    public let isUndoable = true

    public func execute() async throws -> CommandResult {
        guard !accepted.isEmpty || !rejected.isEmpty else { return .success }
        // **写しは実行の直前に取る**（`DeleteLabelsCommand` と同じ理由）。
        // 承認は孤立側と候補側の**両方**を動かすので、両方を控える。
        let touched = accepted.flatMap { [$0.orphanID, $0.candidateID] }
        before = try await services.fileSnapshots(ids: touched)
        try await services.acceptIdentityMatches(accepted)
        try await services.rejectIdentityMatches(rejected)
        return .success
    }

    public func undo() async throws -> UndoResult {
        do {
            if !before.isEmpty { try await services.restoreFiles(before) }
            // **却下の記録も消す。** 残したままだと、⌘Z のあと同じ組が
            // 二度と確認に出てこない（「別物」の判断だけが生き残る）。
            try await services.clearIdentityRejections(rejected)
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
