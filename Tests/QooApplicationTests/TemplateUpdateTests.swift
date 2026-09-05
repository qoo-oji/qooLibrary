import Foundation
import Testing
@testable import QooApplication
@testable import QooKit

//
//  プリセット改訂の検出・差分・適用 [LT-10〜LT-17]。
//
//  **DB を実際に開いて確かめる**（シェルフ・ラベル編集のコマンドと同じ理由）
//  ——ここが守っているのは「適用して取り消すと元とちょうど同じ状態になる」
//  という書き込みの性質で、リポジトリを偽物にすると肝心の部分が試せない。
//
@Suite("プリセット改訂の差分適用 [LT-10〜LT-17]", .serialized)
struct TemplateUpdateTests {

    /// 登録済みのライブラリを 1 つ作る。base には**そのときのプリセット**が入る。
    @MainActor
    private func workspace() async throws -> (ServicesWorkspace, LibraryID) {
        let w = try ServicesWorkspace()
        await w.bootstrap()
        try w.write("(同人誌) [サークル値A (著者値1)] 作品タイトル1 (ジャンル値1).cbz")
        let id = try await w.enable("builtin.doujinshi-a")
        return (w, id)
    }

    /// 「古い版のプリセット」を作る。**実物から作る**——手書きの雛形だと、
    /// プリセットが将来変わったときにこの suite だけ現実とずれる。
    private func olderTemplate(_ template: LibraryTypeTemplate,
                               droppingFormats count: Int = 1,
                               droppingFields: Set<Int> = []) -> LibraryTypeTemplate
    {
        LibraryTypeTemplate(
            key: template.key, displayName: template.displayName,
            libraryTypeName: template.libraryTypeName,
            version: template.version - 1,
            labelGroups: template.labelGroups.filter { !droppingFields.contains($0.index) },
            semanticBindings: template.semanticBindings.filter {
                !droppingFields.contains($0.value)
            },
            folderLevels: template.folderLevels,
            filenameFormats: Array(template.filenameFormats.dropFirst(count)),
            volumeSet: template.volumeSet)
    }

    // MARK: - 検出 [LT-10][LT-12]

    @Test("登録直後は改訂が無い（base ＝ 最新）")
    @MainActor
    func aFreshRegistrationHasNoPendingUpdate() async throws {
        let (w, _) = try await workspace()
        #expect(await TemplateUpdateModel.pending(services: w.services).isEmpty)
    }

    @Test("base が古ければ検出する")
    @MainActor
    func detectsAnOlderBase() async throws {
        let (w, id) = try await workspace()
        let latest = try w.template()
        try await w.services.setRegisteredTemplate(olderTemplate(latest), libraryID: id)

        let pending = await TemplateUpdateModel.pending(services: w.services)
        #expect(pending.count == 1)
        #expect(pending.first?.presetKey == "builtin.doujinshi-a")
        #expect(pending.first?.fromVersion == latest.version - 1)
        #expect(pending.first?.toVersion == latest.version)
    }

    /// **版が下がっているときは黙る**——アプリを古い版へ戻した状況で
    /// 「更新されました」と言うのは嘘になる。
    @Test("base のほうが新しければ検出しない")
    @MainActor
    func ignoresADowngrade() async throws {
        let (w, id) = try await workspace()
        let latest = try w.template()
        let newer = LibraryTypeTemplate(
            key: latest.key, displayName: latest.displayName,
            libraryTypeName: latest.libraryTypeName, version: latest.version + 1,
            labelGroups: latest.labelGroups, semanticBindings: latest.semanticBindings,
            folderLevels: latest.folderLevels, filenameFormats: latest.filenameFormats,
            volumeSet: latest.volumeSet)
        try await w.services.setRegisteredTemplate(newer, libraryID: id)
        #expect(await TemplateUpdateModel.pending(services: w.services).isEmpty)
    }

    /// **base を持たない登録は対象外**（ユーザー定義・白紙・v17 以前）。
    @Test("base が無ければ検出も差分も出ない")
    @MainActor
    func withoutABaseThereIsNothingToShow() async throws {
        let (w, id) = try await workspace()
        try await w.services.setRegisteredTemplate(nil, libraryID: id)
        #expect(await TemplateUpdateModel.pending(services: w.services).isEmpty)

        let model = TemplateUpdateModel()
        await model.load(libraryID: id, services: w.services)
        #expect(model.state == .unavailable(.noBase))
    }

    @Test("最新なら「更新はありません」と分かる形で返る")
    @MainActor
    func upToDateIsDistinctFromEmpty() async throws {
        let (w, id) = try await workspace()
        let model = TemplateUpdateModel()
        await model.load(libraryID: id, services: w.services)
        #expect(model.state == .unavailable(.upToDate))
    }

    // MARK: - 差分と適用 [LT-13][LT-14][LT-16]

