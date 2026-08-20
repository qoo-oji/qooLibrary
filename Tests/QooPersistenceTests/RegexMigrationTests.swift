import Testing
import Foundation
import GRDB
import QooKit
@testable import QooPersistence

/// `v2_regexPatterns` の移行 [2026-08 の仕様変更]。
///
/// **v1 だけを当てた状態から始める。** 完成した DB を見るだけでは、変換が
/// 実際に走ったのか、そもそも旧い行が無かっただけなのかを区別できない。
@Suite("v2_regexPatterns の移行")
struct RegexMigrationTests {

    /// 外部キーを切って親行の用意を省く。ここで見たいのは変換だけ。
    private func v1Store() throws -> DatabaseQueue {
        var config = Configuration()
        config.foreignKeysEnabled = false
        let queue = try DatabaseQueue(configuration: config)
        var v1 = DatabaseMigrator()
        v1.registerMigration(QooMigrations.identifiers[0], migrate: QooMigrations.v1Initial)
        try v1.migrate(queue)
        return queue
    }

    @Test("旧記法の巻数フォーマットが正規表現へ移り、序列は区切りになる")
    func migratesVolumeFormats() throws {
        let queue = try v1Store()
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO volumeFormat (libraryId, source, priority, isEnabled, ordinalRank)
                VALUES (1, '第??巻', 0, 1, NULL), (1, '上巻', 1, 1, 1)
                """)
        }
        try QooMigrations.migrator.migrate(queue)

        let rows = try queue.read {
            try Row.fetchAll($0, sql: "SELECT source, kind FROM volumeFormat ORDER BY priority")
        }
        #expect(rows[0]["source"] == #"第([0-9]+(?:\.[0-9]+)?)巻"#)
        #expect(rows[0]["kind"] == VolumePatternKind.volume.rawValue)
        #expect(rows[1]["source"] == "上巻")
        #expect(rows[1]["kind"] == VolumePatternKind.separator.rawValue)
    }

    @Test("保護文字列がリテラルから正規表現へ移る")
    func migratesProtectedTokens() throws {
        let queue = try v1Store()
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO protectedToken (ownerKind, ownerID, text, position, isEnabled)
                VALUES ('library', 1, '(完全 版)', 'anywhere', 1)
                """)
        }
        try QooMigrations.migrator.migrate(queue)

        let pattern = try queue.read {
            try String.fetchOne($0, sql: "SELECT pattern FROM protectedToken")
        }
        // 空白の弾力性を保つため `\s+` になる [PT-04]。
        #expect(pattern == #"\(完全\s+版\)"#)
    }

    @Test("ordinal だった巻数種別は none になる")
    func clearsOrdinalVolumeKind() throws {
        let queue = try v1Store()
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO managedFile
                    (libraryId, volumeUUID, inode, relativePath, filename, normalizedName, searchKey,
                     fileSize, createdAt, modifiedAt, titleOrigin, volumeKind, rating, state,
                     coverImageSource, isArchived, isBookFolder, libraryTypeMismatch)
                VALUES (1, 'v', 1, '', 'a.cbz', 'a.cbz', 'a.cbz', 0, 0, 0, 'auto', 'ordinal', 0, 'active',
                        'auto', 0, 0, 0)
                """)
        }
        try QooMigrations.migrator.migrate(queue)
        #expect(try queue.read { try String.fetchOne($0, sql: "SELECT volumeKind FROM managedFile") }
                == "none")
    }

    @Test("使わなくなった列が消える")
    func dropsDeadColumns() throws {
        let queue = try v1Store()
        try QooMigrations.migrator.migrate(queue)
        func columns(_ table: String) throws -> [String] {
            try queue.read { try $0.columns(in: table).map(\.name) }
        }
        #expect(try !columns("volumeFormat").contains("ordinalRank"))
        #expect(try !columns("protectedToken").contains("text"))
        #expect(try !columns("volumeOutputStyle").contains("ordinalTemplate"))
    }

    @Test("適用済みの版が記録される [MG-03]")
    func recordsSchemaVersion() throws {
        let queue = try v1Store()
        try QooMigrations.migrator.migrate(queue)
        #expect(try queue.read { try String.fetchOne($0, sql: "SELECT schemaVersion FROM storeMetadata WHERE id = 1") }
                == QooMigrations.identifiers.last)
    }

    @Test("2 回目の移行は何もしない [MG-03]")
    func isIdempotent() throws {
        let queue = try v1Store()
        try QooMigrations.migrator.migrate(queue)
        try QooMigrations.migrator.migrate(queue)      // 落ちないこと
        let names = try queue.read { try $0.columns(in: "volumeFormat").map(\.name) }
        #expect(names.contains("kind"))
    }
}
