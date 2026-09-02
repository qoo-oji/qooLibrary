import Foundation
import QooInfrastructure
import QooKit
import Testing
@testable import QooApplication

//
//  シリーズの提案の適用と無視 [SS-05][SS-06][SS-07]（ステージ 10）。
//
//  **DB を実際に開いて確かめる**——守っているのは「適用が保護まで書くこと」
//  「走査に上書きされないこと」「⌘Z が値も保護も戻すこと」という書き込みの
//  性質で、リポジトリを偽物にすると肝心の部分が試せない
//  （`ProtectionCommandTests` と同じ理由）。
//
@Suite("シリーズの提案の適用と無視 [SS-05][SS-06][SS-07]", .serialized)
struct SeriesSuggestionCommandTests {

    /// 同人誌(A)。**1 冊目に番号が無く 2 冊目に付く**という、この機能が
    /// 救おうとしている形そのものを標本にする。
    private static let files = [
        "(同人誌) [サークル値A (著者値1)] 催眠アプリ試作 (ジャンル値1).cbz",
        "(同人誌) [サークル値A (著者値1)] 催眠アプリ試作2 (ジャンル値1).cbz",
        "(同人誌) [サークル値B (著者値2)] まったく別の話 (ジャンル値1).cbz",
    ]

    @MainActor
    private func workspace(files: [String] = SeriesSuggestionCommandTests.files)
        async throws -> (ServicesWorkspace, LibrarySummary)
    {
        let w = try ServicesWorkspace()
        await w.bootstrap()
        for name in files { try w.write(name) }
        let id = try await w.enable("builtin.doujinshi-a")
        _ = try await w.services.scan(libraryID: id, root: w.libraryRoot)
        let library = try #require(w.services.library(registrationUUID: w.registrationUUID))
        return (w, library)
    }

    @MainActor
    private func model(_ w: ServicesWorkspace, _ library: LibrarySummary,
                       stack: CommandStack) async -> SeriesSuggestionModel {
        let m = SeriesSuggestionModel(commands: stack)
        m.selectedLibraryID = library.id
        await m.prepare(services: w.services, preferring: library.id)
        return m
    }

    // MARK: - 検出 [SS-01][SS-04]

    @Test("走査したままの蔵書から提案が出る [SS-01]")
    @MainActor
    func detectsFromARealLibrary() async throws {
        let (w, library) = try await workspace()
        let report = try await w.services.seriesSuggestions(libraryID: library.id)
        #expect(report.suggestions.count == 1)
        let group = try #require(report.suggestions.first)
        #expect(group.seriesName == "催眠アプリ試作")
        // **番号の無い 1 冊目に 1 を推測しない** [SS-07]。
        #expect(group.members.map(\.volume.number) == [nil, 2])
    }

    // MARK: - 適用 [SS-06][SS-07]

