import Foundation
import QooKit
import Testing
@testable import QooApplication

//
//  孤立ファイルの整理ウインドウ [OR-01〜OR-05][ID-05][15.7 節]。
//
//  絞り込みと既定で選ぶライブラリは**純粋関数**なので DB を開かずに固定できる。
//  再紐づけ・削除と ⌘Z だけ `ServicesWorkspace` を使う
//  （`LabelVaultModelTests` と同じ分け方）。
//

@Suite("孤立一覧の絞り込みと選択 [15.7 節]")
struct OrphanCleanupSelectionTests {

    private func library(_ name: String, id: Int64, online: Bool = true) -> LibrarySummary {
        LibrarySummary(id: LibraryID(rawValue: id), uuid: UUID(), displayName: name,
                       resolvedPath: "/Volumes/\(name)", volumeUUID: "VOL\(id)",
                       libraryTypeID: LibraryTypeID(rawValue: 1), libraryTypeName: "同人誌",
                       isOnline: online, isReadOnlyDueToFS: false, fileCount: 0,
                       settingsRevision: 0)
    }

    private func orphan(_ path: String, id: Int64, labels: Int = 0,
                        candidates: [OrphanCandidate] = []) -> OrphanedFile {
        let name = (path as NSString).lastPathComponent
        return OrphanedFile(
            row: FileRow(id: FileID(rawValue: id), libraryID: LibraryID(rawValue: 1),
                         relativePath: path, filename: name, fileSize: 100,
                         createdAt: Date(timeIntervalSinceReferenceDate: 0),
                         modifiedAt: Date(timeIntervalSinceReferenceDate: 0),
                         title: nil, seriesName: nil, volume: .none, rating: 0,
                         state: .orphaned, isArchived: false, isBookFolder: false),
            labelCount: labels, candidates: candidates)
    }

    // MARK: - 絞り込み

    @Test("検索語が空なら全件を通す")
    func emptyQueryKeepsEverything() {
        let files = [orphan("A/一.cbz", id: 1), orphan("B/二.cbz", id: 2)]
        #expect(OrphanCleanupModel.filter(files, matching: "   ").count == 2)
    }

    /// 孤立の一覧で目印になるのは「どのフォルダにあったか」であることが多い
    /// ——同じ巻数のファイルが複数のシリーズに散っているため。
    @Test("ファイル名だけでなく相対パスにも当たる")
    func matchesAgainstThePathAsWell() {
        let files = [orphan("作品名A/第01巻.cbz", id: 1), orphan("作品名B/第01巻.cbz", id: 2)]
        #expect(OrphanCleanupModel.filter(files, matching: "作品名A").map(\.row.id)
                == [FileID(rawValue: 1)])
        #expect(OrphanCleanupModel.filter(files, matching: "第01巻").count == 2)
    }

    /// **入力の幅までユーザーに合わせさせない**（CLAUDE.md 冒頭の大原則）。
    /// 日本語入力がオンのまま英数字を打てば全角になる。
    @Test("全角で打っても半角のファイル名に当たる")
    func matchingIgnoresCharacterWidth() {
        let files = [orphan("A/STUDIO abc.cbz", id: 1)]
        #expect(OrphanCleanupModel.filter(files, matching: "ＡＢＣ").count == 1)
    }

    // MARK: - 一覧してよいか [OR2-06][ID-08][SB-05]

    @Test("オフラインのライブラリは一覧しない [OR2-06][ID-08]")
    func offlineLibrariesAreNotListed() {
        #expect(OrphanCleanupModel.canListOrphans(of: library("外付け", id: 1, online: false))
                == false)
        #expect(OrphanCleanupModel.canListOrphans(of: library("内蔵", id: 2)))
    }

    // MARK: - 既定で選ぶライブラリ

    @Test("指定されたライブラリが最優先（孤立が 0 件でも）")
    func honoursTheRequestedLibrary() {
        let libs = [library("A", id: 1), library("B", id: 2)]
        #expect(OrphanCleanupModel.defaultLibrary(
            from: libs, orphanCounts: [LibraryID(rawValue: 1): 3],
            preferring: LibraryID(rawValue: 2)) == LibraryID(rawValue: 2))
    }

    @Test("指定が無ければ、孤立を持つ最初のライブラリを選ぶ")
    func picksTheFirstLibraryWithOrphans() {
        let libs = [library("A", id: 1), library("B", id: 2)]
        #expect(OrphanCleanupModel.defaultLibrary(
            from: libs, orphanCounts: [LibraryID(rawValue: 2): 5],
            preferring: nil) == LibraryID(rawValue: 2))
    }

    /// **オフラインには着地しない。** そこを選ぶと開いた瞬間に
    /// 「オフラインのため表示できません」だけが出る行き止まりになる。
    @Test("孤立を持っていてもオフラインなら選ばない [OR2-06]")
    func skipsOfflineLibrariesEvenWhenTheyHaveOrphans() {
        let libs = [library("外付け", id: 1, online: false), library("内蔵", id: 2)]
        #expect(OrphanCleanupModel.defaultLibrary(
            from: libs, orphanCounts: [LibraryID(rawValue: 1): 9],
            preferring: nil) == LibraryID(rawValue: 2))
    }

    @Test("すべてオフラインなら先頭へ落とす（空の一覧を出さないため）")
    func fallsBackToTheFirstWhenEverythingIsOffline() {
        let libs = [library("A", id: 1, online: false), library("B", id: 2, online: false)]
        #expect(OrphanCleanupModel.defaultLibrary(from: libs, orphanCounts: [:], preferring: nil)
                == LibraryID(rawValue: 1))
    }

    @Test("ライブラリが 1 件も無ければ nil")
    func returnsNilWithoutLibraries() {
        #expect(OrphanCleanupModel.defaultLibrary(from: [], orphanCounts: [:], preferring: nil)
                == nil)
    }
}

