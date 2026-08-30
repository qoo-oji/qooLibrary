import Foundation
import GRDB
import QooKit
import Testing

@testable import QooPersistence

/// `v9_reservedWordCleanup` の移行 [§19.10 Stage 5][RWI-02]。
///
/// **v8 までを当てた状態から始める。** 完成した DB を見るだけでは、移行が実際に
/// 走ったのか新しいスキーマで作られただけなのかを区別できない
/// （`Stage1RemovalMigrationTests` と同じ理由）。
///
/// この移行が無いと何が起きるか: 予約語の綴りを変えただけでは保存済みの
/// フォーマットが「不明な予約語」になり、`SQLiteLibraryRepository` が `try?` で
/// 落とすので**フォーマットが 1 本も無いライブラリ**になる——次の走査が
/// タイトルもラベルも全部 nil で上書きする、最も静かな壊れ方をする。
@Suite("v9_reservedWordCleanup の移行")
struct ReservedWordMigrationTests {

    private func v8Store() throws -> DatabaseQueue {
        var config = Configuration()
        config.foreignKeysEnabled = false
        let queue = try DatabaseQueue(configuration: config)
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1_initial") { try QooMigrations.v1Initial($0) }
        migrator.registerMigration("v2_regexPatterns") { try QooMigrations.v2RegexPatterns($0) }
        migrator.registerMigration("v3_embeddedMetadata") { try QooMigrations.v3EmbeddedMetadata($0) }
        migrator.registerMigration("v4_fsEventsCheckpoint") { try QooMigrations.v4FSEventsCheckpoint($0) }
        migrator.registerMigration("v5_identityRejection") { try QooMigrations.v5IdentityRejection($0) }
        migrator.registerMigration("v6_duplicateTitleKey") { try QooMigrations.v6DuplicateTitleKey($0) }
        migrator.registerMigration("v7_identityPending") { try QooMigrations.v7IdentityPending($0) }
        migrator.registerMigration("v8_stage1Removals") { try QooMigrations.v8Stage1Removals($0) }
        try migrator.migrate(queue)
        return queue
    }

    @Test("@librarytype を @booktype へ書き換える")
    func renamesLibraryTypeSpelling() throws {
        let queue = try v8Store()
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO filenameFormat (libraryId, source, priority, isEnabled)
                VALUES (1, '(@librarytype) [@author] @title', 0, 1)
                """)
            try db.execute(sql: """
                INSERT INTO folderLevelMapping (libraryId, level, assignmentKind, formatSource)
                VALUES (1, 1, 'format', '(@librarytype) @title')
                """)
        }
        try queue.write { try QooMigrations.v9ReservedWordCleanup($0) }

        let (source, folder, enabled) = try queue.read { db in
            (try String.fetchOne(db, sql: "SELECT source FROM filenameFormat"),
             try String.fetchOne(db, sql: "SELECT formatSource FROM folderLevelMapping"),
             try Bool.fetchOne(db, sql: "SELECT isEnabled FROM filenameFormat"))
        }
        #expect(source == "(@booktype) [@author] @title")
        #expect(folder == "(@booktype) @title")
        #expect(enabled == true, "書き換えられたものは有効なまま")
    }

    /// **変換先が無いものは無効にして残す。** 消すと利用者が何を失ったか
    /// 分からない——設定画面には見えるので、必要なら書き直せる。
    @Test("@labelgroupN と @libraryname を含む行は無効にする")
    func disablesFormatsWithWithdrawnWords() throws {
        let queue = try v8Store()
        try queue.write { db in
            for (i, src) in ["[@labelgroup2] @title", "@libraryname @title",
                             "[@author] @title"].enumerated() {
                try db.execute(sql: """
                    INSERT INTO filenameFormat (libraryId, source, priority, isEnabled)
                    VALUES (1, ?, ?, 1)
                    """, arguments: [src, i])
            }
        }
        try queue.write { try QooMigrations.v9ReservedWordCleanup($0) }

        let rows = try queue.read { db in
            try Row.fetchAll(db, sql: "SELECT source, isEnabled FROM filenameFormat ORDER BY priority")
        }
        #expect(rows.count == 3, "行は消さない")
        #expect(rows[0]["isEnabled"] == false)
        #expect(rows[1]["isEnabled"] == false)
        #expect(rows[2]["isEnabled"] == true, "撤去した予約語を含まない行は触らない")
    }
}