    @Test("落ちていたフォーマットが差分に出て、適用すると入る")
    @MainActor
    func appliesTheAddedFormat() async throws {
        let (w, id) = try await workspace()
        let latest = try w.template()
        let dropped = latest.filenameFormats[0]
        try await w.services.setRegisteredTemplate(olderTemplate(latest), libraryID: id)
        // base を古くしただけでは設定は動かない [LT-11]。
        var draft = try #require(try await w.services.settingsDraft(libraryID: id))
        draft.filenameFormats.removeAll { $0.source == dropped }
        try await w.services.updateSettings(draft, libraryID: id)

        let model = TemplateUpdateModel()
        await model.load(libraryID: id, services: w.services)
        #expect(model.state == .ready)
        let item = try #require(model.diff?.items.first { $0.subject == dropped })
        #expect(item.change == .added)
        #expect(item.isSelected)

        let stack = CommandStack()
        let changed = try await model.apply(libraryID: id, services: w.services, stack: stack)
        #expect(changed)

        let after = try #require(try await w.services.settingsDraft(libraryID: id))
        #expect(after.filenameFormats.contains { $0.source == dropped })
        // **base が進む**ので、同じ改訂をもう一度見せない [LT-16]。
        #expect(await TemplateUpdateModel.pending(services: w.services).isEmpty)
    }

    /// **1 つの Undo 単位** [LT-16]。設定も base も一緒に戻る——片方だけ
    /// 戻すと、次に開いたときに理由の読めない差分が出る。
    @Test("⌘Z で設定も base も適用前へ戻る")
    @MainActor
    func undoRestoresBothSettingsAndBase() async throws {
        let (w, id) = try await workspace()
        let latest = try w.template()
        let older = olderTemplate(latest)
        let dropped = latest.filenameFormats[0]
        try await w.services.setRegisteredTemplate(older, libraryID: id)
        var draft = try #require(try await w.services.settingsDraft(libraryID: id))
        draft.filenameFormats.removeAll { $0.source == dropped }
        try await w.services.updateSettings(draft, libraryID: id)
        let before = try #require(try await w.services.settingsDraft(libraryID: id))

        let model = TemplateUpdateModel()
        await model.load(libraryID: id, services: w.services)
        let stack = CommandStack()
        try await model.apply(libraryID: id, services: w.services, stack: stack)

        _ = await stack.undo()
        let restored = try #require(try await w.services.settingsDraft(libraryID: id))
        #expect(restored.filenameFormats.map(\.source) == before.filenameFormats.map(\.source))
        #expect(try await w.services.registeredTemplate(libraryID: id) == older)
        // 戻したので、また検出される。
        #expect(await TemplateUpdateModel.pending(services: w.services).count == 1)
    }

    /// **見送る手段が要る** [LT-16]。無いと、適用したくない改訂の通知が
    /// 永久に消えない。
    @Test("1 件も選ばずに適用すると、設定は変わらず base だけ進む")
    @MainActor
    func applyingNothingJustAcknowledgesTheRevision() async throws {
        let (w, id) = try await workspace()
        let latest = try w.template()
        let dropped = latest.filenameFormats[0]
        try await w.services.setRegisteredTemplate(olderTemplate(latest), libraryID: id)
        var draft = try #require(try await w.services.settingsDraft(libraryID: id))
        draft.filenameFormats.removeAll { $0.source == dropped }
        try await w.services.updateSettings(draft, libraryID: id)
        let before = try #require(try await w.services.settingsDraft(libraryID: id))

        let model = TemplateUpdateModel()
        await model.load(libraryID: id, services: w.services)
        for item in model.diff?.items ?? [] { model.setSelected(item.id, false) }
        #expect(model.selectedCount == 0)

        let stack = CommandStack()
        let changed = try await model.apply(libraryID: id, services: w.services, stack: stack)
        #expect(!changed)

        let after = try #require(try await w.services.settingsDraft(libraryID: id))
        #expect(after.filenameFormats.map(\.source) == before.filenameFormats.map(\.source))
        #expect(await TemplateUpdateModel.pending(services: w.services).isEmpty)
    }

    /// ローカル編集を上書きする項目は**既定で選ばれない** [LT-14][LT-15]。
    @Test("ローカル編集済みの項目は既定で外れ、警告の材料になる")
    @MainActor
    func locallyEditedItemsAreUnselectedAndFlagged() async throws {
        let (w, id) = try await workspace()
        let latest = try w.template()
        // 「著者」フィールドの名前が改訂で変わった、という base を作る。
        let renamedBase = LibraryTypeTemplate(
            key: latest.key, displayName: latest.displayName,
            libraryTypeName: latest.libraryTypeName, version: latest.version - 1,
            labelGroups: latest.labelGroups.map {
                $0.index == 1
                    ? LibraryTypeTemplate.FieldSpec(index: 1, name: "旧著者", autoAssign: nil)
                    : $0
            },
            semanticBindings: latest.semanticBindings, folderLevels: latest.folderLevels,
            filenameFormats: latest.filenameFormats, volumeSet: latest.volumeSet)
        try await w.services.setRegisteredTemplate(renamedBase, libraryID: id)
        // 利用者が自分でも名前を変えている。
        var draft = try #require(try await w.services.settingsDraft(libraryID: id))
        if let position = draft.fields.firstIndex(where: { $0.index == 1 }) {
            draft.fields[position].name = "わたしの著者"
        }
        try await w.services.updateSettings(draft, libraryID: id)

        let model = TemplateUpdateModel()
        await model.load(libraryID: id, services: w.services)
        let item = try #require(model.diff?.items.first { $0.category == .field })
        #expect(item.isLocallyEdited)
        #expect(!item.isSelected)
        #expect(!model.overwritesLocalEdits)

        model.setSelected(item.id, true)
        #expect(model.overwritesLocalEdits)
    }
}
