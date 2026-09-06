import Foundation
import GRDB
import QooKit
import Testing
@testable import QooPersistence

//
//  整合性チェック [RB-02][12章 §12.7]。
//
//  **走査がやることを試さない**——「実体が無い」「DB に無い」は `ScanEngine`
//  の担当で、ここでは扱わない（`IntegrityReport` の doc）。
//

@Suite("整合性チェック [RB-02]")
struct IntegrityCheckTests {

    /// 1 ライブラリと 1 ファイルを持つ最小のストア。
    private struct Rig {
        let database: QooDatabase
        let repository: SQLiteIntegrityRepository
        let libraryID: Int64
        let fileID: Int64

        init(relativePath: String = "作品/第01巻.cbz", isArchived: Bool = false) throws {
            database = try QooDatabase.inMemory()
            repository = SQLiteIntegrityRepository(database: database)
            var lib: Int64 = 0
            var file: Int64 = 0
            try database.writer.write { db in
                try db.execute(sql: """
                    INSERT INTO libraryType (presetKey, name, isPreset, version, definitionJSON)
                    VALUES ('p', 'テスト', 1, 1, '{}')
                    """)
                let typeID = db.lastInsertedRowID
                try db.execute(sql: """
                    INSERT INTO library (uuid, libraryTypeId, displayName, resolvedPath,
                                         bookmarkData, volumeUUID, settingsJSON,
                                         settingsRevision, isOnline)
                    VALUES (?, ?, 'ライブラリ', '/tmp/x', ?, 'V', '{}', 1, 1)
                    """, arguments: [UUID().uuidString, typeID, Data()])
                lib = db.lastInsertedRowID
                try db.execute(sql: """
                    INSERT INTO managedFile
                      (libraryId, inode, volumeUUID, relativePath, filename, normalizedName,
                       searchKey, fileSize, createdAt, modifiedAt, isArchived)
                    VALUES (?, 1, 'V', ?, '第01巻.cbz', 'x', 'x', 1, 0, 0, ?)
                    """, arguments: [lib, relativePath, isArchived])
                file = db.lastInsertedRowID
            }
            libraryID = lib
            fileID = file
        }

        /// 複製は「すべて存在する」ことにする（既定）。
        func check(coverExists: Bool = true) async throws -> IntegrityReport {
            try await repository.check { _, _ in coverExists }
        }
    }

    @Test("健全なストアでは何も見つからない [RB-02]")
    func aHealthyStoreReportsNothing() async throws {
        let rig = try Rig()
        let report = try await rig.check()
        #expect(report.isEmpty, "\(report)")
    }

    // MARK: - ユーザー指定カバー [CV-02][CV-06]

    @Test("複製を失ったユーザー指定カバーを見つける [CV-06]")
    func aMissingUserCoverIsFound() async throws {
        let rig = try Rig()
        try await rig.database.writer.write { db in
            try db.execute(sql: """
                UPDATE managedFile SET coverImageSource = 'userSpecified',
                                       coverImageRef = 'gone.png' WHERE id = ?
                """, arguments: [rig.fileID])
        }
        let report = try await rig.check(coverExists: false)
        #expect(report.brokenCoverRefs.count == 1)
        #expect(report.brokenCoverRefs.first?.repair == .clearCoverReference)

        // **実体があるなら不整合ではない**——この対照が無いと、
        // 「常に見つける」実装でも検査が通ってしまう。
        let withCover = try await rig.check(coverExists: true)
        #expect(withCover.isEmpty)
    }

    @Test("自動カバーは複製が無くても不整合ではない [IV-03]")
    func autoCoversAreNotChecked() async throws {
        let rig = try Rig()
        try await rig.database.writer.write { db in
            // `auto` は毎回作り直せる [MG-22] ので、実体が無いのは普通のこと。
            try db.execute(sql: """
                UPDATE managedFile SET coverImageSource = 'auto',
                                       coverImageRef = 'cache.png' WHERE id = ?
                """, arguments: [rig.fileID])
        }
        let report = try await rig.check(coverExists: false)
        #expect(report.isEmpty)
    }

    @Test("複製を直すとカバーが既定へ戻る [IV-03]")
    func repairingACoverFallsBackToTheDefault() async throws {
        let rig = try Rig()
        try await rig.database.writer.write { db in
            try db.execute(sql: """
                UPDATE managedFile SET coverImageSource = 'userSpecified',
                                       coverImageRef = 'gone.png' WHERE id = ?
                """, arguments: [rig.fileID])
        }
        let report = try await rig.check(coverExists: false)
        let repaired = try await rig.repository.repair(report.brokenCoverRefs)
        #expect(repaired == 1)

        let row = try rig.database.writer.read { db in
            try Row.fetchOne(db, sql: "SELECT coverImageRef, coverImageSource FROM managedFile")
        }
        #expect(row?["coverImageRef"] == nil)
        #expect(row?["coverImageSource"] as String? == "auto")
        let after = try await rig.check(coverExists: false)
        #expect(after.isEmpty, "直したのに残っている")
    }

    // MARK: - 保管庫の印 [FA-05][SY-10]

