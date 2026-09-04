import Foundation
import GRDB
import QooKit
import Testing
@testable import QooPersistence

//
//  シリーズスタックを 5 万件で測る [PF-01][C-07][VM3-01]。
//
//  **重複グループ化と違い既定 ON** [VM3-05] なので、費用を払うのは
//  全利用者である——「有効にした人だけが払う」[DU-01] という言い訳が効かない。
//  この違いが実装を決めた（窓関数ではなく `GROUP BY` ＋ 代表 id の JOIN。
//  `seriesStackSubquery` の doc に実測表がある）。
//

@Suite("シリーズスタックの性能 [PF-01][VM3-01]", .serialized)
struct SeriesStackPerformanceTests {

    /// `seriesFilled` はシリーズ名を持つ行の割合。
    private static func corpus(total: Int, seriesFilled: Double,
                               booksPerSeries: Int) async throws -> Fixture {
        let f = try await Fixture.make(preset: "builtin.general-comic-a")
        var produced = 0
        let cutoff = Int(Double(total) * seriesFilled)
        while produced < total {
            let batch = min(500, total - produced)
            let ids = try await f.files.upsertBatch((0..<batch).map { k in
                let i = produced + k
                return f.snapshot(inode: UInt64(i + 1),
                                  path: "第\(i % 200)階層/作品\(i).cbz",
                                  size: Int64(i) * 977)
            })
            let base = produced
            try await f.database.writer.write { db in
                // 走査を 5 万回まわす代わりに列を直に埋める——測りたいのは
                // 問い合わせ側で、書き込み経路は別のテストが固定している。
                let stmt = try db.cachedStatement(sql: """
                    UPDATE managedFile SET title = ?, titleKey = ?,
                           seriesName = ?, seriesKey = ?,
                           volumeNumber = ?, volumeKind = ? WHERE id = ?
                    """)
                for (k, id) in ids.enumerated() {
                    let i = base + k
                    let t = "作品タイトル\(i)"
                    if i < cutoff {
                        let s = "シリーズ\(i / booksPerSeries)"
                        try stmt.execute(arguments: [t, t, s, s,
                                                     Double(i % booksPerSeries + 1), "numeric",
                                                     id.rawValue])
                    } else {
                        try stmt.execute(arguments: [t, t, nil, nil, nil, "none", id.rawValue])
                    }
                }
            }
            produced += batch
        }
        return f
    }

    /// **実測（この機、5 万件・Release）**:
    /// 素の一覧 4.4 ms ／ 窓関数で畳む 144.9 ms ／ **この実装（GROUP BY）29.1 ms**。
    /// 末尾ページ（offset 9,000）でも 30.0 ms で、窓関数の 150.4 ms と差が開く。
    ///
    /// 窓関数が高いのは `COUNT(*) OVER` と `ROW_NUMBER()` が区画全体を見るため
    /// `LIMIT` を先に効かせられないから [DU-04 の実測と同じ理由]。`GROUP BY` は
    /// 索引 `mf_lib_series`（v1 から存在）をそのまま使える。
    @Test("5 万件のスタック表示が 500ms 以内 [PF-01][VM3-01]")
    func stackingAtScale() async throws {
        let f = try await Self.corpus(total: 50_000, seriesFilled: 1.0, booksPerSeries: 5)

        var plain = FileQuery(libraryID: f.libraryID)
        plain.limit = 200
        _ = try await PersistencePerformanceTests.measure("(l) 素の一覧（畳まない）") {
            _ = try await f.files.query(plain)
        }

        var stacked = plain
        stacked.seriesStacking = true
        let stackedMS = try await PersistencePerformanceTests.measure("(m) シリーズで畳む") {
            let page = try await f.files.query(stacked)
            FileHandle.standardError.write(Data(
                "  [perf]    → スタック \(page.totalCount) 組\n".utf8))
        }

        var tail = stacked
        tail.offset = 9_000
        let tailMS = try await PersistencePerformanceTests.measure("(n) 末尾ページ") {
            _ = try await f.files.query(tail)
        }

        #expect(stackedMS < 500, "スタック表示 [PF-01]")
        #expect(tailMS < 500, "ページを送っても [PF-01][FI-05]")
    }

    /// **シリーズ名を持つ行が 1 件も無ければ畳む形そのものを通らない**
    /// [VM3-01、ユーザー判断]。プリセットがシリーズを取らないライブラリ
    /// （成年コミックなど [Stage 10 の調査]）が該当する。
    ///
    /// 畳む形を通すと [実測] 53 ms、通さなければ素の一覧と同じ 4 ms。
    /// 存在確認そのものは 0.1 ms。
    @Test("シリーズが 1 件も無いライブラリでは畳む費用を払わない [VM3-01]")
    func noSeriesMeansNoCost() async throws {
        let f = try await Self.corpus(total: 50_000, seriesFilled: 0.0, booksPerSeries: 5)

        var plain = FileQuery(libraryID: f.libraryID)
        plain.limit = 200
        let plainMS = try await PersistencePerformanceTests.measure("(o) 素の一覧") {
            _ = try await f.files.query(plain)
        }

        var stacked = plain
        stacked.seriesStacking = true
        let stackedMS = try await PersistencePerformanceTests.measure("(p) 畳む指定（実際は畳まない）") {
            let page = try await f.files.query(stacked)
            #expect(page.totalCount == 50_000)
            #expect(page.groupCounts.isEmpty)
        }

        // **素の一覧と同じ桁**であること。畳む形を通していれば 10 倍以上になる
        // （実測 4 ms 対 53 ms）。倍率で見るのは、機種差で絶対値が動くため。
        #expect(stackedMS < max(plainMS * 4, 20),
                "事前確認が効いていない: 素 \(plainMS) ms 対 畳む指定 \(stackedMS) ms")
    }
}
