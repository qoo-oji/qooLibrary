import Testing
import Foundation
import GRDB
@testable import QooPersistence

/// `@Sendable` なコールバックから触る可変値の入れ物。
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0.0
    var value: Double { lock.lock(); defer { lock.unlock() }; return _value }
    func set(_ v: Double) { lock.lock(); _value = v; lock.unlock() }
    func increment() { lock.lock(); _value += 1; lock.unlock() }
}

@Suite("スキーマと移行 [MG-01〜MG-04][SC-01〜SC-05]")
struct SchemaTests {
    @Test("v1 の移行でスキーマが作られる")
    func v1Creates() throws {
        let db = try QooDatabase.inMemory()
        let tables = try db.writer.read { d in
            try String.fetchAll(d, sql: """
                SELECT name FROM sqlite_master WHERE type = 'table'
                  AND name NOT LIKE 'sqlite_%' AND name NOT LIKE 'grdb_%'
                ORDER BY name
                """)
        }
        // 07章 §7.3 のテーブル一覧
        for expected in ["appAssociation", "filenameFormat", "fileLabel", "folderLevelMapping",
                         "label", "labelGroup", "library", "libraryType", "managedFile",
                         "notificationRecord", "operationLog", "pendingMove", "protectedToken",
                         "storeMetadata", "temporaryFolder", "unresolvedFile", "volumeFormat",
                         "volumeOutputStyle"] {
            #expect(tables.contains(expected), "\(expected) が無い")
        }
    }

    @Test("索引が張られている [IX-01][IX-02][IX-06]")
    func indexesExist() throws {
        let db = try QooDatabase.inMemory()
        let indexes = try db.writer.read { d in
            try String.fetchAll(d, sql:
                "SELECT name FROM sqlite_master WHERE type = 'index' AND name NOT LIKE 'sqlite_%'")
        }
        for expected in ["mf_identity", "mf_lib_path", "mf_lib_state", "mf_lib_series",
                         "mf_search", "mf_lib_name_size", "label_group_norm", "fl_label"] {
            #expect(indexes.contains(expected), "\(expected) が無い")
        }
    }

    @Test("(volumeUUID, inode) は一意 [ID-01]")
    func identityIsUnique() throws {
        let db = try QooDatabase.inMemory()
        try db.writer.write { d in
            try seedLibrary(d)
            try insertFile(d, inode: 1, path: "a.cbz")
            #expect(throws: (any Error).self) { try insertFile(d, inode: 1, path: "b.cbz") }
        }
    }

