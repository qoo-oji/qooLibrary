import Foundation
import QooInfrastructure
import QooKit
import Testing
@testable import QooApplication

//
//  保管庫の出し入れコマンド [FA-01〜FA-16][FDA-01][UD-03]。
//
//  **DB と実ファイルを両方とも本物で確かめる。** このコマンドが守っているのは
//  「実体を運んで、DB を実体に合わせて、⌘Z でちょうど元へ戻す」という性質で、
//  どちらかを偽物にすると肝心の部分が試せない（ラベル編集コマンドと同じ方針）。
//  `ServicesWorkspace`（`LibraryServicesTests.swift`）を共有する。
//

@Suite("保管庫の出し入れコマンド [FA-01][FA-07][UD-03]", .serialized)
struct VaultCommandTests {

    @MainActor
    private func workspace(files: Int = 2)
        async throws -> (ServicesWorkspace, LibrarySummary)
    {
        let w = try ServicesWorkspace()
        await w.bootstrap()
        for i in 1...files {
            try w.write("作者A/(同人誌) [サークル値\(i) (著者値\(i))] 作品タイトル\(i) (ジャンル値1).cbz")
        }
        let id = try await w.enable("builtin.doujinshi-a")
        _ = try await w.services.scan(libraryID: id, root: w.libraryRoot)
        let library = try #require(w.services.library(registrationUUID: w.registrationUUID))
        return (w, library)
    }

    @MainActor
    private func rows(_ w: ServicesWorkspace, _ library: LibrarySummary) async throws -> [FileRow] {
        try await w.services.files(FileQuery(libraryID: library.id, includeArchived: true,
                                             limit: 100)).rows
    }

    private func exists(_ w: ServicesWorkspace, _ relativePath: String) -> Bool {
        FileManager.default.fileExists(
            atPath: w.libraryRoot.appendingPathComponent(relativePath).path)
    }

    @MainActor
    private func command(_ w: ServicesWorkspace, _ library: LibrarySummary,
                         rows targets: [FileRow], archived: Bool) -> SetFileArchivedCommand {
        SetFileArchivedCommand(
            targets: targets.map {
                SetFileArchivedCommand.Target(id: $0.id, relativePath: $0.relativePath,
                                              archivedFromPath: $0.archivedFromPath,
                                              archivedAt: $0.archivedAt)
            },
            archived: archived,
            root: w.libraryRoot,
            services: w.services)
    }

    // MARK: - 入れる [FA-01][FA-04][FA-05]

    @MainActor
    @Test("保管庫へ入れると、実体が動き DB も追随する [FA-01][FA-04][FA-05]")
    func archivingMovesTheFileAndUpdatesTheRecord() async throws {
        let (w, library) = try await workspace(files: 1)
        let before = try await rows(w, library)
        let target = try #require(before.first)
        let originalPath = target.relativePath

        _ = try await command(w, library, rows: [target], archived: true).execute()

        #expect(!exists(w, originalPath))
        #expect(exists(w, VaultPath.archived(originalPath)))
        let after = try #require(try await rows(w, library).first)
        #expect(after.id == target.id, "同じ行が動く——新しい行を作らない")
        #expect(after.isArchived)
        #expect(after.relativePath == VaultPath.archived(originalPath))
        #expect(after.archivedFromPath == originalPath)
        #expect(after.archivedAt != nil)
    }

    /// **空になったフォルダを片付ける** [FA-06]。1 件でも残っていれば残す。
    @MainActor
    @Test("最後の 1 件を移すと元のフォルダが消える [FA-06]")
    func theEmptiedFolderIsRemoved() async throws {
        let (w, library) = try await workspace(files: 2)
        let all = try await rows(w, library)

        _ = try await command(w, library, rows: [all[0]], archived: true).execute()
        #expect(exists(w, "作者A"), "まだ 1 件残っているので消さない")

        _ = try await command(w, library, rows: [all[1]], archived: true).execute()
        #expect(!exists(w, "作者A"))
    }

    // MARK: - 戻す [FA-07][FA-09]

    @MainActor
    @Test("保管庫から戻すと元の場所へ返り、記録が消える [FA-07][FA-09]")
    func restoringPutsTheFileBack() async throws {
        let (w, library) = try await workspace(files: 1)
        let target = try #require(try await rows(w, library).first)
        let originalPath = target.relativePath
        _ = try await command(w, library, rows: [target], archived: true).execute()

        let archived = try #require(try await rows(w, library).first)
        _ = try await command(w, library, rows: [archived], archived: false).execute()

        #expect(exists(w, originalPath), "戻す先が消えていても作って戻す [FA-09]")
        let after = try #require(try await rows(w, library).first)
        #expect(!after.isArchived)
        #expect(after.relativePath == originalPath)
        #expect(after.archivedFromPath == nil)
    }

    // MARK: - Undo [UD-03]

    @MainActor
    @Test("⌘Z で実体も記録もちょうど元へ戻る [UD-03]")
    func undoRestoresBothTheFileAndTheRecord() async throws {
        let (w, library) = try await workspace(files: 1)
        let target = try #require(try await rows(w, library).first)
        let originalPath = target.relativePath

        let cmd = command(w, library, rows: [target], archived: true)
        _ = try await cmd.execute()
        let result = try await cmd.undo()

        guard case .complete = result else { Issue.record("取り消しが完了しなかった"); return }
        #expect(exists(w, originalPath))
        #expect(!exists(w, VaultPath.archived(originalPath)))
        let after = try #require(try await rows(w, library).first)
        #expect(!after.isArchived)
        #expect(after.relativePath == originalPath)
        #expect(after.archivedFromPath == nil)
    }

