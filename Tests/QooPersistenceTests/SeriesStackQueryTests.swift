import Foundation
import GRDB
import QooKit
import Testing
@testable import QooPersistence

//
//  シリーズスタックの問い合わせ [VM3-01〜VM3-06]。
//
//  **重複グループ化とは実装が違う**（窓関数ではなく `GROUP BY` ＋ 代表 id の
//  JOIN。理由と実測値は `seriesStackSubquery` の doc）ので、同じ性質を
//  改めて固定する必要がある——とくに「シリーズ名の無い本を畳まない」は、
//  破れると数千件が 1 行を残して画面から消える。
//

@Suite("シリーズスタックの問い合わせ [VM3-01〜VM3-06]")
struct SeriesStackQueryTests {

    @discardableResult
    private func add(_ f: Fixture, inode: UInt64, path: String,
                     title: String? = nil, series: String? = nil,
                     volume: VolumeValue = .none) async throws -> FileID {
        let id = try await f.files.upsert(f.snapshot(inode: inode, path: path))
        try await f.files.setFields(
            FileFieldEdit(title: title ?? (path as NSString).deletingPathExtension,
                          seriesName: series, volume: volume, authorName: nil),
            id: id, protectedScopes: [])
        return id
    }

    private func stacked(_ f: Fixture, series: String? = nil,
                         sort: FileQuery.SortSpec = .byFilename) -> FileQuery {
        var q = FileQuery(libraryID: f.libraryID)
        q.seriesStacking = true
        q.seriesName = series
        q.sort = sort
        return q
    }

    // MARK: - 畳み方

    @Test("同じシリーズが 1 行に畳まれ、冊数が付く [VM3-01][VM3-02]")
    func foldsIntoOneRowWithACount() async throws {
        let f = try await Fixture.make()
        try await add(f, inode: 1, path: "a1.cbz", series: "作品A", volume: .numeric(1, raw: "第01巻"))
        try await add(f, inode: 2, path: "a2.cbz", series: "作品A", volume: .numeric(2, raw: "第02巻"))
        try await add(f, inode: 3, path: "b1.cbz", series: "作品B", volume: .numeric(1, raw: "第01巻"))

        let page = try await f.files.query(stacked(f))
        #expect(page.totalCount == 2, "作品A（1 行）＋ 作品B（1 行）")
        #expect(page.rows.count == 2)
        let counts = page.groupCounts
        #expect(counts.count == 1, "2 冊以上の組だけが件数を持つ")
        #expect(counts.values.first == 2)
    }

    /// **これが破れると数千件が 1 行を残して消える。** SQLite の `GROUP BY` は
    /// NULL どうしを同じ組と見なすので、素の `seriesKey` で括ると
    /// シリーズ名の無い本が全部 1 スタックへ畳まれる。
    @Test("シリーズ名の無い本は畳まれない [VM3-04]")
    func booksWithoutASeriesAreNeverFolded() async throws {
        let f = try await Fixture.make()
        for i in 1...5 {
            try await add(f, inode: UInt64(i), path: "single\(i).cbz", series: nil)
        }
        // **シリーズを持つ本を 1 組だけ混ぜる。** これが無いと事前確認
        // [VM3S-04] が畳む形そのものを飛ばし、**この主張を一度も通らない**
        // ——「標本が主張の前提を満たしていない」型の空振りを、変異検証で
        // 実際に踏んだ（このリポジトリで 8 度目）。
        try await add(f, inode: 90, path: "s1.cbz", series: "本物のシリーズ", volume: .numeric(1, raw: "第01巻"))
        try await add(f, inode: 91, path: "s2.cbz", series: "本物のシリーズ", volume: .numeric(2, raw: "第02巻"))

        let page = try await f.files.query(stacked(f))
        #expect(page.totalCount == 6, "単体 5 件 ＋ スタック 1 件")
        #expect(page.groupCounts.count == 1, "畳まれるのはシリーズを持つ 1 組だけ")
        #expect(page.rows.filter { $0.seriesName == nil }.count == 5)
    }

    /// `TextNormalizer.normalize` は空白だけの入力を空文字へ畳む——手動編集で
    /// そこへ落ちた行を 1 つのシリーズとして括ってはならない。
    @Test("空白だけのシリーズ名も畳まれず、一覧からも消えない [VM3-04]")
    func blankSeriesNamesAreNeverFolded() async throws {
        let f = try await Fixture.make()
        try await add(f, inode: 1, path: "x.cbz", series: "   ")
        try await add(f, inode: 2, path: "y.cbz", series: "\t")
        // 上と同じ理由で、畳む形を実際に通すためにシリーズを 1 組混ぜる。
        try await add(f, inode: 90, path: "s1.cbz", series: "本物のシリーズ", volume: .numeric(1, raw: "第01巻"))
        try await add(f, inode: 91, path: "s2.cbz", series: "本物のシリーズ", volume: .numeric(2, raw: "第02巻"))

        let page = try await f.files.query(stacked(f))
        // **消えないことが要点。** 空文字を畳む側からも畳まない側からも
        // 外すと、その本は一覧から丸ごと落ちる。
        #expect(page.totalCount == 3, "空白 2 件 ＋ スタック 1 件")
        #expect(Set(page.rows.map(\.filename)).isSuperset(of: ["x.cbz", "y.cbz"]))
        #expect(page.groupCounts.count == 1)
    }

