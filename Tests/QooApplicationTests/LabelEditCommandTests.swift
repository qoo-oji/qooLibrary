import Foundation
import QooKit
import Testing
@testable import QooApplication

//
//  ラベルそのものを編集するコマンド [LE-07〜LE-11][LB-05〜LB-07][CO-06]。
//
//  **DB を実際に開いて確かめる。** これらのコマンドが守っているのは
//  「戻したときに元とちょうど同じ状態になる」という書き込みの性質なので、
//  リポジトリを偽物に差し替えると肝心の部分が試せない（評価・ラベル設定と同じ）。
//  `ServicesWorkspace`（`LibraryServicesTests.swift`）を共有する。
//

@Suite("ラベルの編集コマンド [LE-07〜LE-11]", .serialized)
struct LabelEditCommandTests {

    /// 同人誌(A) で走査まで済ませ、サークルグループを返す。
    @MainActor
    private func workspace(files: Int = 3)
        async throws -> (ServicesWorkspace, LibrarySummary, LabelGroupSummary)
    {
        let w = try ServicesWorkspace()
        await w.bootstrap()
        for i in 1...files {
            try w.write("(同人誌) [サークル値\(i) (著者値\(i))] 作品タイトル\(i) (ジャンル値1).cbz")
        }
        let id = try await w.enable("builtin.doujinshi-a")
        _ = try await w.services.scan(libraryID: id, root: w.libraryRoot)
        let library = try #require(w.services.library(registrationUUID: w.registrationUUID))
        let groups = try await w.services.labelGroups(libraryID: library.id)
        let circle = try #require(groups.first { $0.name == "サークル" })
        return (w, library, circle)
    }

    @MainActor
    private func labels(_ w: ServicesWorkspace, _ group: LabelGroupSummary)
        async throws -> [LabelSummary]
    {
        try await w.services.labels(groupID: group.id, includeArchived: true)
    }

    // MARK: - 改名 [LB-06]

    @Test("改名を取り消すと元の名前に戻る [LB-06][UD-01]")
    @MainActor
    func renameIsUndoable() async throws {
        let (w, _, group) = try await workspace()
        let stack = CommandStack()
        let target = try #require(try await labels(w, group).first)
        let before = target.name

        _ = try await stack.run(RenameLabelCommand(
            labelID: target.id, previousName: before, newName: "新しい名前",
            services: w.services))
        #expect(try await labels(w, group).first { $0.id == target.id }?.name == "新しい名前")

        _ = await stack.undo()
        #expect(try await labels(w, group).first { $0.id == target.id }?.name == before)
        // 紐づけは行 ID で張られているので、改名でも取り消しでも維持される
        #expect(try await labels(w, group).first { $0.id == target.id }?.fileCount == 1)
    }

    @Test("Undo メニューに出る名前 [UD-06]")
    @MainActor
    func renameDisplayName() async throws {
        let w = try ServicesWorkspace()
        let c = RenameLabelCommand(labelID: LabelID(rawValue: 1), previousName: "旧",
                                   newName: "新", services: w.services)
        #expect(c.displayName == "ラベル「旧」を「新」に変更")
    }

    // MARK: - 色 [LE-10][CO-06]

    @Test("色の変更と取り消し。既定へ戻す経路も [CO-06]")
    @MainActor
    func colorIsUndoable() async throws {
        let (w, _, group) = try await workspace(files: 1)
        let stack = CommandStack()
        let target = try #require(try await labels(w, group).first)
        #expect(target.colorHex == nil)

        _ = try await stack.run(SetLabelColorCommand(
            labelID: target.id, labelName: target.name,
            previousHex: nil, newHex: "#AABBCC", services: w.services))
        #expect(try await labels(w, group).first?.colorHex == "#AABBCC")

        // 既定（グループ色の継承）へ戻す
        _ = try await stack.run(SetLabelColorCommand(
            labelID: target.id, labelName: target.name,
            previousHex: "#AABBCC", newHex: nil, services: w.services))
        #expect(try await labels(w, group).first?.colorHex == nil)

        _ = await stack.undo()
        #expect(try await labels(w, group).first?.colorHex == "#AABBCC")
        _ = await stack.undo()
        #expect(try await labels(w, group).first?.colorHex == nil)
    }

