//
//  ファイル保管庫が使うリポジトリ API [FA-04][FA-05][FAW-01][FAW-05][FDA-01]。
//
//  保管庫の出入りは**ラベルの非正規化件数を必ず変える** [DB-02][FA-05] ——
//  `fileCount` は「生きていて保管庫にも入っていない」ファイルだけを数えるため。
//  2-14 で `state` について同じ穴を見つけているので、ここを重点的に固定する。
//
import Testing
import Foundation
import GRDB
import QooKit
@testable import QooPersistence

@Suite("ファイル保管庫のリポジトリ [FA-04][FA-05][FAW-01]")
struct FileVaultRepositoryTests {

    struct Setup {
        let f: Fixture
        let file: FileID
        let label: LabelID

        /// ラベルの付いたファイルを 1 件持つ状態。
        static func make(path: String = "A/作品名A 第01巻.cbz") async throws -> Setup {
            let f = try await Fixture.make()
            let file = try await f.files.upsert(f.snapshot(inode: 1, path: path))
            let group = try #require(try await f.labels.group(libraryID: f.libraryID, index: 2))
            let label = try await f.labels.ensureLabel(groupID: group.id, name: "サークル値A")
            try await f.labels.assign(fileID: file, labelID: label, origin: .auto)
            return Setup(f: f, file: file, label: label)
        }

        func fileCount() async throws -> Int {
            let groups = try await f.labels.groups(libraryID: f.libraryID)
            for group in groups {
                let labels = try await f.labels.labels(groupID: group.id, includeArchived: true)
                if let hit = labels.first(where: { $0.id == label }) { return hit.fileCount }
            }
            return -1
        }

        func archive(to path: String, at date: Date = Date()) async throws {
            let row = try #require(try await f.files.row(id: file))
            try await f.files.setArchived(
                [VaultMove(id: file, relativePath: path,
                           previousPath: row.relativePath, archivedAt: date)],
                archived: true)
        }
    }

    // MARK: - 出入りの記録 [FA-04][FA-05]

    @Test("保管庫へ入れると印・元パス・日時が入る [FA-04][FA-05][FAW-05]")
    func archivingRecordsOriginAndTime() async throws {
        let s = try await Setup.make()
        let when = Date(timeIntervalSinceReferenceDate: 12345)
        try await s.archive(to: ".qooarchive/A/作品名A 第01巻.cbz", at: when)

        let rows = try await s.f.files.archivedFiles(libraryID: s.f.libraryID)
        #expect(rows.count == 1)
        #expect(rows[0].row.relativePath == ".qooarchive/A/作品名A 第01巻.cbz")
        #expect(rows[0].row.isArchived)
        #expect(rows[0].archivedFromPath == "A/作品名A 第01巻.cbz")
        #expect(rows[0].archivedAt == when)
        #expect(rows[0].labelCount == 1)
    }

    @Test("保管庫から出すと記録を消す")
    func restoringClearsTheRecord() async throws {
        let s = try await Setup.make()
        try await s.archive(to: ".qooarchive/A/作品名A 第01巻.cbz")

        try await s.f.files.setArchived(
            [VaultMove(id: s.file, relativePath: "A/作品名A 第01巻.cbz",
                       previousPath: ".qooarchive/A/作品名A 第01巻.cbz")],
            archived: false)

        #expect(try await s.f.files.archivedFiles(libraryID: s.f.libraryID).isEmpty)
        let row = try #require(try await s.f.files.row(id: s.file))
        #expect(!row.isArchived)
        #expect(row.relativePath == "A/作品名A 第01巻.cbz")
        // 残っていると、次に入れ直したときに古い出どころが混ざる。
        let raw = try await s.f.database.writer.read { db in
            try Row.fetchOne(db, sql: "SELECT archivedFromPath, archivedAt FROM managedFile WHERE id = ?",
                             arguments: [s.file.rawValue])
        }
        #expect(raw?["archivedFromPath"] == nil as String?)
        #expect(raw?["archivedAt"] == nil as Double?)
    }

    // MARK: - ラベル件数 [DB-02][FA-05]

    @Test("保管庫へ入れるとラベル件数から外れる [FA-05][DB-02]")
    func archivingRemovesTheFileFromLabelCounts() async throws {
        let s = try await Setup.make()
        #expect(try await s.fileCount() == 1)

        try await s.archive(to: ".qooarchive/A/作品名A 第01巻.cbz")
        #expect(try await s.fileCount() == 0)
    }

    @Test("保管庫から出すとラベル件数へ戻る [FA-05][DB-02]")
    func restoringPutsTheFileBackIntoLabelCounts() async throws {
        let s = try await Setup.make()
        try await s.archive(to: ".qooarchive/A/作品名A 第01巻.cbz")
        #expect(try await s.fileCount() == 0)

        try await s.f.files.setArchived(
            [VaultMove(id: s.file, relativePath: "A/作品名A 第01巻.cbz",
                       previousPath: ".qooarchive/A/作品名A 第01巻.cbz")],
            archived: false)
        #expect(try await s.fileCount() == 1)
    }

    // MARK: - 一覧 [FAW-01]

    @Test("保管庫にある行だけを返す [FAW-01]")
    func listsOnlyArchivedRows() async throws {
        let s = try await Setup.make()
        _ = try await s.f.files.upsert(s.f.snapshot(inode: 2, path: "A/作品名A 第02巻.cbz"))
        try await s.archive(to: ".qooarchive/A/作品名A 第01巻.cbz")

        let rows = try await s.f.files.archivedFiles(libraryID: s.f.libraryID)
        #expect(rows.map(\.id) == [s.file])
    }

