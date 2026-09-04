import Foundation
import GRDB
import QooKit
import Testing

@testable import QooPersistence

/// `v15_bookTypeAsLabel` の移行 [TY-01][§19.10]。
///
/// 本の種別を「ライブラリ固有の設定」から「ラベル」へ移した際に落とした 2 列を
/// 見張る。**完成した DB を見るだけでは足りない**——移行が実際に走ったのか、
/// そもそも列を持たないスキーマで作られただけなのかを区別できないため
/// （`Stage1RemovalMigrationTests` と同じ理由）、v14 までを当てた状態から始める。
@Suite("v15_bookTypeAsLabel の移行")
struct BookTypeMigrationTests {

    /// v14 までを当てたストア（外部キーは切って親行の用意を省く）。
    ///
    /// - Note: **v11 は多相参照の孤児を掃除する**ので、`protectedToken` を扱う
    ///   場合は親のライブラリ行が要る [PT-08]。ここでは入れないので影響しない。
    private func v14Store() throws -> DatabaseQueue {
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
        try migrator.migrate(queue)
        return queue
    }

    private func columns(_ queue: DatabaseQueue, of table: String) throws -> Set<String> {
        try queue.read { db in
            Set(try String.fetchAll(db, sql: "SELECT name FROM pragma_table_info(?)",
                                    arguments: [table]))
        }
    }

    @Test("v14 の時点では両方の列がある（前提の確認）")
    func theColumnsExistBeforeTheMigration() throws {
        let queue = try v14Store()
        #expect(try columns(queue, of: "libraryType").contains("libraryTypeName"))
        #expect(try columns(queue, of: "managedFile").contains("libraryTypeMismatch"))
    }

    /// **本の種別はライブラリ固有の値ではなくなった** [TY-01]。あわせて
    /// 「このファイルの印がこのライブラリの型名と違う」警告も計算できなくなる。
    @Test("v15 で libraryTypeName と libraryTypeMismatch が落ちる")
    func theMigrationDropsBothColumns() throws {
        let queue = try v14Store()
        try queue.write(QooMigrations.v15BookTypeAsLabel)

        #expect(!(try columns(queue, of: "libraryType").contains("libraryTypeName")))
        #expect(!(try columns(queue, of: "managedFile").contains("libraryTypeMismatch")))
        // 落としたのはその 2 列だけ——他まで巻き添えにしていない。
        #expect(try columns(queue, of: "libraryType")
                == ["id", "presetKey", "name", "isPreset", "version", "definitionJSON"])
        let version = try queue.read { db in
            try String.fetchOne(db, sql: "SELECT schemaVersion FROM storeMetadata WHERE id = 1")
        }
        #expect(version == "v15_bookTypeAsLabel")
    }

    /// **列を落とす前に、型名を語彙へ移す** [TY-01]。
    ///
    /// これが無いと、型名を編集していたライブラリは `(@booktype)` が二度と
    /// 一致せず、次の走査で全件が未整理になって自動ラベルが消える。
    @Test("編集済みの型名が「本の種別」ラベルとして残る")
    func theEditedTypeNameSurvivesAsALabel() throws {
        let queue = try v14Store()
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO libraryType (id, presetKey, name, libraryTypeName,
                                         isPreset, version, definitionJSON)
                VALUES (1, NULL, 'わたしの型', 'わたしの同人誌', 0, 1, '{}')
                """)
            try db.execute(sql: """
                INSERT INTO library (id, uuid, displayName, bookmarkData, resolvedPath,
                                     volumeUUID, libraryTypeId, settingsJSON)
                VALUES (1, 'U', 'L', X'00', '/tmp/l', 'VOL', 1,
                        '{"semanticBindings":{"@author":1}}')
                """)
            try db.execute(sql: """
                INSERT INTO labelGroup (libraryId, groupIndex, name, colorHexLight,
                                        colorHexDark, displayOrder, assignsAutomatically)
                VALUES (1, 1, '著者', '#111111', '#222222', 1, 1)
                """)
        }
        try queue.write(QooMigrations.v15BookTypeAsLabel)

        let (fieldName, index, bindings, labels) = try queue.read { db -> (String?, Int?, String?, [String]) in
            let row = try Row.fetchOne(db, sql: """
                SELECT name, groupIndex FROM labelGroup WHERE libraryId = 1 AND groupIndex > 1
                """)
            let json = try String.fetchOne(db, sql: "SELECT settingsJSON FROM library WHERE id = 1")
            let names = try String.fetchAll(db, sql: """
                SELECT label.name FROM label
                  JOIN labelGroup ON label.labelGroupId = labelGroup.id
                 WHERE labelGroup.libraryId = 1 AND labelGroup.groupIndex > 1
                """)
            return (row?["name"], row?["groupIndex"], json, names)
        }
        // 既定 1 の隣、2 番へ「本の種別」フィールドができる。
        #expect(index == 2)
        #expect(fieldName == "booktype", "移行は表示言語を知らないので予約語の綴りを使う")
        #expect(bindings?.contains("\"@booktype\":2") == true)
        // **編集していた型名がラベルとして残る**——これが語彙になる。
        #expect(labels == ["わたしの同人誌"])
    }

    @Test("既存の行は保たれる（列を落とすだけで作り直さない）")
    func existingRowsSurvive() throws {
        let queue = try v14Store()
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO libraryType (id, presetKey, name, libraryTypeName,
                                         isPreset, version, definitionJSON)
                VALUES (7, 'builtin.test', '雛形', '同人誌', 1, 3, '{"a":1}')
                """)
        }
        try queue.write(QooMigrations.v15BookTypeAsLabel)

        let row = try queue.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM libraryType WHERE id = 7")
        }
        let r = try #require(row)
        #expect(r["presetKey"] == "builtin.test")
        #expect(r["name"] == "雛形")
        #expect(r["version"] == 3)
        #expect(r["definitionJSON"] == #"{"a":1}"#)
    }
}