    // MARK: - 保管庫 [LA-01][LA-08][LE-09]

    @Test("保管庫へ移す／戻すの取り消しは、1 件ずつ元の状態へ戻す")
    @MainActor
    func archiveRestoresPerLabelState() async throws {
        let (w, _, group) = try await workspace()
        let stack = CommandStack()
        let all = try await labels(w, group)
        #expect(all.count == 3)
        // 1 件だけ先に保管庫へ入れておく——**混ざった状態**を作るのが要点
        try await w.services.setLabelArchived([all[0].id], true)

        let previous = try await labels(w, group).map {
            SetLabelArchivedCommand.Previous(id: $0.id, name: $0.name, isArchived: $0.isArchived)
        }
        _ = try await stack.run(SetLabelArchivedCommand(
            previous: previous, archived: true, services: w.services))
        #expect(try await labels(w, group).allSatisfy(\.isArchived))

        _ = await stack.undo()
        let after = try await labels(w, group)
        // もともと保管庫にあった 1 件は保管庫のまま。一律に戻していない。
        #expect(after.first { $0.id == all[0].id }?.isArchived == true)
        #expect(after.filter(\.isArchived).count == 1)
    }

    @Test("保管庫にあるラベルの紐づけは維持される [LA-04]")
    @MainActor
    func archivingKeepsAssignments() async throws {
        let (w, _, group) = try await workspace(files: 1)
        let stack = CommandStack()
        let target = try #require(try await labels(w, group).first)
        _ = try await stack.run(SetLabelArchivedCommand(
            previous: [.init(id: target.id, name: target.name, isArchived: false)],
            archived: true, services: w.services))
        #expect(try await labels(w, group).first?.fileCount == 1)
    }

    // MARK: - 削除 [LE-07][LE-08][LB-05]

    @Test("削除を取り消すと、同じ ID で紐づけごと戻る [LE-08][UD-01]")
    @MainActor
    func deleteIsUndoable() async throws {
        let (w, _, group) = try await workspace()
        let stack = CommandStack()
        let target = try #require(try await labels(w, group).first)
        try await w.services.setLabelPinned(target.id, true)

        _ = try await stack.run(DeleteLabelsCommand(
            labelIDs: [target.id], labelNames: [target.name], services: w.services))
        #expect(try await labels(w, group).count == 2)

        _ = await stack.undo()
        let restored = try #require(try await labels(w, group).first { $0.id == target.id })
        #expect(restored.name == target.name)
        #expect(restored.isPinned)                 // ピンも戻る
        #expect(restored.fileCount == 1)           // 紐づけも戻る
        #expect(try await labels(w, group).count == 3)
    }

    @Test("削除は取り消しできる操作として記録される [UD-10 の逆]")
    @MainActor
    func deleteGoesOnTheUndoStack() async throws {
        let (w, _, group) = try await workspace(files: 1)
        let stack = CommandStack()
        let target = try #require(try await labels(w, group).first)
        _ = try await stack.run(DeleteLabelsCommand(
            labelIDs: [target.id], labelNames: [target.name], services: w.services))
        #expect(stack.undoTitle != nil)
        #expect(stack.undoTitle?.contains("削除") == true)
    }

