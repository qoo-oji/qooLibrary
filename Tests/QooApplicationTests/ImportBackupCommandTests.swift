import Foundation
import QooInfrastructure
import QooKit
import Testing
@testable import QooApplication

//
//  取り込みを 1 Undo 単位にする [IE-13][JS-08][UD-03]。
//
//  DB を実際に開いて確かめる（`RatingCommandTests` と同じ理由）——守っているのは
//  「取り込みが上書きしたものを、テンプレートまで含めて 1 回の ⌘Z で戻す」
//  という書き込みの性質なので、リポジトリを偽物にすると肝心の部分が試せない。
//

@Suite("取り込みの Undo [IE-13]", .serialized)
struct ImportBackupCommandTests {

    private func sampleTemplate(_ name: String) -> UserTemplate {
        var settings = UserTemplateSettings()
        settings.filenameFormats = [.init(source: "[@circle] @title", isEnabled: true)]
        return UserTemplate(name: name, settings: settings)
    }

    @MainActor
    private func workspace(blockedTemplateStore: Bool = false) async throws
        -> (ServicesWorkspace, LibrarySummary, URL)
    {
        let w = try ServicesWorkspace(blockedTemplateStore: blockedTemplateStore)
        await w.bootstrap()
        let name = "(一般コミック) [著者値A] 作品名A 第01巻.cbz"
        try w.write(name)
        let id = try await w.enable("builtin.general-comic-a")
        _ = try await w.services.scan(libraryID: id, root: w.libraryRoot)
        let library = try #require(w.services.library(registrationUUID: w.registrationUUID))
        return (w, library, w.libraryRoot.appendingPathComponent(name))
    }

    @Test("取り込んで ⌘Z すると、評価もテンプレートも取り込みの前へ戻る [IE-13]")
    @MainActor
    func importAndUndo() async throws {
        let (w, library, url) = try await workspace()
        let row = try #require(try await w.services.fileRow(at: url, in: library))
        try await w.services.setRating(5, ids: [row.id])
        var document = try await w.services.exportBackup()
        document.userTemplates = [sampleTemplate("文書のテンプレート")]
        // 取り込みの前の状態を、文書と違うものにしておく。
        try await w.services.setRating(2, ids: [row.id])

        let stack = CommandStack()
        let command = ImportBackupCommand(document: document, services: w.services)
        #expect(command.isUndoable)
        _ = try await stack.run(command)
        #expect(try await w.services.fileRow(at: url, in: library)?.rating == 5)
        #expect(await w.services.userTemplates.map(\.name) == ["文書のテンプレート"])
        #expect(command.result?.plan.templatesAdded == 1)

        let outcome = await stack.undo()
        #expect(!outcome.needsAttention, "取り消しは完了したはず: \(outcome)")
        #expect(try await w.services.fileRow(at: url, in: library)?.rating == 2)
        #expect(await w.services.userTemplates.isEmpty, "足したテンプレートも消える")

        _ = await stack.redo()
        #expect(try await w.services.fileRow(at: url, in: library)?.rating == 5)
        #expect(await w.services.userTemplates.count == 1)
    }

    /// 文書に**元からあった**テンプレートは、取り込みが足したものではないので
    /// Undo で消えてはならない（`merge` は足した ID だけを返す）。
    @Test("⌘Z は取り込みが足したテンプレートだけを消す")
    @MainActor
    func undoRemovesOnlyTemplatesTheImportAdded() async throws {
        let (w, _, _) = try await workspace()
        let mine = try await w.services.saveUserTemplate(sampleTemplate("手元のもの"))
        var document = try await w.services.exportBackup()
        document.userTemplates = [mine, sampleTemplate("文書のもの")]

        let stack = CommandStack()
        _ = try await stack.run(ImportBackupCommand(document: document, services: w.services))
        #expect(await w.services.userTemplates.count == 2)

        _ = await stack.undo()
        #expect(await w.services.userTemplates.map(\.id) == [mine.id])
    }

    /// **DB をコミットした後にテンプレートを書けなかったら、DB も巻き戻す**
    /// ［code-review で発見］。巻き戻さないと「取り込みに失敗した」と報告
    /// しながら取り込みだけが残り、`execute()` が投げるので `CommandStack` は
    /// Undo スタックへ積まない——**誰も戻せない取り込み**になる。
    @Test("テンプレートを書けなければ、DB の取り込みも巻き戻る [IE-13]")
    @MainActor
    func aTemplateWriteFailureRollsTheDatabaseBack() async throws {
        let (w, library, url) = try await workspace(blockedTemplateStore: true)
        let row = try #require(try await w.services.fileRow(at: url, in: library))
        try await w.services.setRating(5, ids: [row.id])
        var document = try await w.services.exportBackup()
        document.userTemplates = [sampleTemplate("書けないテンプレート")]
        try await w.services.setRating(2, ids: [row.id])

        let stack = CommandStack()
        let command = ImportBackupCommand(document: document, services: w.services)
        await #expect(throws: (any Error).self) { _ = try await stack.run(command) }

        #expect(try await w.services.fileRow(at: url, in: library)?.rating == 2,
                "取り込みが残ってはならない——投げた以上、Undo スタックにも載っていない")
        #expect(await w.services.userTemplates.isEmpty)
    }

    /// **DB は戻ったがテンプレートを消せない**なら `.partial`［code-review で
    /// 発見］。`.impossible` に畳むと「何も戻らなかった」という嘘になる。
    @Test("Undo がテンプレートだけ消せなければ、戻った分を数えて伝える [ER-13]")
    @MainActor
    func undoReportsPartialWhenOnlyTheTemplatesRemain() async throws {
        let (w, library, url) = try await workspace()
        let row = try #require(try await w.services.fileRow(at: url, in: library))
        try await w.services.setRating(5, ids: [row.id])
        var document = try await w.services.exportBackup()
        document.userTemplates = [sampleTemplate("消せなくなるテンプレート")]
        try await w.services.setRating(2, ids: [row.id])

        let stack = CommandStack()
        _ = try await stack.run(ImportBackupCommand(document: document, services: w.services))
        #expect(await w.services.userTemplates.count == 1)

        // 取り込みの後にテンプレートの置き場所を書けなくする。
        let directory = w.templateStoreURL.deletingLastPathComponent()
        let manager = FileManager.default
        try manager.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        defer { try? manager.setAttributes([.posixPermissions: 0o700],
                                           ofItemAtPath: directory.path) }

        let outcome = await stack.undo()
        guard case .partial(_, _, let failed) = outcome else {
            Issue.record("部分的な取り消しとして報告されるはず: \(outcome)")
            return
        }
        #expect(failed.count == 1)
        #expect(try await w.services.fileRow(at: url, in: library)?.rating == 2,
                "DB は戻っている")
        #expect(await w.services.userTemplates.count == 1, "テンプレートは残る")
    }

    @Test("対象と説明はライブラリの根のパスで表す [OH-01]")
    @MainActor
    func logTargetsAreLibraryRoots() async throws {
        let (w, _, _) = try await workspace()
        let document = try await w.services.exportBackup()
        let command = ImportBackupCommand(document: document, services: w.services)
        #expect(command.logTargets == [document.libraries[0].rootPath])
        #expect(Log.paths(in: command.logDescription) == [document.libraries[0].rootPath])
    }
}
