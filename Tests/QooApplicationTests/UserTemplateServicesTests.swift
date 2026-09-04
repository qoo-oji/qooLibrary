//
//  ユーザー定義テンプレートとアプリ層の結線 [LT-02][LT-06][★8]。
//
import Foundation
import QooInfrastructure
import QooKit
import Testing

@testable import QooApplication

@Suite(.serialized) struct UserTemplateServicesTests {

    private func sample(_ name: String,
                        format: String = "[@circle] @title") -> UserTemplate {
        var settings = UserTemplateSettings()
        settings.filenameFormats = [.init(source: format, isEnabled: true)]
        return UserTemplate(name: name, settings: settings)
    }

    @MainActor
    @Test func savingAndRemovingIsReflectedInThePublishedList() async throws {
        let w = try ServicesWorkspace()
        await w.bootstrap()
        #expect(await w.services.userTemplates.isEmpty)

        let saved = try await w.services.saveUserTemplate(sample("私のテンプレート"))
        #expect(await w.services.userTemplates.map(\.name) == ["私のテンプレート"])

        try await w.services.removeUserTemplate(id: saved.id)
        #expect(await w.services.userTemplates.isEmpty)
    }

    /// **バックアップに含める** [★8]。含めないと「設定を書き出したのに
    /// テンプレートだけ戻らない」——この種の機能でよく報告される失敗様式。
    @MainActor
    @Test func backupCarriesUserTemplates() async throws {
        let w = try ServicesWorkspace()
        await w.bootstrap()
        try await w.enable()
        try await w.services.saveUserTemplate(sample("持ち出す"))

        let document = try await w.services.exportBackup()

        #expect(document.userTemplates?.map(\.name) == ["持ち出す"])
    }

    /// テンプレートが 1 件も無ければ鍵ごと出さない（`Optional` にした意味）。
    @MainActor
    @Test func backupOmitsTheKeyWhenThereAreNoTemplates() async throws {
        let w = try ServicesWorkspace()
        await w.bootstrap()
        try await w.enable()

        let document = try await w.services.exportBackup()

        #expect(document.userTemplates == nil)
    }

