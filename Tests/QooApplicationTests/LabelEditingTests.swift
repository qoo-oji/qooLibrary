import Foundation
import QooKit
import Testing
@testable import QooApplication

//
//  右ペインのラベル設定 [RL-01〜RL-07][RP-02]。
//
//  DB を実際に開いて確かめる——`AssignLabelCommand` が守っているのは
//  「変更前の origin を 1 件ずつ持って戻す」という**書き込みの性質**なので、
//  リポジトリを偽物に差し替えると肝心の部分が試せない（評価と同じ）。
//  `ServicesWorkspace`（`LibraryServicesTests.swift`）を共有する。
//

@Suite("ラベル設定 [RL-01〜RL-07][RP-02]", .serialized)
struct LabelEditingTests {

    /// 同人誌(A) はサークル・著者・イベント・ジャンルの 4 グループを持ち、
    /// 走査で自動ラベルが付く——`auto` を外す経路 [RC-04] を試すには、
    /// **その主張が成り立ちうる前提**（自動で付いたラベルがあること）が要る。
    @MainActor
    private func workspace(files: [String], preset: String = "builtin.doujinshi-a")
        async throws -> (ServicesWorkspace, LibrarySummary, [URL])
    {
        let w = try ServicesWorkspace()
        await w.bootstrap()
        for name in files { try w.write(name) }
        let id = try await w.enable(preset)
        _ = try await w.services.scan(libraryID: id, root: w.libraryRoot)
        let library = try #require(w.services.library(registrationUUID: w.registrationUUID))
        return (w, library, files.map { w.libraryRoot.appendingPathComponent($0) })
    }

    private static func name(_ n: Int) -> String {
        "(同人誌) [サークル値\(n) (著者値\(n))] 作品タイトル\(n) (ジャンル値1).cbz"
    }

    @MainActor
    private func model(_ w: ServicesWorkspace, _ library: LibrarySummary, _ urls: [URL],
                       stack: CommandStack) async -> LabelEditorModel {
        let m = LabelEditorModel(commands: stack)
        await m.load(urls: urls, library: library, services: w.services)
        return m
    }

    // MARK: - 読み込み

    @Test("ライブラリ経由でなければ欄を出さない [LF-01 と同じ判断]")
    @MainActor
    func notApplicableOutsideALibrary() async throws {
        let w = try ServicesWorkspace()
        await w.bootstrap()
        let m = LabelEditorModel(commands: CommandStack())
        await m.load(urls: [w.libraryRoot.appendingPathComponent("a.cbz")],
                     library: nil, services: w.services)
        #expect(m.state == .notApplicable)
    }

    @Test("ライブラリの中でも DB に行が無ければ理由を出す")
    @MainActor
    func notInLibraryWhenNoRowExists() async throws {
        let (w, library, _) = try await workspace(files: [Self.name(1)])
        try w.write("メモ.txt")                       // 対象拡張子ではない [AL-11]
        let m = await model(w, library, [w.libraryRoot.appendingPathComponent("メモ.txt")],
                            stack: CommandStack())
        #expect(m.state == .notInLibrary)
    }

    @Test("走査で付いた自動ラベルが読める [RL-01][RL-06]")
    @MainActor
    func readsAutoLabels() async throws {
        let (w, library, urls) = try await workspace(files: [Self.name(1)])
        let m = await model(w, library, urls, stack: CommandStack())
        guard case .ready(let subject) = m.state else { Issue.record("読めていない"); return }
        #expect(subject.targetCount == 1)
        #expect(subject.skippedCount == 0)
        #expect(!m.displayGroups.isEmpty, "自動付与があるので一覧に出るグループがある")

        let assigned = m.displayGroups.flatMap { m.visibleLabels(in: $0) }.filter { m.isAssigned($0) }
        #expect(!assigned.isEmpty)
        // 走査が付けただけのフィールドは保護されていない [PR-01]。
        #expect(assigned.allSatisfy { !m.assignment(of: $0).isProtected })
        #expect(assigned.allSatisfy { m.assignment(of: $0).checkState == .all })
    }

