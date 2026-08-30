import Testing
import Foundation
import GRDB
import QooKit
@testable import QooPersistence

//
//  テンプレート → 草案 → 登録の往復 [LT-01〜LT-03][LS-01][RG-01]。
//
//  **有効化ダイアログが見せる草案と、実際に登録される内容が一致すること**が
//  この suite の主題。ずれると「選んだものと違う設定で走査が始まる」という、
//  利用者からは原因の見えない壊れ方になる。
//
@Suite("テンプレートから草案・登録 [LT-03][LS-01]")
struct TemplateDraftTests {

    private static func sets() throws -> VolumeSetDefinition {
        try BuiltInTemplates.volumeSets()
    }

    @Test("プリセットから作った草案は検証を通る [LT-01]",
          arguments: try BuiltInTemplates.libraryTypes())
    func presetDraftsValidate(_ template: LibraryTypeTemplate) throws {
        let draft = TemplateInstantiation.draft(
            from: template, volumeSets: try Self.sets(), displayName: "テスト")
        let errors = draft.validationErrors
        #expect(errors.isEmpty,
                "\(template.key): \(errors.map(\.message).joined(separator: " / "))")
        // 空で登録すると走査が `.DS_Store` まで拾う [AL-11][IF-01]。
        #expect(!draft.targetExtensions.isEmpty)
        #expect(draft.labelGroups.count == template.labelGroups.count)
        #expect(draft.filenameFormats.count == template.filenameFormats.count)
        #expect(!draft.volumeFormats.isEmpty || template.volumeSet == "VS-None")
    }

    /// **これが一番大事な検査。** 有効化ダイアログはこの `draft(from:)` の結果を
    /// 見せる。登録した後に読み戻したものが一致しなければ、「見たものと違う
    /// 設定が入った」ことになる。
    @Test("登録して読み戻した設定が、見せた草案と一致する [LT-03]")
    func registeringPreservesWhatTheDraftShowed() async throws {
        let db = try QooDatabase.inMemory()
        let sets = try Self.sets()
        let template = try #require(try BuiltInTemplates.libraryTypes()
            .first { $0.key == "builtin.doujinshi-a" })
        let repository = SQLiteLibraryRepository(database: db, volumeSets: sets)

        let shown = TemplateInstantiation.draft(
            from: template, volumeSets: sets, displayName: "テスト")
        let id = try await repository.register(
            LibraryRegistration(uuid: UUID(), displayName: "テスト", bookmarkData: Data(),
                                resolvedPath: "/tmp/lib", volumeUUID: "VOL",
                                libraryTypeID: LibraryTypeID(rawValue: 0)),
            template: template)

        let stored = try #require(try await repository.settingsDraft(libraryID: id))
        #expect(stored.displayName == shown.displayName)
        #expect(stored.libraryTypeName == shown.libraryTypeName)
        #expect(stored.targetExtensions == shown.targetExtensions)
        #expect(stored.delimiters == shown.delimiters)
        #expect(stored.semanticBindings == shown.semanticBindings)
        #expect(stored.seriesTitleCompositionFormat == shown.seriesTitleCompositionFormat)
        // 行 ID と UUID は保存で付くので、意味のある値だけを比べる。
        #expect(stored.labelGroups.map(\.index) == shown.labelGroups.map(\.index))
        #expect(stored.labelGroups.map(\.name) == shown.labelGroups.map(\.name))
        #expect(stored.labelGroups.map(\.colorHexLight) == shown.labelGroups.map(\.colorHexLight))
        #expect(stored.labelGroups.map(\.assignsAutomatically)
                == shown.labelGroups.map(\.assignsAutomatically))
        #expect(stored.filenameFormats.map(\.source) == shown.filenameFormats.map(\.source))
        #expect(stored.filenameFormats.map(\.isEnabled) == shown.filenameFormats.map(\.isEnabled))
        #expect(stored.volumeFormats.map(\.source) == shown.volumeFormats.map(\.source))
        #expect(stored.volumeFormats.map(\.kind) == shown.volumeFormats.map(\.kind))
        #expect(stored.folderLevels.map(\.level) == shown.folderLevels.map(\.level))
        #expect(stored.folderLevels.map(\.assignment) == shown.folderLevels.map(\.assignment))
    }

    @Test("草案を編集してから登録すると、編集後の内容が入る [LS-01]")
    func editedDraftIsWhatGetsRegistered() async throws {
        let db = try QooDatabase.inMemory()
        let sets = try Self.sets()
        let template = try #require(try BuiltInTemplates.libraryTypes()
            .first { $0.key == "builtin.adult-comic-a" })
        let repository = SQLiteLibraryRepository(database: db, volumeSets: sets)

        var draft = TemplateInstantiation.draft(
            from: template, volumeSets: sets, displayName: "テスト")
        draft.labelGroups[0].name = "自分で決めた名前"
        draft.filenameFormats.append(FilenameFormatDraft(source: "@title"))
        draft.targetExtensions = ["cbz"]

        let id = try await repository.register(
            LibraryRegistration(uuid: UUID(), displayName: "テスト", bookmarkData: Data(),
                                resolvedPath: "/tmp/lib", volumeUUID: "VOL",
                                libraryTypeID: LibraryTypeID(rawValue: 0)),
            draft: draft, template: template)

        let stored = try #require(try await repository.settingsDraft(libraryID: id))
        #expect(stored.labelGroups[0].name == "自分で決めた名前")
        #expect(stored.filenameFormats.contains { $0.source == "@title" })
        #expect(stored.targetExtensions == ["cbz"])
    }

    @Test("白紙から登録できる [LT-02]")
    func blankDraftCanBeRegistered() async throws {
        let db = try QooDatabase.inMemory()
        let sets = try Self.sets()
        let repository = SQLiteLibraryRepository(database: db, volumeSets: sets)

        var draft = TemplateInstantiation.blankDraft(
            volumeSets: sets, displayName: "白紙", defaultFieldNames: ["著者", "サークル", "ジャンル", "イベント", "キーワード"])
        draft.libraryTypeName = "自作"
        #expect(draft.validationErrors.isEmpty)
        // フォーマットは 1 本も無い——どのファイル名にも一致しないのが正しい。
        #expect(draft.filenameFormats.isEmpty)
        #expect(!draft.volumeFormats.isEmpty, "巻数フォーマットは既定セットが入る")

        let id = try await repository.register(
            LibraryRegistration(uuid: UUID(), displayName: "白紙", bookmarkData: Data(),
                                resolvedPath: "/tmp/blank", volumeUUID: "VOL",
                                libraryTypeID: LibraryTypeID(rawValue: 0)),
            draft: draft, template: nil)

        let summary = try #require(try await repository.library(id: id))
        #expect(summary.libraryTypeName == "自作")
        let stored = try #require(try await repository.settingsDraft(libraryID: id))
        // 白紙でも既定フィールド 5 種は入る [§19.2]——フォーマットが 1 本も
        // 無いのとは別で、分類の軸は最初から用意しておく。
        #expect(stored.labelGroups.map(\.name)
                == ["著者", "サークル", "ジャンル", "イベント", "キーワード"])
        for (offset, keyword) in SemanticKeyword.defaultFields.enumerated() {
            #expect(stored.semanticBindings[keyword] == offset + 1)
        }
        #expect(stored.filenameFormats.isEmpty)
        // カスタムは非プリセット型 [LT-05]。
        let isPreset = try await db.writer.read { d in
            try Bool.fetchOne(d, sql: "SELECT isPreset FROM libraryType")
        }
        #expect(isPreset == false)
    }

    /// **プリセットの `libraryType` 行は複数ライブラリで共有される** [LT-05]。
    /// 型名を書き換えたまま同じ行を使うと、他のライブラリの `@booktype` の
    /// 照合値まで変わってしまう。
    @Test("型名を変えて登録すると専用の型ができ、他のライブラリに波及しない [LT-05]")
    func editingTheTypeNameForksTheLibraryType() async throws {
        let db = try QooDatabase.inMemory()
        let sets = try Self.sets()
        let template = try #require(try BuiltInTemplates.libraryTypes()
            .first { $0.key == "builtin.doujinshi-a" })
        let repository = SQLiteLibraryRepository(database: db, volumeSets: sets)

        // 1 件目はテンプレートのまま登録する。
        let first = try await repository.register(
            LibraryRegistration(uuid: UUID(), displayName: "そのまま", bookmarkData: Data(),
                                resolvedPath: "/tmp/a", volumeUUID: "VOL",
                                libraryTypeID: LibraryTypeID(rawValue: 0)),
            template: template)

        // 2 件目は型名を書き換えて登録する。
        var draft = TemplateInstantiation.draft(
            from: template, volumeSets: sets, displayName: "書き換え")
        draft.libraryTypeName = "わたしの同人誌"
        let second = try await repository.register(
            LibraryRegistration(uuid: UUID(), displayName: "書き換え", bookmarkData: Data(),
                                resolvedPath: "/tmp/b", volumeUUID: "VOL",
                                libraryTypeID: LibraryTypeID(rawValue: 0)),
            draft: draft, template: template)

        let a = try #require(try await repository.library(id: first))
        let b = try #require(try await repository.library(id: second))
        #expect(a.libraryTypeName == template.libraryTypeName, "1 件目が巻き添えになっている")
        #expect(b.libraryTypeName == "わたしの同人誌")
        #expect(a.libraryTypeID != b.libraryTypeID, "同じ型の行を共有している")
    }
}
