import Foundation
import GRDB
import QooKit
import Testing

@testable import QooPersistence

/// `v10_metadataProtection` の移行 [PR-08][§19.10 Stage 6]。
///
/// **v9 までを当てた状態から始める。** 完成した DB を見るだけでは、移行が
/// 実際に走ったのか、そもそも新しいスキーマで作られただけなのかを区別できない
/// （`Stage1RemovalMigrationTests` と同じ理由）。
///
/// **取り返しがつかないので丁寧に見る。** 変換を間違えると、手で直したタイトル
/// と手で付けたラベルが「守られていない」状態で残り、次の走査で黙って消える。
@Suite("v10_metadataProtection の移行 [PR-08]")
struct MetadataProtectionMigrationTests {

    /// v9 までを当てたストア（外部キーは切って親行の用意を省く）。
    private func v9Store() throws -> DatabaseQueue {
        var config = Configuration()
        config.foreignKeysEnabled = false
        let queue = try DatabaseQueue(configuration: config)
        var migrator = DatabaseMigrator()
        for (i, id) in QooMigrations.identifiers.enumerated()
        where id != "v10_metadataProtection" {
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
            default: break
            }
        }
        try migrator.migrate(queue)
        return queue
    }

    /// ファイル 3 件・フィールド 2 つ・ラベル 3 つを、旧来の印付きで用意する。
    private func seed(_ queue: DatabaseQueue) throws {
        try queue.write { db in
            for (id, titleOrigin) in [(1, "manual"), (2, "auto"), (3, "auto")] {
                try db.execute(sql: """
                    INSERT INTO managedFile
                        (id, libraryId, inode, volumeUUID, relativePath, filename,
                         normalizedName, searchKey, fileSize, createdAt, modifiedAt,
                         title, titleOrigin, rating, coverImageSource, isArchived,
                         isBookFolder, state, libraryTypeMismatch, volumeKind)
                    VALUES (?, 1, ?, 'VOL', ?, ?, ?, ?, 4096, 0, 0,
                            '題', ?, 0, 'auto', 0, 0, 'active', 0, 'none')
                    """, arguments: [id, id * 100, "\(id).cbz", "\(id).cbz",
                                     "\(id)", "\(id)", titleOrigin])
            }
            // フィールド 2 つ（`labelGroup`）とラベル 3 つ。
            for (id, index) in [(10, 1), (20, 2)] {
                try db.execute(sql: """
                    INSERT INTO labelGroup (id, libraryId, groupIndex, name, displayOrder,
                                            assignsAutomatically, colorHexLight, colorHexDark)
                    VALUES (?, 1, ?, ?, ?, 1, '#000000', '#FFFFFF')
                    """, arguments: [id, index, "G\(index)", index])
            }
            for (id, field) in [(100, 10), (200, 10), (300, 20)] {
                try db.execute(sql: """
                    INSERT INTO label (id, labelGroupId, name, normalizedName,
                                       isPinned, isArchived, fileCount)
                    VALUES (?, ?, ?, ?, 0, 0, 0)
                    """, arguments: [id, field, "L\(id)", "l\(id)"])
            }
            // ファイル 2: フィールド 10 のラベルを手で付けた → 保護へ
            // ファイル 3: フィールド 20 のラベルを手で外した → 保護へ、行は消える
            // ファイル 1: 自動ラベルだけ → 保護は増えない（titleOrigin 由来のみ）
            for (file, label, origin) in [(1, 100, "auto"), (2, 100, "manual"),
                                          (2, 200, "auto"), (3, 300, "manuallyRemoved")] {
                try db.execute(sql: """
                    INSERT INTO fileLabel (managedFileId, labelId, origin, assignedAt)
                    VALUES (?, ?, ?, 0)
                    """, arguments: [file, label, origin])
            }
        }
    }

    private func scopes(_ queue: DatabaseQueue, id: Int) throws -> Set<ProtectionScope> {
        try queue.read { db in
            ProtectionScopeCoding.decode(try String.fetchOne(db, sql:
                "SELECT protectedScopes FROM managedFile WHERE id = ?", arguments: [id]))
        }
    }

    @Test("titleOrigin = manual は基本情報の保護になる")
    func manualTitleBecomesBasicProtection() throws {
        let queue = try v9Store()
        try seed(queue)
        try QooMigrations.migrator.migrate(queue)
        #expect(try scopes(queue, id: 1).contains(.basic))
        #expect(!(try scopes(queue, id: 2).contains(.basic)))
    }

    /// **`manuallyRemoved` も保護へ変換する**のが要点 [PR-08]。行を消すだけでは
    /// 次の走査で外したはずのラベルが復活する。
    @Test("手で付けた／外したラベルは、そのフィールドの保護になる")
    func manualLabelsBecomeFieldProtection() throws {
        let queue = try v9Store()
        try seed(queue)
        try QooMigrations.migrator.migrate(queue)
        #expect(try scopes(queue, id: 2) == [.field(FieldID(rawValue: 10))])
        #expect(try scopes(queue, id: 3) == [.field(FieldID(rawValue: 20))])
        // 自動ラベルしか無いファイルは、保護が増えない。
        #expect(try scopes(queue, id: 1) == [.basic])
    }

    @Test("除去の印が付いた行は消える。付いているものは残る")
    func removedRowsAreDeletedAndAttachedOnesRemain() throws {
        let queue = try v9Store()
        try seed(queue)
        try QooMigrations.migrator.migrate(queue)
        let rows = try queue.read { db in
            try Row.fetchAll(db, sql:
                "SELECT managedFileId, labelId FROM fileLabel ORDER BY managedFileId, labelId")
        }
        #expect(rows.map { ($0["managedFileId"] as Int, $0["labelId"] as Int) }
            .map { "\($0.0)-\($0.1)" } == ["1-100", "2-100", "2-200"])
    }

    /// **綴りは `ProtectionScopeCoding.encode` と揃える。** 揃っていないと、
    /// 移行が書いた行と以後に書いた行で同じ集合が違う文字列になり、JSON
    /// バックアップに意味の無い差分が出る。
    @Test("書き込む綴りが Swift 側の符号化と一致する")
    func encodingMatchesTheSwiftSide() throws {
        let queue = try v9Store()
        try seed(queue)
        try QooMigrations.migrator.migrate(queue)
        let raw = try queue.read { db in
            try String.fetchOne(db, sql: "SELECT protectedScopes FROM managedFile WHERE id = ?",
                                arguments: [2])
        }
        #expect(raw == ProtectionScopeCoding.encode([.field(FieldID(rawValue: 10))]))
    }

    @Test("旧来の 2 列が消える")
    func dropsTheOldColumns() throws {
        let queue = try v9Store()
        let before = try queue.read { db in
            (try db.columns(in: "managedFile").contains { $0.name == "titleOrigin" },
             try db.columns(in: "fileLabel").contains { $0.name == "origin" })
        }
        #expect(before == (true, true), "前提: 移行前は存在する")

        try QooMigrations.migrator.migrate(queue)

        let after = try queue.read { db in
            (try db.columns(in: "managedFile").contains { $0.name == "titleOrigin" },
             try db.columns(in: "fileLabel").contains { $0.name == "origin" },
             try db.columns(in: "managedFile").contains { $0.name == "protectedScopes" })
        }
        #expect(after == (false, false, true))
    }

    /// **保護の無いファイルは既定値のまま。** 空文字ではなく `"[]"` で、
    /// `ProtectionScopeCoding.empty` と同じ形であること。
    @Test("保護が無ければ既定値のまま")
    func filesWithoutProtectionKeepTheDefault() throws {
        let queue = try v9Store()
        try seed(queue)
        try QooMigrations.migrator.migrate(queue)
        let raw = try queue.read { db in
            try String.fetchOne(db, sql: """
                SELECT protectedScopes FROM managedFile WHERE id = 1
                """)
        }
        #expect(raw != nil)
        // ファイル 1 は基本情報だけが保護されるので、空ではない。空の例は
        // 別に作る——`seed` の 3 件はすべて何かしらの印を持つため。
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO managedFile
                    (id, libraryId, inode, volumeUUID, relativePath, filename,
                     normalizedName, searchKey, fileSize, createdAt, modifiedAt,
                     rating, coverImageSource, isArchived, isBookFolder, state,
                     libraryTypeMismatch, volumeKind, protectedScopes)
                VALUES (9, 1, 900, 'VOL', '9.cbz', '9.cbz', '9', '9', 1, 0, 0,
                        0, 'auto', 0, 0, 'active', 0, 'none', ?)
                """, arguments: [ProtectionScopeCoding.empty])
        }
        #expect(try scopes(queue, id: 9).isEmpty)
    }
}
