import Testing
import Foundation
import GRDB
import QooKit
@testable import QooPersistence

//
//  JSON の書き出しと取り込み [IE-01〜IE-14][JS-01〜JS-09][BK-05][MG-23]。
//
//  **この suite の一番の仕事は網羅性の検証** [MG-23][B-13]——再生成不可能な列
//  （`RegenerabilityDeclaring` の宣言から機械的に導ける）が、JSON の DTO に
//  漏れなく現れることを確かめる。列を足して分類を忘れたときに落ちる。
//

@Suite("JSON バックアップ [IE-01〜IE-14][BK-05]")
struct BackupTests {

    /// 評価・手動タイトル・手動ラベルを持つライブラリを 1 つ作る。
    private static func seeded() async throws -> (Fixture, SQLiteBackupRepository) {
        let f = try await Fixture.make(preset: "builtin.doujinshi-a")
        let backup = SQLiteBackupRepository(database: f.database)

        let a = try await f.files.upsert(f.snapshot(inode: 1, path: "A/作品1.cbz"))
        let b = try await f.files.upsert(f.snapshot(inode: 2, path: "A/作品2.cbz"))
        _ = try await f.files.upsert(f.snapshot(inode: 3, path: "A/作品3.cbz"))

        // 評価 [RA-01]
        try await f.database.writer.write { db in
            try db.execute(sql: "UPDATE managedFile SET rating = 5 WHERE id = ?",
                           arguments: [a.rawValue])
            try db.execute(sql: """
                UPDATE managedFile SET title = ?, titleOrigin = 'manual' WHERE id = ?
                """, arguments: ["手で付けた題", b.rawValue])
        }

        // 手動ラベルと「手で外した」記録 [RC-04]
        let groups = try await f.labels.groups(libraryID: f.libraryID)
        let circle = try #require(groups.first { $0.name == "サークル" })
        let manual = try await f.labels.ensureLabel(groupID: circle.id, name: "サークル値A")
        try await f.labels.assign(fileID: a, labelID: manual, origin: .manual)
        let removed = try await f.labels.ensureLabel(groupID: circle.id, name: "サークル値B")
        try await f.labels.assign(fileID: b, labelID: removed, origin: .manuallyRemoved)
        // 自動ラベルは再スキャンが付け直すので、書き出しの対象外になるはず
        let auto = try await f.labels.ensureLabel(groupID: circle.id, name: "サークル値C")
        try await f.labels.assign(fileID: b, labelID: auto, origin: .auto)

        // ラベルの色・ピン・アーカイブ [MG-22]
        try await f.labels.setPinned(manual, true)

        // **Optional をすべて埋めた標本を 1 件置く。** `JSONEncoder` は nil の
        // キーを丸ごと省くので、これが無いと網羅性の検証（下記）が
        // 「そのキーは無い」と正しく判定できず空振りする。
        let full = try await f.files.upsert(f.snapshot(inode: 4, path: "A/全項目.cbz"))
        try await f.database.writer.write { db in
            try db.execute(sql: """
                UPDATE managedFile
                   SET rating = 3, title = '題', titleOrigin = 'manual',
                       coverImageSource = 'userSpecified', coverImageRef = 'cover-ref',
                       isArchived = 1, archivedFromPath = 'old/path.cbz', archivedAt = 100,
                       isDuplicateRepresentativePinned = 1,
                       state = 'trashed', trashedAt = 200
                 WHERE id = ?
                """, arguments: [full.rawValue])
            try db.execute(sql: """
                UPDATE label SET colorHex = '#123456' WHERE name = 'サークル値A'
                """)
        }
        try await f.labels.assign(fileID: full, labelID: manual, origin: .manual)
        return (f, backup)
    }

    // MARK: - 網羅性 [MG-23][BK-05][B-13]

