//
//  ユーザー定義テンプレートの保管 [LT-02][LT-06]。
//
import Foundation
import QooKit
import Testing

@testable import QooInfrastructure

@Suite struct UserTemplateStoreTests {

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("qoo-usertemplate-test-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func sample(_ name: String, typeName: String = "型") -> UserTemplate {
        var settings = UserTemplateSettings()
        settings.libraryTypeName = typeName
        settings.filenameFormats = [.init(source: "[@author] @title", isEnabled: true)]
        return UserTemplate(name: name, settings: settings)
    }

    @Test func startsEmpty() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = UserTemplateStore(storageURL: root.appendingPathComponent("t.json"))

        #expect(await store.templates().isEmpty)
    }

    /// **別のインスタンスから読み直せる。**
    ///
    /// 書き出しと読み込みで日付の書式が食い違っていると、保存したファイルが
    /// 次回の読み込みで毎回「壊れている」と判定されて退避される——実装中に
    /// 実際にそうなりかけたので、往復を直に固定する。
    @Test func persistsAcrossInstances() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("t.json")
        let created = Date(timeIntervalSince1970: 1_700_000_000)
        var template = sample("私の同人誌")
        template.createdAt = created
        template.updatedAt = created

        try await UserTemplateStore(storageURL: url).save(template)
        let reloaded = await UserTemplateStore(storageURL: url).templates()

        #expect(reloaded.count == 1)
        #expect(reloaded.first?.id == template.id)
        #expect(reloaded.first?.name == "私の同人誌")
        #expect(reloaded.first?.settings.libraryTypeName == "型")
        #expect(reloaded.first?.createdAt == created)
        // 退避ファイルが作られていない＝壊れていると誤判定されていない。
        let siblings = try FileManager.default
            .contentsOfDirectory(atPath: root.path)
            .filter { $0.contains("corrupt") }
        #expect(siblings.isEmpty)
    }

    @Test func savingTheSameIdentityOverwritesInsteadOfAppending() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = UserTemplateStore(storageURL: root.appendingPathComponent("t.json"))
        let template = sample("元")

        try await store.save(template)
        try await store.save(template.updated(name: "改", settings: template.settings))

        let all = await store.templates()
        #expect(all.count == 1)
        #expect(all.first?.name == "改")
        #expect(all.first?.version == 2)
    }

    @Test func removesById() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = UserTemplateStore(storageURL: root.appendingPathComponent("t.json"))
        let a = sample("A"), b = sample("B")
        try await store.save(a)
        try await store.save(b)

        try await store.remove(id: a.id)

        #expect(await store.templates().map(\.name) == ["B"])
    }

    /// 保存順で返る（名前順に並べ替えない）。
    @Test func keepsInsertionOrder() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = UserTemplateStore(storageURL: root.appendingPathComponent("t.json"))
        for name in ["ん", "あ", "か"] { try await store.save(sample(name)) }

        #expect(await store.templates().map(\.name) == ["ん", "あ", "か"])
    }

    // MARK: - 入出力 [LT-06]

    @Test func exportsSelectedTemplatesOnly() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = UserTemplateStore(storageURL: root.appendingPathComponent("t.json"))
        let a = sample("A"), b = sample("B")
        try await store.save(a)
        try await store.save(b)

        let all = await store.exportDocument()
        let one = await store.exportDocument(ids: [b.id])

        #expect(all.templates.count == 2)
        #expect(one.templates.map(\.name) == ["B"])
        #expect(one.schemaVersion == UserTemplateDocument.currentSchemaVersion)
    }

    /// **取り込みは常に新しい身元で足す**——既存を書き換えない［★22］。
    @Test func importingNeverOverwritesAnExistingTemplate() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = UserTemplateStore(storageURL: root.appendingPathComponent("t.json"))
        let mine = sample("私の設定", typeName: "手元で編集した型")
        try await store.save(mine)

        // 同じ id・同じ名前で、中身だけ違う文書を取り込む。
        var incoming = mine
        incoming.settings.libraryTypeName = "取り込んだ型"
        let outcome = try await store.importDocument(
            UserTemplateDocument(templates: [incoming]))

        #expect(outcome.added.count == 1)
        #expect(outcome.rejections.isEmpty)
        let all = await store.templates()
        #expect(all.count == 2)
        // 手元のものは無傷。
        #expect(all.first { $0.id == mine.id }?.settings.libraryTypeName == "手元で編集した型")
        #expect(all.first { $0.id != mine.id }?.settings.libraryTypeName == "取り込んだ型")
    }

    /// **何を弾いたかを返す**（黙って一部だけ入れない）。
    @Test func importingReportsWhatItRejected() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = UserTemplateStore(storageURL: root.appendingPathComponent("t.json"))
        let document = UserTemplateDocument(templates: [
            sample("入る"),
            UserTemplate(name: "   ", settings: UserTemplateSettings()),
        ])

        let outcome = try await store.importDocument(document)

        #expect(outcome.added.map(\.name) == ["入る"])
        #expect(outcome.rejections == [.init(name: "   ", reason: .emptyName)])
        #expect(await store.templates().count == 1)
    }

    /// **新しすぎる文書は読まない** [F21]。
    @Test func refusesADocumentFromANewerApp() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = UserTemplateStore(storageURL: root.appendingPathComponent("t.json"))
        let newer = UserTemplateDocument(
            schemaVersion: UserTemplateDocument.currentSchemaVersion + 1,
            templates: [sample("未来")])

        await #expect(throws: UserTemplateStoreError.documentTooNew(
            schemaVersion: UserTemplateDocument.currentSchemaVersion + 1)) {
            try await store.importDocument(newer)
        }
        #expect(await store.templates().isEmpty)
    }

    @Test func importsFromAFileWrittenByExport() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = UserTemplateStore(storageURL: root.appendingPathComponent("a.json"))
        try await source.save(sample("持ち出す"))
        let file = root.appendingPathComponent("export.json")
        try UserTemplateDocument.makeEncoder()
            .encode(await source.exportDocument()).write(to: file)

        let destination = UserTemplateStore(storageURL: root.appendingPathComponent("b.json"))
        let outcome = try await destination.importDocument(at: file)

        #expect(outcome.added.map(\.name) == ["持ち出す"])
        #expect(await destination.templates().count == 1)
    }

    @Test func reportsAnUnreadableFile() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("broken.json")
        try Data("これは JSON ではありません".utf8).write(to: file)
        let store = UserTemplateStore(storageURL: root.appendingPathComponent("t.json"))

        await #expect(throws: UserTemplateStoreError.unreadableDocument) {
            try await store.importDocument(at: file)
        }
    }

    // MARK: - 壊れたファイル

    /// **消さずに隣へ退避する。** 空で上書きすると手で作ったものが復旧不能になる。
    @Test func corruptStorageFileIsRetiredInsteadOfBeingOverwritten() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("t.json")
        try Data("{ 壊れている".utf8).write(to: url)
        let store = UserTemplateStore(storageURL: url)

        #expect(await store.templates().isEmpty)
        try await store.save(sample("新しく作った"))

        let retired = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.contains(".corrupt-") }
        #expect(retired.count == 1)
        let backup = try Data(contentsOf: root.appendingPathComponent(retired[0]))
        #expect(String(decoding: backup, as: UTF8.self) == "{ 壊れている")
    }
}
