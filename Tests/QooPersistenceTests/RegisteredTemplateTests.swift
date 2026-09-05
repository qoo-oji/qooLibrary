import Foundation
import GRDB
import QooKit
import Testing

@testable import QooPersistence

/// 登録時のプリセット定義（差分の base）[LT-10][LT-13][LT-15]。
///
/// **これが無いと差分は嘘をつく**——「プリセットが改訂した項目」と「利用者が
/// 自分で変えた項目」を区別できず、自分で消したフォーマットが毎回
/// 「追加されました」として並び続ける。
@Suite("登録時のプリセット定義 [LT-10]")
struct RegisteredTemplateTests {

    private static func registration(_ name: String = "テスト") -> LibraryRegistration {
        LibraryRegistration(uuid: UUID(), displayName: name, bookmarkData: Data(),
                            resolvedPath: "/tmp/\(name)", volumeUUID: "VOL",
                            libraryTypeID: LibraryTypeID(rawValue: 0))
    }

    private static func repository() throws -> (SQLiteLibraryRepository, QooDatabase) {
        let db = try QooDatabase.inMemory()
        return (SQLiteLibraryRepository(database: db, volumeSets: try BuiltInTemplates.volumeSets()),
                db)
    }

    @Test("プリセットから登録すると、その定義がそのまま base になる")
    func registrationStoresThePresetAsBase() async throws {
        let (repository, _) = try Self.repository()
        let template = try #require(try BuiltInTemplates.libraryTypes()
            .first { $0.key == "builtin.doujinshi-a" })
        let id = try await repository.register(Self.registration(), template: template)

        let stored = try #require(try await repository.registeredTemplate(libraryID: id))
        #expect(stored == template)
        #expect(stored.version == template.version)
    }

    /// **プリセット由来でない登録は base を持たない**——ユーザー定義
    /// テンプレートも白紙も「改訂」という概念を持たないため。
    @Test("白紙から登録すると base は入らない")
    func blankRegistrationHasNoBase() async throws {
        let (repository, _) = try Self.repository()
        let template = try #require(try BuiltInTemplates.libraryTypes().first)
        var draft = TemplateInstantiation.draft(
            from: template, volumeSets: try BuiltInTemplates.volumeSets(), displayName: "白紙")
        draft.displayName = "白紙"
        let id = try await repository.register(Self.registration("白紙"),
                                               draft: draft, template: nil)
        #expect(try await repository.registeredTemplate(libraryID: id) == nil)
    }

    @Test("base を進められる（差分の適用後）")
    func baseCanBeAdvanced() async throws {
        let (repository, _) = try Self.repository()
        let all = try BuiltInTemplates.libraryTypes()
        let template = try #require(all.first { $0.key == "builtin.doujinshi-a" })
        let other = try #require(all.first { $0.key == "builtin.general-comic-a" })
        let id = try await repository.register(Self.registration(), template: template)

        try await repository.setRegisteredTemplate(other, libraryID: id)
        #expect(try await repository.registeredTemplate(libraryID: id) == other)

        try await repository.setRegisteredTemplate(nil, libraryID: id)
        #expect(try await repository.registeredTemplate(libraryID: id) == nil)
    }

    /// 壊れた JSON は `nil` に倒す。**「base が無い」と「base が壊れている」で
    /// 振る舞いが同じ**（どちらも差分を出さない）ので、安全側に倒れる。
    @Test("読めない base は nil として扱う")
    func malformedBaseReadsAsNil() async throws {
        let (repository, db) = try Self.repository()
        let template = try #require(try BuiltInTemplates.libraryTypes().first)
        let id = try await repository.register(Self.registration(), template: template)
        try await db.writer.write { conn in
            try conn.execute(sql: "UPDATE library SET registeredTemplateJSON = ? WHERE id = ?",
                             arguments: ["{壊れている", id.rawValue])
        }
        #expect(try await repository.registeredTemplate(libraryID: id) == nil)
    }
}

/// `v17_registeredTemplate` の移行 [LT-10]。
///
/// **完成した DB を見るだけでは足りない**——移行が実際に走ったのか、そもそも
/// その形のスキーマで作られただけなのかを区別できないため、v16 までを当てた
/// 状態から始める（`BookTypeMigrationTests` と同じ理由）。
@Suite("v17_registeredTemplate の移行")
struct RegisteredTemplateMigrationTests {