    /// 取り込みは**併合**（上書きも削除もしない）。
    @MainActor
    @Test func importingABackupAddsMissingTemplatesWithoutTouchingLocalOnes() async throws {
        let w = try ServicesWorkspace()
        await w.bootstrap()
        let mine = sample("手元のもの", format: "[@circle] 手元で編集した@title")
        try await w.services.saveUserTemplate(mine)

        // 別の環境で書き出された文書（手元に無いものが 1 件）。
        var document = try await w.services.exportBackup()
        document.userTemplates = [sample("よそのもの"),
                                  // 同じ身元だが中身は違う——**上書きされてはならない**
                                  UserTemplate(id: mine.id, name: "書き換えられた",
                                               settings: UserTemplateSettings())]
        try await w.services.importBackup(document)

        let all = await w.services.userTemplates
        #expect(all.count == 2)
        #expect(all.first { $0.id == mine.id }?.name == "手元のもの")
        #expect(all.first { $0.id == mine.id }?.settings.filenameFormats.first?.source
                == "[@circle] 手元で編集した@title")
        #expect(all.contains { $0.name == "よそのもの" })
    }

    /// 同じバックアップを 2 度取り込んでも増えない（冪等）。
    @MainActor
    @Test func importingTheSameBackupTwiceDoesNotDuplicate() async throws {
        let w = try ServicesWorkspace()
        await w.bootstrap()
        try await w.enable()
        try await w.services.saveUserTemplate(sample("1 件だけ"))
        let document = try await w.services.exportBackup()

        try await w.services.importBackup(document)
        try await w.services.importBackup(document)

        #expect(await w.services.userTemplates.count == 1)
    }

    /// **ライブラリが 1 つも一致しなくても、テンプレートは取り込める**
    /// ［code-review で発見］。
    ///
    /// 復旧の手順は「有効化 → 再スキャン → 取り込み」[MG-24] なので、
    /// **ライブラリを作る前に取り込む場面が普通にある**——数に入れないと
    /// 「取り込むものがありません」で止まり、テンプレートだけを戻す経路が
    /// 丸ごと消える。
    @MainActor
    @Test func aBackupWithOnlyTemplatesIsStillImportable() async throws {
        let w = try ServicesWorkspace()
        await w.bootstrap()
        // ライブラリを 1 つも有効化していない状態の文書。
        let document = BackupDocument(
            exportedAt: Date(), appVersion: nil, libraries: [],
            userTemplates: [sample("テンプレートだけ")])

        let plan = try await w.services.planImport(document)

        #expect(plan.libraries.isEmpty)
        #expect(plan.templatesAdded == 1)
        #expect(!plan.isEmpty, "テンプレートだけでも「取り込むものがある」")

        let applied = try await w.services.importBackup(document)
        #expect(applied.templatesAdded == 1)
        #expect(await w.services.userTemplates.map(\.name) == ["テンプレートだけ"])
    }

    /// 既にあるテンプレートは数に入れない（見積もりと実際が食い違わない）。
    @MainActor
    @Test func planDoesNotCountTemplatesThatAreAlreadyThere() async throws {
        let w = try ServicesWorkspace()
        await w.bootstrap()
        let mine = sample("もうある")
        try await w.services.saveUserTemplate(mine)
        let document = BackupDocument(exportedAt: Date(), appVersion: nil,
                                      libraries: [], userTemplates: [mine])

        #expect(try await w.services.planImport(document).templatesAdded == 0)
        #expect(try await w.services.planImport(document).isEmpty)
    }

    /// **テンプレートを書けなかったら取り込みは失敗する**［code-review で発見］。
    ///
    /// `try?` で握りつぶすと「テンプレート追加 0 件」と成功を報告してしまい、
    /// 書けなかった事実が画面のどこにも出ない。
    @MainActor
    @Test func importFailsLoudlyWhenTemplatesCannotBeWritten() async throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("qoo-services-\(UUID().uuidString)")
        let store = URL(fileURLWithPath: "/dev/null/blocked/userTemplates.json")
        let services = LibraryServices(
            userCoverStore: DefaultUserCoverStore(
                baseDirectory: base.appendingPathComponent("usercovers")),
            userTemplateStore: UserTemplateStore(storageURL: store))
        await services.bootstrap(
            storeURL: base.appendingPathComponent("store/qooLibrary.sqlite"))
        defer { try? FileManager.default.removeItem(at: base) }
        let document = BackupDocument(exportedAt: Date(), appVersion: nil,
                                      libraries: [], userTemplates: [sample("書けない")])

        await #expect(throws: (any Error).self) {
            try await services.importBackup(document)
        }
    }

    /// **保存した設定がそのまま登録に使える。**
    ///
    /// テンプレート → 草案 → 登録 → DB から読み戻し、で 1 項目も落ちないこと。
    /// ここが崩れると「テンプレートで設定した値が、登録すると違う」という
    /// 最も気づきにくい壊れ方になる。
    @MainActor
    @Test func aTemplateRoundTripsThroughRegistration() async throws {
        let w = try ServicesWorkspace()
        await w.bootstrap()
        var settings = UserTemplateSettings()
        settings.targetExtensions = ["cbz", "pdf"]
        settings.protectedTokens = [.init(pattern: #"\(完結\)"#, position: .suffix,
                                          isEnabled: true)]
        settings.seriesTitleCompositionFormat = "@series 第@volume巻"
        settings.filenameFormats = [.init(source: "[@circle] @title", isEnabled: true)]
        settings.volumeFormats = [.init(source: #"第(\d+)巻"#, isEnabled: true, kind: .volume)]
        settings.fields = [.init(index: 2, name: "サークル", colorHexLight: "#112233",
                                 colorHexDark: "#445566", assignsAutomatically: true)]
        settings.semanticBindings = ["@circle": 2]

        let draft = settings.draft(displayName: "テストライブラリ")
        let id = try await w.services.enable(
            registrationUUID: w.registrationUUID, displayName: "テストライブラリ",
            url: w.libraryRoot, bookmarkData: Data(), draft: draft, template: nil)

        let stored = try #require(try await w.services.settingsDraft(libraryID: id))
        #expect(stored.targetExtensions.sorted() == ["cbz", "pdf"])
        #expect(stored.protectedTokens.map(\.pattern) == [#"\(完結\)"#])
        #expect(stored.protectedTokens.map(\.position) == [.suffix])
        #expect(stored.seriesTitleCompositionFormat == "@series 第@volume巻")
        #expect(stored.filenameFormats.map(\.source) == ["[@circle] @title"])
        #expect(stored.volumeFormats.map(\.source) == [#"第(\d+)巻"#])
        #expect(stored.fields.map(\.name) == ["サークル"])
        #expect(stored.fields.map(\.colorHexLight) == ["#112233"])
        #expect(stored.semanticBindings == [.circle: 2])
    }
}