    @Test("ゴミ箱の行は保管庫の一覧に出さない [TR-02]")
    func excludesTrashedRows() async throws {
        let s = try await Setup.make()
        try await s.archive(to: ".qooarchive/A/作品名A 第01巻.cbz")
        try await s.f.files.markTrashed([s.file], at: Date())

        #expect(try await s.f.files.archivedFiles(libraryID: s.f.libraryID).isEmpty)
        #expect(try await s.f.files.archivedFileCounts()[s.f.libraryID] == nil)
    }

    @Test("ライブラリごとの件数を 1 問い合わせで返す")
    func countsPerLibrary() async throws {
        let s = try await Setup.make()
        #expect(try await s.f.files.archivedFileCounts().isEmpty)
        try await s.archive(to: ".qooarchive/A/作品名A 第01巻.cbz")
        #expect(try await s.f.files.archivedFileCounts()[s.f.libraryID] == 1)
    }

    @Test("元のフォルダは記録が無ければ現在のパスから導く [FA-03]")
    func originalFolderFallsBackToTheCurrentPath() async throws {
        let f = try await Fixture.make()
        // 外部（Finder 等）で `.qooarchive` へ入れられた形——走査が印だけ立てる。
        let id = try await f.files.upsert(
            f.snapshot(inode: 9, path: ".qooarchive/B/作品名B 第01巻.cbz"))
        let rows = try await f.files.archivedFiles(libraryID: f.libraryID)
        #expect(rows.map(\.id) == [id])
        #expect(rows[0].archivedFromPath == nil)
        #expect(rows[0].originalFolder == "B")
    }

    // MARK: - 走査が印を書く [SY-10]

    @Test("走査は `.qooarchive` 配下を保管庫として取り込む [SY-10]")
    func scanMarksFilesInsideTheVault() async throws {
        let f = try await Fixture.make()
        let id = try await f.files.upsert(
            f.snapshot(inode: 5, path: ".qooarchive/A/作品名A 第03巻.cbz"))
        let row = try #require(try await f.files.row(id: id))
        #expect(row.isArchived)
    }

    @Test("外部で保管庫から出されたら、走査で印が外れてラベル件数へ戻る [SY-10][DB-02]")
    func scanFollowsTheFileOutOfTheVault() async throws {
        let s = try await Setup.make()
        try await s.archive(to: ".qooarchive/A/作品名A 第01巻.cbz")
        #expect(try await s.fileCount() == 0)

        // 同じ inode のまま外の場所で観測された＝外で動かされた。
        _ = try await s.f.files.upsertBatch(
            [s.f.snapshot(inode: 1, path: "A/作品名A 第01巻.cbz")])

        let row = try #require(try await s.f.files.row(id: s.file))
        #expect(!row.isArchived)
        #expect(try await s.fileCount() == 1)
    }

    @Test("外部で保管庫へ入れられたら、走査で印が付いてラベル件数から外れる [SY-10][DB-02]")
    func scanFollowsTheFileIntoTheVault() async throws {
        let s = try await Setup.make()
        #expect(try await s.fileCount() == 1)

        _ = try await s.f.files.upsertBatch(
            [s.f.snapshot(inode: 1, path: ".qooarchive/A/作品名A 第01巻.cbz")])

        let row = try #require(try await s.f.files.row(id: s.file))
        #expect(row.isArchived)
        #expect(try await s.fileCount() == 0)
    }

    // MARK: - フォルダ配下の引き当て [FDA-01]

    @Test("フォルダ配下は成分の境界で切る [FDA-01]")
    func filesUnderRespectsComponentBoundaries() async throws {
        let f = try await Fixture.make()
        let inside = try await f.files.upsert(f.snapshot(inode: 1, path: "A/B/x.cbz"))
        // **`a/bc` は `a/b` の配下ではない。** 素の `hasPrefix` では拾ってしまう。
        _ = try await f.files.upsert(f.snapshot(inode: 2, path: "A/BC/y.cbz"))
        _ = try await f.files.upsert(f.snapshot(inode: 3, path: "Z/z.cbz"))

        let found = try await f.files.filesUnder(libraryID: f.libraryID, folderRelativePath: "A/B")
        #expect(found == [inside: "A/B/x.cbz"])
    }

    @Test("フォルダ自身の行も含める（ブックフォルダ）[IF-01][FDA-01]")
    func filesUnderIncludesTheFolderRowItself() async throws {
        let f = try await Fixture.make()
        // ブックフォルダは 1 冊 = 1 行で、`relativePath` はフォルダそのもの。
        let book = try await f.files.upsert(f.snapshot(inode: 1, path: "A/作品名A 第01巻"))
        let found = try await f.files.filesUnder(libraryID: f.libraryID,
                                                 folderRelativePath: "A/作品名A 第01巻")
        #expect(found == [book: "A/作品名A 第01巻"])
    }

    @Test("フォルダ名に含まれる LIKE のワイルドカードを打ち消す")
    func filesUnderEscapesLikeWildcards() async throws {
        let f = try await Fixture.make()
        let inside = try await f.files.upsert(f.snapshot(inode: 1, path: "10%_OFF/x.cbz"))
        _ = try await f.files.upsert(f.snapshot(inode: 2, path: "10ZZOFF/y.cbz"))

        let found = try await f.files.filesUnder(libraryID: f.libraryID,
                                                 folderRelativePath: "10%_OFF")
        #expect(found == [inside: "10%_OFF/x.cbz"])
    }
}
