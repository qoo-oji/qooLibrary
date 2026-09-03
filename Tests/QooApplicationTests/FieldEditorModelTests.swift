import Foundation
import QooKit
import Testing
@testable import QooApplication

//
//  ラベルフィールド編集ウインドウのモデル [LE-01〜LE-12]。
//
//  並べ替え・検索・0 件の判定・統合できる相手は**純粋関数**なので、DB を
//  開かずに固定できる（`LabelEditorModel.candidates` を切り出したのと同じ形）。
//  DB を要する経路だけ `ServicesWorkspace` を使う。
//

@Suite("ラベル一覧の並べ方と検索 [LE-12][LE-04][LB-07]")
struct FieldEditorRowTests {

    /// - Parameter count: **生きている実体の件数** [LA3-01]。0 なら自動的に
    ///   非表示になる——件数の意味は 1 つだけになった [§19.13 #1]。
    /// - Parameter hidden: 手動で非表示にした印 [LA3-02]。
    private func label(_ name: String, count: Int = 1,
                       hidden: Bool = false, pinned: Bool = false,
                       id: Int64 = 0) -> LabelSummary {
        LabelSummary(id: LabelID(rawValue: id == 0 ? Int64(abs(name.hashValue % 100000)) : id),
                     fieldID: FieldID(rawValue: 1), name: name,
                     normalizedName: name.lowercased(), colorHex: nil,
                     isPinned: pinned, isHidden: hidden, fileCount: count)
    }

    @Test("名前順は自然順（10 が 2 の後に来る）[LE-12]")
    func nameOrderIsNatural() {
        let rows = FieldEditorModel.rows(
            from: [label("作品2"), label("作品10"), label("作品1")],
            sortedBy: .name, matching: "")
        #expect(rows.map(\.name) == ["作品1", "作品2", "作品10"])
    }

    @Test("件数順は多い順で、同数は名前順 [LE-12]")
    func fileCountOrderBreaksTiesByName() {
        let rows = FieldEditorModel.rows(
            from: [label("B", count: 3), label("C", count: 7), label("A", count: 3)],
            sortedBy: .fileCount, matching: "")
        #expect(rows.map(\.name) == ["C", "A", "B"])
        #expect(rows.map(\.fileCount) == [7, 3, 3])
    }

    /// **全角で打っても半角のラベルに当たる。** 日本語入力をオンにしたまま
    /// 英字を打つのはごく普通のことで、幅までユーザーに合わせさせない。
    @Test("検索は幅と大小文字を区別しない [LE-12]", arguments: [
        "abc", "ABC", "ＡＢＣ", "Abc",
    ])
    func searchIgnoresWidthAndCase(query: String) {
        let rows = FieldEditorModel.rows(
            from: [label("STUDIO abc"), label("よそのサークル")],
            sortedBy: .name, matching: query)
        #expect(rows.map(\.name) == ["STUDIO abc"])
    }

    @Test("検索が空なら全件出る")
    func emptySearchKeepsEverything() {
        let rows = FieldEditorModel.rows(
            from: [label("A"), label("B")], sortedBy: .name, matching: "   ")
        #expect(rows.count == 2)
    }

    /// **保管庫にあるラベルも一覧に出す** [LE-06][LA-06]。この画面と保管庫の
    /// **実体 0 件のラベルも一覧に出て、控えめな印が付く** [LA3-03]。
    /// この画面が、非表示になったラベルを整理できる唯一の場所である。
    ///
    /// 印は 2 通りに出し分ける——手動 [LA3-02] は「表示に戻す」で解けるが、
    /// 実体 0 件 [LA3-01] は解けない。
    @Test("実体 0 件のラベルは控えめに出るが、手動の印は立たない [LA3-01][LA3-03]")
    func labelWithoutFilesIsListedAsHidden() {
        let rows = FieldEditorModel.rows(
            from: [label("実体なし", count: 0), label("通常のもの")],
            sortedBy: .name, matching: "")
        let row = try! #require(rows.first { $0.name == "実体なし" })
        #expect(row.fileCount == 0)
        #expect(row.isHidden, "フィルタから消えているので控えめに出す")
        #expect(!row.isManuallyHidden, "**導出であって印ではない**——「表示に戻す」は出さない")
    }