    @Test("ラベルは (グループ, 正規化名) で一意 [LB-01][IX-02]")
    func labelUniqueness() throws {
        let db = try QooDatabase.inMemory()
        try db.writer.write { d in
            try seedLibrary(d)
            try d.execute(sql: """
                INSERT INTO labelGroup (libraryId, groupIndex, name, colorHexLight, colorHexDark, displayOrder)
                VALUES (1, 1, '著者', '#FFF', '#000', 0)
                """)
            try d.execute(sql: "INSERT INTO label (labelGroupId, name, normalizedName) VALUES (1, '佐藤秀峰', '佐藤秀峰')")
            #expect(throws: (any Error).self) {
                try d.execute(sql: "INSERT INTO label (labelGroupId, name, normalizedName) VALUES (1, 'サトウ', '佐藤秀峰')")
            }
        }
    }

    @Test("ラベルの rowid は再利用されない（AUTOINCREMENT）[07章 §7.3]")
    func labelIDsAreNotReused() throws {
        let db = try QooDatabase.inMemory()
        try db.writer.write { d in
            try seedLibrary(d)
            try d.execute(sql: """
                INSERT INTO labelGroup (libraryId, groupIndex, name, colorHexLight, colorHexDark, displayOrder)
                VALUES (1, 1, '著者', '#FFF', '#000', 0)
                """)
            try d.execute(sql: "INSERT INTO label (labelGroupId, name, normalizedName) VALUES (1, 'A', 'a')")
            let first = d.lastInsertedRowID
            try d.execute(sql: "DELETE FROM label WHERE id = ?", arguments: [first])
            try d.execute(sql: "INSERT INTO label (labelGroupId, name, normalizedName) VALUES (1, 'B', 'b')")
            #expect(d.lastInsertedRowID != first, "rowid が再利用された")
        }
    }

    @Test("外部キーの連鎖削除が効く")
    func cascadeDelete() throws {
        let db = try QooDatabase.inMemory()
        try db.writer.write { d in
            try seedLibrary(d)
            try insertFile(d, inode: 1, path: "a.cbz")
            try d.execute(sql: """
                INSERT INTO labelGroup (libraryId, groupIndex, name, colorHexLight, colorHexDark, displayOrder)
                VALUES (1, 1, '著者', '#FFF', '#000', 0)
                """)
            try d.execute(sql: "INSERT INTO label (labelGroupId, name, normalizedName) VALUES (1, 'A', 'a')")
            try d.execute(sql: """
                INSERT INTO fileLabel (managedFileId, labelId, origin, assignedAt) VALUES (1, 1, 'auto', 0)
                """)
            try d.execute(sql: "DELETE FROM library WHERE id = 1")
            let mfCount = try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM managedFile"); #expect(mfCount == 0)
            let flCount = try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM fileLabel"); #expect(flCount == 0)
            let lbCount = try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM label"); #expect(lbCount == 0)
        }
    }

    @Test("外部キー制約が有効になっている [CN-02]")
    func foreignKeysEnforced() throws {
        let db = try QooDatabase.inMemory()
        try db.writer.write { d in
            let fk = try Int.fetchOne(d, sql: "PRAGMA foreign_keys"); #expect(fk == 1)
            #expect(throws: (any Error).self) {
                try d.execute(sql: """
                    INSERT INTO label (labelGroupId, name, normalizedName) VALUES (999, 'A', 'a')
                    """)
            }
        }
    }

    @Test("移行はファイル上のストアでも通り、2 回目は何もしない [MG-03]")
    func migrationIsIdempotentOnDisk() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("qoo-schema-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("qoo.sqlite")

        let beforeCalled = Counter()
        let first = try QooDatabase.open(at: url) { _ in beforeCalled.increment() }
        #expect(beforeCalled.value == 1, "新規ストアで移行前フックが呼ばれていない [MG-10]")
        try first.writer.write { try $0.execute(sql: "INSERT INTO volumeOutputStyle (name, numericTemplate, digits, numeralWidth, ordinalTemplate, noneOutput) VALUES ('x','{n}',2,'halfwidth','{s}','')") }
        _ = try first.writer.close()

        let second = try QooDatabase.open(at: url) { _ in beforeCalled.increment() }
        #expect(beforeCalled.value == 1, "適用済みなのに移行前フックが呼ばれた")
        let styles = try second.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM volumeOutputStyle") }
        #expect(styles == 1)
    }

    /// [MG-12] アプリが知らない移行が適用済みなら起動を中止する。
    @Test("知らない移行が適用済みのストアは開かない [MG-12]")
    func rejectsSchemaTooNew() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("qoo-toonew-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("qoo.sqlite")
        let db = try QooDatabase.open(at: url)
        // 将来の版が適用された状態を作る
        try db.writer.write {
            try $0.execute(sql: "INSERT INTO grdb_migrations (identifier) VALUES ('v99_future')")
        }
        _ = try db.writer.close()
        #expect(throws: QooDatabase.StoreError.schemaTooNew) { try QooDatabase.open(at: url) }
    }

    @Test("整合性検査が通る [RB-03]")
    func integrityCheck() async throws {
        let db = try QooDatabase.inMemory()
        let ok = try await db.integrityCheck()
        #expect(ok)
    }

    @Test("オンラインバックアップが取れる [BK-01][BK2-01]")
    func onlineBackup() async throws {
        let db = try QooDatabase.inMemory()
        try await db.writer.write { try seedLibrary($0) }
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("qoo-backup-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let dest = dir.appendingPathComponent("backup.sqlite")
        let lastProgress = Counter()
        try await db.backup(to: dest) { lastProgress.set($0) }
        #expect(FileManager.default.fileExists(atPath: dest.path))
        #expect(lastProgress.value > 0)
        let restored = try DatabaseQueue(path: dest.path)
        let count = try await restored.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM library") }
        #expect(count == 1)
    }

    @Test("スキーマ版がストアに記録される [MG-03]")
    func storeMetadata() throws {
        let db = try QooDatabase.inMemory()
        let version = try db.writer.read {
            try String.fetchOne($0, sql: "SELECT schemaVersion FROM storeMetadata WHERE id = 1")
        }
        #expect(version == QooMigrations.identifiers.last)
    }
}

// MARK: - 補助

func seedLibrary(_ d: Database) throws {
    try d.execute(sql: """
        INSERT INTO libraryType (presetKey, name, libraryTypeName, isPreset, version, definitionJSON)
        VALUES ('builtin.test', 'テスト', 'テスト', 1, 1, '{}')
        """)
    try d.execute(sql: """
        INSERT INTO library (uuid, displayName, bookmarkData, resolvedPath, volumeUUID,
                             libraryTypeId, settingsJSON)
        VALUES (?, 'テストライブラリ', X'00', '/tmp/lib', 'VOL', 1, '{}')
        """, arguments: [UUID().uuidString])
}

func insertFile(_ d: Database, inode: Int64, path: String) throws {
    try d.execute(sql: """
        INSERT INTO managedFile (libraryId, inode, volumeUUID, relativePath, filename,
                                 normalizedName, searchKey, fileSize, createdAt, modifiedAt)
        VALUES (1, ?, 'VOL', ?, ?, ?, ?, 100, 0, 0)
        """, arguments: [inode, path, path, path, path])
}
