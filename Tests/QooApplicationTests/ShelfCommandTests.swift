import Foundation
import QooKit
import Testing
@testable import QooApplication

//
//  シェルフのコマンド [SH-01〜SH-04][SH-11] とモデル [SH-06][SH-08]。
//
//  **DB を実際に開いて確かめる**（ラベル編集コマンドと同じ理由）——これらが
//  守っているのは「戻したときに元とちょうど同じ状態になる」という書き込みの
//  性質で、リポジトリを偽物に差し替えると肝心の部分が試せない。
//

@Suite("シェルフのコマンド [SH-01〜SH-04][SH-11]", .serialized)
struct ShelfCommandTests {

    @MainActor
    private func workspace()
        async throws -> (ServicesWorkspace, LibrarySummary, [LabelSummary])
    {
        let w = try ServicesWorkspace()
        await w.bootstrap()
        for i in 1...3 {
            try w.write("(同人誌) [サークル値\(i) (著者値\(i))] 作品タイトル\(i) (ジャンル値1).cbz")
        }
        let id = try await w.enable("builtin.doujinshi-a")
        _ = try await w.services.scan(libraryID: id, root: w.libraryRoot)
        let library = try #require(w.services.library(registrationUUID: w.registrationUUID))
        let groups = try await w.services.labelGroups(libraryID: library.id)
        let circle = try #require(groups.first { $0.name == "サークル" })
        let labels = try await w.services.labels(groupID: circle.id)
        return (w, library, labels)
    }

    private func condition(_ labels: [LabelSummary], stars: Int? = nil,
                           search: String? = nil) -> ShelfCondition {
        ShelfCondition(labelIDs: labels.map(\.id),
                       rating: stars.map { FileQuery.RatingFilter(stars: $0) },
                       searchText: search)
    }

    // MARK: - 保存 [SH-01]

    @Test("保存を取り消すと消え、やり直すと同じ行 ID で戻る [SH-01][SH-11]")
    @MainActor
    func createIsUndoableAndKeepsRowID() async throws {
        let (w, library, labels) = try await workspace()
        let stack = CommandStack()

        _ = try await stack.run(CreateShelfCommand(
            libraryID: library.id, name: "未読",
            condition: condition(labels, stars: 3), services: w.services))
        let created = try #require(try await w.services.shelves(libraryID: library.id).first)
        #expect(created.name == "未読")
        #expect(created.condition.rating?.stars == 3)

        _ = await stack.undo()
        #expect(try await w.services.shelves(libraryID: library.id).isEmpty)

        _ = await stack.redo()
        let again = try #require(try await w.services.shelves(libraryID: library.id).first)
        #expect(again.id == created.id, "やり直しで別 ID になると、シェルフの同一性が切れる")
        #expect(again.condition == created.condition)
    }

    // MARK: - 改名 [SH-03]

    @Test("改名を取り消すと元の名前に戻る [SH-03]")
    @MainActor
    func renameIsUndoable() async throws {
        let (w, library, labels) = try await workspace()
        let stack = CommandStack()
        let id = try await w.services.createShelf(libraryID: library.id, name: "前",
                                                  condition: condition(labels))

        _ = try await stack.run(RenameShelfCommand(shelfID: id, previousName: "前",
                                                   newName: "後", services: w.services))
        #expect(try await w.services.shelves(libraryID: library.id).first?.name == "後")

        _ = await stack.undo()
        #expect(try await w.services.shelves(libraryID: library.id).first?.name == "前")
    }

    // MARK: - 上書き保存 [SH-04]

    @Test("上書き保存を取り消すと元の条件に戻る [SH-04]")
    @MainActor
    func updateIsUndoable() async throws {
        let (w, library, labels) = try await workspace()
        let stack = CommandStack()
        let before = condition(labels, stars: 1)
        let id = try await w.services.createShelf(libraryID: library.id, name: "S",
                                                  condition: before)
        let after = condition(Array(labels.prefix(1)), search: "作品")

        _ = try await stack.run(UpdateShelfCommand(
            shelfID: id, shelfName: "S", previousCondition: before,
            newCondition: after, services: w.services))
        #expect(try await w.services.shelves(libraryID: library.id).first?.condition == after)

        _ = await stack.undo()
        #expect(try await w.services.shelves(libraryID: library.id).first?.condition == before)
        // 名前と並び順は動かさない [SH-04]。
        #expect(try await w.services.shelves(libraryID: library.id).first?.name == "S")
    }

    // MARK: - 削除 [SH-02][SH-11]