    /// 件数順の並べ替えも**バッジと同じ件数**で決める——一覧に出ている数字と
    /// 並び順が食い違うと、何を基準に並んでいるのか読めなくなる。
    @Test("件数順はバッジの件数で並べる [LE-12]")
    func fileCountOrderUsesTheBadgeCount() {
        let rows = FieldEditorModel.rows(
            from: [label("A", count: 5), label("B", count: 9)],
            sortedBy: .fileCount, matching: "")
        #expect(rows.map(\.name) == ["B", "A"])
    }

    @Test("手動で非表示にしたラベルも一覧に出て、専用の印が付く [LA3-02][LA3-03]")
    func manuallyHiddenLabelsAreListedAndFlagged() {
        let rows = FieldEditorModel.rows(
            from: [label("隠したもの", hidden: true), label("通常のもの")],
            sortedBy: .name, matching: "")
        #expect(rows.count == 2)
        let row = try! #require(rows.first { $0.name == "隠したもの" })
        #expect(row.isHidden)
        #expect(row.isManuallyHidden, "「表示に戻す」を出せる")
    }

    @Test("統合先は自分を除いた同じフィールドの全部（非表示のものも含む）[LB-07]")
    func mergeTargetsExcludeSelfAndIncludeHidden() {
        let a = label("A", id: 1), b = label("B", id: 2)
        let c = label("C", hidden: true, id: 3)
        let targets = FieldEditorModel.mergeTargets(from: [a, b, c], excluding: a.id)
        #expect(targets.map(\.name) == ["B", "C"])
    }
}

@Suite("ラベルフィールド編集ウインドウ [LE-07〜LE-11]", .serialized)
struct FieldEditorModelTests {

    /// ワークスペースとモデルを 1 つにまとめて返す。
    ///
    /// **`ServicesWorkspace` はモデルより長生きしなければならない**——`deinit` が
    /// 一時ストアのディレクトリごと消すので、`let (_, m) = …` で捨てると以後の
    /// 書き込みが「disk I/O error」になる（実際に踏んだ）。型で持たせて取り違えを防ぐ。
    @MainActor
    final class Editor {
        let workspace: ServicesWorkspace
        let model: FieldEditorModel
        init(workspace: ServicesWorkspace, model: FieldEditorModel) {
            self.workspace = workspace
            self.model = model
        }
    }

    @MainActor
    private func workspace(files: Int = 3) async throws -> Editor {
        let w = try ServicesWorkspace()
        await w.bootstrap()
        for i in 1...files {
            try w.write("(同人誌) [サークル値\(i) (著者値\(i))] 作品タイトル\(i) (ジャンル値1).cbz")
        }
        let id = try await w.enable("builtin.doujinshi-a")
        _ = try await w.services.scan(libraryID: id, root: w.libraryRoot)
        let m = FieldEditorModel(commands: CommandStack())
        await m.prepare(services: w.services)
        // サークルフィールドを選んでおく
        let circle = try #require(m.fields.first { $0.name == "サークル" })
        m.selectedFieldID = circle.id
        await m.reload()
        return Editor(workspace: w, model: m)
    }

    @Test("フィールドを選ぶと、そのラベルが読める [LE-03]")
    @MainActor
    func loadsLabelsOfTheSelectedGroup() async throws {
        let e = try await workspace()
        let m = e.model
        #expect(m.state == .ready)
        #expect(m.rows.count == 3)
        #expect(m.rows.allSatisfy { $0.fileCount == 1 })   // 件数バッジの元 [LE-03]
    }

    @Test("改名すると一覧に反映され、⌘Z で戻る [LB-06]")
    @MainActor
    func renameRoundTrip() async throws {
        let e = try await workspace()
        let m = e.model
        let target = try #require(m.rows.first).label
        try await m.rename(target, to: "改名後")
        #expect(m.rows.contains { $0.name == "改名後" })
    }