    @Test("再生成不可能な列が JSON の DTO に漏れなく現れる [MG-23][BK-05]")
    func exportCoversEveryNonRegenerableColumn() async throws {
        let (f, backup) = try await Self.seeded()
        let document = try await backup.export(scope: .everything, appVersion: "test")
        let json = try #require(try JSONSerialization.jsonObject(
            with: BackupCoding.encode(document)) as? [String: Any])
        let libraries = try #require(json["libraries"] as? [[String: Any]])
        let library = try #require(libraries.first)

        // DTO のキー名が列名と違うものだけを対応づける。
        // **列を足したら、ここか DTO のどちらかを直さないと落ちる。**
        let renamed: [String: [String: String]] = [
            "library": ["resolvedPath": "rootPath", "settingsJSON": "settings",
                        "libraryTypeVersion": "libraryType"],
            "managedFile": [:], "label": [:], "labelGroup": [:], "fileLabel": [:],
        ]
        func unionKeys(_ objects: [[String: Any]]) -> Set<String> {
            objects.reduce(into: Set<String>()) { $0.formUnion($1.keys) }
        }
        let groups = (library["labelGroups"] as? [[String: Any]]) ?? []
        let files = (library["files"] as? [[String: Any]]) ?? []
        let keysByTable: [String: Set<String>] = [
            "library": Set(library.keys),
            "labelGroup": unionKeys(groups),
            "label": unionKeys(groups.flatMap { ($0["labels"] as? [[String: Any]]) ?? [] }),
            "managedFile": unionKeys(files),
            "fileLabel": unionKeys(files.flatMap { ($0["labels"] as? [[String: Any]]) ?? [] }),
        ]

        try await f.database.writer.read { db in
            for type in RegenerabilityRegistry.declaringTypes {
                let table = type.databaseTableName
                let actual = try RegenerabilityRegistry.actualColumns(db, table: table)
                let mustExport = actual
                    .subtracting(type.regenerableColumns)
                    .subtracting(type.internalColumns)
                let present = try #require(keysByTable[table], "\(table) の DTO キーが取れない")
                let map = renamed[table] ?? [:]
                let missing = mustExport.filter { !present.contains(map[$0] ?? $0) }
                #expect(missing.isEmpty,
                        "\(table): 再生成不可能な列が JSON に無い \(missing.sorted())")
            }
        }
    }

    // MARK: - 往復 [IE-01]

    @Test("書き出して取り込むと、評価・手動タイトル・手動ラベルが戻る")
    func roundTripRestoresUnrecoverableData() async throws {
        let (f, backup) = try await Self.seeded()
        let document = try await backup.export(scope: .everything, appVersion: nil)
        let encoded = try BackupCoding.encode(document)

        // 破壊する: 評価・手動タイトル・手動ラベルを消す（ファイル行は残す
        // ——復旧手順は「有効化 → 再スキャン → 取り込み」なので、取り込みの
        // 時点では走査済みの行があるのが前提）。
        try await f.database.writer.write { db in
            try db.execute(sql: """
                UPDATE managedFile SET rating = 0, title = NULL, titleOrigin = 'auto'
                """)
            try db.execute(sql: "DELETE FROM fileLabel")
            try db.execute(sql: "DELETE FROM label")
        }

        let restored = try BackupCoding.decode(encoded)
        let plan = try await backup.import(restored)
        #expect(plan.libraries.count == 1)
        #expect(plan.libraries[0].kind == .update)
        #expect(plan.filesMissing == 0)
        #expect(plan.filesUpdated == 3)

        try await f.database.writer.read { db in
            let rating = try Int.fetchOne(db, sql: """
                SELECT rating FROM managedFile WHERE filename = '作品1.cbz'
                """)
            #expect(rating == 5)
            let title = try String.fetchOne(db, sql: """
                SELECT title FROM managedFile WHERE filename = '作品2.cbz'
                """)
            #expect(title == "手で付けた題")
            let origin = try String.fetchOne(db, sql: """
                SELECT titleOrigin FROM managedFile WHERE filename = '作品2.cbz'
                """)
            #expect(origin == "manual")
            // 手で付けたラベルと、手で外した記録の両方が戻る [RC-04]
            let origins = try String.fetchAll(db, sql: """
                SELECT fileLabel.origin FROM fileLabel
                JOIN label ON label.id = fileLabel.labelId
                ORDER BY label.name, fileLabel.managedFileId
                """)
            // 自動ラベルは戻らない（書き出していない）。人が付けた 2 件と、
            // 人が外した 1 件の記録だけが復元される [RC-04]。
            #expect(origins == ["manual", "manual", "manuallyRemoved"])
            // ピン留めも戻る [LB-03]
            let pinned = try Bool.fetchOne(db, sql: """
                SELECT isPinned FROM label WHERE name = 'サークル値A'
                """)
            #expect(pinned == true)
        }
    }

    @Test("再生成できる情報しか持たない行は書き出さない")
    func exportOmitsRowsThatScanCanRebuild() async throws {
        let (_, backup) = try await Self.seeded()
        let document = try await backup.export(scope: .everything, appVersion: nil)
        let files = try #require(document.libraries.first?.files)
        // 3 件のうち、評価も手動タイトルも手動ラベルも無い「作品3.cbz」は出ない。
        #expect(files.map(\.filename).sorted() == ["作品1.cbz", "作品2.cbz", "全項目.cbz"])
        // 自動ラベルだけの紐づけも出ない [RC-04]
        let all = files.flatMap(\.labels)
        #expect(all.allSatisfy { $0.origin != "auto" })
    }

    // MARK: - 取り込みの安全性

    @Test("プレビューは DB を変えない [IE-11]")
    func planDoesNotTouchTheDatabase() async throws {
        let (f, backup) = try await Self.seeded()
        let document = try await backup.export(scope: .everything, appVersion: nil)
        try await f.database.writer.write { db in
            try db.execute(sql: "UPDATE managedFile SET rating = 0")
        }
        let plan = try await backup.plan(document)
        #expect(plan.filesUpdated == 3)
        let rating = try await f.database.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT MAX(rating) FROM managedFile")
        }
        #expect(rating == 0, "plan が書き込んでいる")
    }

    @Test("DB に無いライブラリは取り込まず missing として報告する")
    func unknownLibraryIsReportedNotCreated() async throws {
        let (f, backup) = try await Self.seeded()
        var document = try await backup.export(scope: .everything, appVersion: nil)
        document.libraries[0].displayName = "存在しないライブラリ"

        let plan = try await backup.import(document)
        #expect(plan.libraries[0].kind == .missing)
        #expect(plan.missingLibraries.count == 1)
        let count = try await f.database.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM library")
        }
        #expect(count == 1, "取り込みがライブラリを作っている")
    }

    @Test("文書にあって DB に無いファイルは行を作らず数えるだけ [ID-06]")
    func missingFilesAreCountedNotCreated() async throws {
        let (f, backup) = try await Self.seeded()
        let document = try await backup.export(scope: .everything, appVersion: nil)
        try await f.database.writer.write { db in
            try db.execute(sql: "DELETE FROM managedFile")
        }
        let plan = try await backup.import(document)
        #expect(plan.filesMissing == 3)
        #expect(plan.filesUpdated == 0)
        let count = try await f.database.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM managedFile")
        }
        #expect(count == 0, "取り込みがファイルの行を作っている")
    }

    @Test("新しすぎるスキーマ版は拒否する [IE-14][JS-09]")
    func rejectsNewerSchema() async throws {
        let (_, backup) = try await Self.seeded()
        var document = try await backup.export(scope: .everything, appVersion: nil)
        document.schemaVersion = BackupDocument.currentSchemaVersion + 1
        let data = try BackupCoding.encode(document)

        #expect(throws: BackupError.schemaTooNew(
            found: BackupDocument.currentSchemaVersion + 1,
            supported: BackupDocument.currentSchemaVersion)) {
            _ = try BackupCoding.decode(data)
        }
        // リポジトリ側でも止める（復号を経ずに渡された場合の砦）
        await #expect(throws: BackupError.self) {
            _ = try await backup.import(document)
        }
    }

    @Test("書き出しの範囲をライブラリで絞れる [IE-02]")
    func scopeSelectsLibraries() async throws {
        let (f, backup) = try await Self.seeded()
        let all = try await backup.export(scope: .everything, appVersion: nil)
        #expect(all.libraries.count == 1)
        let none = try await backup.export(scope: .libraries([]), appVersion: nil)
        #expect(none.libraries.isEmpty)
        let one = try await backup.export(scope: .libraries([f.libraryID]), appVersion: nil)
        #expect(one.libraries.count == 1)
    }

    @Test("同じ内容を 2 回書き出すと同じバイト列になる [IE-04]")
    func outputIsStableForDiffing() async throws {
        let (_, backup) = try await Self.seeded()
        let first = try await backup.export(scope: .everything, appVersion: nil)
        var second = try await backup.export(scope: .everything, appVersion: nil)
        // 書き出し時刻だけは必ず変わるので揃える。
        second.exportedAt = first.exportedAt
        #expect(try BackupCoding.encode(first) == BackupCoding.encode(second))
        // 整形されていて、キーが名前順に並んでいること。
        let text = try #require(String(data: BackupCoding.encode(first), encoding: .utf8))
        #expect(text.contains("\n"))
        let libIndex = try #require(text.range(of: "\"libraries\""))
        let schemaIndex = try #require(text.range(of: "\"schemaVersion\""))
        #expect(libIndex.lowerBound < schemaIndex.lowerBound, "キーが名前順でない")
    }

    @Test("取り込みはライブラリ設定を復元する [LS-01][VT-02]")
    func importRestoresLibrarySettings() async throws {
        let (f, backup) = try await Self.seeded()
        let document = try await backup.export(scope: .everything, appVersion: nil)
        let before = try await f.database.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM filenameFormat")
        }
        #expect((before ?? 0) > 0)

        try await f.database.writer.write { db in
            try db.execute(sql: "DELETE FROM filenameFormat")
            try db.execute(sql: "UPDATE library SET thumbnailsAlwaysHidden = 1")
        }
        _ = try await backup.import(document)

        try await f.database.writer.read { db in
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM filenameFormat") == before)
            #expect(try Bool.fetchOne(db, sql: "SELECT thumbnailsAlwaysHidden FROM library") == false)
            // 設定を書き換えたら版を上げる [VT-02]。上げ忘れるとパーサが
            // 古いコンパイル結果を使い続ける。
            let revision = try Int.fetchOne(db, sql: "SELECT settingsRevision FROM library") ?? 0
            #expect(revision > 0)
        }
    }
}