    @Test("削除を取り消すと同じ行 ID・同じ条件で戻る [SH-11]")
    @MainActor
    func deleteRestoresSameRow() async throws {
        let (w, library, labels) = try await workspace()
        let stack = CommandStack()
        let target = condition(labels, stars: 4, search: "語")
        let id = try await w.services.createShelf(libraryID: library.id, name: "消す",
                                                  condition: target)
        _ = try await w.services.createShelf(libraryID: library.id, name: "残る",
                                             condition: condition(labels))

        _ = try await stack.run(DeleteShelfCommand(shelfID: id, shelfName: "消す",
                                                   services: w.services))
        #expect(try await w.services.shelves(libraryID: library.id).map(\.name) == ["残る"])

        _ = await stack.undo()
        let restored = try #require(
            try await w.services.shelves(libraryID: library.id).first { $0.name == "消す" })
        #expect(restored.id == id)
        #expect(restored.condition == target)
    }

    @Test("Undo メニューの文言にシェルフ名が出る [UD-06]")
    @MainActor
    func undoTitleNamesTheShelf() async throws {
        let (w, library, labels) = try await workspace()
        let stack = CommandStack()
        _ = try await stack.run(CreateShelfCommand(
            libraryID: library.id, name: "未読", condition: condition(labels),
            services: w.services))
        #expect(stack.undoTitle?.contains("未読") == true)
    }

    // MARK: - モデル [SH-06][SH-08]

    @Test("いまの絞り込みと同じシェルフを見分ける [SH-08]")
    @MainActor
    func matchesCurrentCondition() async throws {
        let (w, library, labels) = try await workspace()
        let target = condition(labels, stars: 2)
        _ = try await w.services.createShelf(libraryID: library.id, name: "A", condition: target)
        _ = try await w.services.createShelf(libraryID: library.id, name: "B",
                                             condition: condition(Array(labels.prefix(1))))

        let model = ShelfModel()
        await model.load(library: library, services: w.services)
        #expect(model.shelves.count == 2)
        #expect(model.matchingShelf(for: target)?.name == "A")
        #expect(model.matchingShelf(for: condition([], search: "無い")) == nil)
    }

    @Test("復元するとラベルの選択と評価が戻る [SH-06]")
    @MainActor
    func applyRestoresSelectionAndRating() async throws {
        let (w, _, labels) = try await workspace()
        let filter = LabelFilterModel()
        await filter.load(registrationUUID: w.registrationUUID, services: w.services)

        let target = try #require(labels.first)
        filter.apply(ShelfCondition(labelIDs: [target.id], rating: .init(stars: 3)))

        #expect(filter.isSelected(target))
        #expect(filter.ratingFilter?.stars == 3)
        // チェックの入ったフィールドは開いておく——畳まれたままだと
        // 何が効いているのか確かめようがない。
        #expect(filter.expandedGroups.contains(target.groupID))
    }

    @Test("いま無いラベルは復元しても選ばれない [SH-05]")
    @MainActor
    func applyIgnoresUnknownLabels() async throws {
        let (w, _, labels) = try await workspace()
        let filter = LabelFilterModel()
        await filter.load(registrationUUID: w.registrationUUID, services: w.services)

        let known = try #require(labels.first)
        filter.apply(ShelfCondition(labelIDs: [known.id, LabelID(rawValue: 99999)]))

        #expect(filter.selectedLabelCount == 1)
        #expect(filter.isSelected(known))
    }

    @Test("いまの絞り込みを条件として取り出せる [SH-01]")
    @MainActor
    func currentConditionReflectsSelection() async throws {
        let (w, _, labels) = try await workspace()
        let filter = LabelFilterModel()
        await filter.load(registrationUUID: w.registrationUUID, services: w.services)
        let target = try #require(labels.first)
        filter.toggle(target)
        filter.ratingFilter = .init(stars: 5, mode: .exact)

        let c = filter.currentCondition(searchText: " 作品 ",
                                        sort: .init(key: .title, ascending: false),
                                        displayMode: .libraryFlat)
        #expect(c.labelIDs == [target.id])
        #expect(c.rating == .init(stars: 5, mode: .exact))
        #expect(c.searchText == "作品")
        #expect(c.sort == .init(key: .title, ascending: false))
        #expect(c.isActive)
    }
}

// MARK: - 非表示のラベルを含むシェルフ [SH-05][SH-08]

extension ShelfCommandTests {
    /// **畳まずに比べると二度と一致しない**［code-review の指摘］。復元しても
    /// 非表示のラベルは選択に入らないので、条件は永久に食い違ったままになり、
    /// 「上書き保存」が出続けて、残しておいたはずの ID [SH-05] を捨てさせる。
    @Test("非表示のラベルを含むシェルフでも、いまの絞り込みと一致する [SH-08]")
    @MainActor
    func matchingToleratesHiddenLabels() async throws {
        let (w, library, labels) = try await workspace()
        #expect(labels.count >= 2)
        let visible = labels[0]
        let hidden = labels[1]

        _ = try await w.services.createShelf(
            libraryID: library.id, name: "S",
            condition: ShelfCondition(labelIDs: [visible.id, hidden.id]))
        // 片方を非表示にする（実体を失ったラベルと同じ見え方 [LA3-05]）。
        try await w.services.setLabelArchived([hidden.id], true)

        let filter = LabelFilterModel()
        await filter.load(registrationUUID: w.registrationUUID, services: w.services)
        filter.toggle(visible)      // 復元後に残るのはこちらだけ

        let model = ShelfModel()
        await model.load(library: library, services: w.services)
        let current = filter.currentCondition(searchText: nil, sort: .byFilename,
                                              displayMode: .libraryFlat)

        #expect(model.matchingShelf(for: current, resolving: filter.resolvable)?.name == "S")
        // 記録そのものは畳まない——ラベルを戻せば条件も生き返る [SH-05]。
        let stored = try #require(try await w.services.shelves(libraryID: library.id).first)
        #expect(stored.condition.labelIDs.count == 2)
    }
}
