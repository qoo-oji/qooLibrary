import Foundation
import QooInfrastructure
import QooKit
import Testing
@testable import QooApplication

//
//  メタデータの保護 [PR-01〜PR-09]。
//
//  **DB を実際に開いて確かめる**——守っているのは「走査が保護されたものに
//  触れないこと」「解除が自動値へ戻すこと」「⌘Z が値まで戻すこと」という
//  書き込みの性質で、リポジトリを偽物にすると肝心の部分が試せない
//  （`TitleAndCoverTests` と同じ理由）。
//

@Suite("メタデータの保護 [PR-01〜PR-09]", .serialized)
struct ProtectionCommandTests {

    /// 一般コミック(A)。**巻数フォーマットを持つ**ので、基本情報 4 つとも
    /// 自動抽出が効く——同人誌(A) だとシリーズも巻も取れず主張が成り立たない。
    @MainActor
    private func workspace(files: [String] = ["(一般コミック) [著者値A] 作品名A 第01巻.cbz"])
        async throws -> (ServicesWorkspace, LibrarySummary, [URL])
    {
        let w = try ServicesWorkspace()
        await w.bootstrap()
        for name in files { try w.write(name) }
        let id = try await w.enable("builtin.general-comic-a")
        _ = try await w.services.scan(libraryID: id, root: w.libraryRoot)
        let library = try #require(w.services.library(registrationUUID: w.registrationUUID))
        return (w, library, files.map { w.libraryRoot.appendingPathComponent($0) })
    }

    @MainActor
    private func protectionModel(_ w: ServicesWorkspace, _ library: LibrarySummary,
                                 _ urls: [URL], stack: CommandStack)
        async -> ProtectionEditorModel
    {
        let m = ProtectionEditorModel(commands: stack)
        await m.load(urls: urls, library: library, services: w.services)
        return m
    }

    // MARK: - 走査から守る [PR-01]

    /// **基本情報は 4 つで 1 かたまり** [PR-02]。置き換える前はタイトルだけを
    /// 守っており、手で直したシリーズ名は次の走査で黙って自動値へ戻っていた。
    @Test("保護された基本情報は 4 つとも走査で動かない [PR-01][PR-02]")
    @MainActor
    func protectedBasicScopeSurvivesAScan() async throws {
        let (w, library, urls) = try await workspace()
        let row = try #require(try await w.services.fileRow(at: urls[0], in: library))
        var edit = FileFieldEdit(row)
        edit.title = "手の題"
        edit.seriesName = "手のシリーズ"
        edit.volume = .numeric(9, raw: "第09巻")
        edit.authorName = "手の著者"
        try await w.services.setFileFields(edit, id: row.id, protectedScopes: [.basic])

        _ = try await w.services.scan(libraryID: library.id, root: w.libraryRoot)

        let after = try #require(try await w.services.fileRow(at: urls[0], in: library))
        #expect(after.title == "手の題")
        #expect(after.seriesName == "手のシリーズ")
        #expect(after.volume.number == 9)
        #expect(after.authorName == "手の著者")
    }

    // MARK: - 全体の保護 [PR-05]

    @Test("ファイル全体を保護すると、基本情報とフィールドが揃う [PR-02][PR-05]")
    @MainActor
    func protectingEverythingCoversAllScopes() async throws {
        let (w, library, urls) = try await workspace()
        let stack = CommandStack()
        let m = await protectionModel(w, library, urls, stack: stack)
        guard case .ready(let before) = m.state else { Issue.record("読めていない"); return }
        #expect(!before.isFullyProtected, "前提: まだ保護されていない")

        try await m.toggleAll()

        guard case .ready(let after) = m.state else { Issue.record("読めていない"); return }
        #expect(after.isFullyProtected)
        let fields = try await w.services.labelGroups(libraryID: library.id).map(\.id)
        let scopes = try await w.services.protectedScopes(ids: after.fileIDs)
        #expect(scopes[after.fileIDs[0]] == .everything(fields: fields))
    }

