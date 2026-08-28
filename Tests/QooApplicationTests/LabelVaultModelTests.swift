import Foundation
import QooKit
import Testing
@testable import QooApplication

//
//  ラベル保管庫の整理ウインドウ [LAW-01〜LAW-03][LA-01][LA-06][LA-08][15.3 節]。
//
//  セクションの組み立て・既定で選ぶライブラリは**純粋関数**なので DB を
//  開かずに固定できる。戻す・一括で戻す・削除と ⌘Z だけ `ServicesWorkspace`
//  を使う（`LabelGroupEditorModelTests` と同じ分け方）。
//

@Suite("保管庫の一覧の組み立て [15.3 節][LAW-01]")
struct LabelVaultSectionTests {

    private func group(_ name: String, id: Int64, order: Int = 0) -> LabelGroupSummary {
        LabelGroupSummary(id: LabelGroupID(rawValue: id), libraryID: LibraryID(rawValue: 1),
                          index: Int(id), name: name,
                          colorHexLight: "#E3DBB6", colorHexDark: "#666145",
                          displayOrder: order, labelCount: 0)
    }

    private func label(_ name: String, id: Int64, group: Int64,
                       archived: Bool = true, count: Int = 1) -> LabelSummary {
        LabelSummary(id: LabelID(rawValue: id), groupID: LabelGroupID(rawValue: group),
                     name: name, normalizedName: name.lowercased(), colorHex: nil,
                     isPinned: false, isArchived: archived, fileCount: count)
    }

    /// §15.3 は「グループごとに整理」と定める。**セクションの並びは
    /// `groups` の順（＝`displayOrder`）そのもの**で、中身の並べ替えでは動かない。
    @Test("グループごとの区画になり、順序は渡された並びを保つ [15.3 節]")
    func sectionsFollowTheGroupOrder() {
        let sections = LabelVaultModel.sections(
            groups: [group("サークル", id: 1, order: 0), group("著者", id: 2, order: 1)],
            labels: [LabelGroupID(rawValue: 1): [label("ぜ", id: 10, group: 1)],
                     LabelGroupID(rawValue: 2): [label("あ", id: 20, group: 2)]],
            sortedBy: .name, matching: "")
        #expect(sections.map(\.group.name) == ["サークル", "著者"])
        #expect(sections.map { $0.rows.map(\.name) } == [["ぜ"], ["あ"]])
    }

    /// **並べ替えはセクションの中へ効く。** グループをまたいで混ぜると
    /// §15.3 が定める整理が消える。
    @Test("並べ替えはセクションの中だけに効く [15.3 節]")
    func sortingStaysInsideSections() {
        let sections = LabelVaultModel.sections(
            groups: [group("A", id: 1), group("B", id: 2)],
            labels: [LabelGroupID(rawValue: 1): [label("少", id: 10, group: 1, count: 1),
                                                 label("多", id: 11, group: 1, count: 9)],
                     LabelGroupID(rawValue: 2): [label("中", id: 20, group: 2, count: 5)]],
            sortedBy: .fileCount, matching: "")
        #expect(sections.map(\.group.name) == ["A", "B"], "件数順でもグループは混ざらない")
        #expect(sections[0].rows.map(\.name) == ["多", "少"])
    }

    /// **保管庫の画面に保管庫外のラベルが混ざるのは、意味そのものが壊れた状態。**
    /// 呼び出し側が絞って渡す前提だが、この関数自身が不変条件を守る。
    @Test("アーカイブされていないラベルは通さない [LA-06]")
    func nonArchivedLabelsAreExcluded() {
        let sections = LabelVaultModel.sections(
            groups: [group("サークル", id: 1)],
            labels: [LabelGroupID(rawValue: 1): [
                label("保管庫の中", id: 10, group: 1, archived: true),
                label("ふつう", id: 11, group: 1, archived: false)]],
            sortedBy: .name, matching: "")
        #expect(sections.count == 1)
        #expect(sections[0].rows.map(\.name) == ["保管庫の中"])
    }

    @Test("アーカイブ済みが 1 件も無いグループは区画ごと出さない")
    func emptyGroupsAreDropped() {
        let sections = LabelVaultModel.sections(
            groups: [group("サークル", id: 1), group("イベント", id: 2)],
            labels: [LabelGroupID(rawValue: 1): [label("あ", id: 10, group: 1)],
                     LabelGroupID(rawValue: 2): []],
            sortedBy: .name, matching: "")
        #expect(sections.map(\.group.name) == ["サークル"])
    }

