import Testing
import Foundation
import GRDB
import QooKit
@testable import QooPersistence

//
//  JSON 取り込みの Undo [IE-13][JS-08][UD-03]。
//
//  **主張は「取り込みの前とちょうど同じ状態へ戻る」**——列を 1 つずつ見るのでは
//  なく、取り込みが触るテーブルを丸ごと写して突き合わせる。列を足したときに
//  写し忘れると、この比較が落ちる（`OrphanRepositoryTests` の往復と同じ考え方）。
//

@Suite("取り込みの Undo [IE-13]")
struct ImportRevertTests {

    /// 取り込みが触るテーブルの、行 ID と `settingsRevision` を除いた写し。
    ///
    /// フォーマット類は取り込みも Undo も「消して入れ直す」ので行 ID が変わる
    /// ——それは仕様（`updateSettings` も同じ）なので比べない。
    /// `settingsRevision` は Undo でも**上がる** [VT-02] ので除く。
    private static func digest(_ db: Database) throws -> [String: [[String: String]]] {
        func rows(_ sql: String, dropping: Set<String>) throws -> [[String: String]] {
            try Row.fetchAll(db, sql: sql).map { row in
                var out: [String: String] = [:]
                for (name, value) in row where !dropping.contains(name) {
                    out[name] = String(describing: value)
                }
                return out
            }
        }
        return [
            "library": try rows("SELECT * FROM library ORDER BY id", dropping: ["settingsRevision"]),
            "labelGroup": try rows("SELECT * FROM labelGroup ORDER BY id", dropping: []),
            "label": try rows("SELECT * FROM label ORDER BY id", dropping: []),
            "shelf": try rows("SELECT * FROM shelf ORDER BY id", dropping: ["createdAt"]),
            "managedFile": try rows("SELECT * FROM managedFile ORDER BY id", dropping: []),
            "fileLabel": try rows("SELECT * FROM fileLabel ORDER BY managedFileId, labelId", dropping: []),
            "unresolvedFile": try rows("SELECT * FROM unresolvedFile ORDER BY id", dropping: []),
            "filenameFormat": try rows("SELECT * FROM filenameFormat ORDER BY priority, source", dropping: ["id"]),
            "volumeFormat": try rows("SELECT * FROM volumeFormat ORDER BY priority, source", dropping: ["id"]),
            "folderLevelMapping": try rows("SELECT * FROM folderLevelMapping ORDER BY level", dropping: ["id"]),
            "protectedToken": try rows("SELECT * FROM protectedToken ORDER BY pattern", dropping: ["id"]),
        ]
    }

    /// 評価・保護・手動ラベル・シェルフ・無視印を持つライブラリを 1 つ作る。
    private static func seeded() async throws -> (Fixture, SQLiteBackupRepository) {
        let f = try await Fixture.make(preset: "builtin.doujinshi")
        let backup = SQLiteBackupRepository(database: f.database)
        let a = try await f.files.upsert(f.snapshot(inode: 1, path: "A/作品1.cbz"))
        let b = try await f.files.upsert(f.snapshot(inode: 2, path: "A/作品2.cbz"))
        try await f.database.writer.write { db in
            try db.execute(sql: """
                UPDATE managedFile SET rating = 5, title = '手で付けた題',
                    protectedScopes = '["basic"]' WHERE id = ?
                """, arguments: [a.rawValue])
        }
        let fields = try await f.labels.fields(libraryID: f.libraryID)
        let circle = try #require(fields.first { $0.name == "サークル" })
        let manual = try await f.labels.ensureLabel(fieldID: circle.id, name: "サークル値A")
        try await f.labels.assign(fileID: a, labelID: manual)
        try await f.labels.assign(fileID: b, labelID: manual)
        try await f.files.setProtectedScopes([a: [.basic, .field(circle.id)],
                                              b: [.field(circle.id)]])
        try await f.labels.setPinned(manual, true)
        _ = try await SQLiteShelfRepository(database: f.database).create(
            libraryID: f.libraryID, name: "棚",
            condition: ShelfCondition(labelIDs: [manual], rating: nil, searchText: "作品",
                                      sort: .init(key: .title, ascending: false),
                                      displayMode: .libraryFlat))
        try await f.files.syncUnresolved(
            unresolved: [UnresolvedObservation(fileID: b, filename: "作品2.cbz")],
            resolved: [], libraryID: f.libraryID, now: Date())
        try await f.files.setUnresolvedIgnored([b], true)
        return (f, backup)
    }