// MARK: - 実際の DB を通した操作

@Suite("孤立ファイルの整理（実 DB）[OR-01〜OR-04]", .serialized)
struct OrphanCleanupModelIntegrationTests {

    /// `ServicesWorkspace` はモデルより長生きしなければならない（`deinit` が
    /// 一時ストアを消すので、捨てると以後の書き込みが「disk I/O error」になる）。
    @MainActor
    final class Bench {
        let workspace: ServicesWorkspace
        let model: OrphanCleanupModel
        let commands: CommandStack
        let libraryID: LibraryID
        init(workspace: ServicesWorkspace, model: OrphanCleanupModel,
             commands: CommandStack, libraryID: LibraryID) {
            self.workspace = workspace
            self.model = model
            self.commands = commands
            self.libraryID = libraryID
        }
    }

    /// 3 件取り込んでから 1 件を「別のフォルダへ移した」状態にして走査し直す。
    /// 同じ名前で場所だけ変わるので、走査は**新規レコードを作り、元のレコードを
    /// 孤立にする**——`.nameOnly` でしか一致しないため [ID-03]③[ID-05]。
    @MainActor
    private func bench(moving: Bool = true) async throws -> Bench {
        let w = try ServicesWorkspace()
        await w.bootstrap()
        for i in 1...3 {
            try w.write("旧/(同人誌) [サークル値\(i) (著者値\(i))] 作品タイトル\(i) (ジャンル値1).cbz")
        }
        let id = try await w.enable("builtin.doujinshi-a")
        _ = try await w.services.scan(libraryID: id, root: w.libraryRoot)

        if moving {
            let name = "(同人誌) [サークル値1 (著者値1)] 作品タイトル1 (ジャンル値1).cbz"
            let from = w.libraryRoot.appendingPathComponent("旧/\(name)")
            let to = w.libraryRoot.appendingPathComponent("新/\(name)")
            try FileManager.default.createDirectory(at: to.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            // **サイズを変えて移す。** 同じサイズだと走査が [ID-03]② で自動的に
            // 紐づけ直してしまい（それが正しい）、孤立が 1 件も生まれない。
            try Data(repeating: 0x42, count: 32).write(to: to)
            try FileManager.default.removeItem(at: from)
            _ = try await w.services.scan(libraryID: id, root: w.libraryRoot)
        }

        let commands = CommandStack()
        let m = OrphanCleanupModel(commands: commands)
        await m.prepare(services: w.services)
        return Bench(workspace: w, model: m, commands: commands, libraryID: id)
    }

    @Test("孤立になった行だけが一覧に出る [OR-01]")
    @MainActor
    func listsOrphanedRowsOnly() async throws {
        let b = try await bench()
        #expect(b.model.state == .ready)
        #expect(b.model.files.count == 1)
        #expect(b.model.files[0].row.relativePath.hasPrefix("旧/"))
        #expect(b.model.orphanCounts[b.libraryID] == 1)
    }

    @Test("同じ名前で生きている行が候補として出る [OR-02][ID-05]")
    @MainActor
    func offersTheMovedFileAsACandidate() async throws {
        let b = try await bench()
        let file = try #require(b.model.files.first)
        #expect(file.candidates.count == 1)
        #expect(file.candidates[0].relativePath.hasPrefix("新/"))
    }

    @Test("孤立が無ければ一覧は空（検索で 0 件になった場合と区別できる）")
    @MainActor
    func reportsAnEmptyVaultDistinctly() async throws {
        let b = try await bench(moving: false)
        #expect(b.model.state == .ready)
        #expect(b.model.hasNoOrphans)

        b.model.searchText = "存在しない語"
        #expect(b.model.visibleFiles.isEmpty)
        #expect(b.model.hasNoOrphans, "検索の結果と、そもそも 0 件であることは別")
    }

    @Test("候補へ再紐づけすると、孤立側の行が生き残る [OR-02][ID-04]")
    @MainActor
    func reattachKeepsTheOrphanRow() async throws {
        let b = try await bench()
        let file = try #require(b.model.files.first)
        let orphanID = file.row.id
        // ラベルと評価を付けて、それが引き継がれることを見る。
        try await b.workspace.services.setRating(4, ids: [orphanID])

        try await b.model.reattach(file, to: file.candidates[0])

        #expect(b.model.files.isEmpty, "孤立が解消される")
        let library = try #require(b.workspace.services.libraries.first)
        let row = try #require(try await b.workspace.services.fileRow(
            at: b.workspace.libraryRoot.appendingPathComponent(
                "新/(同人誌) [サークル値1 (著者値1)] 作品タイトル1 (ジャンル値1).cbz"),
            in: library))
        #expect(row.id == orphanID, "候補側ではなく孤立側の行が残る")
        #expect(row.rating == 4, "評価が引き継がれる")
        #expect(row.state == .active)
    }

    @Test("再紐づけを ⌘Z で戻すと、候補側の行も復活する [UD-03]")
    @MainActor
    func undoingAReattachRevivesBothRows() async throws {
        let b = try await bench()
        let file = try #require(b.model.files.first)
        let candidateID = file.candidates[0].fileID
        try await b.model.reattach(file, to: file.candidates[0])

        _ = await b.commands.undo()
        await b.model.reload()

        #expect(b.model.files.map(\.row.id) == [file.row.id], "孤立へ戻る")
        #expect(b.model.files[0].row.relativePath.hasPrefix("旧/"))
        let revived = try await b.workspace.services.files(
            FileQuery(libraryID: b.libraryID, mode: .libraryFlat, limit: 100))
        #expect(revived.rows.contains { $0.id == candidateID }, "候補側の行も戻る")
    }

    @Test("削除すると一覧から消え、⌘Z で同じ行 ID へ戻る [OR-04][UD-03]")
    @MainActor
    func deleteAndUndo() async throws {
        let b = try await bench()
        let file = try #require(b.model.files.first)

        try await b.model.delete([file])
        #expect(b.model.files.isEmpty)
        #expect(b.model.orphanCounts[b.libraryID] == nil)

        _ = await b.commands.undo()
        await b.model.reload()
        #expect(b.model.files.map(\.row.id) == [file.row.id])
    }

    @Test("Undo メニューの文言が対象を名指しする [UD-06]")
    @MainActor
    func undoTitleNamesTheTarget() async throws {
        let b = try await bench()
        let file = try #require(b.model.files.first)
        try await b.model.delete([file])
        // **表示は「孤立」と言わない**［ユーザー判断、15章 §15.7］——消えるのは
        // ファイルではなく「そのファイルについて覚えている記録」。
        #expect(b.commands.undoTitle?.contains("記録の削除") == true)
        #expect(b.commands.undoTitle?.contains(file.row.filename) == true)
    }

    /// **選択は一括削除 [OR-04] の対象**なので、消えた行を指したまま残ると
    /// 次の削除が「もう無い行」を巻き込む。
    @Test("消えた行を指した選択は落とす")
    func staleSelectionIsDropped() async throws {
        let b = try await bench()
        await MainActor.run { b.model.selection = [FileID(rawValue: 9999)] }
        await b.model.reload()
        #expect(await MainActor.run { b.model.selection.isEmpty })
    }
}
