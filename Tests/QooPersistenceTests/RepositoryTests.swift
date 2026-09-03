import Testing
import Foundation
import GRDB
import QooKit
@testable import QooPersistence

// MARK: - 補助

struct Fixture {
    let database: QooDatabase
    let libraries: SQLiteLibraryRepository
    let files: SQLiteManagedFileRepository
    let labels: SQLiteLabelRepository
    let libraryID: LibraryID

    static func make(preset key: String = "builtin.doujinshi-a") async throws -> Fixture {
        let db = try QooDatabase.inMemory()
        let sets = try BuiltInTemplates.volumeSets()
        let template = try #require(try BuiltInTemplates.libraryTypes().first { $0.key == key })
        let libraries = SQLiteLibraryRepository(database: db, volumeSets: sets)
        let id = try await libraries.register(
            LibraryRegistration(uuid: UUID(), displayName: "テスト", bookmarkData: Data(),
                                resolvedPath: "/tmp/lib", volumeUUID: "VOL",
                                libraryTypeID: LibraryTypeID(rawValue: 0)),
            template: template)
        return Fixture(database: db, libraries: libraries,
                       files: SQLiteManagedFileRepository(database: db),
                       labels: SQLiteLabelRepository(database: db), libraryID: id)
    }

    func snapshot(inode: UInt64, path: String, size: Int64 = 1000,
                  volume: String = "VOL") -> FileSnapshot {
        FileSnapshot(identity: FileIdentity(volumeUUID: volume, inode: inode),
                     libraryID: libraryID, relativePath: path,
                     filename: (path as NSString).lastPathComponent,
                     fileSize: size, createdAt: Date(timeIntervalSinceReferenceDate: 0),
                     modifiedAt: Date(timeIntervalSinceReferenceDate: 0))
    }
}

// MARK: - ライブラリ

@Suite("SQLiteLibraryRepository [RG-01][LT-03]")
struct LibraryRepositoryTests {
    @Test("テンプレートの内容がライブラリ側へコピーされる [LT-03]")
    func registerCopiesTemplate() async throws {
        let f = try await Fixture.make(preset: "builtin.doujinshi-a")
        let summary = try #require(try await f.libraries.library(id: f.libraryID))
        #expect(summary.displayName == "テスト")
        #expect(summary.libraryTypeName == "同人誌")

        let fields = try await f.labels.fields(libraryID: f.libraryID)
        #expect(fields.count == 6)
        #expect(fields.map(\.name).contains("サークル"))
        // 既定色が割り当てられている [CO-01][MT-13]。**文字色は色ごとに決まる**
        // [CO-03][CO-05]——彩度を上げた [CO-02、2026-08-30] ので「全部黒」ではない。
        for g in fields {
            #expect(g.colorHexLight.hasPrefix("#"))
            #expect(LabelColorPalette.readableForeground(on: g.colorHexLight) != nil,
                    "\(g.name) の \(g.colorHexLight) は黒でも白でも読めない")
        }

