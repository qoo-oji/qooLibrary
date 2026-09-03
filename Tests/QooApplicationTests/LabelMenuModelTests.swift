import Foundation
import QooKit
import Testing
@testable import QooApplication

//
//  中央ペインのラベルメニュー [RL3-01〜RL3-03]。
//
//  DB を実際に開いて確かめる——`fileIDsByChildName` の既定の絞り（active・
//  保管庫外 [FI-02]）と `AssignLabelCommand.toggling` の書き込みの性質は、
//  リポジトリを偽物に差し替えると試せない（`LabelEditingTests` と同じ理由）。
//  `ServicesWorkspace`（`LibraryServicesTests.swift`）を共有する。
//

@Suite("中央ペインのラベルメニュー [RL3-01〜RL3-03]", .serialized)
struct LabelMenuModelTests {

    private static func name(_ n: Int) -> String {
        "(同人誌) [サークル値\(n) (著者値\(n))] 作品タイトル\(n) (ジャンル値1).cbz"
    }

    /// 同人誌(A) で走査まで済ませた作業場。ラベルは自動付与で付く。
    @MainActor
    private func workspace(files: [String]) async throws
        -> (ServicesWorkspace, LibrarySummary, [URL])
    {
        let w = try ServicesWorkspace()
        await w.bootstrap()
        for name in files { try w.write(name) }
        let id = try await w.enable("builtin.doujinshi-a")
        _ = try await w.services.scan(libraryID: id, root: w.libraryRoot)
        let library = try #require(w.services.library(registrationUUID: w.registrationUUID))
        return (w, library, files.map { w.libraryRoot.appendingPathComponent($0) })
    }

    @MainActor
    private func loadedModel(_ w: ServicesWorkspace, _ library: LibrarySummary?,
                             relativePath: String = "", stack: CommandStack = CommandStack())
        async -> LabelMenuModel
    {
        let m = LabelMenuModel(commands: stack)
        await m.load(library: library, relativePath: relativePath,
                     libraryRows: [], services: w.services)
        return m
    }

    /// メニュー用に「そのフィールドの、対象に付いているラベル」を引く補助。
    @MainActor
    private func assignedLabels(_ m: LabelMenuModel, ids: [FileID]) -> [LabelSummary] {
        m.groups.flatMap { m.menuLabels(in: $0, for: ids) }
            .filter { m.checkState(of: $0, for: ids) != .none }
    }

    // MARK: - 読み込みと対象の解決 [RL3-01]

    @Test("ライブラリ経由でなければメニューを出さない [LF-01 と同じ判断]")
    @MainActor
    func emptyOutsideALibrary() async throws {
        let (w, _, _) = try await workspace(files: [Self.name(1)])
        let m = await loadedModel(w, nil)
        #expect(m.groups.isEmpty)
        #expect(m.fileID(forChildName: Self.name(1)) == nil)
    }

