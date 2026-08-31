import Foundation
import GRDB
import QooKit
import Testing

@testable import QooPersistence

/// `v11_orphanedProtectedTokens` の移行 [PT-08]。
///
/// **v10 までを当てた状態から始める。** 完成した DB を見るだけでは、移行が
/// 実際に走ったのか、そもそも孤児が最初から無かったのかを区別できない
/// （`MetadataProtectionMigrationTests` と同じ理由）。
///
/// 掃除そのものより**削除の範囲**が要点——広すぎると、残っているライブラリの
/// 保護文字列まで失われる。パースが静かに変わるだけなので気づけない。
@Suite("v11_orphanedProtectedTokens の移行 [PT-08]")
struct OrphanedProtectedTokenMigrationTests {

    /// v10 までを当てたストア（外部キーは切って親行の用意を省く）。
    private func v10Store() throws -> DatabaseQueue {
        var config = Configuration()
        config.foreignKeysEnabled = false
        let queue = try DatabaseQueue(configuration: config)
        var migrator = DatabaseMigrator()
        for (i, id) in QooMigrations.identifiers.enumerated()
        where id != "v11_orphanedProtectedTokens" {
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
            default: break
            }
        }
        try migrator.migrate(queue)
        return queue
    }

    /// 生きているライブラリ 1 件と、既に消えたライブラリ 2 件ぶんの保護文字列。
    /// 実ストアで観測したのと同じ形（`library` に居ない `ownerID` が残る）。
    private func seed(_ queue: DatabaseQueue) throws {
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO library
                    (id, uuid, displayName, bookmarkData, resolvedPath, volumeUUID,
                     libraryTypeId, libraryTypeVersion, settingsJSON, duplicateGrouping,
                     thumbnailsAlwaysHidden, isOnline, isReadOnlyDueToFS, settingsRevision)
                VALUES (7, 'U', 'L', X'', '/tmp', 'V', 1, 1, '{}', 'off', 0, 1, 0, 1)
                """)
            for (kind, owner, pattern) in [
                ("library", 7, "生きている"),        // 残るべき
                ("library", 11, "孤児 A"),           // 消えるべき
                ("library", 12, "孤児 B"),           // 消えるべき
                ("temporary", 3, "テンポラリの孤児"), // 消えるべき（親テーブルが空）
            ] as [(String, Int, String)] {
                try db.execute(sql: """
                    INSERT INTO protectedToken (ownerKind, ownerID, pattern, position, isEnabled)
                    VALUES (?, ?, ?, 'anywhere', 1)
                    """, arguments: [kind, owner, pattern])
            }
        }
    }

    private func patterns(_ queue: DatabaseQueue) throws -> [String] {
        try queue.read { db in
            try String.fetchAll(db, sql: "SELECT pattern FROM protectedToken ORDER BY pattern")
        }
    }

    @Test("消えたライブラリの保護文字列だけを消す [PT-08]")
    func removesOnlyOrphans() throws {
        let queue = try v10Store()
        try seed(queue)
        #expect(try patterns(queue).count == 4)

        try queue.write(QooMigrations.v11OrphanedProtectedTokens)

        // 生きているライブラリのぶんだけが残る。範囲が広すぎれば 0 件になり、
        // 狭すぎれば孤児が残るので、どちらへ外れてもこの 1 つで捕まる。
        #expect(try patterns(queue) == ["生きている"])
    }

    /// 親テーブルが空でも、そこを参照していない種別まで巻き込まない。
    /// 将来 `ownerKind` を増やしたとき、この移行が黙って消してはならない
    /// ——移行は 1 回きりなので、消えたことに後から気づけない。
    @Test("知らない ownerKind には触れない [PT-08]")
    func leavesUnknownOwnerKindsAlone() throws {
        let queue = try v10Store()
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO protectedToken (ownerKind, ownerID, pattern, position, isEnabled)
                VALUES ('future', 1, '将来の種別', 'anywhere', 1)
                """)
        }

        try queue.write(QooMigrations.v11OrphanedProtectedTokens)

        #expect(try patterns(queue) == ["将来の種別"])
    }

    @Test("移行後に schemaVersion が進む [SC-03]")
    func advancesSchemaVersion() throws {
        let queue = try v10Store()
        try queue.write(QooMigrations.v11OrphanedProtectedTokens)
        let version = try queue.read { db in
            try String.fetchOne(db, sql: "SELECT schemaVersion FROM storeMetadata WHERE id = 1")
        }
        #expect(version == "v11_orphanedProtectedTokens")
    }
}