    /// **DB に行が無いものが混ざっても黙って落とさない** [RP-02]。
    /// 「10 件選んだのに 8 件にしか付かなかった」を数字で見えるようにする。
    @Test("対象外が混ざったら件数の差に出る [RP-02]")
    @MainActor
    func reportsSkippedSelection() async throws {
        let (w, library, urls) = try await workspace(files: [Self.name(1), Self.name(2)])
        try w.write("メモ.txt")
        let m = await model(w, library, urls + [w.libraryRoot.appendingPathComponent("メモ.txt")],
                            stack: CommandStack())
        guard case .ready(let subject) = m.state else { Issue.record("読めていない"); return }
        #expect(subject.selectedCount == 3)
        #expect(subject.targetCount == 2)
        #expect(subject.skippedCount == 1)
    }

    // MARK: - 付け外し

    /// **PR-03 そのもの。** 保護を立てないと、次の再スキャンで自動付与が復活する。
    @Test("ラベルを外すとそのフィールドが保護される [PR-03]")
    @MainActor
    func removingALabelProtectsItsField() async throws {
        let (w, library, urls) = try await workspace(files: [Self.name(1)])
        let stack = CommandStack()
        let m = await model(w, library, urls, stack: stack)
        guard case .ready(let subject) = m.state else { Issue.record("読めていない"); return }
        let label = try #require(m.displayGroups.flatMap { m.visibleLabels(in: $0) }
            .first { m.assignment(of: $0).assignedCount > 0 })

        try await m.toggle(label)
        let after = try await w.services.labelAssignments(fileIDs: subject.fileIDs)
        #expect(after[subject.fileIDs[0]]?.contains(label.id) != true)
        let scopes = try await w.services.protectedScopes(ids: subject.fileIDs)
        #expect(scopes[subject.fileIDs[0]]?.contains(.field(label.groupID)) == true)

