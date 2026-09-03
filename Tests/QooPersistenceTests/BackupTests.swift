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
            // **自動値も入れておく。** これが無いと「保護されていない基本
            // 情報を出さない」検査が空振りする——出しても中身が nil で、
            // 出す／出さないの差が観測できない。
            try db.execute(sql: """
                UPDATE managedFile SET rating = 5, title = ?, seriesName = ?,
                    volumeNumber = 1, volumeKind = 'numeric', volumeRaw = ?,
                    authorName = ?
                 WHERE id = ?
                """, arguments: ["自動の題", "自動のシリーズ", "第01巻", "自動の著者",
                                 a.rawValue])
            try db.execute(sql: """
                UPDATE managedFile SET title = ?, protectedScopes = '["basic"]' WHERE id = ?
                """, arguments: ["手で付けた題", b.rawValue])
        }

        // 保護されたフィールドのラベル [PR-02]（＝書き出しの対象）
        let groups = try await f.labels.groups(libraryID: f.libraryID)
        let circle = try #require(groups.first { $0.name == "サークル" })
        let manual = try await f.labels.ensureLabel(groupID: circle.id, name: "サークル値A")
        try await f.labels.assign(fileID: a, labelID: manual)
        try await f.files.setProtectedScopes([a: [.field(circle.id)]])
        // 保護されていないフィールドのラベルは再スキャンが付け直すので、
        // 書き出しの対象外になるはず
        let auto = try await f.labels.ensureLabel(groupID: circle.id, name: "サークル値C")
        try await f.labels.assign(fileID: b, labelID: auto)

        // ラベルの色・ピン・アーカイブ [MG-22]
        try await f.labels.setPinned(manual, true)

        // シェルフ [SH-12]。**Optional をすべて埋める**——`JSONEncoder` は nil の
        // キーを省くので、埋めないと下の網羅性の検証が空振りする（ファイルの
        // 標本と同じ事情）。
        _ = try await SQLiteShelfRepository(database: f.database).create(
            libraryID: f.libraryID, name: "標本のシェルフ",
            condition: ShelfCondition(labelIDs: [manual],
                                      rating: .init(stars: 3, mode: .exact),
                                      searchText: "作品",
                                      sort: .init(key: .title, ascending: false),
                                      displayMode: .libraryFlat))

        // **Optional をすべて埋めた標本を 1 件置く。** `JSONEncoder` は nil の
        // キーを丸ごと省くので、これが無いと網羅性の検証（下記）が
        // 「そのキーは無い」と正しく判定できず空振りする。
        let full = try await f.files.upsert(f.snapshot(inode: 4, path: "A/全項目.cbz"))
        try await f.database.writer.write { db in
            try db.execute(sql: """
                UPDATE managedFile
                   SET rating = 3, title = '題', protectedScopes = '["basic"]',
                       coverImageSource = 'userSpecified', coverImageRef = 'cover-ref',
                       isArchived = 1, archivedFromPath = 'old/path.cbz', archivedAt = 100,
                       state = 'trashed', trashedAt = 200
                 WHERE id = ?
                """, arguments: [full.rawValue])
            try db.execute(sql: """
                UPDATE label SET colorHex = '#123456' WHERE name = 'サークル値A'
                """)
        }
        try await f.labels.assign(fileID: full, labelID: manual)

        // 「以後無視する」[AL-33]。**再生成不可能な列を持つ唯一の行**なので、
        // これが無いと `unresolvedFile` の網羅性の検証が空振りする
        // （`isUnresolvedIgnored` は立っているときだけ書き出す）。
        try await f.files.syncUnresolved(
            unresolved: [UnresolvedObservation(fileID: a, filename: "作品1.cbz")],
            resolved: [], libraryID: f.libraryID, now: Date())
        try await f.files.setUnresolvedIgnored([a], true)

        // シリーズの提案の「以後出さない」[SS-05]。これも**再生成不可能な列を
        // 持つ唯一の経路**なので、立てておかないと網羅性の検証が空振りする
        // （立っているときだけ書き出すため）。
        try await f.files.updateSeriesSuggestionIgnored(set: [a: "作品1"], clear: [])
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
        //
        // 値が配列なのは、**1 列が複数のキーへ分かれることがある**ため
        // ——`shelf.conditionJSON` は DB では JSON 1 列だが、文書では
        // ラベル・評価・検索語・並び順・表示モードへ展開して出す [SH-12]
        // （行 ID を持ち出さないための翻訳を伴うので、生の JSON は出せない）。
        let renamed: [String: [String: [String]]] = [
            "library": ["resolvedPath": ["rootPath"], "settingsJSON": ["settings"],
                        "libraryTypeVersion": ["libraryType"]],
            "managedFile": [:], "label": [:], "labelGroup": [:], "fileLabel": [:],
            // `unresolvedFile` は `managedFile` と 1:1 なので、ファイルの
            // 属性として畳んである [AL-33]。
            "unresolvedFile": ["isIgnored": ["isUnresolvedIgnored"]],
            "shelf": ["conditionJSON": ["labels", "ratingStars", "ratingMode",
                                        "searchText", "sortKey", "sortAscending",
                                        "displayMode"]],
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
            "unresolvedFile": unionKeys(files),
            "shelf": unionKeys((library["shelves"] as? [[String: Any]]) ?? []),
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
                let missing = mustExport.filter { column in
                    !(map[column] ?? [column]).allSatisfy(present.contains)
                }
                #expect(missing.isEmpty,
                        "\(table): 再生成不可能な列が JSON に無い \(missing.sorted())")
            }
        }
    }

    // MARK: - 往復 [IE-01]

    /// 「以後無視する」[AL-33] は走査からは作り直せない利用者の判断なので、
    /// バックアップに含める [MG-22]。
    @Test("書き出して取り込むと「以後無視する」が戻る [AL-33][MG-22]")
    func roundTripRestoresTheIgnoreFlag() async throws {
        let (f, backup) = try await Self.seeded()
        let document = try await backup.export(scope: .everything, appVersion: nil)
        let encoded = try BackupCoding.encode(document)

        // 破壊する: 無視を解く（未解決の行そのものは走査が作り直すので残す
        // ——復旧手順は「有効化 → 再スキャン → 取り込み」[MG-24]）。
        try await f.database.writer.write { db in
            try db.execute(sql: "UPDATE unresolvedFile SET isIgnored = 0")
        }
        #expect(try await f.files.unresolvedFileCounts()[f.libraryID]?.pending == 1)

        _ = try await backup.import(try BackupCoding.decode(encoded))
        let counts = try #require(try await f.files.unresolvedFileCounts()[f.libraryID])
        #expect(counts == UnresolvedCounts(pending: 0, ignored: 1),
                "無視が戻れば「片付けるべき件数」から外れ、無視の側へ移る")
    }

    /// **行が無いのは「いまは解決している」という意味**なので、そこへ無視を
    /// 作ってはならない——解決済みのファイルに人の判断が蘇ることになる。
    @Test("未解決の記録が無いファイルには無視を書き戻さない")
    func importDoesNotResurrectTheFlagWithoutARecord() async throws {
        let (f, backup) = try await Self.seeded()
        let document = try await backup.export(scope: .everything, appVersion: nil)
        let encoded = try BackupCoding.encode(document)

        try await f.database.writer.write { db in
            try db.execute(sql: "DELETE FROM unresolvedFile")
        }
        _ = try await backup.import(try BackupCoding.decode(encoded))
        let rows = try await f.database.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM unresolvedFile") ?? -1
        }
        #expect(rows == 0)
    }

    /// このキーを持たない版 1／2 の文書がある。非 Optional にすると
    /// `keyNotFound` で**文書全体の取り込みが失敗する**。
    @Test("`isUnresolvedIgnored` を持たない古い文書もそのまま読める [IE-14]")
    func decodesDocumentsWrittenBeforeTheIgnoreFlagExisted() async throws {
        let (f, backup) = try await Self.seeded()
        let document = try await backup.export(scope: .everything, appVersion: nil)
        var json = try #require(try JSONSerialization.jsonObject(
            with: BackupCoding.encode(document)) as? [String: Any])
        var libraries = try #require(json["libraries"] as? [[String: Any]])
        var library = libraries[0]
        library["files"] = (library["files"] as? [[String: Any]] ?? []).map { file -> [String: Any] in
            var copy = file
            copy.removeValue(forKey: "isUnresolvedIgnored")
            return copy
        }
        libraries[0] = library
        json["libraries"] = libraries

        let stripped = try JSONSerialization.data(withJSONObject: json)
        let decoded = try BackupCoding.decode(stripped)
        #expect(decoded.libraries.count == 1)
        #expect(decoded.libraries[0].files.allSatisfy { $0.isUnresolvedIgnored == nil })
        _ = try await backup.import(decoded)
        // 無視は元のまま（取り込みは立てるだけで、下ろさない）。
        #expect(try await f.files.unresolvedFileCounts()[f.libraryID]
                == UnresolvedCounts(pending: 0, ignored: 1))
    }

    /// **版 4 で `isArchived` を `isHidden` へ改名した** [LA3-02]。版を上げたのは
    /// 書き出す側の話で、**以前書き出した文書は読めなければならない** [IE-14]
    /// ——古い綴りも「フィルタから外す」という同じ意図を持っていた。
    @Test("版 3 以前の `isArchived` を `isHidden` として読む [LA3-02][IE-14]")
    func decodesLabelVisibilityWrittenUnderTheOldName() async throws {
        let (f, backup) = try await Self.seeded()
        try await f.database.writer.write { db in
            try db.execute(sql: "UPDATE label SET isHidden = 1")
        }
        let document = try await backup.export(scope: .everything, appVersion: nil)
        #expect(document.schemaVersion == 4)

        // 版 3 の文書に化けさせる——キーを旧しい綴りへ戻す。
        let encoded = try BackupCoding.encode(document)
        var json = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        json["schemaVersion"] = 3
        var libraries = try #require(json["libraries"] as? [[String: Any]])
        var library = libraries[0]
        library["labelGroups"] = (library["labelGroups"] as? [[String: Any]] ?? [])
            .map { group -> [String: Any] in
                var copy = group
                copy["labels"] = (group["labels"] as? [[String: Any]] ?? []).map { label -> [String: Any] in
                    var l = label
                    l["isArchived"] = l.removeValue(forKey: "isHidden") ?? false
                    return l
                }
                return copy
            }
        libraries[0] = library
        json["libraries"] = libraries

        let legacy = try JSONSerialization.data(withJSONObject: json)
        let decoded = try BackupCoding.decode(legacy)
        let labels = decoded.libraries[0].labelGroups.flatMap(\.labels)
        #expect(!labels.isEmpty)
        #expect(labels.allSatisfy { $0.isHidden }, "旧しい綴りから読み替える")
    }

    /// **キーが消えるので版を上げた** [IE-14][JS-09]。版 3 までの実装は
    /// `isArchived` を非 Optional で要求しており、無いと文書全体の取り込みが
    /// 失敗する——版 3 のときと同じ判断。
    /// **ファイル側の `isArchived`（保管庫 [FA-05]）は存続する**ので、文書全体を
    /// 文字列で見ても区別が付かない——ラベルのブロックだけを取り出して確かめる。
    @Test("書き出す文書はラベルに `isHidden` を使う [LA3-02]")
    func exportsLabelVisibilityUnderTheNewName() async throws {
        let (_, backup) = try await Self.seeded()
        let document = try await backup.export(scope: .everything, appVersion: nil)
        let data = try BackupCoding.encode(document)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let libraries = try #require(json["libraries"] as? [[String: Any]])
        let labels = libraries.flatMap { ($0["labelGroups"] as? [[String: Any]] ?? []) }
            .flatMap { ($0["labels"] as? [[String: Any]] ?? []) }
        #expect(!labels.isEmpty)
        #expect(labels.allSatisfy { $0["isHidden"] != nil })
        #expect(labels.allSatisfy { $0["isArchived"] == nil }, "ラベル側の旧しい綴りは出さない")
        #expect(labels.allSatisfy { $0["fileCount"] == nil }, "件数は出さない [DB-02 撤回]")
    }

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
                UPDATE managedFile SET rating = 0, title = NULL, protectedScopes = '[]'
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
            let scopes = try String.fetchOne(db, sql: """
                SELECT protectedScopes FROM managedFile WHERE filename = '作品2.cbz'
                """)
            #expect(scopes == #"["basic"]"#, "保護も戻る [PR-09]")
            // **保護されたフィールドの紐づけだけが戻る** [PR-01]。保護されて
            // いないフィールドのラベルは再スキャンが付け直すので出していない。
            let names = try String.fetchAll(db, sql: """
                SELECT label.name FROM fileLabel
                JOIN label ON label.id = fileLabel.labelId
                ORDER BY label.name, fileLabel.managedFileId
                """)
            #expect(names == ["サークル値A"])
            // ピン留めも戻る [LB-03]
            let pinned = try Bool.fetchOne(db, sql: """
                SELECT isPinned FROM label WHERE name = 'サークル値A'
                """)
            #expect(pinned == true)
        }
    }

    /// **保護されていない基本情報は出さない** [PR-01][MG-22]。走査が作り直す
    /// ので、10 万件ぶん書いても取り込みが何もしない——出す／出さないの判定を
    /// 落とすと JSON が無意味に膨らむ。
    @Test("保護されていない基本情報は書き出さない [MG-22]")
    func exportOmitsUnprotectedBasicFields() async throws {
        let (_, backup) = try await Self.seeded()
        let document = try await backup.export(scope: .everything, appVersion: nil)
        let files = try #require(document.libraries.first?.files)
        // 作品1: 評価とラベルのために出るが、基本情報は保護されていない。
        let unprotected = try #require(files.first { $0.filename == "作品1.cbz" })
        #expect(unprotected.title == nil)
        #expect(unprotected.seriesName == nil)
        #expect(unprotected.volumeNumber == nil)
        #expect(unprotected.authorName == nil)
        // 作品2: 基本情報が保護されているので出る。
        let protected = try #require(files.first { $0.filename == "作品2.cbz" })
        #expect(protected.title == "手で付けた題")
        #expect(protected.protectedScopes?.contains("basic") == true)
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
