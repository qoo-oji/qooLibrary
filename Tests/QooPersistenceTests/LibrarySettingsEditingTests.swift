//
//  設定の編集経路 [LS-01〜LS-03][LT-03]。
//
//  「テンプレートは雛形でしかない」を実際に成立させるための往復を固定する。
//
import Testing
import Foundation
import QooKit
@testable import QooPersistence

@Suite("ライブラリ設定の編集 [LS-01][LT-03]")
struct LibrarySettingsEditingTests {

    @Test("テンプレートで登録した内容が、そのまま編集用の草案として読み戻せる")
    func draftRoundTripsTemplateContents() async throws {
        let f = try await Fixture.make(preset: "builtin.doujinshi-a")
        let draft = try #require(try await f.libraries.settingsDraft(libraryID: f.libraryID))

        #expect(draft.displayName == "テスト")
        #expect(draft.fields.count == 7)   // 既定 6 種 ＋ プリセット固有の 1 つ
        #expect(draft.fields.allSatisfy { $0.persistentID != nil })
        #expect(draft.filenameFormats.count == 20)
        #expect(!draft.volumeFormats.isEmpty)
        // 登録時に既定が入っている [AL-11]。空だと全ファイルが対象になる。
        #expect(draft.targetExtensions.contains("cbz"))
        #expect(draft.validationErrors.isEmpty)
    }

    @Test("保存すると settingsRevision が上がる [VT-02]")
    func savingBumpsSettingsRevision() async throws {
        let f = try await Fixture.make()
        let before = try #require(try await f.libraries.library(id: f.libraryID)).settingsRevision
        var draft = try #require(try await f.libraries.settingsDraft(libraryID: f.libraryID))
        draft.displayName = "変更後"
        try await f.libraries.updateSettings(draft, libraryID: f.libraryID)

        let after = try #require(try await f.libraries.library(id: f.libraryID))
        #expect(after.settingsRevision == before + 1)
        #expect(after.displayName == "変更後")
    }

    @Test("フォーマットの追加・並べ替え・無効化が保存され、無効なものも残る [FF-03][FF-05]")
    func filenameFormatEditsPersist() async throws {
        let f = try await Fixture.make(preset: "builtin.general-comic-a")
        var draft = try #require(try await f.libraries.settingsDraft(libraryID: f.libraryID))

        draft.filenameFormats[0].isEnabled = false
        draft.filenameFormats.insert(FilenameFormatDraft(source: "@title"), at: 0)
        try await f.libraries.updateSettings(draft, libraryID: f.libraryID)

        let reloaded = try #require(try await f.libraries.settingsDraft(libraryID: f.libraryID))
        #expect(reloaded.filenameFormats.count == 3)
        #expect(reloaded.filenameFormats[0].source == "@title")
        // **無効にしたものが消えていない。** パーサ用スナップショットを編集に
        // 使うとここで落ちる（あちらは isEnabled = 1 で絞るため）。
        #expect(reloaded.filenameFormats[1].isEnabled == false)

        // パーサ用スナップショットのほうは、無効な行を除いて返す [VT-01]。
        let snapshot = try #require(try await f.libraries.settingsSnapshot(libraryID: f.libraryID))
        #expect(snapshot.filenameFormats.count == 2)
    }

    @Test("ラベルフィールドの名前を変えても、紐づいたラベルは消えない [LB-05]")
    func renamingAFieldKeepsItsLabels() async throws {
        let f = try await Fixture.make(preset: "builtin.general-comic-a")
        let fields = try await f.labels.fields(libraryID: f.libraryID)
        let author = try #require(fields.first { $0.name == "著者" })
        _ = try await f.labels.ensureLabel(fieldID: author.id, name: "著者名A")
        _ = try await f.labels.ensureLabel(fieldID: author.id, name: "著者名B")

        var draft = try #require(try await f.libraries.settingsDraft(libraryID: f.libraryID))
        let position = try #require(draft.fields.firstIndex { $0.name == "著者" })
        draft.fields[position].name = "作者"
        try await f.libraries.updateSettings(draft, libraryID: f.libraryID)

        let after = try await f.labels.fields(libraryID: f.libraryID)
        let renamed = try #require(after.first { $0.name == "作者" })
        // **ここが要点**——作り直す実装だと 0 件になる。
        #expect(renamed.id == author.id)
        #expect(try await f.labels.labels(fieldID: renamed.id).count == 2)
    }

    @Test("ラベルフィールドを増やせる")
    func addingAField() async throws {
        let f = try await Fixture.make(preset: "builtin.general-comic-a")
        var draft = try #require(try await f.libraries.settingsDraft(libraryID: f.libraryID))
        // **プリセットの件数を直に書かない。** 既定フィールド 5 種の保証 [§19.2]
        // のようにテンプレート側が増減すると、この検査の主張と無関係に落ちる。
        let before = try await f.labels.fields(libraryID: f.libraryID).count
        let index = try #require(draft.nextAvailableFieldIndex)
        draft.fields.append(FieldDraft(
            index: index, name: "レーベル", colorHexLight: "#EEDDEE", colorHexDark: "#443344"))
        try await f.libraries.updateSettings(draft, libraryID: f.libraryID)

        let fields = try await f.labels.fields(libraryID: f.libraryID)
        #expect(fields.count == before + 1)
        #expect(fields.contains { $0.name == "レーベル" })
    }

