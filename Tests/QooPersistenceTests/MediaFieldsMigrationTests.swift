import Foundation
import GRDB
import QooKit
import Testing

@testable import QooPersistence

/// `v19_mediaFields` の移行 [MF-01〜MF-23]。
///
/// **v18 までを当てた状態から始める。** 完成した DB を見るだけでは、移行が実際に
/// 走ったのか新しいスキーマで作られただけなのかを区別できない
/// （`BookTypeMigrationTests` と同じ理由）。
///
/// この移行が無いと何が起きるか: 予約語の綴りを変えただけでは保存済みの
/// フォーマットが「不明な予約語」になり、`SQLiteLibraryRepository` が `try?` で
/// 落とすので**フォーマットが 1 本も無いライブラリ**になる——次の走査が
/// タイトルもラベルも全部 nil で上書きする、最も静かな壊れ方をする（v9 と同じ）。
@Suite("v19_mediaFields の移行")
struct MediaFieldsMigrationTests {

    /// v18 までを当てたストア（外部キーは切って親行の用意を省く）。
    private func v18Store() throws -> DatabaseQueue {
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
        migrator.registerMigration(ids[16], migrate: QooMigrations.v17RegisteredTemplate)
        migrator.registerMigration(ids[17], migrate: QooMigrations.v18MergedPresets)
        try migrator.migrate(queue)
        return queue
    }

    private func columns(_ queue: DatabaseQueue, of table: String) throws -> Set<String> {
        try queue.read { db in
            Set(try String.fetchAll(db, sql: "SELECT name FROM pragma_table_info(?)",
                                    arguments: [table]))
        }
    }

    @Test("v18 の時点では 4 列も role も無い（前提の確認）")
    func theColumnsDoNotExistBeforeTheMigration() throws {
        let queue = try v18Store()
        let file = try columns(queue, of: "managedFile")
        for column in ["subtitle", "seasonNumber", "episodeNumber", "releaseDate"] {
            #expect(!file.contains(column))
        }
        #expect(!(try columns(queue, of: "volumeFormat").contains("role")))
    }

    @Test("メディア向けの 4 列と volumeFormat.role が増える")
    func theMigrationAddsTheColumns() throws {
        let queue = try v18Store()
        try queue.write(QooMigrations.v19MediaFields)

        let file = try columns(queue, of: "managedFile")
        for column in ["subtitle", "seasonNumber", "episodeNumber", "releaseDate"] {
            #expect(file.contains(column))
        }
        #expect(try columns(queue, of: "volumeFormat").contains("role"))

        let version = try queue.read { db in
            try String.fetchOne(db, sql: "SELECT schemaVersion FROM storeMetadata WHERE id = 1")
        }
        #expect(version == "v19_mediaFields")
    }

    /// **既存の行は巻数として読む。** `role` を持たない行が「役割不明」になると、
    /// 移行しただけで巻数が 1 件も取れなくなる。
    @Test("既存の巻数フォーマットは role = volume になる")
    func existingPatternsBecomeVolumePatterns() throws {
        let queue = try v18Store()
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO volumeFormat (libraryId, source, priority, isEnabled, kind)
                VALUES (1, '第([0-9]+)巻', 0, 1, 'volume')
                """)
        }
        try queue.write(QooMigrations.v19MediaFields)

        let role = try queue.read { db in
            try String.fetchOne(db, sql: "SELECT role FROM volumeFormat")
        }
        #expect(role == "volume")
    }

    /// 予約語 2 語の改名 [MF-23]。**5 箇所すべてを書き換える**——1 箇所でも
    /// 取り残すと、そこだけ古い綴りのまま「不明な予約語」になる。
    @Test("@circle → @studio、@booktype → @mediatype を 5 箇所で書き換える")
    func theMigrationRenamesReservedWords() throws {
        let queue = try v18Store()
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO filenameFormat (libraryId, source, priority, isEnabled)
                VALUES (1, '(@booktype) [@circle (@author)] @title', 0, 1)
                """)
            try db.execute(sql: """
                INSERT INTO folderLevelMapping (libraryId, level, assignmentKind, formatSource)
                VALUES (1, 1, 'format', '(@booktype) @circle')
                """)
            try db.execute(sql: """
                INSERT INTO library (uuid, displayName, bookmarkData, resolvedPath,
                                     volumeUUID, libraryTypeId, settingsJSON,
                                     registeredTemplateJSON)
                VALUES ('U', '見本', x'00', '/x', 'V', 1,
                        '{"semanticBindings":{"@circle":2,"@booktype":7}}',
                        '{"filenameFormats":["(@booktype) [@circle] @title"]}')
                """)
            try db.execute(sql: """
                INSERT INTO libraryType (presetKey, name, isPreset, version, definitionJSON)
                VALUES ('builtin.sample', '見本', 1, 1,
                        '{"filenameFormats":["(@booktype) [@circle] @title"]}')
                """)
        }
        try queue.write(QooMigrations.v19MediaFields)

        let (format, folder, settings, registered, definition) = try queue.read { db in
            (try String.fetchOne(db, sql: "SELECT source FROM filenameFormat"),
             try String.fetchOne(db, sql: "SELECT formatSource FROM folderLevelMapping"),
             try String.fetchOne(db, sql: "SELECT settingsJSON FROM library"),
             try String.fetchOne(db, sql: "SELECT registeredTemplateJSON FROM library"),
             try String.fetchOne(db, sql: "SELECT definitionJSON FROM libraryType"))
        }
        #expect(format == "(@mediatype) [@studio (@author)] @title")
        #expect(folder == "(@mediatype) @studio")
        // **`settingsJSON` も書き換える**（v9 と違う点）——この 2 語は
        // `SemanticKeyword` で、束縛の**鍵**として保存されている [MF-23]。
        #expect(settings == #"{"semanticBindings":{"@studio":2,"@mediatype":7}}"#)
        #expect(registered == #"{"filenameFormats":["(@mediatype) [@studio] @title"]}"#)
        #expect(definition == #"{"filenameFormats":["(@mediatype) [@studio] @title"]}"#)
    }
}
