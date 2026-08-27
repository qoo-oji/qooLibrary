import Foundation
import GRDB
import QooKit
import Testing
@testable import QooPersistence

//
//  重複グループ化を 5 万件で測る [PF-01〜PF-05][C-07]。
//
//  **窓関数で畳むことが、素の一覧と比べてどれだけ高くつくかは測るまで
//  分からない。** T-03 で「`LabelIndex` を作らない」と決めたときと同じで、
//  推測ではなく実測で判断する。
//

@Suite("重複グループの性能 [PF-01][DU-04]", .serialized)
struct DuplicatePerformanceTests {

    /// **実測（この機、5 万件・重複 1 万組）**:
    /// 素の一覧 6.6 ms / タイトルで畳む 199 ms / 巻数まで見る 217 ms /
    /// 重複のみ 163 ms。
    ///
    /// 畳むと素の一覧の 30 倍かかる——`COUNT(*) OVER` と `ROW_NUMBER()` が
    /// 区画全体を見るので `LIMIT` を先に効かせられず、ページを送るたびに
    /// 全件を処理するため。**グループ化は既定で無効** [DU-01] なので、
    /// 費用を払うのは自分で有効にした利用者だけである。
    ///
    /// 途中で 298 ms だったのを 199 ms にしたのは、総数を
    /// `SELECT COUNT(*) FROM (…)` で**別に数えていて窓関数を 2 回走らせて
    /// いた**のを、`COUNT(*) OVER ()` で同じ走査に畳んだため。
    @Test("5 万件のグループ化した一覧が 500ms 以内 [PF-01][DU-04]")
    func groupingAtScale() async throws {
        let f = try await Fixture.make(preset: "builtin.doujinshi-a")

        // 5 万件。タイトルは 4 万種で、**1 万件が誰かと重複する**——
        // 実蔵書に近い「ほとんどは 1 件、ときどき 2〜3 件」の形にする。
        let total = 50_000
        let distinct = 40_000
        var produced = 0
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
                           volumeNumber = ?, volumeKind = 'numeric' WHERE id = ?
                    """)
                for (k, id) in ids.enumerated() {
                    let i = base + k
                    let t = "作品タイトル\(i % distinct)"
                    try stmt.execute(arguments: [t, t, Double(i % 12 + 1), id.rawValue])
                }
            }
            produced += batch
        }

        var plain = FileQuery(libraryID: f.libraryID)
        plain.limit = 200
        let plainMS = try await PersistencePerformanceTests.measure("(h) 素の一覧（畳まない）") {
            _ = try await f.files.query(plain)
        }

        var grouped = plain
        grouped.grouping = .byTitle
        let groupedMS = try await PersistencePerformanceTests.measure("(i) タイトルで畳む") {
            _ = try await f.files.query(grouped)
        }

        var withVolume = plain
        withVolume.grouping = .byTitleAndVolume
        let volumeMS = try await PersistencePerformanceTests.measure("(j) タイトル＋巻数で畳む") {
            _ = try await f.files.query(withVolume)
        }

        var only = grouped
        only.duplicatesOnly = true
        let onlyMS = try await PersistencePerformanceTests.measure("(k) 重複のみを表示") {
            let page = try await f.files.query(only)
            FileHandle.standardError.write(Data(
                "  [perf]    → 重複グループ \(page.totalCount) 組\n".utf8))
        }

        _ = plainMS
        #expect(groupedMS < 500, "グループ化した一覧 [PF-01]")
        #expect(volumeMS < 500, "巻数まで見ても [PF-01]")
        #expect(onlyMS < 500, "重複のみ [DU-11]")
    }
}