    @Test("検証を通らない設定は保存しない [LS-01]")
    func invalidDraftsAreRejected() async throws {
        let f = try await Fixture.make(preset: "builtin.general-comic-a")
        var draft = try #require(try await f.libraries.settingsDraft(libraryID: f.libraryID))
        draft.targetExtensions = []          // 空 = 全ファイル対象になる [AL-11][IF-01]

        await #expect(throws: (any Error).self) {
            try await f.libraries.updateSettings(draft, libraryID: f.libraryID)
        }
        // 変更前の状態が保たれている（部分的に書き込まれていない）。
        let reloaded = try #require(try await f.libraries.settingsDraft(libraryID: f.libraryID))
        #expect(reloaded.targetExtensions.contains("cbz"))
    }

    @Test("区切り文字・保護文字列・階層割り当ても往復する [DL-02][PT-01][AL-02]")
    func lexicalAndFolderSettingsRoundTrip() async throws {
        let f = try await Fixture.make(preset: "builtin.general-comic-a")
        var draft = try #require(try await f.libraries.settingsDraft(libraryID: f.libraryID))
        draft.delimiters.pairs.append(PairDelimiter(open: "【", close: "】"))
        draft.protectedTokens.append(ProtectedToken(pattern: #"\(完全版\)"#, position: .suffix))
        draft.folderLevels = [FolderLevelDraft(level: 1, assignment: .singleLabelGroup(index: 1))]
        try await f.libraries.updateSettings(draft, libraryID: f.libraryID)

        let reloaded = try #require(try await f.libraries.settingsDraft(libraryID: f.libraryID))
        #expect(reloaded.delimiters.pairs.contains { $0.open == "【" })
        #expect(reloaded.protectedTokens.contains { $0.pattern == #"\(完全版\)"# })
        #expect(reloaded.folderLevels == [FolderLevelDraft(id: reloaded.folderLevels[0].id,
                                                          level: 1,
                                                          assignment: .singleLabelGroup(index: 1))])
    }
}

@Suite("設定の検証 [LS-01]")
struct LibrarySettingsValidationTests {

    private func base() -> LibrarySettingsDraft {
        LibrarySettingsDraft(
            displayName: "L",
            targetExtensions: ["cbz"],
            fields: [FieldDraft(index: 1, name: "サークル",
                                          colorHexLight: "#EEE", colorHexDark: "#444")],
            semanticBindings: [.circle: 1],
            filenameFormats: [FilenameFormatDraft(source: "[@circle] @title")])
    }

    @Test("素直な設定は通る")
    func validDraftPasses() {
        #expect(base().validate().isEmpty)
    }

    @Test("対象拡張子が空なら拒否する [AL-11][IF-01]")
    func emptyTargetExtensionsIsAnError() {
        var d = base()
        d.targetExtensions = []
        #expect(d.validationErrors.contains { $0.section == .extensions })
    }

    @Test("存在しないラベルフィールドを参照するフォーマットを拒否する")
    func formatReferencingAMissingFieldIsAnError() {
        var d = base()
        d.filenameFormats = [FilenameFormatDraft(source: "[@event] @title")]
        #expect(d.validationErrors.contains { $0.section == .filenameFormats })
    }

    @Test("無効にしてあるフォーマットの不備は警告に留める")
    func disabledFormatProblemsAreWarningsOnly() {
        var d = base()
        d.filenameFormats.append(FilenameFormatDraft(source: "[@event] @title", isEnabled: false))
        #expect(d.validationErrors.isEmpty)
        #expect(d.validate().contains { $0.severity == .warning })
    }

    @Test("フィールド番号の重複を拒否する")
    func duplicateFieldIndexIsAnError() {
        var d = base()
        d.fields.append(FieldDraft(index: 1, name: "別",
                                             colorHexLight: "#E", colorHexDark: "#4"))
        #expect(d.validationErrors.contains { $0.section == .fields })
    }

    @Test("1 フィールドに複数の予約語を紐づけられない [RW-14][LE-02]")
    func aFieldCannotCarryTwoSemanticKeywords() {
        var d = base()
        d.semanticBindings = [.series: 1, .author: 1]
        #expect(d.validationErrors.contains { $0.section == .fields })
    }

    @Test("存在しないフィールドへの予約語紐づけを拒否する")
    func semanticBindingToAMissingGroupIsAnError() {
        var d = base()
        d.semanticBindings = [.series: 7]
        #expect(d.validationErrors.contains { $0.section == .fields })
    }

    @Test("有効なフォーマットが 1 つも無いのは警告（白紙から作れるようにするため）")
    func noEnabledFormatIsOnlyAWarning() {
        var d = base()
        d.filenameFormats = []
        #expect(d.validationErrors.isEmpty)
        #expect(d.validate().contains { $0.severity == .warning && $0.section == .filenameFormats })
    }

    @Test("壊れたフォーマットを拒否する")
    func malformedFormatIsAnError() {
        var d = base()
        d.filenameFormats = [FilenameFormatDraft(source: "[@circle @title")]
        #expect(d.validationErrors.contains { $0.section == .filenameFormats })
    }
}