        // 再スキャンしても復活しない [PR-01]。
        _ = try await w.services.scan(libraryID: library.id, root: w.libraryRoot)
        let rescanned = try await w.services.labelAssignments(fileIDs: subject.fileIDs)
        #expect(rescanned[subject.fileIDs[0]]?.contains(label.id) != true,
                "保護されたフィールドへ走査が付け足してはならない")
    }

    /// 手で作って付けたラベルを外したときも同じ——保護は「そのフィールドを
    /// 触った」ことに対して立つ [PR-03]。
    @Test("手で付けたラベルを外したときも保護が立つ [PR-03]")
    @MainActor
    func removingAManuallyAddedLabelAlsoProtects() async throws {
        let (w, library, urls) = try await workspace(files: [Self.name(1)])
        let stack = CommandStack()
        let m = await model(w, library, urls, stack: stack)
        guard case .ready(let subject) = m.state else { Issue.record("読めていない"); return }
        let group = try #require(m.allGroups.first)

        try await m.createAndAdd(groupID: group.id, name: "手で付けた値")
        await m.reload()
        let label = try #require(m.addableLabels(in: group).first { $0.name == "手で付けた値" })
        #expect(m.assignment(of: label).isProtected, "付けた時点で保護されている [PR-03]")

        try await m.toggle(label)
        let after = try await w.services.labelAssignments(fileIDs: subject.fileIDs)
        #expect(after[subject.fileIDs[0]]?.contains(label.id) != true)
        let scopes = try await w.services.protectedScopes(ids: subject.fileIDs)
        #expect(scopes[subject.fileIDs[0]]?.contains(.field(label.groupID)) == true)
    }

    /// **これが崩れると ⌘Z が元の状態を壊す。** ファイルごとに「付いていた／
    /// いなかった」と保護の集合が違うので、一律に戻す実装だと「戻した」ように
    /// 見えて別の状態になる [RA-06 と同じ形]。
    @Test("取り消しはファイルごとの元の状態へ戻す [RL-07][UD-01]")
    @MainActor
    func undoRestoresPerFileState() async throws {
        let (w, library, urls) = try await workspace(files: [Self.name(1), Self.name(2)])
        let stack = CommandStack()
        let m = await model(w, library, urls, stack: stack)
        guard case .ready(let subject) = m.state else { Issue.record("読めていない"); return }
        // ジャンル値1 は 2 件とも自動で付く。1 件目だけ先に保護しておく。
        let group = try #require(m.allGroups.first { g in
            m.visibleLabels(in: g).contains { m.assignment(of: $0).checkState == .all }
        })
        let label = try #require(m.visibleLabels(in: group).first {
            m.assignment(of: $0).checkState == .all
        })
        try await w.services.setProtectedScopes(
            [subject.fileIDs[0]: [.field(label.groupID)]])
        await m.reload()

        try await m.toggle(label)                       // 2 件とも外れる
        let removed = try await w.services.labelAssignments(fileIDs: subject.fileIDs)
        #expect(removed[subject.fileIDs[0]]?.contains(label.id) != true)
        #expect(removed[subject.fileIDs[1]]?.contains(label.id) != true)

        _ = await stack.undo()
        let restored = try await w.services.labelAssignments(fileIDs: subject.fileIDs)
        #expect(restored[subject.fileIDs[0]]?.contains(label.id) == true, "2 件とも戻る")
        #expect(restored[subject.fileIDs[1]]?.contains(label.id) == true)
        // **保護はファイルごとに元へ戻る**——一律に落とすと、元から保護されて
        // いた 1 件目まで守られなくなる。
        let scopes = try await w.services.protectedScopes(ids: subject.fileIDs)
        #expect(scopes[subject.fileIDs[0]]?.contains(.field(label.groupID)) == true)
        #expect(scopes[subject.fileIDs[1]]?.contains(.field(label.groupID)) != true)
    }

    @Test("付けた直後の取り消しは、紐づけの行ごと消す [RL-07]")
    @MainActor
    func undoOfAnAdditionRemovesTheRow() async throws {
        let (w, library, urls) = try await workspace(files: [Self.name(1)])
        let stack = CommandStack()
        let m = await model(w, library, urls, stack: stack)
        guard case .ready(let subject) = m.state else { Issue.record("読めていない"); return }
        let group = try #require(m.allGroups.first)
        try await m.createAndAdd(groupID: group.id, name: "新しい値")
        await m.reload()
        let label = try #require(m.addableLabels(in: group).first { $0.name == "新しい値" })

        _ = await stack.undo()
        let after = try await w.services.labelAssignments(fileIDs: subject.fileIDs)
        #expect(after[subject.fileIDs[0]]?.contains(label.id) != true,
                "行が無かったのだから、行ごと消えるのが元の状態")

        _ = await stack.redo()
        let redone = try await w.services.labelAssignments(fileIDs: subject.fileIDs)
        #expect(redone[subject.fileIDs[0]]?.contains(label.id) == true)
    }

    // MARK: - 複数選択 [RP-02]

    @Test("一部にだけ付いていれば三状態の中間になる [RP-02]")
    @MainActor
    func mixedSelectionIsPartiallyChecked() async throws {
        let (w, library, urls) = try await workspace(files: [Self.name(1), Self.name(2)])
        let stack = CommandStack()
        let m = await model(w, library, urls, stack: stack)
        guard case .ready(let subject) = m.state else { Issue.record("読めていない"); return }
        // サークル値1 は 1 件目にだけ付く。
        let label = try #require(m.displayGroups.flatMap { m.visibleLabels(in: $0) }
            .first { m.assignment(of: $0).checkState == .some })
        let a = m.assignment(of: label)
        #expect(a.assignedCount == 1)
        #expect(a.targetCount == 2)
        _ = subject
    }

    /// **`.some` を押したら全部に付ける**——外す側に倒すと、まだ付けていない
    /// ファイルではなく「付いていたファイル」の側が変わる。
    @Test("中間状態を押すと全部に付く [RP-02][RL-03]")
    @MainActor
    func togglingAMixedStateAssignsToAll() async throws {
        let (w, library, urls) = try await workspace(files: [Self.name(1), Self.name(2)])
        let stack = CommandStack()
        let m = await model(w, library, urls, stack: stack)
        let label = try #require(m.displayGroups.flatMap { m.visibleLabels(in: $0) }
            .first { m.assignment(of: $0).checkState == .some })

        try await m.toggle(label)
        await m.reload()
        #expect(m.assignment(of: label).checkState == .all)

        try await m.toggle(label)                        // 今度は全部から外れる
        await m.reload()
        #expect(m.assignment(of: label).checkState == .none)
    }

    /// [RL-06] 混在しているのに「自動」の印を出すと、手で付けたものまで
    /// 再スキャンで消えるように読めてしまう。
    @Test("自動と手動が混ざったら自動の印を出さない [RL-06]")
    @MainActor
    func mixedProtectionIsNotShownAsProtected() async throws {
        let (w, library, urls) = try await workspace(files: [Self.name(1), Self.name(2)])
        let stack = CommandStack()
        let m = await model(w, library, urls, stack: stack)
        guard case .ready(let subject) = m.state else { Issue.record("読めていない"); return }
        let label = try #require(m.displayGroups.flatMap { m.visibleLabels(in: $0) }
            .first { m.assignment(of: $0).checkState == .all })
        #expect(!m.assignment(of: label).isProtected, "走査が付けただけなら保護なし")

        // 片方だけ保護する。
        try await w.services.setProtectedScopes(
            [subject.fileIDs[0]: [.field(label.groupID)]])
        await m.reload()
        #expect(!m.assignment(of: label).isProtected,
                "混在で鍵を出すと、守られていないほうまで守られているように読める")
    }

    // MARK: - 出し分け

    /// [LA-03] 追加候補には出さないが、[RL-05] 付与済みなら一覧に出す
    /// ——出さないと「画面に無いのに付いている」ラベルができ、外す手段が消える。
    @Test("手動で非表示にしたものは候補に出さないが、付与済みなら一覧に出す [LA-03][RL-05]")
    func hiddenLabelsAreOmittedUnlessAssigned() {
        func label(_ id: Int64, hidden: Bool) -> LabelSummary {
            LabelSummary(id: LabelID(rawValue: id), groupID: LabelGroupID(rawValue: 1),
                         name: "l\(id)", normalizedName: "l\(id)", colorHex: nil,
                         isPinned: false, isHidden: hidden, fileCount: 1)
        }
        let all = [label(1, hidden: false), label(2, hidden: true), label(3, hidden: true)]
        // 2 番だけ付与済み。
        let shown = LabelEditorModel.candidates(from: all, isAssigned: { $0.id.rawValue == 2 })
        #expect(shown.map(\.id.rawValue) == [1, 2], "[RL-05] 付いているものは見えなければならない")
        #expect(LabelEditorModel.addable(from: all).map(\.id.rawValue) == [1],
                "[LA-03] 追加候補には手動で非表示にしたものを出さない")
    }

    /// **実体 0 件のラベルは、追加候補には出す**［ユーザー判断、LA3-01］。
    ///
    /// ラベルフィルタ [LA3-05] は「いま在るもので絞る」ための一覧なので 0 件を
    /// 隠すが、こちらは「これから付けるもの」の一覧で目的が違う——付ければ
    /// 1 件になって自動的に表示へ戻る。隠すと、同名で「新規作成」して既存の行を
    /// 引き当てるという遠回りしか手段が無くなる。
    @Test("実体 0 件のラベルは追加候補に出す [LA3-01]")
    func labelsWithoutFilesRemainAddable() {
        func label(_ id: Int64, count: Int) -> LabelSummary {
            LabelSummary(id: LabelID(rawValue: id), groupID: LabelGroupID(rawValue: 1),
                         name: "l\(id)", normalizedName: "l\(id)", colorHex: nil,
                         isPinned: false, isHidden: false, fileCount: count)
        }
        let all = [label(1, count: 3), label(2, count: 0)]
        #expect(!all[1].isVisible, "フィルタからは消えている [LA3-01]")
        #expect(LabelEditorModel.addable(from: all).map(\.id.rawValue) == [1, 2])
        #expect(LabelEditorModel.candidates(from: all, isAssigned: { _ in false })
            .map(\.id.rawValue) == [1, 2])
    }

    @Test("同じ状態への操作は Undo スタックを汚さない")
    @MainActor
    func noOpDoesNotRecord() async throws {
        let (w, library, urls) = try await workspace(files: [Self.name(1)])
        let stack = CommandStack()
        let m = await model(w, library, urls, stack: stack)
        let label = try #require(m.displayGroups.flatMap { m.visibleLabels(in: $0) }
            .first { m.assignment(of: $0).checkState == .all })
        try await m.toggle(label)                        // 外す
        let depth = stack.operationHistory.count
        try await m.toggle(label)                        // 付ける
        try await m.toggle(label)                        // また外す
        #expect(stack.operationHistory.count == depth + 2)
        try await m.add(label)                            // 付ける
        let afterAdd = stack.operationHistory.count
        try await m.add(label)                            // すでに付いている
        #expect(stack.operationHistory.count == afterAdd, "変化しないなら記録しない")
    }

    // MARK: - 消えないことの担保

    @Test("手動で付けたラベルは再スキャンで消えない [RC-04]")
    @MainActor
    func manualLabelsSurviveRescan() async throws {
        let (w, library, urls) = try await workspace(files: [Self.name(1)])
        let stack = CommandStack()
        let m = await model(w, library, urls, stack: stack)
        guard case .ready(let subject) = m.state else { Issue.record("読めていない"); return }
        let group = try #require(m.allGroups.first)
        try await m.createAndAdd(groupID: group.id, name: "残るべき値")
        await m.reload()
        let label = try #require(m.addableLabels(in: group).first { $0.name == "残るべき値" })

        _ = try await w.services.scan(libraryID: library.id, root: w.libraryRoot)
        let after = try await w.services.labelAssignments(fileIDs: subject.fileIDs)
        #expect(after[subject.fileIDs[0]]?.contains(label.id) == true,
                "保護されたフィールドは走査が動かさない [PR-01]")
    }

    // MARK: - コマンド

    @Test("Undo メニューに出る名前 [UD-06]")
    @MainActor
    func displayNames() async throws {
        let w = try ServicesWorkspace()
        let url = w.libraryRoot.appendingPathComponent(Self.name(1))
        let previous = [AssignLabelCommand.Previous(
            fileID: FileID(rawValue: 1), url: url, wasAssigned: false, protectedScopes: [])]
        let group = LabelGroupID(rawValue: 1)
        let add = AssignLabelCommand(labelID: LabelID(rawValue: 1), groupID: group,
                                     labelName: "サークル値1",
                                     previous: previous, assigning: true,
                                     subjectName: Self.name(1), services: w.services)
        #expect(add.displayName == "「\(Self.name(1))」のラベル「サークル値1」を付与")
        #expect(add.isUndoable)

        let remove = AssignLabelCommand(labelID: LabelID(rawValue: 1), groupID: group,
                                        labelName: "サークル値1",
                                        previous: previous, assigning: false,
                                        subjectName: "3 項目", services: w.services)
        #expect(remove.displayName == "「3 項目」のラベル「サークル値1」を除去")
    }

    /// 診断ログの匿名化が拾えるのは絶対パスと `Log.redactable` の印だけ
    /// [LG2-06]。素のファイル名を書くと書き出しバンドルに残る。
    @Test("診断ログの説明は絶対パスで書く [LG2-06]")
    @MainActor
    func logDescriptionUsesAbsolutePaths() async throws {
        let w = try ServicesWorkspace()
        let url = w.libraryRoot.appendingPathComponent(Self.name(1))
        let command = AssignLabelCommand(
            labelID: LabelID(rawValue: 1), groupID: LabelGroupID(rawValue: 1),
            labelName: "サークル値1",
            previous: [AssignLabelCommand.Previous(fileID: FileID(rawValue: 1), url: url,
                                                   wasAssigned: false, protectedScopes: [])],
            assigning: true, subjectName: Self.name(1), services: w.services)
        let text = command.logDescription
        #expect(text.contains(url.path))
        #expect(!text.contains("「\(Self.name(1))」"), "`displayName` をそのまま流用していない")
    }
}

