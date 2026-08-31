import Foundation
import GRDB
import QooKit
import Testing
@testable import QooPersistence

//
//  重複グループの問い合わせ [DU-01〜DU-06][DU-11][DU-13]。
//
//  **SQL の窓関数と Swift の `DuplicateSelection` は同じ規則を 2 通りに
//  書いている。** 食い違うと、一覧に出る代表と比較ビューの並びが噛み合わない
//  ——このスイートがその一致を固定する。
//

@Suite("重複グループの問い合わせ [DU-01〜DU-06][DU-11]")
struct DuplicateGroupingQueryTests {

    /// タイトルを与えてファイルを 1 件作る。
    @discardableResult
    private func add(_ f: Fixture, inode: UInt64, path: String,
                     title: String?, volume: VolumeValue = .none,
                     size: Int64 = 1000, rating: Int = 0) async throws -> FileID {
        let id = try await f.files.upsert(f.snapshot(inode: inode, path: path, size: size))
        if let title {
            try await f.files.setFields(
                FileFieldEdit(title: title, seriesName: nil,
                              volume: volume, authorName: nil), id: id, protectedScopes: [])
        }
        if rating > 0 { try await f.files.setRating(rating, ids: [id]) }
        return id
    }

    private func query(_ f: Fixture, _ mode: DuplicateGrouping,
                       duplicatesOnly: Bool = false) -> FileQuery {
        var q = FileQuery(libraryID: f.libraryID)
        q.grouping = mode
        q.duplicatesOnly = duplicatesOnly
        return q
    }

    // MARK: - 畳み方

    @Test("既定（off）では 1 件も畳まない [DU-01]")
    func offShowsEveryFile() async throws {
        let f = try await Fixture.make()
        try await add(f, inode: 1, path: "a.cbz", title: "作品名A")
        try await add(f, inode: 2, path: "b.cbz", title: "作品名A")
        let page = try await f.files.query(query(f, .off))
        #expect(page.totalCount == 2)
        #expect(page.duplicateCounts.isEmpty)
    }

    @Test("同じタイトルが 1 行に畳まれ、件数が付く [DU-02][DU-06]")
    func byTitleFoldsIntoOneRowWithACount() async throws {
        let f = try await Fixture.make()
        try await add(f, inode: 1, path: "a.cbz", title: "作品名A")
        try await add(f, inode: 2, path: "b.cbz", title: "作品名A")
        try await add(f, inode: 3, path: "c.cbz", title: "別の作品")

        let page = try await f.files.query(query(f, .byTitle))
        #expect(page.totalCount == 2, "2 グループ（作品名A と 別の作品）")
        #expect(page.rows.count == 2)
        let counts = page.duplicateCounts
        #expect(counts.count == 1, "重複しているのは 1 組だけ")
        #expect(counts.values.first == 2)
    }

    @Test("巻数まで見ると別の巻は別グループになる [DU-02]")
    func byTitleAndVolumeSeparatesVolumes() async throws {
        let f = try await Fixture.make()
        try await add(f, inode: 1, path: "v1a.cbz", title: "作品名A",
                      volume: .numeric(1, raw: "第01巻"))
        try await add(f, inode: 2, path: "v1b.cbz", title: "作品名A",
                      volume: .numeric(1, raw: "第01巻"))
        try await add(f, inode: 3, path: "v2.cbz", title: "作品名A",
                      volume: .numeric(2, raw: "第02巻"))

        #expect(try await f.files.query(query(f, .byTitle)).totalCount == 1)
        #expect(try await f.files.query(query(f, .byTitleAndVolume)).totalCount == 2)
    }

    /// **この検査がいちばん重要。**
    ///
    /// SQLite の `PARTITION BY` は NULL どうしを同じ区画と見なすので、素の
    /// `titleKey` で区切ると**タイトルを取れなかったファイル全部が 1 つの
    /// グループに畳まれ、1 行を残して画面から消える**。未解決ファイル
    /// [AL-30] は蔵書によっては数千件あるので、静かな大量消失になる。
    @Test("タイトルの無いファイルは 1 件も畳まれない [DU-02]")
    func filesWithoutATitleAreNeverFolded() async throws {
        let f = try await Fixture.make()
        for i in 1...5 {
            try await add(f, inode: UInt64(i), path: "謎\(i).cbz", title: nil)
        }
        for mode in [DuplicateGrouping.byTitle, .byTitleAndVolume] {
            let page = try await f.files.query(query(f, mode))
            #expect(page.totalCount == 5, "\(mode): 5 件とも残る")
            #expect(page.duplicateCounts.isEmpty, "\(mode): 重複扱いされない")
        }
    }

