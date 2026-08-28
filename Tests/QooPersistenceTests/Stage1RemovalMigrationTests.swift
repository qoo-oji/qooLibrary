import Foundation
import GRDB
import QooKit
import Testing

@testable import QooPersistence

/// `v8_stage1Removals` の移行 [§19.8][§19.10 Stage 1]。
///
/// **v7 までを当てた状態から始める。** 完成した DB を見るだけでは、移行が
/// 実際に走ったのか、そもそも新しいスキーマで作られただけなのかを区別できない
/// （`EmbeddedMetadataMigrationTests` と同じ理由）。
@Suite("v8_stage1Removals の移行")
struct Stage1RemovalMigrationTests {

    /// v7 までを当てたストア（外部キーは切って親行の用意を省く）。
    private func v7Store() throws -> DatabaseQueue {
        var config = Configuration()
        config.foreignKeysEnabled = false
        let queue = try DatabaseQueue(configuration: config)
        var migrator = DatabaseMigrator()
        for (i, id) in QooMigrations.identifiers.enumerated() where id != "v8_stage1Removals" {
            switch i {
            case 0: migrator.registerMigration(id, migrate: QooMigrations.v1Initial)
            case 1: migrator.registerMigration(id, migrate: QooMigrations.v2RegexPatterns)
            case 2: migrator.registerMigration(id, migrate: QooMigrations.v3EmbeddedMetadata)
            case 3: migrator.registerMigration(id, migrate: QooMigrations.v4FSEventsCheckpoint)
            case 4: migrator.registerMigration(id, migrate: QooMigrations.v5IdentityRejection)
            case 5: migrator.registerMigration(id, migrate: QooMigrations.v6DuplicateTitleKey)
            case 6: migrator.registerMigration(id, migrate: QooMigrations.v7IdentityPending)
            default: break
            }
        }
        try migrator.migrate(queue)
        return queue
    }

    private struct Shape: Equatable {
        var pending: Bool
        var rejection: Bool
        var caseSensitive: Bool
        var pinned: Bool
    }

    private func shape(of queue: DatabaseQueue) throws -> Shape {
        try queue.read { db in
            Shape(pending: try db.tableExists("identityPending"),
                  rejection: try db.tableExists("identityRejection"),
                  caseSensitive: try db.columns(in: "library")
                      .contains { $0.name == "caseSensitive" },
                  pinned: try db.columns(in: "managedFile")
                      .contains { $0.name == "isDuplicateRepresentativePinned" })
        }
    }

    @Test("identity の 2 テーブルが落ち、撤回した 2 列が消える")
    func dropsIdentityTablesAndWithdrawnColumns() throws {
        let queue = try v7Store()
        // 移行前は確かに存在する（＝この検査が v8 を見ていることの裏付け）。
        let before = try shape(of: queue)
        #expect(before == Shape(pending: true, rejection: true,
                                caseSensitive: true, pinned: true))

        try QooMigrations.migrator.migrate(queue)

        let after = try shape(of: queue)
        #expect(after == Shape(pending: false, rejection: false,
                               caseSensitive: false, pinned: false))
    }

    /// **列を落としても他の列の値は動かない。** 手で直した題・評価・保管庫の
    /// 記録は移行で失ってはならない値 [MG-22]。
    @Test("既存の行の値を保ったまま列だけが消える")
    func preservesRowValuesWhileDroppingColumns() throws {
        let queue = try v7Store()
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO managedFile
                    (id, libraryId, inode, volumeUUID, relativePath, filename,
                     normalizedName, searchKey, fileSize, createdAt, modifiedAt,
                     titleOrigin, rating, coverImageSource, isArchived, isBookFolder,
                     isDuplicateRepresentativePinned, state, libraryTypeMismatch, volumeKind)
                VALUES (1, 1, 100, 'VOL', '作品名A.cbz', '作品名A.cbz',
                        'さくひんめいa', 'さくひんめいa', 4096, 0, 0,
                        'manual', 3, 'auto', 1, 0, 1, 'active', 0, 'none')
                """)
            try db.execute(sql: "UPDATE managedFile SET title = ? WHERE id = 1",
                           arguments: ["手で直した題"])
            // 撤回済みの確認待ち・却下の記録が残っていても、移行は黙って捨てる。
            try db.execute(sql: """
                INSERT INTO identityPending (orphanFileId, candidateFileId, detectedAt)
                VALUES (1, 1, 0)
                """)
        }

        try QooMigrations.migrator.migrate(queue)

        let row = try #require(try queue.read {
            try Row.fetchOne($0, sql: "SELECT * FROM managedFile WHERE id = 1")
        })
        #expect(row["title"] == "手で直した題")
        #expect(row["titleOrigin"] == "manual")
        #expect(row["rating"] == 3)
        #expect(row["isArchived"] == true)
    }
}
