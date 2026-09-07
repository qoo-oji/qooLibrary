//
//  JSON バックアップの取り込みを 1 つの Undo 単位にする [IE-13][JS-08][UD-03]。
//
//  取り込みは評価・保護・ラベル・シェルフ・ライブラリ設定を**上書き**する
//  ——間違った文書を読むと、手で付けたものが黙って書き換わる。だから
//  `CommandStack` を通す。写しは永続化層が取り込みと同じトランザクションで
//  取り（`ImportSnapshot`）、テンプレートの分だけこの層で足す。
//
//  Redo は既定実装＝もう一度取り込む。取り込みは「重ねる」だけ [JS-05] なので
//  冪等で、そのとき写しは取り直される。
//
//  **`.partial` を返しうる** [ER-13]。Undo の書き込み先は DB と
//  `userTemplates.json` の 2 つで、DB を戻したあとテンプレートだけ消せない
//  ことがある——そこを `.impossible` に畳むと「何も戻らなかった」という嘘に
//  なる［code-review で発見］。
//
import Foundation
import QooInfrastructure
import QooKit

@MainActor
public final class ImportBackupCommand: Command {
    private let document: BackupDocument
    private let services: LibraryServices
    /// 最後の実行の結果。UI が件数を出すために読む。
    public private(set) var result: LibraryServices.BackupImportResult?

    public init(document: BackupDocument, services: LibraryServices) {
        self.document = document
        self.services = services
    }

    /// 名詞句 [UD-06]。「取り込みを取り消す」と読めるように。
    public var displayName: String {
        QooApplicationStrings.text("command.importBackup")
    }

    /// 文書には URL が無いので、対象はライブラリの根のパス [OH-01]。
    public var logDescription: String {
        "importBackup(libraries: \(document.libraries.count)): "
            + document.libraries.map { Log.path(URL(fileURLWithPath: $0.rootPath)) }
                .joined(separator: ", ")
    }
    public var logTargets: [String] { document.libraries.map(\.rootPath) }

    public let isUndoable = true

    public func execute() async throws -> CommandResult {
        result = try await services.importBackup(document)
        return .success
    }

    public func undo() async throws -> UndoResult {
        guard let result else {
            return .impossible(reason: QooApplicationStrings.text("command.undo.nothingToRestore"))
        }
        do {
            try await services.revertImport(result)
            return .complete
        } catch let failure as LibraryServices.ImportRevertPartialFailure {
            // DB は戻っている。**戻った分を数えて伝える**——`.impossible` に
            // 畳むと「取り消しは失敗した（＝取り込みのまま）」と読まれる。
            return .partial(
                succeeded: result.snapshot.libraries.count,
                failed: [FailedItem(
                    item: QooApplicationStrings.format(
                        "command.importBackup.templatesRemaining", failure.templatesRemaining),
                    reason: failure.underlying.localizedDescription)])
        } catch {
            return .impossible(reason: error.localizedDescription)
        }
    }
}