    @Test("「重複のみを表示」は 2 件以上の組だけを残す [DU-11]")
    func duplicatesOnlyKeepsGroupsOfTwoOrMore() async throws {
        let f = try await Fixture.make()
        try await add(f, inode: 1, path: "a.cbz", title: "作品名A")
        try await add(f, inode: 2, path: "b.cbz", title: "作品名A")
        try await add(f, inode: 3, path: "c.cbz", title: "ひとりだけ")
        try await add(f, inode: 4, path: "d.cbz", title: nil)

        let page = try await f.files.query(query(f, .byTitle, duplicatesOnly: true))
        #expect(page.totalCount == 1)
        #expect(page.rows.first?.title == "作品名A")
    }

    @Test("保管庫のファイルはグループに数えない [DU-13]")
    func archivedFilesAreExcluded() async throws {
        let f = try await Fixture.make()
        let a = try await add(f, inode: 1, path: "a.cbz", title: "作品名A")
        try await add(f, inode: 2, path: "b.cbz", title: "作品名A")
        _ = a
        var page = try await f.files.query(query(f, .byTitle, duplicatesOnly: true))
        #expect(page.totalCount == 1, "はじめは 2 件の組")

        try await f.database.writer.write { db in
            try db.execute(sql: "UPDATE managedFile SET isArchived = 1 WHERE id = ?",
                           arguments: [a.rawValue])
        }
        page = try await f.files.query(query(f, .byTitle, duplicatesOnly: true))
        #expect(page.totalCount == 0, "1 件だけになったので組ではなくなる")
    }

    // MARK: - 代表の決定が Swift と一致する [DU-05][DU-08]

    @Test("評価・サイズ・自然順が SQL 側でも同じ順で効く [DU-05]")
    func representativeMatchesTheSwiftRule() async throws {
        let f = try await Fixture.make()
        // 評価も大きさも同じにして、**自然順だけ**で決まる状況を作る。
        try await add(f, inode: 1, path: "作品名A 第10巻.cbz", title: "作品名A")
        try await add(f, inode: 2, path: "作品名A 第2巻.cbz", title: "作品名A")

        let page = try await f.files.query(query(f, .byTitle))
        #expect(page.rows.first?.filename == "作品名A 第2巻.cbz",
                "素の BINARY 照合なら 第10巻 が先に来てしまう")
    }

    @Test("評価はサイズより優先される [DU-05]")
    func ratingBeatsSizeInSQLToo() async throws {
        let f = try await Fixture.make()
        try await add(f, inode: 1, path: "大きい.cbz", title: "作品名A", size: 999_999)
        try await add(f, inode: 2, path: "評価あり.cbz", title: "作品名A", size: 1, rating: 4)

        let page = try await f.files.query(query(f, .byTitle))
        #expect(page.rows.first?.filename == "評価あり.cbz")
    }

    /// SQL が選んだ代表と、Swift が同じ行から選ぶ代表が一致すること。
    /// **2 通りに書いた規則が噛み合っていることの直接の確認。**
    @Test("SQL と DuplicateSelection が同じ代表を選ぶ [DU-05]")
    func sqlAndSwiftAgreeOnTheRepresentative() async throws {
        let f = try await Fixture.make()
        let names = ["作品名A 第2巻.cbz", "作品名A 第10巻.cbz", "作品名A 第1巻.cbz",
                     "作品名A 序章.cbz"]
        for (i, n) in names.enumerated() {
            try await add(f, inode: UInt64(i + 1), path: n, title: "作品名A")
        }
        let sqlPick = try await f.files.query(query(f, .byTitle)).rows.first
        // 同じ母集団を素で取り直して Swift 側の規則を当てる。
        var all = FileQuery(libraryID: f.libraryID)
        all.grouping = .off
        let everyRow = try await f.files.query(all).rows
        let swiftPick = DuplicateSelection.representative(of: everyRow)
        #expect(sqlPick?.id == swiftPick?.id)
    }
}