@Suite("ピン留めのある一覧の並べ方 [PN-02][PN-03][PN-06][RL-05]")
struct PinnedLabelListingTests {

    private func label(_ id: Int64, _ name: String, pinned: Bool = false) -> LabelSummary {
        LabelSummary(id: LabelID(rawValue: id), groupID: LabelGroupID(rawValue: 1),
                     name: name, normalizedName: name, colorHex: nil,
                     isPinned: pinned, isHidden: false, fileCount: 1)
    }

    @Test("ピン留めがあればピン留めだけ [PN-02]")
    func pinnedWins() {
        let all = [label(1, "a"), label(2, "b", pinned: true), label(3, "c")]
        let shown = PinnedLabelListing.visible(all, collapsedLimit: 10, isRevealed: false,
                                               searchText: "", mustInclude: { _ in false })
        #expect(shown.map(\.name) == ["b"])
    }

    @Test("ピン留めが無ければ上位 N 件 [PN-03]")
    func topNWhenNothingPinned() {
        let all = (1...5).map { label(Int64($0), "l\($0)") }
        let shown = PinnedLabelListing.visible(all, collapsedLimit: 3, isRevealed: false,
                                               searchText: "", mustInclude: { _ in false })
        #expect(shown.map(\.name) == ["l1", "l2", "l3"])
        #expect(PinnedLabelListing.hasMore(all, collapsedLimit: 3, isRevealed: false,
                                           mustInclude: { _ in false }))
    }

    /// [PN-06][RL-05] ここが崩れると「チェックが入っているのに画面に無い」
    /// ラベルができ、外す手段が消える。
    @Test("必ず含めるものはピン対象外でも出る [PN-06][RL-05]")
    func mustIncludeAlwaysShows() {
        let all = (1...5).map { label(Int64($0), "l\($0)") }
        let shown = PinnedLabelListing.visible(all, collapsedLimit: 2, isRevealed: false,
                                               searchText: "",
                                               mustInclude: { $0.name == "l5" })
        #expect(shown.map(\.name) == ["l1", "l2", "l5"])
    }

    @Test("展開中は全件。検索で絞る [PN-05]")
    func revealedShowsEverything() {
        let all = [label(1, "作品名A"), label(2, "作品名B")]
        #expect(PinnedLabelListing.visible(all, collapsedLimit: 1, isRevealed: true,
                                           searchText: "", mustInclude: { _ in false })
                .count == 2)
        #expect(PinnedLabelListing.visible(all, collapsedLimit: 1, isRevealed: true,
                                           searchText: "B", mustInclude: { _ in false })
                .map(\.name) == ["作品名B"])
        #expect(!PinnedLabelListing.hasMore(all, collapsedLimit: 1, isRevealed: true,
                                            mustInclude: { _ in false }))
    }
}