    /// 取り込みの前に、取り込みが上書きする側の値を**あえて違う状態**にしておく。
    /// 同じ値のままだと「戻った」と「何もしなかった」が区別できない。
    private static func diverge(_ f: Fixture) async throws {
        // 紐づけも「消す」ではなく「別のものへ差し替える」（下記と同じ理由）。
        // 取り込みの前にだけ付いているラベルが、Undo で戻らなければ分かる。
        let fields = try await f.labels.fields(libraryID: f.libraryID)
        let circle = try #require(fields.first { $0.name == "サークル" })
        let only = try await f.labels.ensureLabel(fieldID: circle.id, name: "取り込み前だけのラベル")
        try await f.database.writer.write { db in
            try db.execute(sql: "UPDATE managedFile SET rating = 1, title = '違う題', protectedScopes = '[]'")
            try db.execute(sql: "DELETE FROM fileLabel")
            try db.execute(sql: """
                INSERT INTO fileLabel (managedFileId, labelId, assignedAt)
                SELECT id, ?, 0 FROM managedFile WHERE filename = '作品1.cbz'
                """, arguments: [only.rawValue])
            try db.execute(sql: "UPDATE label SET isPinned = 0, colorHex = '#000000'")
            try db.execute(sql: "UPDATE labelGroup SET name = name || '（改）'")
            try db.execute(sql: "UPDATE shelf SET conditionJSON = '{}'")
            try db.execute(sql: "UPDATE unresolvedFile SET isIgnored = 0")
            try db.execute(sql: "UPDATE library SET thumbnailsAlwaysHidden = 1, registeredTemplateJSON = NULL")
            // **消すのではなく、別のものに差し替える。** 空にしてしまうと、
            // 「Undo が戻さない」と「元から無かった」が区別できず、戻し忘れの
            // 変異が空振りする（実際に一度空振りした）。
            try db.execute(sql: "DELETE FROM filenameFormat")
            try db.execute(sql: """
                INSERT INTO filenameFormat (libraryId, source, priority, isEnabled)
                VALUES (?, '取り込み前だけの @title', 0, 1)
                """, arguments: [f.libraryID.rawValue])
            try db.execute(sql: "DELETE FROM protectedToken")
            try db.execute(sql: """
                INSERT INTO protectedToken (ownerKind, ownerID, pattern, position, isEnabled)
                VALUES ('library', ?, '\\(取り込み前だけ\\)', 'anywhere', 1)
                """, arguments: [f.libraryID.rawValue])
        }
    }

    @Test("取り込んで戻すと、取り込みの前とちょうど同じ状態になる")
    func revertRestoresExactly() async throws {
        let (f, backup) = try await Self.seeded()
        let document = try await backup.export(scope: .everything, appVersion: nil)
        try await Self.diverge(f)
        let before = try await f.database.writer.read(Self.digest)
        let revision: (Database) throws -> Int = { db in
            try Int.fetchOne(db, sql: "SELECT settingsRevision FROM library") ?? 0
        }

        let outcome = try await backup.import(document)
        #expect(outcome.plan.filesUpdated == 2)
        #expect(!outcome.snapshot.isEmpty)
        let during = try await f.database.writer.read(Self.digest)
        #expect(during != before, "取り込みが何も変えなければ、この検査は空振りする")
        // **取り込みの後の版を基準にする。** 取り込み自体も版を上げるので、
        // 取り込みの前と比べたのでは「Undo が上げない」変異を捕まえられない。
        let revisionAfterImport = try await f.database.writer.read(revision)

        try await backup.revertImport(outcome.snapshot)

        let after = try await f.database.writer.read(Self.digest)
        for (table, rows) in before {
            #expect(after[table] == rows, "\(table) が取り込みの前へ戻っていない")
        }
        // 設定が変わった以上、版は戻さず上げる [VT-02]。
        #expect(try await f.database.writer.read(revision) > revisionAfterImport)
    }

    /// 取り込みが**新しく作った**ラベル・フィールド・シェルフは削除される。
    @Test("取り込みが作った行は Undo で消える")
    func revertDeletesInsertedRows() async throws {
        let (f, backup) = try await Self.seeded()
        let document = try await backup.export(scope: .everything, appVersion: nil)
        // 文書側にだけあるもの: 別のラベル・別のシェルフ。
        var altered = document
        var library = altered.libraries[0]
        var groups = library.labelGroups
        let circleIndex = try #require(groups.firstIndex { $0.name == "サークル" })
        groups[circleIndex].labels.append(LabelBackup(
            name: "文書だけのラベル", colorHex: nil, isPinned: false, isHidden: false))
        library.labelGroups = groups
        library.shelves = (library.shelves ?? []) + [ShelfBackup(
            name: "文書だけの棚", displayOrder: 9, labels: [], ratingStars: nil, ratingMode: nil,
            searchText: nil, sortKey: "title", sortAscending: true, displayMode: "libraryFlat")]
        altered.libraries[0] = library

        let counts: (Database) throws -> (Int, Int) = { db in
            (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM label") ?? 0,
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM shelf") ?? 0)
        }
        let before = try await f.database.writer.read(counts)
        let outcome = try await backup.import(altered)
        let during = try await f.database.writer.read(counts)
        #expect(during.0 == before.0 + 1 && during.1 == before.1 + 1)
        #expect(outcome.snapshot.libraries[0].insertedLabelIDs.count == 1)
        #expect(outcome.snapshot.libraries[0].insertedShelfIDs.count == 1)

        try await backup.revertImport(outcome.snapshot)
        let after = try await f.database.writer.read(counts)
        #expect(after == before)
    }

    /// `dryRun`（計画）は写しを作らない——書かないので戻すものが無い。
    @Test("計画は写しを作らず、DB も変えない [IE-11]")
    func planDoesNotSnapshot() async throws {
        let (f, backup) = try await Self.seeded()
        let document = try await backup.export(scope: .everything, appVersion: nil)
        let before = try await f.database.writer.read(Self.digest)
        let outcome = try await f.database.writer.read { db in
            try SQLiteBackupRepository.apply(db, document, dryRun: true)
        }
        #expect(outcome.snapshot.isEmpty)
        #expect(try await f.database.writer.read(Self.digest) == before)
    }

    /// 取り込みの後にライブラリごと消えていたら、その分は黙って飛ばす。
    @Test("登録解除されたライブラリの分は飛ばし、投げない")
    func revertSkipsAVanishedLibrary() async throws {
        let (f, backup) = try await Self.seeded()
        let document = try await backup.export(scope: .everything, appVersion: nil)
        let outcome = try await backup.import(document)
        try await f.libraries.unregister(id: f.libraryID)

        try await backup.revertImport(outcome.snapshot)

        let libraries = try await f.database.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM library") ?? 0
        }
        #expect(libraries == 0)
    }
}