    @Test("1 冊だけのシリーズは件数を持たない（印を出さない）[VM3-04]")
    func aSingleVolumeSeriesCarriesNoCount() async throws {
        let f = try await Fixture.make()
        try await add(f, inode: 1, path: "only.cbz", series: "ひとりぼっち", volume: .numeric(1, raw: "第01巻"))
        let page = try await f.files.query(stacked(f))
        #expect(page.totalCount == 1)
        #expect(page.groupCounts.isEmpty)
    }

    // MARK: - 代表 [VM3-02]

    @Test("代表は巻数順の先頭 [VM3-02]")
    func representativeIsTheFirstVolume() async throws {
        let f = try await Fixture.make()
        // **わざと巻数順と逆の順で入れる**——挿入順や id 順で選んでいたら通らない。
        try await add(f, inode: 1, path: "z-third.cbz", series: "作品A", volume: .numeric(3, raw: "第03巻"))
        try await add(f, inode: 2, path: "a-second.cbz", series: "作品A", volume: .numeric(2, raw: "第02巻"))
        try await add(f, inode: 3, path: "m-first.cbz", series: "作品A", volume: .numeric(1, raw: "第01巻"))

        let page = try await f.files.query(stacked(f))
        #expect(page.rows.count == 1)
        #expect(page.rows.first?.filename == "m-first.cbz")
        #expect(page.rows.first?.volume == .numeric(1, raw: "第01巻"))
    }