    @Test("保管庫の印と相対パスの食い違いを見つける [FA-05]")
    func anArchiveFlagMismatchIsFound() async throws {
        // `.qooarchive` の中にあるのに印が立っていない。
        let rig = try Rig(relativePath: ".qooarchive/作品/第01巻.cbz", isArchived: false)
        let report = try await rig.check()
        #expect(report.archiveMismatches.count == 1)
        #expect(report.archiveMismatches.first?.repair == .matchArchiveFlagToPath(true))

        let fixed = try await rig.repository.repair(report.archiveMismatches)
        #expect(fixed == 1)
        let flag = try await rig.database.writer.read { db in
            try Bool.fetchOne(db, sql: "SELECT isArchived FROM managedFile")
        }
        #expect(flag == true)
    }

    @Test("逆向きの食い違いも見つける [FA-05]")
    func theOppositeMismatchIsAlsoFound() async throws {
        // 保管庫の外にあるのに印が立っている。
        let rig = try Rig(relativePath: "作品/第01巻.cbz", isArchived: true)
        let report = try await rig.check()
        #expect(report.archiveMismatches.first?.repair == .matchArchiveFlagToPath(false))
    }

    // MARK: - 保護文字列の孤児 [PT-08]

    @Test("持ち主を失った保護文字列を見つける [PT-08]")
    func anOrphanedProtectedTokenIsFound() async throws {
        let rig = try Rig()
        try await rig.database.writer.write { db in
            // **外部キーで守れない**（多相参照）ので、存在しない持ち主を
            // 指す行を作れてしまう——実際にライブラリの登録解除で 36 件
            // 積み上がっていたことがある。
            try db.execute(sql: """
                INSERT INTO protectedToken (ownerKind, ownerID, pattern, position)
                VALUES ('library', 99999, '\\(完結\\)', 'anywhere')
                """)
        }
        let report = try await rig.check()
        #expect(report.orphanedProtectedTokens.count == 1)

        // **生きている持ち主のものは残す**——この対照が無いと、
        // 「全部消す」実装でも検査が通る。
        try await rig.database.writer.write { db in
            try db.execute(sql: """
                INSERT INTO protectedToken (ownerKind, ownerID, pattern, position)
                VALUES ('library', ?, '生きている', 'anywhere')
                """, arguments: [rig.libraryID])
        }
        let second = try await rig.check()
        #expect(second.orphanedProtectedTokens.count == 1, "生きている持ち主のものまで数えている")

        let removed = try await rig.repository.repair(second.orphanedProtectedTokens)
        #expect(removed == 1)
        let remaining = try await rig.database.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM protectedToken")
        }
        #expect(remaining == 1, "生きている持ち主のものを消してしまった")
    }

    // MARK: - 直せないもの

    @Test("外部キー違反は一覧に出すが直し方は出さない [12章 §12.7]")
    func foreignKeyViolationsAreReportedWithoutARepair() async throws {
        let rig = try Rig()
        // 制約を切って壊す——**普通は起こらない**が、起きたときに黙って
        // いてはならない。何が正しい状態かはアプリには決められないので、
        // 直し方は出さない。
        //
        // **`writeWithoutTransaction` でなければならない**——`PRAGMA
        // foreign_keys` はトランザクションの中では**黙って無視される**
        // （SQLite の仕様）。`write { }` は必ず囲うので、そこで切ったつもりに
        // なると制約が生きたまま `DELETE` が拒否され、この検査は
        // 「違反が 0 件」で落ちる（実際にそうなった）。
        try await rig.database.writer.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA foreign_keys = OFF")
            try db.execute(sql: "DELETE FROM library WHERE id = ?", arguments: [rig.libraryID])
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        let report = try await rig.check()
        #expect(!report.foreignKeyViolations.isEmpty)
        #expect(report.foreignKeyViolations.allSatisfy { $0.repair == nil })
        #expect(report.repairableCount == report.totalCount - report.foreignKeyViolations.count)
    }

    @Test("直し方の無い項目を渡しても何もしない [12章 §12.7]")
    func findingsWithoutARepairAreIgnored() async throws {
        let rig = try Rig()
        try await rig.database.writer.write { db in
            try db.execute(sql: """
                INSERT INTO protectedToken (ownerKind, ownerID, pattern, position)
                VALUES ('library', ?, '生きている', 'anywhere')
                """, arguments: [rig.libraryID])
        }
        // **呼び出し側が絞り忘れても壊さない。** id の綴りは種別をまたいで
        // 同じ形（`種別-行 ID`）なので、絞らずに渡すと**無関係な行を
        // 消しにいく**——外部キー違反の `fk-managedFile-1` が
        // `protectedToken#1` を消す、という形で。
        let bogus = IntegrityFinding(id: "fk-managedFile-1", subject: "managedFile",
                                     detail: "rowid 1", repair: nil)
        let repaired = try await rig.repository.repair([bogus])
        #expect(repaired == 0)
        let remaining = try await rig.database.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM protectedToken")
        }
        #expect(remaining == 1, "直し方の無い項目で行が消えた")
    }
}