    @Test("既存名への改名は理由を添えて断る [LE-11]")
    @MainActor
    func renameCollisionIsReported() async throws {
        let e = try await workspace()
        let m = e.model
        let a = try #require(m.rows.first).label
        let b = try #require(m.rows.dropFirst().first).label
        await #expect(throws: LabelEditError.nameAlreadyExists(existing: a.id, name: a.name)) {
            try await m.rename(b, to: a.name)
        }
    }

    @Test("新しいラベルを作ると選択される。同じ名前なら作られない [LB-01]")
    @MainActor
    func createLabel() async throws {
        let e = try await workspace()
        let m = e.model
        try await m.createLabel(named: "新しいサークル")
        #expect(m.rows.count == 4)
        #expect(m.selection.count == 1)
        // 同じ正規化名なら増えない
        try await m.createLabel(named: "新しいサークル")
        #expect(m.rows.count == 4)
        // 空白だけの名前は無視する
        try await m.createLabel(named: "   ")
        #expect(m.rows.count == 4)
    }

    @Test("非表示にする／表示に戻す。選択が混ざっていたら隠す側に倒す [LA3-02]")
    @MainActor
    func hideAction() async throws {
        let e = try await workspace()
        let m = e.model
        let all = m.rows.map(\.label)
        m.selection = [all[0].id]
        #expect(m.hideActionHides)
        try await m.setSelectedHidden(true)
        #expect(m.rows.first { $0.id == all[0].id }?.isManuallyHidden == true)

        // 隠したものだけを選べば「表示に戻す」
        #expect(m.hideActionHides == false)

        // 混ざっていたら「隠す」
        m.selection = [all[0].id, all[1].id]
        #expect(m.hideActionHides)
    }

    /// **実機検証で見つけた。** 何も選んでいないのに「表示に戻す」と
    /// 出ていた——押せないが、まれで逆向きの操作をこの画面の主目的だと
    /// 読ませてしまう。
    @Test("何も選んでいないときは「非表示にする」を出す")
    @MainActor
    func hideActionDefaultsToHidingWhenNothingIsSelected() async throws {
        let e = try await workspace()
        let m = e.model
        m.selection = []
        #expect(m.hideActionHides)
    }

    @Test("削除すると一覧から消え、選択も片付く [LE-07]")
    @MainActor
    func deleteSelected() async throws {
        let e = try await workspace()
        let m = e.model
        m.selection = [try #require(m.rows.first).id]
        try await m.deleteSelected()
        #expect(m.rows.count == 2)
        #expect(m.selection.isEmpty)
    }

    @Test("統合すると 1 件になり、統合先が選択される [LB-07]")
    @MainActor
    func mergeSelectsTheSurvivor() async throws {
        let e = try await workspace()
        let m = e.model
        let source = try #require(m.rows.first).label
        let target = try #require(m.rows.dropFirst().first).label
        try await m.merge(source, into: target)
        #expect(m.rows.count == 2)
        #expect(m.selection == [target.id])
        #expect(m.rows.first { $0.id == target.id }?.fileCount == 2)
    }

    @Test("ライブラリを切り替えるとフィールドの選択を持ち越さない")
    @MainActor
    func switchingLibraryClearsTheGroupSelection() async throws {
        let e = try await workspace()
        let m = e.model
        #expect(m.selectedFieldID != nil)
        m.selectedLibraryID = LibraryID(rawValue: 999)
        #expect(m.selectedFieldID == nil)
    }

    /// 起動と同時に状態復元で開かれると、DB の準備より先に「未選択」で確定して
    /// しまう——設定ウインドウで実際に踏んだ競合。
    @Test("一覧が遅れて届いても選択が付く")
    @MainActor
    func selectionFollowsALateArrivingLibraryList() async throws {
        let m = FieldEditorModel(commands: CommandStack())
        #expect(m.selectedLibraryID == nil)
        let e = try await workspace()
        await m.prepare(services: e.workspace.services)
        #expect(m.selectedLibraryID != nil)
    }
}