    @Test("直下の蔵書だけが名前で引ける（サブフォルダ・対象拡張子外は引けない）")
    @MainActor
    func mapsOnlyDirectChildren() async throws {
        let deep = "サブ/\(Self.name(2))"
        let (w, library, _) = try await workspace(files: [Self.name(1), deep])
        try w.write("メモ.txt")
        _ = try await w.services.scan(libraryID: library.id, root: w.libraryRoot)
        let m = await loadedModel(w, library)
        #expect(m.fileID(forChildName: Self.name(1)) != nil)
        #expect(m.fileID(forChildName: Self.name(2)) == nil,
                "サブフォルダの中身は直下の対応表に載らない")
        #expect(m.fileID(forChildName: "メモ.txt") == nil, "DB に行が無い [AL-11]")
        #expect(m.fileID(forChildName: "サブ") == nil, "通常フォルダは蔵書ではない")
    }

    @Test("孤立したレコードは対象にならない [FI-02 の既定の絞り]")
    @MainActor
    func orphanedRowsAreExcluded() async throws {
        let (w, library, urls) = try await workspace(files: [Self.name(1), Self.name(2)])
        try FileManager.default.removeItem(at: urls[1])
        _ = try await w.services.scan(libraryID: library.id, root: w.libraryRoot)
        let m = await loadedModel(w, library)
        #expect(m.fileID(forChildName: Self.name(1)) != nil)
        #expect(m.fileID(forChildName: Self.name(2)) == nil,
                "実体を失った記録にラベルは付けない")
    }

    // MARK: - 三状態 [RP-02]

    @Test("自動付与のラベルは all、無関係のラベルは none")
    @MainActor
    func checkStateReflectsAssignments() async throws {
        let (w, library, _) = try await workspace(files: [Self.name(1), Self.name(2)])
        let m = await loadedModel(w, library)
        let id1 = try #require(m.fileID(forChildName: Self.name(1)))
        let id2 = try #require(m.fileID(forChildName: Self.name(2)))

        // サークル値1 は 1 冊目にだけ付く（自動付与）。
        let circle1 = try #require(m.groups.flatMap { m.menuLabels(in: $0, for: [id1]) }
            .first { $0.name == "サークル値1" })
        #expect(m.checkState(of: circle1, for: [id1]) == .all)
        #expect(m.checkState(of: circle1, for: [id2]) == .none)
        #expect(m.checkState(of: circle1, for: [id1, id2]) == .some,
                "片方にだけ付いていれば三状態の中間 [RP-02]")
    }

    @Test("manuallyRemoved は「付いていない」と数える [RC-04]")
    @MainActor
    func manuallyRemovedCountsAsUnassigned() async throws {
        let (w, library, _) = try await workspace(files: [Self.name(1)])
        let stack = CommandStack()
        let m = await loadedModel(w, library, stack: stack)
        let id1 = try #require(m.fileID(forChildName: Self.name(1)))
        let label = try #require(assignedLabels(m, ids: [id1]).first)

        try await m.toggle(label, targets: [.init(id: id1, url: URL(fileURLWithPath: "/t"))])
        #expect(m.checkState(of: label, for: [id1]) == .none)
        let after = try await w.services.labelAssignments(fileIDs: [id1])
        #expect(after[id1]?.contains(label.id) != true, "行ごと消える [PR-08]")
        // 外した操作はそのフィールドを保護する [PR-03]。
        let scopes = try await w.services.protectedScopes(ids: [id1])
        #expect(scopes[id1]?.contains(.field(label.groupID)) == true)
    }

    // MARK: - トグル [RL3-01][RL3-03]

    @Test("中間状態を押したら全部に付ける（インスペクタと同じ向き）")
    @MainActor
    func togglingAPartialLabelAssignsToAll() async throws {
        let (w, library, urls) = try await workspace(files: [Self.name(1), Self.name(2)])
        let stack = CommandStack()
        let m = await loadedModel(w, library, stack: stack)
        let id1 = try #require(m.fileID(forChildName: Self.name(1)))
        let id2 = try #require(m.fileID(forChildName: Self.name(2)))
        let circle1 = try #require(m.groups.flatMap { m.menuLabels(in: $0, for: [id1]) }
            .first { $0.name == "サークル値1" })
        #expect(m.checkState(of: circle1, for: [id1, id2]) == .some)

        let targets = [LabelMenuModel.Target(id: id1, url: urls[0]),
                       LabelMenuModel.Target(id: id2, url: urls[1])]
        try await m.toggle(circle1, targets: targets)
        #expect(m.checkState(of: circle1, for: [id1, id2]) == .all)
        let after = try await w.services.labelAssignments(fileIDs: [id1, id2])
        // どちらにも付き、そのフィールドが保護される [PR-03]。インスペクタ
        // （`LabelEditorModel`）と同じ挙動で、変更前の状態は ⌘Z のために
        // `Previous` が 1 件ずつ持つ（次のテスト）。
        #expect(after[id1]?.contains(circle1.id) == true)
        #expect(after[id2]?.contains(circle1.id) == true)
        let scopes = try await w.services.protectedScopes(ids: [id1, id2])
        #expect(scopes[id1]?.contains(.field(circle1.groupID)) == true)
        #expect(scopes[id2]?.contains(.field(circle1.groupID)) == true)
    }

    /// **RL3-03 そのもの。** ⌘Z がファイルごとの変更前の状態へ戻す——
    /// `AssignLabelCommand.toggling` をインスペクタと共有していることの検証。
    @Test("⌘Z がファイルごとの元の状態へ戻す [RL3-03][RA-06 と同じ判断]")
    @MainActor
    func undoRestoresPerFileState() async throws {
        let (w, library, urls) = try await workspace(files: [Self.name(1), Self.name(2)])
        let stack = CommandStack()
        let m = await loadedModel(w, library, stack: stack)
        let id1 = try #require(m.fileID(forChildName: Self.name(1)))
        let id2 = try #require(m.fileID(forChildName: Self.name(2)))
        let circle1 = try #require(m.groups.flatMap { m.menuLabels(in: $0, for: [id1]) }
            .first { $0.name == "サークル値1" })

        let targets = [LabelMenuModel.Target(id: id1, url: urls[0]),
                       LabelMenuModel.Target(id: id2, url: urls[1])]
        try await m.toggle(circle1, targets: targets)
        _ = try await stack.undo()
        let after = try await w.services.labelAssignments(fileIDs: [id1, id2])
        #expect(after[id1]?.contains(circle1.id) == true, "1 冊目は付いたまま")
        #expect(after[id2]?.contains(circle1.id) != true, "2 冊目は行なしへ戻る")
        let scopes = try await w.services.protectedScopes(ids: [id1, id2])
        #expect(scopes[id1]?.contains(.field(circle1.groupID)) != true, "保護も戻る")
    }

    @Test("既にその状態なら Undo スタックを汚さない（factory が nil を返す）")
    @MainActor
    func noOpToggleDoesNotPushUndo() async throws {
        let (w, library, urls) = try await workspace(files: [Self.name(1)])
        let stack = CommandStack()
        let m = await loadedModel(w, library, stack: stack)
        let id1 = try #require(m.fileID(forChildName: Self.name(1)))
        let label = try #require(assignedLabels(m, ids: [id1]).first)

        // 全部に付いている → 外す → もう一度トグルで付け直す、は変化がある。
        // ここで試すのは factory の no-op 判定そのもの。
        let command = AssignLabelCommand.toggling(
            labelID: label.id, groupID: label.groupID, labelName: label.name,
            files: [(id: id1, url: urls[0])],
            assignments: [id1: [label.id]],
            protectedScopes: [id1: [.field(label.groupID)]],
            assigning: true, subjectName: "x", services: w.services)
        #expect(command == nil, "付いていて保護もされていれば書くことが無い")
        #expect(stack.undoTitle == nil)
    }

    // MARK: - ラベルの出し分け [LA-03][RL-05]

    @Test("アーカイブ済みラベルは付与済みのときだけメニューに出る")
    @MainActor
    func archivedLabelsAppearOnlyWhenAssigned() async throws {
        let (w, library, _) = try await workspace(files: [Self.name(1), Self.name(2)])
        var m = await loadedModel(w, library)
        let id1 = try #require(m.fileID(forChildName: Self.name(1)))
        let id2 = try #require(m.fileID(forChildName: Self.name(2)))
        let circle1 = try #require(m.groups.flatMap { m.menuLabels(in: $0, for: [id1]) }
            .first { $0.name == "サークル値1" })

        try await w.services.setLabelHidden([circle1.id], true)
        m = await loadedModel(w, library)
        let group = try #require(m.groups.first { group in
            m.menuLabels(in: group, for: [id1]).contains { $0.id == circle1.id }
        }, "付与済みの対象では出る [RL-05]")
        #expect(!m.menuLabels(in: group, for: [id2]).contains { $0.id == circle1.id },
                "付いていない対象では候補に出ない [LA-03]")
    }
}
