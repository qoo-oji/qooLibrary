import Foundation
import GRDB
import QooKit
import Testing

@testable import QooPersistence

/// `v18_mergedPresets` の移行 [2026-09-08]。
///
/// プリセットの (A)/(B) を 4 種へ統合したことに追随して `presetKey` の綴りを
/// 直す。**綴りが古いままだとそのライブラリは「プリセット由来ではない」と
/// 見なされ**、改訂の差分 [LT-10〜17] に二度と乗らなくなる。
@Suite("v18_mergedPresets の移行")
struct MergedPresetMigrationTests {

    /// v17 までを当てたストア（外部キーは切って親行の用意を省く）。
    private func v17Store() throws -> DatabaseQueue {
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
        try migrator.migrate(queue)
        return queue
    }

    private func applyV18(_ queue: DatabaseQueue) throws {
        try queue.write { try QooMigrations.v18MergedPresets($0) }
    }

    private func insertType(_ db: Database, id: Int64, key: String, name: String) throws {
        try db.execute(sql: """
            INSERT INTO libraryType (id, presetKey, name, isPreset, version, definitionJSON)
            VALUES (?, ?, ?, 1, 4, '{}')
            """, arguments: [id, key, name])
    }

    private func insertLibrary(_ db: Database, id: Int64, typeID: Int64,
                               registered: String?) throws
    {
        try db.execute(sql: """
            INSERT INTO library (id, uuid, displayName, bookmarkData, resolvedPath,
                                 volumeUUID, libraryTypeId, settingsJSON,
                                 settingsRevision, isOnline, registeredTemplateJSON)
            VALUES (?, ?, 'L', x'00', '/tmp/L', 'V', ?, '{}', 1, 1, ?)
            """, arguments: [id, UUID().uuidString, typeID, registered])
    }

    @Test("presetKey から (A)/(B) の綴りが落ちる")
    func presetKeyIsRenamed() throws {
        let queue = try v17Store()
        try queue.write { db in
            try insertType(db, id: 1, key: "builtin.doujinshi-a", name: "同人誌(A)")
            try insertType(db, id: 2, key: "builtin.general-comic-b", name: "一般コミック(B)")
        }
        try applyV18(queue)
        let rows = try queue.read { db in
            try Row.fetchAll(db, sql: "SELECT presetKey, name FROM libraryType ORDER BY id")
        }
        #expect(rows.map { $0["presetKey"] as String } ==
                ["builtin.doujinshi", "builtin.general-comic"])
        #expect(rows.map { $0["name"] as String } == ["同人誌", "一般コミック"])
    }

    @Test("(A) と (B) の行が両方あるとき、参照を寄せてから畳む [UNIQUE 制約]")
    func bothVariantsAreFoldedWithoutViolatingUnique() throws {
        let queue = try v17Store()
        try queue.write { db in
            try insertType(db, id: 1, key: "builtin.doujinshi-a", name: "同人誌(A)")
            try insertType(db, id: 2, key: "builtin.doujinshi-b", name: "同人誌(B)")
            try insertLibrary(db, id: 10, typeID: 1, registered: nil)
            try insertLibrary(db, id: 11, typeID: 2, registered: nil)
        }
        try applyV18(queue)
        let (keys, typeIDs) = try queue.read { db in
            (try String.fetchAll(db, sql: "SELECT presetKey FROM libraryType"),
             try Int64.fetchAll(db, sql: "SELECT libraryTypeId FROM library ORDER BY id"))
        }
        #expect(keys == ["builtin.doujinshi"])          // 1 行に畳まれる
        #expect(Set(typeIDs).count == 1)                // 両方が生き残った行を指す
        #expect(typeIDs.count == 2)                     // ライブラリは 1 つも消えない
    }

    @Test("登録時の定義は key・displayName・version だけ直し、中身は残す")
    func registeredTemplateKeepsItsBody() throws {
        let base = """
            {"key":"builtin.doujinshi-b","displayName":"同人誌(B)",
             "libraryTypeName":"同人誌","version":5,
             "labelGroups":[{"index":2,"name":"サークル"}],
             "semanticBindings":{"@circle":2},
             "folderLevels":{"1":{"kind":"singleLabelGroup","labelGroup":2}},
             "filenameFormats":["[@circle] @title"],
             "volumeSet":"VS-None"}
            """
        let queue = try v17Store()
        try queue.write { db in
            try insertType(db, id: 1, key: "builtin.doujinshi-b", name: "同人誌(B)")
            try insertLibrary(db, id: 10, typeID: 1, registered: base)
        }
        try applyV18(queue)
        let json = try queue.read { db in
            try String.fetchOne(db, sql: "SELECT registeredTemplateJSON FROM library")!
        }
        let decoded = try JSONDecoder().decode(LibraryTypeTemplate.self,
                                               from: Data(json.utf8))
        #expect(decoded.key == "builtin.doujinshi")
        #expect(decoded.displayName == "同人誌")
        #expect(decoded.version == 1)
        // **当時の定義はそのまま残す**——統合は改訂ではないので、
        // 差分（`latest.version > base.version`）に乗せない。
        #expect(decoded.folderLevels["1"]?.labelGroup == 2)
        #expect(decoded.filenameFormats == ["[@circle] @title"])
    }

    @Test("ライブラリの設定には触れない [旧 (A) の挙動を勝手に変えない]")
    func librarySettingsAreUntouched() throws {
        let settings = #"{"folderLevelMapping":{},"targetExtensions":["cbz"]}"#
        let queue = try v17Store()
        try queue.write { db in
            try insertType(db, id: 1, key: "builtin.doujinshi-a", name: "同人誌(A)")
            try db.execute(sql: """
                INSERT INTO library (id, uuid, displayName, bookmarkData, resolvedPath,
                                     volumeUUID, libraryTypeId, settingsJSON,
                                     settingsRevision, isOnline)
                VALUES (10, ?, 'L', x'00', '/tmp/L', 'V', 1, ?, 1, 1)
                """, arguments: [UUID().uuidString, settings])
        }
        try applyV18(queue)
        let after = try queue.read { db in
            try String.fetchOne(db, sql: "SELECT settingsJSON FROM library")!
        }
        #expect(after == settings)
    }

    @Test("ユーザー定義の型は巻き添えにしない")
    func userDefinedTypesAreUntouched() throws {
        let queue = try v17Store()
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO libraryType (id, presetKey, name, isPreset, version, definitionJSON)
                VALUES (1, NULL, '自作(A)', 0, 1, '{}')
                """)
        }
        try applyV18(queue)
        let name = try queue.read { db in
            try String.fetchOne(db, sql: "SELECT name FROM libraryType")!
        }
        #expect(name == "自作(A)")   // isPreset = 0 なので (A) を落とさない
    }
}