    /// 検索で全部消えたグループの見出しだけが残ると、何のための区画か読めない。
    @Test("検索で 0 件になった区画も消える")
    func searchDropsEmptiedSections() {
        let sections = LabelVaultModel.sections(
            groups: [group("サークル", id: 1), group("著者", id: 2)],
            labels: [LabelGroupID(rawValue: 1): [label("STUDIO abc", id: 10, group: 1)],
                     LabelGroupID(rawValue: 2): [label("よその名前", id: 20, group: 2)]],
            sortedBy: .name, matching: "ＡＢＣ")
        #expect(sections.map(\.group.name) == ["サークル"],
                "全角で打っても半角のラベルに当たる")
    }
}

@Suite("既定で選ぶライブラリ [15.3 節]")
struct LabelVaultDefaultLibraryTests {

    private func library(_ id: Int64, _ name: String) -> LibrarySummary {
        LibrarySummary(id: LibraryID(rawValue: id), uuid: UUID(), displayName: name,
                       resolvedPath: "/tmp/\(name)", volumeUUID: "V",
                       libraryTypeID: LibraryTypeID(rawValue: 1), libraryTypeName: "同人誌(A)",
                       isOnline: true, isReadOnlyDueToFS: false, fileCount: 0,
                       settingsRevision: 1)
    }

    /// **素直に先頭を選ぶと、保管庫が空のライブラリに着地して行き止まりになる。**
    @Test("指定が無ければ、保管庫に中身のある最初のライブラリを選ぶ")
    func picksTheFirstLibraryWithArchivedLabels() {
        let libs = [library(1, "空っぽ"), library(2, "中身あり")]
        let picked = LabelVaultModel.defaultLibrary(
            from: libs, archivedCounts: [LibraryID(rawValue: 2): 3], preferring: nil)
        #expect(picked == LibraryID(rawValue: 2))
    }

    /// **その登録の保管庫を見に来たのだから、空でもそのライブラリを見せる**
    /// ——「空だった」という答えも答えである。
    @Test("入口が指定したライブラリは、空でも最優先")
    func explicitRequestWinsEvenWhenEmpty() {
        let libs = [library(1, "空っぽ"), library(2, "中身あり")]
        let picked = LabelVaultModel.defaultLibrary(
            from: libs, archivedCounts: [LibraryID(rawValue: 2): 3],
            preferring: LibraryID(rawValue: 1))
        #expect(picked == LibraryID(rawValue: 1))
    }

    @Test("どこにも保管庫が無ければ先頭へ落とす")
    func fallsBackToTheFirstLibrary() {
        let libs = [library(1, "A"), library(2, "B")]
        #expect(LabelVaultModel.defaultLibrary(from: libs, archivedCounts: [:], preferring: nil)
                == LibraryID(rawValue: 1))
    }

    @Test("消えたライブラリを指定されても、実在するものへ落とす")
    func staleRequestIsIgnored() {
        let libs = [library(1, "A")]
        #expect(LabelVaultModel.defaultLibrary(from: libs, archivedCounts: [:],
                                               preferring: LibraryID(rawValue: 99))
                == LibraryID(rawValue: 1))
    }

    @Test("ライブラリが 1 件も無ければ nil")
    func noLibrariesYieldsNil() {
        #expect(LabelVaultModel.defaultLibrary(from: [], archivedCounts: [:], preferring: nil) == nil)
    }
}

@Suite("保管庫の整理ウインドウ [LAW-01〜LAW-03]", .serialized)
struct LabelVaultModelTests {

    /// `ServicesWorkspace` はモデルより長生きしなければならない（`deinit` が
    /// 一時ストアを消すので、捨てると以後の書き込みが「disk I/O error」になる）。
    @MainActor
    final class Vault {
        let workspace: ServicesWorkspace
        let model: LabelVaultModel
        let commands: CommandStack
        init(workspace: ServicesWorkspace, model: LabelVaultModel, commands: CommandStack) {
            self.workspace = workspace
            self.model = model
            self.commands = commands
        }
    }

    /// サークル 3 件のうち 2 件を保管庫へ入れた状態を作る。
    @MainActor
    private func vault(archiving count: Int = 2) async throws -> Vault {
        let w = try ServicesWorkspace()
        await w.bootstrap()
        for i in 1...3 {
            try w.write("(同人誌) [サークル値\(i) (著者値\(i))] 作品タイトル\(i) (ジャンル値1).cbz")
        }
        let id = try await w.enable("builtin.doujinshi-a")
        _ = try await w.services.scan(libraryID: id, root: w.libraryRoot)

        let groups = try await w.services.labelGroups(libraryID: id)
        let circle = try #require(groups.first { $0.name == "サークル" })
        let labels = try await w.services.labels(groupID: circle.id)
        try await w.services.setLabelArchived(Array(labels.prefix(count).map(\.id)), true)

        let commands = CommandStack()
        let m = LabelVaultModel(commands: commands)
        await m.prepare(services: w.services)
        return Vault(workspace: w, model: m, commands: commands)
    }