        let settings = try #require(try await f.libraries.settingsSnapshot(libraryID: f.libraryID))
        #expect(settings.filenameFormats.count == 20)
        #expect(settings.filenameFormats.map(\.priority) == Array(0..<20))
        #expect(!settings.volumeFormats.isEmpty)          // VS-Doujin
    }

    @Test("フォルダ階層割り当てもコピーされる [AL-01]")
    func registerCopiesFolderLevels() async throws {
        let f = try await Fixture.make(preset: "builtin.doujinshi-b")
        let settings = try #require(try await f.libraries.settingsSnapshot(libraryID: f.libraryID))
        guard case .singleLabelGroup(let field) = settings.folderLevelAssignments[1] else {
            Issue.record("第1階層の割り当てが違う"); return
        }
        #expect(field == 2)
    }

    @Test("UUID で引ける（フェーズ 1 の登録フォルダ ID を引き継ぐ）")
    func lookupByUUID() async throws {
        let db = try QooDatabase.inMemory()
        let sets = try BuiltInTemplates.volumeSets()
        let template = try #require(try BuiltInTemplates.libraryTypes().first)
        let repo = SQLiteLibraryRepository(database: db, volumeSets: sets)
        let uuid = UUID()
        _ = try await repo.register(
            LibraryRegistration(uuid: uuid, displayName: "L", bookmarkData: Data(),
                                resolvedPath: "/tmp", volumeUUID: "V",
                                libraryTypeID: LibraryTypeID(rawValue: 0)),
            template: template)
        #expect(try await repo.library(uuid: uuid) != nil)
        #expect(try await repo.library(uuid: UUID()) == nil)
    }

    @Test("登録解除でファイルもラベルも消える [RG-06]")
    func unregisterCascades() async throws {
        let f = try await Fixture.make()
        _ = try await f.files.upsert(f.snapshot(inode: 1, path: "a.cbz"))
        try await f.libraries.unregister(id: f.libraryID, keepLabels: false)
        #expect(try await f.libraries.libraries().isEmpty)
        #expect(try await f.libraries.totalFileCount() == 0)
    }

    /// **`protectedToken` は `ownerKind`／`ownerID` の多相参照なので外部キー
    /// 制約を張れず、`library` を消しても連鎖しない** [PT-08]。実際、解除の
    /// 経路にだけ削除が無く、登録・解除のたびに孤児が 3 件ずつ積み上がって
    /// いた（実ストアで 12 ライブラリ分・36 件を実測）。
    ///
    /// **`PRAGMA foreign_key_check` はこれを検出しない**ので、件数で見張る。
    @Test("登録解除で保護文字列も消える（多相参照は連鎖しない）[PT-08]")
    func unregisterRemovesProtectedTokens() async throws {
        let f = try await Fixture.make()
        let before = try await f.database.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM protectedToken") ?? 0
        }
        // テンプレート由来の既定が入っていること＝この検査が空振りしない前提。
        #expect(before > 0)

        try await f.libraries.unregister(id: f.libraryID, keepLabels: false)

        let after = try await f.database.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM protectedToken") ?? 0
        }
        #expect(after == 0)
    }

    /// 削除の範囲が広すぎないこと。`ownerID` で絞らずに消すと、1 つ解除した
    /// だけで**残っているライブラリの保護文字列まで失われる**——しかも
    /// 次のパースまで誰も気づけない。
    @Test("登録解除は他のライブラリの保護文字列に触れない [PT-08]")
    func unregisterKeepsOtherLibrariesTokens() async throws {
        let f = try await Fixture.make()
        let template = try #require(try BuiltInTemplates.libraryTypes().first)
        let other = try await f.libraries.register(
            LibraryRegistration(uuid: UUID(), displayName: "もう 1 つ", bookmarkData: Data(),
                                resolvedPath: "/tmp/other", volumeUUID: "VOL2",
                                libraryTypeID: LibraryTypeID(rawValue: 0)),
            template: template)
        let otherBefore = try await f.database.writer.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM protectedToken
                 WHERE ownerKind = 'library' AND ownerID = ?
                """, arguments: [other.rawValue]) ?? 0
        }
        #expect(otherBefore > 0)

        try await f.libraries.unregister(id: f.libraryID, keepLabels: false)

        let otherAfter = try await f.database.writer.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM protectedToken
                 WHERE ownerKind = 'library' AND ownerID = ?
                """, arguments: [other.rawValue]) ?? 0
        }
        #expect(otherAfter == otherBefore)
    }

    @Test("同じプリセットで 2 つ登録してもライブラリタイプは 1 つ [LT-10]")
    func presetTypeIsShared() async throws {
        let db = try QooDatabase.inMemory()
        let sets = try BuiltInTemplates.volumeSets()
        let template = try #require(try BuiltInTemplates.libraryTypes().first)
        let repo = SQLiteLibraryRepository(database: db, volumeSets: sets)
        for i in 0..<2 {
            _ = try await repo.register(
                LibraryRegistration(uuid: UUID(), displayName: "L\(i)", bookmarkData: Data(),
                                    resolvedPath: "/tmp/\(i)", volumeUUID: "V",
                                    libraryTypeID: LibraryTypeID(rawValue: 0)),
                template: template)
        }
        let types = try await db.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM libraryType") }
        #expect(types == 1)
    }
}

// MARK: - 同一性判定

@Suite("同一性判定 [ID-01〜ID-08]")
struct IdentityTests {
    @Test("(volumeUUID, inode) で引ける [ID-01][ID-02]")
    func findByIdentity() async throws {
        let f = try await Fixture.make()
        let id = try await f.files.upsert(f.snapshot(inode: 42, path: "作品.cbz"))
        #expect(try await f.files.find(identity: FileIdentity(volumeUUID: "VOL", inode: 42)) == id)
        #expect(try await f.files.find(identity: FileIdentity(volumeUUID: "VOL", inode: 43)) == nil)
        // 別ボリュームの同じ inode は別物
        #expect(try await f.files.find(identity: FileIdentity(volumeUUID: "OTHER", inode: 42)) == nil)
    }

    @Test("同じ inode の再スキャンはパス・ファイル名の変化を追従更新する [ID-02]")
    func followsRename() async throws {
        let f = try await Fixture.make()
        let id = try await f.files.upsert(f.snapshot(inode: 1, path: "旧/古い名前.cbz"))
        let again = try await f.files.upsert(f.snapshot(inode: 1, path: "新/新しい名前.cbz"))
        #expect(again == id, "同じレコードが更新されるべき")
        let row = try #require(try await f.files.row(id: id))
        #expect(row.relativePath == "新/新しい名前.cbz")
        #expect(row.filename == "新しい名前.cbz")
        #expect(try await f.libraries.totalFileCount() == 1)
    }