    @Test("写しは組み立て時ではなく実行の直前に取る")
    @MainActor
    func snapshotIsTakenAtExecutionTime() async throws {
        let (w, library, group) = try await workspace()
        let stack = CommandStack()
        let target = try #require(try await labels(w, group).first)
        let command = DeleteLabelsCommand(labelIDs: [target.id], labelNames: [target.name],
                                          services: w.services)

        // コマンドを作ってから実行するまでの間に、他所が紐づけを増やす。
        // **そのラベルがまだ付いていないファイル**を選ぶ（付いているファイルへ
        // 足しても件数が変わらず、この検査が空振りする）。
        let urls = (1...3).map {
            w.libraryRoot.appendingPathComponent(
                "(同人誌) [サークル値\($0) (著者値\($0))] 作品タイトル\($0) (ジャンル値1).cbz")
        }
        let rows = try await w.services.fileRows(at: urls, in: library)
        let assigned = try await w.services.labelAssignments(fileIDs: rows.values.map(\.id))
        let extra = try #require(rows.values.first { assigned[$0.id]?.contains(target.id) != true })
        try await w.services.applyLabelAssignments(
            labelID: target.id, [LabelAssignmentChange(fileID: extra.id, isAssigned: true)],
            protectedScopes: [:])
        let countBeforeDelete = try await labels(w, group).first { $0.id == target.id }?.fileCount
        #expect(countBeforeDelete == 2, "前提: 実行の直前に 2 件へ増えていること")

        _ = try await stack.run(command)
        _ = await stack.undo()

        // 増えた紐づけも含めて戻る＝写しが実行の直前に取られている
        #expect(try await labels(w, group).first { $0.id == target.id }?.fileCount
                == countBeforeDelete)
    }

    // MARK: - 統合 [LB-07][LE-11]

    @Test("統合を取り消すと 2 つのラベルが元どおりに分かれる [LB-07][UD-01]")
    @MainActor
    func mergeIsUndoable() async throws {
        let (w, _, group) = try await workspace()
        let stack = CommandStack()
        let all = try await labels(w, group)
        let source = all[0], target = all[1]

        _ = try await stack.run(MergeLabelsCommand(
            source: source.id, sourceName: source.name,
            target: target.id, targetName: target.name, services: w.services))
        let merged = try await labels(w, group)
        #expect(merged.count == 2)
        #expect(merged.first { $0.id == target.id }?.fileCount == 2)
        #expect(merged.contains { $0.id == source.id } == false)

        _ = await stack.undo()
        let after = try await labels(w, group)
        #expect(after.count == 3)
        #expect(after.first { $0.id == source.id }?.fileCount == 1)
        #expect(after.first { $0.id == target.id }?.fileCount == 1)
    }

    @Test("Undo メニューに出る名前 [UD-06]")
    @MainActor
    func mergeDisplayName() async throws {
        let w = try ServicesWorkspace()
        let c = MergeLabelsCommand(source: LabelID(rawValue: 1), sourceName: "旧表記",
                                   target: LabelID(rawValue: 2), targetName: "新表記",
                                   services: w.services)
        #expect(c.displayName == "ラベル「旧表記」を「新表記」に統合")
    }

    // MARK: - 診断ログ [LG2-06]

    /// **ラベル名は利用者が付けた語。** 絶対パスと違い匿名化の対象にならないので、
    /// `Log.redactable(_:)` の印（`⟨…⟩`）で包まないと書き出しバンドルに実名が残る。
    @Test("診断ログの説明はラベル名を伏せ字にできる形で書く [LG2-06]")
    @MainActor
    func logDescriptionsWrapUserSuppliedNames() async throws {
        let w = try ServicesWorkspace()
        let id = LabelID(rawValue: 1)
        let commands: [any Command] = [
            RenameLabelCommand(labelID: id, previousName: "実名A", newName: "実名B",
                               services: w.services),
            SetLabelColorCommand(labelID: id, labelName: "実名A", previousHex: nil,
                                 newHex: "#112233", services: w.services),
            SetLabelArchivedCommand(previous: [.init(id: id, name: "実名A", isArchived: false)],
                                    archived: true, services: w.services),
            SetLabelPinnedCommand(labelID: id, labelName: "実名A", pinned: true,
                                  services: w.services),
            DeleteLabelsCommand(labelIDs: [id], labelNames: ["実名A"], services: w.services),
            MergeLabelsCommand(source: id, sourceName: "実名A",
                               target: LabelID(rawValue: 2), targetName: "実名B",
                               services: w.services),
        ]
        for command in commands {
            let text = command.logDescription
            #expect(text.contains("⟨実名A⟩") || text.contains("⟨実名B⟩"),
                    "包まれていない: \(text)")
            // 素の名前が印の外に出ていないこと
            #expect(!text.replacingOccurrences(of: "⟨実名A⟩", with: "")
                        .replacingOccurrences(of: "⟨実名B⟩", with: "")
                        .contains("実名"), "素の名前が残っている: \(text)")
        }
    }
}