    private func v16Store() throws -> DatabaseQueue {
        var config = Configuration()
        config.foreignKeysEnabled = false
        let queue = try DatabaseQueue(configuration: config)
        var migrator = DatabaseMigrator()
        let ids = QooMigrations.identifiers
        migrator.registerMigration(ids[0], migrate: QooMigrations.v1Initial)
        migrator.registerMigration(ids[1], migrate: QooMigrations.v2RegexPatterns)
        migrator.registerMigration(ids[2], migrate: QooMigrations.v3EmbeddedMetadata)
        migrator.registerMigration(ids[3], migrate: QooMigrations.v4FSEventsCheckpoint)
        migrator.registerMigration(ids[4], migrate: QooMigrations.v5IdentityRejection)
        migrator.registerMigration(ids[5], migrate: QooMigrations.v6DuplicateTitleKey)
        migrator.registerMigration(ids[6], migrate: QooMigrations.v7IdentityPending)
        migrator.registerMigration(ids[7], migrate: QooMigrations.v8Stage1Removals)
        migrator.registerMigration(ids[8], migrate: QooMigrations.v9ReservedWordCleanup)
        migrator.registerMigration(ids[9], migrate: QooMigrations.v10MetadataProtection)
        migrator.registerMigration(ids[10], migrate: QooMigrations.v11OrphanedProtectedTokens)
        migrator.registerMigration(ids[11], migrate: QooMigrations.v12Shelf)
        migrator.registerMigration(ids[12], migrate: QooMigrations.v13SeriesSuggestionIgnore)
        migrator.registerMigration(ids[13], migrate: QooMigrations.v14LabelVisibility)
        migrator.registerMigration(ids[14], migrate: QooMigrations.v15BookTypeAsLabel)
        migrator.registerMigration(ids[15], migrate: QooMigrations.v16OperationLog)
        try migrator.migrate(queue)
        return queue
    }

    private func columns(_ queue: DatabaseQueue, of table: String) throws -> Set<String> {
        try queue.read { db in
            Set(try String.fetchAll(db, sql: "SELECT name FROM pragma_table_info(?)",
                                    arguments: [table]))
        }
    }

    @Test("v16 の時点では libraryTypeVersion があり、base の列は無い（前提の確認）")
    func theShapeBeforeTheMigration() throws {
        let queue = try v16Store()
        let before = try columns(queue, of: "library")
        #expect(before.contains("libraryTypeVersion"))
        #expect(!before.contains("registeredTemplateJSON"))
    }

    /// **同じ事実を 2 箇所で持たない。** 版は base の中にあるので、
    /// どこからも読まれていなかった `libraryTypeVersion` は落とす。
    @Test("v17 で base の列が増え、libraryTypeVersion が落ちる")
    func theMigrationSwapsTheColumns() throws {
        let queue = try v16Store()
        try queue.write(QooMigrations.v17RegisteredTemplate)

        let after = try columns(queue, of: "library")
        #expect(after.contains("registeredTemplateJSON"))
        #expect(!after.contains("libraryTypeVersion"))
        // 巻き添えにしていないこと。
        #expect(after.isSuperset(of: ["id", "uuid", "displayName", "bookmarkData",
                                      "resolvedPath", "volumeUUID", "libraryTypeId",
                                      "settingsJSON", "settingsRevision", "isOnline"]))
        let version = try queue.read { db in
            try String.fetchOne(db, sql: "SELECT schemaVersion FROM storeMetadata WHERE id = 1")
        }
        #expect(version == "v17_registeredTemplate")
    }

    /// 既存の行は base を持たない＝**差分の対象外**になる。推測で埋めない。
    @Test("移行しても既存の行の base は NULL のまま")
    func existingRowsGetNoBase() throws {
        let queue = try v16Store()
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO library (id, uuid, displayName, bookmarkData, resolvedPath,
                                     volumeUUID, libraryTypeId, libraryTypeVersion,
                                     settingsJSON, duplicateGrouping, thumbnailsAlwaysHidden,
                                     lastFSEventID, isOnline, isReadOnlyDueToFS, settingsRevision)
                VALUES (1, 'U', '蔵書', X'00', '/tmp/x', 'VOL', 1, 3, '{}', 'off', 0, 0, 1, 0, 0)
                """)
        }
        try queue.write(QooMigrations.v17RegisteredTemplate)
        let json = try queue.read { db in
            try String.fetchOne(db, sql: "SELECT registeredTemplateJSON FROM library WHERE id = 1")
        }
        #expect(json == nil)
    }
}