    @Test("再照合の候補は確度の高い順に返る [ID-03][ID3-02]")
    func candidateOrdering() async throws {
        let f = try await Fixture.make()
        // ① 同一相対パス + 同一サイズ
        _ = try await f.files.upsert(f.snapshot(inode: 1, path: "A/作品.cbz", size: 100))
        // ② 同一ファイル名 + 同一サイズ（別パス）
        _ = try await f.files.upsert(f.snapshot(inode: 2, path: "B/作品.cbz", size: 100))
        // ③ 同一ファイル名のみ（サイズ違い）
        _ = try await f.files.upsert(f.snapshot(inode: 3, path: "C/作品.cbz", size: 999))

        let probe = f.snapshot(inode: 99, path: "A/作品.cbz", size: 100)
        let candidates = try await f.files.findCandidates(for: probe)
        #expect(candidates.map(\.confidence) == [.pathAndSize, .nameAndSize, .nameOnly])
    }

    @Test("自分自身は候補に含めない")
    func selfIsNotACandidate() async throws {
        let f = try await Fixture.make()
        let s = f.snapshot(inode: 1, path: "作品.cbz")
        _ = try await f.files.upsert(s)
        #expect(try await f.files.findCandidates(for: s).isEmpty)
    }

    @Test("inode を差し替えても紐づけたラベルは残る [ID-04]")
    func reidentifyKeepsLabels() async throws {
        let f = try await Fixture.make()
        let id = try await f.files.upsert(f.snapshot(inode: 1, path: "作品.cbz"))
        let field = try #require(try await f.labels.field(libraryID: f.libraryID, index: 2))
        let label = try await f.labels.ensureLabel(fieldID: field.id, name: "サークルA")
        try await f.labels.assign(fileID: id, labelID: label)

        try await f.files.reidentify(id, to: FileIdentity(volumeUUID: "VOL", inode: 777))
        #expect(try await f.files.find(identity: FileIdentity(volumeUUID: "VOL", inode: 777)) == id)
        #expect(try await f.labels.labelIDs(fileID: id) == [label])
    }

    @Test("観測されなかったレコードは孤立にする。削除しない [ID-06][ID3-04]")
    func unseenBecomesOrphaned() async throws {
        let f = try await Fixture.make()
        let kept = try await f.files.upsert(f.snapshot(inode: 1, path: "残る.cbz"))
        let gone = try await f.files.upsert(f.snapshot(inode: 2, path: "消えた.cbz"))
        let changed = try await f.files.markUnseenAsOrphaned(
            libraryID: f.libraryID, scope: .library, seen: [kept])
        #expect(changed == 1)
        #expect(try await f.files.row(id: gone)?.state == .orphaned)
        #expect(try await f.files.row(id: kept)?.state == .active)
        #expect(try await f.libraries.totalFileCount() == 2, "削除してはいけない")
    }

    @Test("孤立の判定はフォルダスコープを尊重する [SY-06]")
    func orphanScope() async throws {
        let f = try await Fixture.make()
        let inScope = try await f.files.upsert(f.snapshot(inode: 1, path: "A/中.cbz"))
        let outOfScope = try await f.files.upsert(f.snapshot(inode: 2, path: "B/外.cbz"))
        _ = try await f.files.markUnseenAsOrphaned(
            libraryID: f.libraryID, scope: .folder(path: "A", recursive: true), seen: [])
        #expect(try await f.files.row(id: inScope)?.state == .orphaned)
        #expect(try await f.files.row(id: outOfScope)?.state == .active)
    }

    @Test("孤立から復帰した再スキャンは active へ戻す [TR-05]")
    func orphanRecovers() async throws {
        let f = try await Fixture.make()
        let id = try await f.files.upsert(f.snapshot(inode: 1, path: "作品.cbz"))
        try await f.files.setState(.orphaned, ids: [id])
        _ = try await f.files.upsert(f.snapshot(inode: 1, path: "作品.cbz"))
        #expect(try await f.files.row(id: id)?.state == .active)
    }

    @Test("ゴミ箱レコードは期限まで保持し、過ぎたら消す [TR-01][TR-06]")
    func trashRetention() async throws {
        let f = try await Fixture.make()
        let old = try await f.files.upsert(f.snapshot(inode: 1, path: "古い.cbz"))
        let recent = try await f.files.upsert(f.snapshot(inode: 2, path: "最近.cbz"))
        let now = Date()
        try await f.files.markTrashed([old], at: now.addingTimeInterval(-40 * 86_400))
        try await f.files.markTrashed([recent], at: now.addingTimeInterval(-1 * 86_400))
        let purged = try await f.files.purgeExpiredTrashed(retentionDays: 30, now: now)
        #expect(purged == 1)
        #expect(try await f.files.row(id: old) == nil)
        #expect(try await f.files.row(id: recent)?.state == .trashed)
    }

    @Test("バッチ投入は 1 トランザクションで通る [HP2-02]")
    func batchUpsert() async throws {
        let f = try await Fixture.make()
        let ids = try await f.files.upsertBatch((1...500).map {
            f.snapshot(inode: UInt64($0), path: "作品\($0).cbz")
        })
        #expect(ids.count == 500)
        #expect(Set(ids).count == 500)
        #expect(try await f.libraries.totalFileCount() == 500)
    }
}