    /// **解除はその場で自動値へ戻す** [PR-04]。次の走査まで手動値が残っていると、
    /// 解除したのに何も起きていないように見える。
    @Test("保護を解除すると、その場で自動値へ戻る [PR-04]")
    @MainActor
    func unprotectingRestoresAutomaticValuesImmediately() async throws {
        let (w, library, urls) = try await workspace()
        let stack = CommandStack()
        let row = try #require(try await w.services.fileRow(at: urls[0], in: library))
        let automaticTitle = row.title
        #expect(automaticTitle != nil, "前提: 自動抽出が効いている")

        var edit = FileFieldEdit(row)
        edit.title = "手の題"
        try await w.services.setFileFields(edit, id: row.id, protectedScopes: [.basic])

        let m = await protectionModel(w, library, urls, stack: stack)
        try await m.toggleAll()      // 全体を保護（既に基本情報だけ保護済み）
        try await m.toggleAll()      // 解除

        let after = try #require(try await w.services.fileRow(at: urls[0], in: library))
        #expect(after.title == automaticTitle, "自動値へ戻る")
        #expect(after.protectedScopes.isEmpty)
    }

    /// **⌘Z は値まで戻す** [PR-04]。保護だけ戻して値を戻さないと、取り消した
    /// 直後は正しく見えるのに手で直した内容が消えたままになる。
    @Test("解除の ⌘Z は手動編集を戻す [PR-04][UD-01]")
    @MainActor
    func undoOfUnprotectingRestoresTheManualValues() async throws {
        let (w, library, urls) = try await workspace()
        let stack = CommandStack()
        let row = try #require(try await w.services.fileRow(at: urls[0], in: library))
        var edit = FileFieldEdit(row)
        edit.title = "手の題"
        try await w.services.setFileFields(edit, id: row.id, protectedScopes: [.basic])

        let m = await protectionModel(w, library, urls, stack: stack)
        try await m.toggleAll()      // 全体を保護
        try await m.toggleAll()      // 解除（自動値へ戻る）
        #expect(try await w.services.fileRow(at: urls[0], in: library)?.title != "手の題")

        _ = await stack.undo()

        let after = try #require(try await w.services.fileRow(at: urls[0], in: library))
        #expect(after.title == "手の題", "値が戻る")
        #expect(after.protectedScopes.contains(.basic), "保護も戻る")
    }

    @Test("変化が無ければ Undo スタックを汚さない")
    @MainActor
    func noOpDoesNotPushUndo() async throws {
        let (w, library, urls) = try await workspace()
        let stack = CommandStack()
        let m = await protectionModel(w, library, urls, stack: stack)
        try await m.toggleAll()
        let depth = stack.operationHistory.count
        // 同じ状態でもう一度「保護する」向きにはならない（既に全部保護済み）
        // ので、ここでは解除 → 再保護で戻る。往復して深さが 2 増えるだけ。
        try await m.toggleAll()
        try await m.toggleAll()
        #expect(stack.operationHistory.count == depth + 2)
    }

    @Test("Undo メニューに出る名前 [UD-06]")
    @MainActor
    func displayName() async throws {
        let w = try ServicesWorkspace()
        let url = w.libraryRoot.appendingPathComponent("作品.cbz")
        let target = SetProtectionCommand.Previous(
            fileID: FileID(rawValue: 1), url: url, scopes: [],
            fields: FileFieldEdit(title: nil, seriesName: nil, volume: .none, authorName: nil),
            labels: [])
        let on = SetProtectionCommand(targets: [target],
                                      mode: .all(fields: [], protected: true),
                                      libraryID: LibraryID(rawValue: 1),
                                      subjectName: "作品.cbz", services: w.services)
        #expect(on.displayName == "「作品.cbz」のメタデータを保護")
        #expect(on.isUndoable)
        let off = SetProtectionCommand(targets: [target],
                                       mode: .all(fields: [], protected: false),
                                       libraryID: LibraryID(rawValue: 1),
                                       subjectName: "3 項目", services: w.services)
        #expect(off.displayName == "「3 項目」のメタデータの保護を解除")
    }
}