    /// **元の日時へ戻す** [FAW-05]。「戻す」を取り消して保管庫へ返したときに
    /// 「今」を書くと、日時での並べ替えが実態とずれる。
    @MainActor
    @Test("「戻す」の ⌘Z は、しまった日時を書き換えない [FAW-05]")
    func undoingARestoreKeepsTheOriginalArchivedDate() async throws {
        let (w, library) = try await workspace(files: 1)
        let target = try #require(try await rows(w, library).first)
        _ = try await command(w, library, rows: [target], archived: true).execute()

        let archived = try #require(try await rows(w, library).first)
        let when = try #require(archived.archivedAt)
        let restore = command(w, library, rows: [archived], archived: false)
        _ = try await restore.execute()
        _ = try await restore.undo()

        let after = try #require(try await rows(w, library).first)
        #expect(after.isArchived)
        #expect(after.archivedAt == when)
    }

    /// **実体が動いたあとに DB の書き込みが失敗しても、投げ返さない**
    /// ［レビューで発見］。`CommandStack.run` は `execute()` が投げると
    /// **Undo スタックへ積まない**ので、投げると「ファイルは `.qooarchive` へ
    /// 移ったのに ⌘Z で戻せない」状態が残る。
    @MainActor
    @Test("DB の書き込みに失敗しても、動いた分は取り消せる [ER-13][ER-16]")
    func aFailedDatabaseWriteStillLeavesTheMoveUndoable() async throws {
        let (w, library) = try await workspace(files: 1)
        let target = try #require(try await rows(w, library).first)
        let originalPath = target.relativePath

        // 準備していない `LibraryServices` は `ServiceError.notReady` を投げる。
        let broken = LibraryServices(userCoverStore: DefaultUserCoverStore(
            baseDirectory: w.coverDirectory.appendingPathComponent("broken")))
        let cmd = SetFileArchivedCommand(
            targets: [SetFileArchivedCommand.Target(id: target.id,
                                                    relativePath: target.relativePath)],
            archived: true, root: w.libraryRoot, services: broken)

        let result = try await cmd.execute()

        guard case .partial(let succeeded, let failures) = result else {
            Issue.record("投げ返さず部分的な成功として返すべき"); return
        }
        #expect(succeeded == 1)
        #expect(!failures.isEmpty, "理由を伝えなければ、黙って一部だけ動いたことになる")
        #expect(exists(w, VaultPath.archived(originalPath)), "実体は動いている")

        // **ここが本題**——動いた分を戻せる（DB が書けなくても実体は戻る）。
        let undone = try await cmd.undo()
        guard case .partial = undone else {
            Issue.record("DB が書けなかったことを伝えつつ、実体は戻すべき"); return
        }
        #expect(exists(w, originalPath))
        #expect(!exists(w, VaultPath.archived(originalPath)))
    }

    // MARK: - フォルダ丸ごと [FDA-01][FDA-02]

    @MainActor
    @Test("フォルダを丸ごと移すと、配下の全行が保管庫に入る [FDA-01][FDA-02]")
    func archivingAFolderMovesEverythingUnderIt() async throws {
        let (w, library) = try await workspace(files: 2)
        // DB に載らないものも一緒に運ぶ——「丸ごと」の意味 [FDA-01]。
        try w.write("作者A/メモ.txt")

        let cmd = ArchiveFolderCommand(libraryID: library.id, folderRelativePath: "作者A",
                                       root: w.libraryRoot, services: w.services)
        _ = try await cmd.execute()

        #expect(!exists(w, "作者A"))
        #expect(exists(w, ".qooarchive/作者A/メモ.txt"))
        let after = try await rows(w, library)
        #expect(after.count == 2)
        let allArchived = after.allSatisfy(\.isArchived)
        let allMoved = after.allSatisfy { $0.relativePath.hasPrefix(".qooarchive/作者A/") }
        let allRecorded = after.allSatisfy { $0.archivedFromPath?.hasPrefix("作者A/") == true }
        #expect(allArchived)
        #expect(allMoved)
        #expect(allRecorded)
    }

    @MainActor
    @Test("フォルダ丸ごとの ⌘Z も元へ戻す [FDA-01][UD-03]")
    func undoingAFolderArchiveRestoresEverything() async throws {
        let (w, library) = try await workspace(files: 2)
        let before = try await rows(w, library).map(\.relativePath).sorted()

        let cmd = ArchiveFolderCommand(libraryID: library.id, folderRelativePath: "作者A",
                                       root: w.libraryRoot, services: w.services)
        _ = try await cmd.execute()
        let result = try await cmd.undo()

        guard case .complete = result else { Issue.record("取り消しが完了しなかった"); return }
        #expect(!exists(w, ".qooarchive/作者A"))
        let after = try await rows(w, library)
        #expect(after.map(\.relativePath).sorted() == before)
        let allRestored = after.allSatisfy { !$0.isArchived }
        #expect(allRestored)
    }
}
