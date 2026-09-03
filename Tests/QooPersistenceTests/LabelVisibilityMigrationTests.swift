import Foundation
import GRDB
import QooKit
import Testing

@testable import QooPersistence

/// `v14_labelVisibility` の移行 [LA3-02][DB-02 撤回][§19.10 Stage 11]。
///
/// **v13 までを当てた状態から始める。** 完成した DB を見るだけでは、移行が
/// 実際に走ったのか、そもそも新しいスキーマで作られただけなのかを区別できない
/// （`Stage1RemovalMigrationTests` と同じ理由）。
@Suite("v14_labelVisibility の移行")
struct LabelVisibilityMigrationTests {

    /// v13 までを当てたストア（外部キーは切って親行の用意を省く）。
    private func v13Store() throws -> DatabaseQueue {
        var config = Configuration()
        config.foreignKeysEnabled = false
        let queue = try DatabaseQueue(configuration: config)
        var migrator = DatabaseMigrator()
        for (i, id) in QooMigrations.identifiers.enumerated() where id != "v14_labelVisibility" {
            switch i {
            case 0: migrator.registerMigration(id, migrate: QooMigrations.v1Initial)
            case 1: migrator.registerMigration(id, migrate: QooMigrations.v2RegexPatterns)
            case 2: migrator.registerMigration(id, migrate: QooMigrations.v3EmbeddedMetadata)
            case 3: migrator.registerMigration(id, migrate: QooMigrations.v4FSEventsCheckpoint)
            case 4: migrator.registerMigration(id, migrate: QooMigrations.v5IdentityRejection)
            case 5: migrator.registerMigration(id, migrate: QooMigrations.v6DuplicateTitleKey)
            case 6: migrator.registerMigration(id, migrate: QooMigrations.v7IdentityPending)
            case 7: migrator.registerMigration(id, migrate: QooMigrations.v8Stage1Removals)
            case 8: migrator.registerMigration(id, migrate: QooMigrations.v9ReservedWordCleanup)
            case 9: migrator.registerMigration(id, migrate: QooMigrations.v10MetadataProtection)
            case 10: migrator.registerMigration(id, migrate: QooMigrations.v11OrphanedProtectedTokens)
            case 11: migrator.registerMigration(id, migrate: QooMigrations.v12Shelf)
            case 12: migrator.registerMigration(id, migrate: QooMigrations.v13SeriesSuggestionIgnore)
            default: break
            }
        }
        try migrator.migrate(queue)
        return queue
    }

    private func migrateToV14(_ queue: DatabaseQueue) throws {
        var migrator = DatabaseMigrator()
        for (i, id) in QooMigrations.identifiers.enumerated() {
            switch i {
            case 0: migrator.registerMigration(id, migrate: QooMigrations.v1Initial)
            case 1: migrator.registerMigration(id, migrate: QooMigrations.v2RegexPatterns)
            case 2: migrator.registerMigration(id, migrate: QooMigrations.v3EmbeddedMetadata)
            case 3: migrator.registerMigration(id, migrate: QooMigrations.v4FSEventsCheckpoint)
            case 4: migrator.registerMigration(id, migrate: QooMigrations.v5IdentityRejection)
            case 5: migrator.registerMigration(id, migrate: QooMigrations.v6DuplicateTitleKey)
            case 6: migrator.registerMigration(id, migrate: QooMigrations.v7IdentityPending)
            case 7: migrator.registerMigration(id, migrate: QooMigrations.v8Stage1Removals)
            case 8: migrator.registerMigration(id, migrate: QooMigrations.v9ReservedWordCleanup)
            case 9: migrator.registerMigration(id, migrate: QooMigrations.v10MetadataProtection)
            case 10: migrator.registerMigration(id, migrate: QooMigrations.v11OrphanedProtectedTokens)
            case 11: migrator.registerMigration(id, migrate: QooMigrations.v12Shelf)
            case 12: migrator.registerMigration(id, migrate: QooMigrations.v13SeriesSuggestionIgnore)
            case 13: migrator.registerMigration(id, migrate: QooMigrations.v14LabelVisibility)
            default: break
            }
        }
        try migrator.migrate(queue)
    }

    /// **手動の非表示は「保管庫」から意味を引き継ぐ** [LA3-02]。どちらも
    /// 「フィルタから外す」という同じ効果を持っていたので、値をそのまま運ぶ。
    @Test("isArchived が isHidden へ改名され、値がそのまま残る [LA3-02]")
    func renamesTheColumnKeepingItsValue() throws {
        let queue = try v13Store()
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO label (id, labelGroupId, name, normalizedName,
                                   colorHex, isPinned, isArchived, fileCount)
                VALUES (1, 1, '保管庫のもの', 'あ', NULL, 0, 1, 7),
                       (2, 1, '通常のもの',   'い', NULL, 1, 0, 3)
                """)
        }
        // 移行前は確かに旧しい形（＝この検査が v14 を見ていることの裏付け）。
        let before = try queue.read { db in try db.columns(in: "label").map(\.name) }
        #expect(before.contains("isArchived"))
        #expect(before.contains("fileCount"))
        #expect(!before.contains("isHidden"))

        try migrateToV14(queue)

        let columns = try queue.read { db in try db.columns(in: "label").map(\.name) }
        #expect(columns.contains("isHidden"))
        #expect(!columns.contains("isArchived"), "ファイル側の保管庫と綴りを分ける")
        #expect(!columns.contains("fileCount"), "[DB-02 撤回] 件数は表示のたびに数える")

        let rows = try queue.read { db in
            try Row.fetchAll(db, sql: "SELECT id, name, isPinned, isHidden FROM label ORDER BY id")
        }
        #expect(rows.count == 2, "行そのものは消さない")
        #expect(rows[0]["isHidden"] as Bool == true, "保管庫にあったものは非表示のまま")
        #expect(rows[1]["isHidden"] as Bool == false)
        #expect(rows[1]["isPinned"] as Bool == true, "他の列は触らない")
    }

    /// **ファイル側の `isArchived` は存続する** [FA-05]。同じ綴りの列を持つ
    /// 別のテーブルを巻き添えにしていないことを固定する。
    @Test("managedFile.isArchived は残る [FA-05]")
    func keepsTheFileVaultColumn() throws {
        let queue = try v13Store()
        try migrateToV14(queue)
        let columns = try queue.read { db in try db.columns(in: "managedFile").map(\.name) }
        #expect(columns.contains("isArchived"))
    }

    @Test("スキーマ版が記録される [SC-03]")
    func recordsTheSchemaVersion() throws {
        let queue = try v13Store()
        try migrateToV14(queue)
        let version = try queue.read { db in
            try String.fetchOne(db, sql: "SELECT schemaVersion FROM storeMetadata WHERE id = 1")
        }
        #expect(version == "v14_labelVisibility")
    }
}