    @Test("保管庫の中身だけが、グループごとに並ぶ [LA-06][15.3 節]")
    @MainActor
    func listsOnlyArchivedLabels() async throws {
        let v = try await vault()
        #expect(v.model.state == .ready)
        #expect(v.model.sections.count == 1, "アーカイブ済みがあるのはサークルだけ")
        let section = try #require(v.model.sections.first)
        #expect(section.group.name == "サークル")
        #expect(section.rows.count == 2)
        #expect(section.rows.allSatisfy { $0.isArchived })
    }

    /// **保管庫へ入れても紐づけは維持される** [LA-04]。バッジは保管庫の
    /// ファイルも数える [LE-05]。
    @Test("保管庫のラベルも件数を持つ [LA-04][LE-05]")
    @MainActor
    func archivedLabelsKeepTheirCount() async throws {
        let v = try await vault()
        let rows = try #require(v.model.sections.first?.rows)
        #expect(rows.allSatisfy { $0.fileCount == 1 })
    }

    @Test("ライブラリごとのアーカイブ済み件数が読める [15.3 節のグレーアウト]")
    @MainActor
    func archivedCountsAreReported() async throws {
        let v = try await vault()
        let id = try #require(v.model.selectedLibraryID)
        #expect(v.model.archivedCounts[id] == 2)
    }

    @Test("戻すと一覧から消え、⌘Z で保管庫へ返る [LAW-01][LA-08]")
    @MainActor
    func restoreRoundTrip() async throws {
        let v = try await vault()
        let target = try #require(v.model.sections.first?.rows.first?.label)

        try await v.model.restore([target])
        #expect(v.model.sections.first?.rows.count == 1)

        _ = await v.commands.undo()
        await v.model.reload()
        #expect(v.model.sections.first?.rows.count == 2, "⌘Z で保管庫へ戻る")
    }

    @Test("複数選択してまとめて戻せる [LAW-03]")
    @MainActor
    func restoreSelectedInBulk() async throws {
        let v = try await vault()
        v.model.selection = Set(try #require(v.model.sections.first?.rows.map(\.id)))
        #expect(v.model.selection.count == 2)

        try await v.model.restoreSelected()
        #expect(v.model.sections.isEmpty, "全部戻したので区画ごと消える")
        #expect(v.model.vaultIsEmpty)
        #expect(v.model.selection.isEmpty, "消えた行の選択は残さない")
    }

    /// **一括の戻しは 1 つの Undo 単位。** 1 件ずつのコマンドを並べると
    /// ⌘Z を選択件数ぶん押すことになる。
    @Test("一括で戻しても ⌘Z は 1 回で全部返る [LAW-03][UD-04]")
    @MainActor
    func bulkRestoreIsASingleUndoStep() async throws {
        let v = try await vault()
        v.model.selection = Set(try #require(v.model.sections.first?.rows.map(\.id)))
        try await v.model.restoreSelected()

        _ = await v.commands.undo()
        await v.model.reload()
        #expect(v.model.sections.first?.rows.count == 2)
    }

    @Test("削除すると一覧から消え、⌘Z で同じ行 ID へ戻る [LAW-02][LE-07]")
    @MainActor
    func deleteRoundTripKeepsTheRowID() async throws {
        let v = try await vault()
        let target = try #require(v.model.sections.first?.rows.first?.label)
        v.model.selection = [target.id]

        try await v.model.deleteSelected()
        #expect(v.model.sections.first?.rows.count == 1)
        #expect(v.model.selection.isEmpty)

        _ = await v.commands.undo()
        await v.model.reload()
        let restored = try #require(v.model.sections.first?.rows.map(\.id))
        #expect(restored.contains(target.id), "AUTOINCREMENT のおかげで同じ ID へ戻る")
    }

    /// **⌘Z のたびに呼ばれる `reload()` が、利用者の選んだライブラリを勝手に
    /// 切り替えてはならない。**
    @Test("読み直しても選んだライブラリは動かない")
    @MainActor
    func reloadDoesNotMoveTheSelection() async throws {
        let v = try await vault()
        let chosen = try #require(v.model.selectedLibraryID)
        await v.model.reload()
        #expect(v.model.selectedLibraryID == chosen)
    }

    /// 「保管庫は空」と「検索に一致しない」は次の一手が違うので区別する。
    @Test("検索で 0 件になっても、保管庫が空とは言わない")
    @MainActor
    func emptySearchResultIsNotAnEmptyVault() async throws {
        let v = try await vault()
        v.model.searchText = "存在しない名前"
        #expect(v.model.sections.isEmpty)
        #expect(!v.model.vaultIsEmpty, "保管庫自体には中身がある")
    }

    @Test("保管庫が空のライブラリでは、空だと言う")
    @MainActor
    func emptyVaultIsReported() async throws {
        let v = try await vault(archiving: 0)
        #expect(v.model.sections.isEmpty)
        #expect(v.model.vaultIsEmpty)
    }
}