    @Test("適用がシリーズ名と巻数を書き、基本情報を保護する [SS-06][SS-07]")
    @MainActor
    func applyWritesSeriesAndProtects() async throws {
        let (w, library) = try await workspace()
        let stack = CommandStack()
        let m = await model(w, library, stack: stack)
        try await m.apply(m.visibleGroups)

        let rows = try await w.services.seriesSuggestions(libraryID: library.id)
        #expect(rows.suggestions.isEmpty, "適用済みは候補から外れる [SS-08]")

        let ids = try await idsOfSeries(w, library, named: "催眠アプリ試作")
        #expect(ids.count == 2)
        let scopes = try await w.services.protectedScopes(ids: ids)
        #expect(ids.allSatisfy { scopes[$0]?.contains(.basic) == true },
                "値と保護は同じ操作で書く [PR-03][SS-06]")
        let volumes = try await volumes(w, ids: ids)
        #expect(volumes.sorted { ($0 ?? 0) < ($1 ?? 0) } == [nil, 2])
    }

    @Test("適用した結果は走査に上書きされない [SS-06]")
    @MainActor
    func appliedSeriesSurvivesAScan() async throws {
        let (w, library) = try await workspace()
        let m = await model(w, library, stack: CommandStack())
        try await m.apply(m.visibleGroups)

        _ = try await w.services.scan(libraryID: library.id, root: w.libraryRoot)
        #expect(try await idsOfSeries(w, library, named: "催眠アプリ試作").count == 2)
    }

    @Test("⌘Z がシリーズ名も巻数も保護も戻す [UD-04]")
    @MainActor
    func undoRestoresEverything() async throws {
        let (w, library) = try await workspace()
        let stack = CommandStack()
        let m = await model(w, library, stack: stack)
        try await m.apply(m.visibleGroups)
        _ = try await stack.undo()

        #expect(try await idsOfSeries(w, library, named: "催眠アプリ試作").isEmpty)
        let report = try await w.services.seriesSuggestions(libraryID: library.id)
        #expect(report.suggestions.count == 1, "候補へ戻る")
        let ids = report.suggestions[0].members.map(\.id)
        let scopes = try await w.services.protectedScopes(ids: ids)
        #expect(ids.allSatisfy { (scopes[$0] ?? []).isEmpty }, "保護も戻る")
    }

    // MARK: - 無視 [SS-05]

    @Test("無視すると一覧から消え、⌘Z で戻る [SS-05][UD-04]")
    @MainActor
    func ignoreHidesTheGroupAndUndoBringsItBack() async throws {
        let (w, library) = try await workspace()
        let stack = CommandStack()
        let m = await model(w, library, stack: stack)
        try await m.setIgnored(m.visibleGroups, true)
        #expect(m.visibleGroups.isEmpty)
        #expect(m.hiddenIgnoredCount == 1)

        // 左ペインの件数も無視を除く（数えるのは片付けるべき組だけ）。
        #expect(m.suggestionCounts[library.id] == 0)

        _ = try await stack.undo()
        await m.reload()
        #expect(m.visibleGroups.count == 1)
        #expect(m.suggestionCounts[library.id] == 1)
    }

    /// **元から無視だったものは裏返らない** [SS-05]。一括で立てた選択には
    /// 既に印の付いたものが混ざりうるので、`undo()` が一律に解くと「触って
    /// いないもの」まで解ける——しかも画面上は「戻った」ように見える
    /// （`SetUnresolvedIgnoredCommand` と同じ理由）。
    @Test("無視の取り消しは 1 件ずつ元の値へ戻す [SS-05][UD-04]")
    @MainActor
    func undoOfIgnoreRestoresPerFile() async throws {
        let (w, library) = try await workspace()
        let report = try await w.services.seriesSuggestions(libraryID: library.id)
        let members = try #require(report.suggestions.first).members
        let already = members[0].id

        // 1 冊だけ先に印を立てておく（別の経路で無視されていた状態）。
        try await w.services.updateSeriesSuggestionIgnored(
            set: [already: members[0].title], clear: [])

        let stack = CommandStack()
        let m = await model(w, library, stack: stack)
        try await m.setIgnored(m.visibleGroups, true)
        _ = try await stack.undo()

        let marks = try await w.services.seriesSuggestionIgnoredTitles(
            ids: members.map(\.id))
        #expect(marks[already] != nil, "元から無視だったものは解けない")
        #expect(marks.count == 1)
    }

    @Test("無視したまま「無視したものも表示」で見え、解除できる")
    @MainActor
    func ignoredGroupsCanBeRevealedAndCleared() async throws {
        let (w, library) = try await workspace()
        let m = await model(w, library, stack: CommandStack())
        try await m.setIgnored(m.visibleGroups, true)
        m.showsIgnored = true
        #expect(m.visibleGroups.count == 1)
        #expect(m.visibleGroups[0].isIgnored)

        try await m.setIgnored(m.visibleGroups, false)
        m.showsIgnored = false
        #expect(m.visibleGroups.count == 1)
        #expect(!m.visibleGroups[0].isIgnored)
    }

    @Test("無視した組は適用できない [SS-05]")
    @MainActor
    func ignoredGroupsAreNotApplied() async throws {
        let (w, library) = try await workspace()
        let m = await model(w, library, stack: CommandStack())
        try await m.setIgnored(m.visibleGroups, true)
        m.showsIgnored = true
        try await m.apply(m.visibleGroups)

        #expect(try await idsOfSeries(w, library, named: "催眠アプリ試作").isEmpty)
    }

    /// **複数のグループをまとめて適用したら 1 つの Undo 単位** [UD-04]。
    ///
    /// グループごとに積むと `operationHistory.count` が動くたびに検出が
    /// 走り直す（5 万件で 1 回 400 ms）——しかも適用のループがまだ回っている
    /// 最中に重なる［code-review の指摘］。
    @Test("一括の適用は 1 つの Undo 単位にまとまる [UD-04]")
    @MainActor
    func bulkApplyIsOneUndoStep() async throws {
        let (w, library) = try await workspace(files: SeriesSuggestionCommandTests.files + [
            "(同人誌) [サークル値C (著者値3)] 別作品タイトル (ジャンル値1).cbz",
            "(同人誌) [サークル値C (著者値3)] 別作品タイトル2 (ジャンル値1).cbz",
        ])
        let stack = CommandStack()
        let m = await model(w, library, stack: stack)
        #expect(m.visibleGroups.count == 2)

        let before = stack.operationHistory.count
        try await m.apply(m.visibleGroups)
        #expect(stack.operationHistory.count == before + 1, "積むのは 1 回だけ")

        // 1 回の ⌘Z で 2 グループとも戻る。
        _ = try await stack.undo()
        #expect(try await idsOfSeries(w, library, named: "催眠アプリ試作").isEmpty)
        #expect(try await idsOfSeries(w, library, named: "別作品タイトル").isEmpty)
    }

    // MARK: - 補助

    @MainActor
    private func idsOfSeries(_ w: ServicesWorkspace, _ library: LibrarySummary,
                             named name: String) async throws -> [FileID] {
        var query = FileQuery(libraryID: library.id, scope: .library)
        query.mode = .libraryFlat
        query.limit = 100
        let page = try await w.services.files(query)
        return page.rows.filter { $0.seriesName == name }.map(\.id)
    }

    @MainActor
    private func volumes(_ w: ServicesWorkspace, ids: [FileID]) async throws -> [Double?] {
        var out: [Double?] = []
        for id in ids {
            out.append(try await w.services.fileRow(id: id)?.volume.number)
        }
        return out
    }
}
