import Testing
import Foundation
import GRDB
import QooKit
@testable import QooPersistence

//
//  未解決ファイルの記録と整理 [AL-30〜AL-34][UR-01〜UR-06]。
//

@Suite("未解決ファイル [AL-31][AL-33][UR-01]")
struct UnresolvedRepositoryTests {

    private func seeded() async throws -> (Fixture, FileID, FileID) {
        let f = try await Fixture.make()
        let a = try await f.files.upsert(f.snapshot(inode: 1, path: "A/謎の名前1.cbz"))
        let b = try await f.files.upsert(f.snapshot(inode: 2, path: "A/謎の名前2.cbz"))
        try await f.files.syncUnresolved(
            unresolved: [.init(fileID: a, filename: "謎の名前1.cbz"),
                         .init(fileID: b, filename: "謎の名前2.cbz")],
            resolved: [], libraryID: f.libraryID, now: Date())
        return (f, a, b)
    }

    @Test("走査が未解決を記録し、解決したものは同じ呼び出しで消える [AL-31]")
    func syncRecordsAndRemoves() async throws {
        let (f, a, b) = try await seeded()
        #expect(try await f.files.unresolvedFiles(libraryID: f.libraryID,
                                                  includeIgnored: false).count == 2)

        // フォーマットを足して a だけ解決した、という次の走査。
        try await f.files.syncUnresolved(
            unresolved: [.init(fileID: b, filename: "謎の名前2.cbz")],
            resolved: [a], libraryID: f.libraryID, now: Date())
        let rest = try await f.files.unresolvedFiles(libraryID: f.libraryID, includeIgnored: false)
        #expect(rest.map(\.row.id) == [b])
    }

    @Test("同じ走査を 2 回流しても行は増えない（冪等）[FO-20]")
    func syncIsIdempotent() async throws {
        let (f, a, b) = try await seeded()
        try await f.files.syncUnresolved(
            unresolved: [.init(fileID: a, filename: "謎の名前1.cbz"),
                         .init(fileID: b, filename: "謎の名前2.cbz")],
            resolved: [], libraryID: f.libraryID, now: Date())
        #expect(try await f.files.unresolvedFiles(libraryID: f.libraryID,
                                                  includeIgnored: false).count == 2)
    }

    @Test("無視したものは一覧にも件数にも出ない [AL-33][UR2-04]")
    func ignoredIsHidden() async throws {
        let (f, a, _) = try await seeded()
        try await f.files.setUnresolvedIgnored([a], true)

        let visible = try await f.files.unresolvedFiles(libraryID: f.libraryID,
                                                        includeIgnored: false)
        #expect(visible.count == 1)
        #expect(try await f.files.unresolvedFileCounts()[f.libraryID]?.pending == 1)

        // **行は残す** [UR2-04]——消すと次の走査でまた未解決として現れる。
        let all = try await f.files.unresolvedFiles(libraryID: f.libraryID, includeIgnored: true)
        #expect(all.count == 2)
        #expect(all.first { $0.row.id == a }?.isIgnored == true)
    }

    @Test("名前が変わったら無視を解く [AL-33、ユーザー判断 2026-08]")
    func renameClearsIgnore() async throws {
        let (f, a, _) = try await seeded()
        try await f.files.setUnresolvedIgnored([a], true)

        // 利用者が名前を直したが、まだどのフォーマットにも当たらない。
        try await f.files.syncUnresolved(
            unresolved: [.init(fileID: a, filename: "直した名前.cbz")],
            resolved: [], libraryID: f.libraryID, now: Date())

        let visible = try await f.files.unresolvedFiles(libraryID: f.libraryID,
                                                        includeIgnored: false)
        #expect(visible.contains { $0.row.id == a })
    }

    @Test("名前が同じままなら無視は保つ（中身だけ差し替えた場合）[ID-13]")
    func replacementKeepsIgnore() async throws {
        let (f, a, _) = try await seeded()
        try await f.files.setUnresolvedIgnored([a], true)
        try await f.files.syncUnresolved(
            unresolved: [.init(fileID: a, filename: "謎の名前1.cbz")],
            resolved: [], libraryID: f.libraryID, now: Date())
        let visible = try await f.files.unresolvedFiles(libraryID: f.libraryID,
                                                        includeIgnored: false)
        #expect(!visible.contains { $0.row.id == a })
    }

    @Test("最初に検出した時刻は、名前が変わっても更新しない")
    func detectedAtIsTheFirstSighting() async throws {
        let (f, a, _) = try await seeded()
        let first = try #require(try await f.files
            .unresolvedFiles(libraryID: f.libraryID, includeIgnored: true)
            .first { $0.row.id == a }?.detectedAt)
        try await f.files.syncUnresolved(
            unresolved: [.init(fileID: a, filename: "別の名前.cbz")],
            resolved: [], libraryID: f.libraryID,
            now: first.addingTimeInterval(10_000))
        let again = try #require(try await f.files
            .unresolvedFiles(libraryID: f.libraryID, includeIgnored: true)
            .first { $0.row.id == a }?.detectedAt)
        #expect(abs(again.timeIntervalSince(first)) < 0.001)
    }

    @Test("見つからなくなったものは未解決一覧に出さない [OR-01 の担当]")
    func orphanedIsNotListed() async throws {
        let (f, a, _) = try await seeded()
        try await f.files.setState(.orphaned, ids: [a])

        let visible = try await f.files.unresolvedFiles(libraryID: f.libraryID,
                                                        includeIgnored: false)
        #expect(!visible.contains { $0.row.id == a })
        #expect(try await f.files.unresolvedFileCounts()[f.libraryID]?.pending == 1)
    }

    /// ファイル保管庫（2-11）はまだ無いので**列を直に書いて固定する**
    /// ——保管庫へ送ったファイルは蔵書の一覧から外れる [FA-05] のに、
    /// 未解決一覧にだけ残っていると「片付けたのに減らない」ことになる。
    @Test("保管庫へ送ったファイルは未解決一覧に出さない [FA-05]")
    func archivedIsNotListed() async throws {
        let (f, a, _) = try await seeded()
        try await f.database.writer.write { db in
            try db.execute(sql: """
                UPDATE managedFile SET isArchived = 1 WHERE id = ?
                """, arguments: [a.rawValue])
        }
        let visible = try await f.files.unresolvedFiles(libraryID: f.libraryID,
                                                        includeIgnored: true)
        #expect(!visible.contains { $0.row.id == a })
        #expect(try await f.files.unresolvedFileCounts()[f.libraryID]?.pending == 1)
    }

    @Test("ファイルの行を消すと記録も消える（ON DELETE CASCADE）")
    func deletingTheFileRemovesTheRecord() async throws {
        let (f, a, _) = try await seeded()
        try await f.files.deleteFiles([a])
        let count = try await f.database.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM unresolvedFile") ?? -1
        }
        #expect(count == 1)
    }

    /// 走査は 1 チャンク（`scanBatchSize`）ぶんしか渡さないが、再マッチング
    /// [AL-34] は**未解決の全件**を渡す——`unresolvedBulkThreshold`（500）を
    /// 超える状況はこの機能がまさに想定しているもの。区切りが無いと、ホスト
    /// 変数の上限が低いビルドで**再マッチングが丸ごと失敗する**。
    ///
    /// **区切りを外してもこのテストは通る**［既知の空振り、変異検証で確認］
    /// ——この環境の SQLite（3.51）は上限が 32,766 で 1,500 件では届かない。
    /// 壊れるのは上限の低いビルドと速度のほうなので、通ることを理由に
    /// 区切りを外さないこと（`setRating` / `matchingRelativePaths` と同じ事情）。
    @Test("埋め込みメタデータのキャッシュを 900 件超でも引ける（束縛変数の上限）")
    func metadataCacheHandlesMoreIDsThanTheParameterLimit() async throws {
        let f = try await Fixture.make()
        var ids: [FileID] = []
        for i in 1...1_500 {
            ids.append(try await f.files.upsert(f.snapshot(inode: UInt64(i), path: "A/\(i).cbz")))
        }
        try await f.files.saveEmbeddedMetadata(
            Dictionary(uniqueKeysWithValues: ids.map {
                ($0, EmbeddedMetadataCacheEntry(stamp: "s", metadata: nil))
            }))
        let cache = try await f.files.embeddedMetadataCache(ids: ids)
        #expect(cache.count == 1_500)
    }

    @Test("件数はライブラリごとに分かれ、無視したものと分けて返る [UR-02][AL-33]")
    func countsAreGroupedByLibrary() async throws {
        let (f, a, _) = try await seeded()
        #expect(try await f.files.unresolvedFileCounts()
                == [f.libraryID: UnresolvedCounts(pending: 2, ignored: 0)])

        // **無視したものは `pending` から外れ、`ignored` に移る。** 混ぜると
        // 空状態の文言が嘘になる（「すべて一致しています」と言ってしまう）。
        try await f.files.setUnresolvedIgnored([a], true)
        #expect(try await f.files.unresolvedFileCounts()
                == [f.libraryID: UnresolvedCounts(pending: 1, ignored: 1)])
    }

    @Test("900 件を超えても 1 回の呼び出しで記録できる（束縛変数の上限）")
    func handlesMoreRowsThanTheParameterLimit() async throws {
        let f = try await Fixture.make()
        var observations: [UnresolvedObservation] = []
        for i in 1...1_500 {
            let id = try await f.files.upsert(f.snapshot(inode: UInt64(i), path: "A/\(i).cbz"))
            observations.append(.init(fileID: id, filename: "\(i).cbz"))
        }
        try await f.files.syncUnresolved(unresolved: observations, resolved: [],
                                         libraryID: f.libraryID, now: Date())
        #expect(try await f.files.unresolvedFileCounts()[f.libraryID]?.pending == 1_500)

        // 削除側も同じ上限を越える。
        try await f.files.syncUnresolved(unresolved: [],
                                         resolved: observations.map(\.fileID),
                                         libraryID: f.libraryID, now: Date())
        #expect(try await f.files.unresolvedFileCounts()[f.libraryID]?.pending == nil)
    }
}
