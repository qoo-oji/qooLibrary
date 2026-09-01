import Foundation
import GRDB
import QooKit
import Testing

@testable import QooPersistence

/// `v12_shelf` の移行 [SH-01][19章 §19.9]。
///
/// **v11 までを当てた状態から始める**（既存の移行テストと同じ理由——完成した
/// DB を見るだけでは、移行が実際に走ったのか最初からそうだったのかを
/// 区別できない）。
@Suite("v12_shelf の移行 [SH-01]")
struct ShelfMigrationTests {

    /// v11 までを当てたストア。
    private func v11Store() throws -> DatabaseQueue {
        let queue = try DatabaseQueue()
        var migrator = DatabaseMigrator()
        let steps: [(String, @Sendable (Database) throws -> Void)] = [
            ("v1_initial", QooMigrations.v1Initial),
            ("v2_regexPatterns", QooMigrations.v2RegexPatterns),
            ("v3_embeddedMetadata", QooMigrations.v3EmbeddedMetadata),
            ("v4_fsEventsCheckpoint", QooMigrations.v4FSEventsCheckpoint),
            ("v5_identityRejection", QooMigrations.v5IdentityRejection),
            ("v6_duplicateTitleKey", QooMigrations.v6DuplicateTitleKey),
            ("v7_identityPending", QooMigrations.v7IdentityPending),
            ("v8_stage1Removals", QooMigrations.v8Stage1Removals),
            ("v9_reservedWordCleanup", QooMigrations.v9ReservedWordCleanup),
            ("v10_metadataProtection", QooMigrations.v10MetadataProtection),
            ("v11_orphanedProtectedTokens", QooMigrations.v11OrphanedProtectedTokens),
        ]
        for (id, step) in steps { migrator.registerMigration(id, migrate: step) }
        try migrator.migrate(queue)
        return queue
    }

    @Test("既存ストアにシェルフの表が足される")
    func addsShelfTable() throws {
        let queue = try v11Store()
        let existedBefore = try queue.read { db in try db.tableExists("shelf") }
        #expect(!existedBefore)

        var migrator = DatabaseMigrator()
        migrator.registerMigration("v12_shelf", migrate: QooMigrations.v12Shelf)
        try migrator.migrate(queue)

        let (exists, columns, version) = try queue.read { db in
            (try db.tableExists("shelf"),
             Set(try db.columns(in: "shelf").map(\.name)),
             try String.fetchOne(db, sql: "SELECT schemaVersion FROM storeMetadata WHERE id = 1"))
        }
        #expect(exists)
        #expect(columns == ["id", "libraryId", "name", "displayOrder",
                            "conditionJSON", "createdAt"])
        #expect(version == "v12_shelf")   // 版の印も進む
    }

    @Test("ライブラリへの外部キーが張られている——孤児を積み上げない [PT-08 の轍]")
    func hasCascadingForeignKey() throws {
        let db = try QooDatabase.inMemory()
        let keys = try db.writer.read { d in try d.foreignKeys(on: "shelf") }
        #expect(keys.count == 1)
        #expect(keys.first?.destinationTable == "library")
    }

    @Test("行 ID を再利用しない——削除した ID で復元できる [SH-11]")
    func idsAreNotReused() async throws {
        let f = try await Fixture.make()
        let repo = SQLiteShelfRepository(database: f.database)
        let a = try await repo.create(libraryID: f.libraryID, name: "A",
                                      condition: ShelfCondition(labelIDs: []))
        let b = try await repo.create(libraryID: f.libraryID, name: "B",
                                      condition: ShelfCondition(labelIDs: []))
        try await repo.delete([a, b])

        let c = try await repo.create(libraryID: f.libraryID, name: "C",
                                      condition: ShelfCondition(labelIDs: []))
        // AUTOINCREMENT が無ければ 1 に戻る——戻ると、削除の ⌘Z が
        // 「同じ ID で作り直す」[SH-11] を満たせなくなる。
        #expect(c.rawValue == 3)
    }
}