    @Test("巻数を持たない本は代表の候補として後回しになる [VM3-02]")
    func volumelessBooksSortAfterNumberedOnes() async throws {
        let f = try await Fixture.make()
        try await add(f, inode: 1, path: "aaa-extra.cbz", series: "作品A", volume: .none)
        try await add(f, inode: 2, path: "zzz-vol5.cbz", series: "作品A", volume: .numeric(5, raw: "第05巻"))
        let page = try await f.files.query(stacked(f))
        #expect(page.rows.first?.filename == "zzz-vol5.cbz",
                "巻数を持つ本が先。ファイル名順なら aaa- が勝ってしまう")
    }

    /// **代表がちらつかないこと。** 巻数が同点のとき、合成鍵に id を混ぜて
    /// いなければ SQLite がどの行を返すかは仕様上決まらない——実行のたびに
    /// 代表が変われば一覧のカバーが入れ替わって見える。
    ///
    /// **［既知の空振り］この検査は「id を鍵から外す」変異を検出できない。**
    /// 同じ計画・同じデータなら SQLite は同じ行を返すため（`min()` が最初に
    /// 出会った行を採り、`mf_lib_series` の走査順は区画内で rowid 順）。
    /// **id の混ぜ込みは計画が変わったときへの保険**であって、今日観測できる
    /// 差ではない——索引が増えたり `ANALYZE` で統計が変わったりすれば
    /// 走査順は変わりうる。**通ることを理由に鍵から外さないこと**
    /// （`setRating` の 900 件区切りと同じ事情）。
    ///
    /// 代表の決め方そのもの（巻数の種別 → 巻数）は上の 2 つが固定しており、
    /// そちらは変異検証で検出できる。
    @Test("巻数が同点でも代表は決定的 [VM3-02]")
    func representativeIsDeterministicWhenVolumesTie() async throws {
        let f = try await Fixture.make()
        // **わざとファイル名の順と id の順を逆にする**——名前順で代表を
        // 選んでいたら tie6 が勝つ。
        for i in stride(from: 6, through: 1, by: -1) {
            try await add(f, inode: UInt64(7 - i), path: "tie\(i).cbz",
                          series: "作品A", volume: .none)
        }
        var seen = Set<String>()
        for _ in 0..<8 {
            let page = try await f.files.query(stacked(f))
            #expect(page.rows.count == 1)
            seen.insert(page.rows.first?.filename ?? "")
        }
        #expect(seen.count == 1, "代表が実行のたびに変わってはならない: \(seen)")
        // 鍵の末尾が id なので、同点なら**最小の id** が代表になる
        // （最初に入れた tie6.cbz）。
        #expect(seen == ["tie6.cbz"])
    }

    // MARK: - ドリルイン [VM3-03]

    @Test("シリーズ名で絞るとその巻だけが出る [VM3-03]")
    func drillingInShowsOnlyThatSeries() async throws {
        let f = try await Fixture.make()
        try await add(f, inode: 1, path: "a1.cbz", series: "作品A", volume: .numeric(1, raw: "第01巻"))
        try await add(f, inode: 2, path: "a2.cbz", series: "作品A", volume: .numeric(2, raw: "第02巻"))
        try await add(f, inode: 3, path: "b1.cbz", series: "作品B", volume: .numeric(1, raw: "第01巻"))

        var q = FileQuery(libraryID: f.libraryID)
        q.seriesName = "作品A"
        let page = try await f.files.query(q)
        #expect(page.totalCount == 2)
        #expect(Set(page.rows.map(\.filename)) == ["a1.cbz", "a2.cbz"])
    }

    /// **正規化は永続化層が導出する** [3.8 節]。呼び出し側に畳ませると同じ規則が
    /// 2 箇所に生まれ、規則が変わったときにドリルインだけが黙って空になる。
    @Test("シリーズ名の照合は正規化を通る [VM3-03]")
    func drillingInNormalizesTheName() async throws {
        let f = try await Fixture.make()
        try await add(f, inode: 1, path: "a1.cbz", series: "Comic A", volume: .numeric(1, raw: "第01巻"))

        var q = FileQuery(libraryID: f.libraryID)
        q.seriesName = "ＣＯＭＩＣ　Ａ"      // 全角・大文字・全角空白
        let page = try await f.files.query(q)
        #expect(page.totalCount == 1)
    }

    @Test("空白だけのシリーズ名では絞らない [VM3-03]")
    func aBlankSeriesNameDoesNotFilter() async throws {
        let f = try await Fixture.make()
        try await add(f, inode: 1, path: "a.cbz", series: nil)
        try await add(f, inode: 2, path: "b.cbz", series: nil)

        var q = FileQuery(libraryID: f.libraryID)
        q.seriesName = "   "
        let page = try await f.files.query(q)
        #expect(page.totalCount == 2, "空文字で絞ると、シリーズ名の無い本が全部対象になってしまう")
    }

    // MARK: - 費用の事前確認 [VM3-01、ユーザー判断]

    /// [実測] 畳む形にするだけで 53 ms かかるのに対し、この存在確認は 0.1 ms。
    /// プリセットがシリーズを取らないライブラリでは費用が完全にゼロになる。
    @Test("シリーズ名を持つ行が 0 件なら畳む経路を通らない [VM3-01]")
    func skipsFoldingWhenNoBookHasASeries() async throws {
        let f = try await Fixture.make()
        try await add(f, inode: 1, path: "a.cbz", series: nil)
        let hasSeries = try await f.database.writer.read { db in
            try SQLiteManagedFileRepository.hasAnySeries(db, libraryID: f.libraryID)
        }
        #expect(!hasSeries)

        try await add(f, inode: 2, path: "b.cbz", series: "作品A")
        let now = try await f.database.writer.read { db in
            try SQLiteManagedFileRepository.hasAnySeries(db, libraryID: f.libraryID)
        }
        #expect(now)
    }

    @Test("空白だけのシリーズ名は「シリーズあり」と数えない [VM3-01]")
    func blankSeriesDoesNotCountAsHavingASeries() async throws {
        let f = try await Fixture.make()
        try await add(f, inode: 1, path: "a.cbz", series: " ")
        let hasSeries = try await f.database.writer.read { db in
            try SQLiteManagedFileRepository.hasAnySeries(db, libraryID: f.libraryID)
        }
        #expect(!hasSeries)
    }

    // MARK: - 並び順 [VM3-04]

    @Test("タイトル順はシリーズ名と単体タイトルの混在ソートになる [VM3-04]")
    func titleSortMixesSeriesNamesAndStandaloneTitles() async throws {
        let f = try await Fixture.make()
        // スタック（シリーズ名 "B シリーズ"）の代表のタイトルは "Z" にしてある
        // ——代表のタイトルで並べていたら末尾へ行ってしまう。
        try await add(f, inode: 1, path: "s1.cbz", title: "Z", series: "B シリーズ", volume: .numeric(1, raw: "第01巻"))
        try await add(f, inode: 2, path: "s2.cbz", title: "Z2", series: "B シリーズ", volume: .numeric(2, raw: "第02巻"))
        try await add(f, inode: 3, path: "x.cbz", title: "A 単体", series: nil)
        try await add(f, inode: 4, path: "y.cbz", title: "C 単体", series: nil)

        let page = try await f.files.query(
            stacked(f, sort: FileQuery.SortSpec(key: .title, ascending: true)))
        #expect(page.rows.map { $0.seriesName ?? $0.title ?? "" }
                == ["A 単体", "B シリーズ", "C 単体"])
    }
}

