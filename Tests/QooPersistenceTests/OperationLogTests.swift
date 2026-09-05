//
//  操作履歴ストア [HS-01〜HS-04][OH-01〜OH-06][15章 §15.13]。
//
//  **最も壊れやすいのは「消えない」という約束**——掃除は保持期間と件数の
//  上限だけが行い、それ以外に行が減る経路があってはならない
//  （`OperationLogStore` の型コメント参照）。
//
import Foundation
import Testing
import QooKit
@testable import QooPersistence

@Suite("操作履歴ストア [HS-01][OH-02]")
struct OperationLogTests {

    private func store() throws -> SQLiteOperationLogStore {
        SQLiteOperationLogStore(database: try QooDatabase.inMemory())
    }

    private func draft(_ summary: String,
                       kind: OperationLogKind = .executed,
                       commandName: String = "MoveFilesCommand",
                       targets: [String] = [],
                       libraryUUID: UUID? = nil,
                       detail: String? = nil,
                       date: Date = Date()) -> OperationLogDraft {
        OperationLogDraft(date: date, commandName: commandName, kind: kind,
                          targets: targets, libraryUUID: libraryUUID,
                          summary: summary, detail: detail)
    }

    // MARK: - 記録の範囲

    @Test("種別を問わずすべて記録する [HS-01、ユーザー判断 2026-09]")
    func everyKindIsRecorded() async throws {
        let store = try store()
        for kind in OperationLogKind.allCases {
            try await store.append(draft("x", kind: kind))
        }
        let rows = try await store.query(OperationLogFilter())
        #expect(rows.count == OperationLogKind.allCases.count)
    }

    @Test("往復で全項目が保たれる")
    func roundTripPreservesEveryField() async throws {
        let store = try store()
        let uuid = UUID()
        let when = Date(timeIntervalSince1970: 1_700_000_000)
        try await store.append(draft("「A.cbz」を移動", kind: .undonePartially,
                                     commandName: "MoveFilesCommand",
                                     targets: ["/Volumes/X/A.cbz", "/Volumes/X/B.cbz"],
                                     libraryUUID: uuid, detail: "成功 1 件 / 失敗 1 件",
                                     date: when))
        let row = try #require(try await store.query(OperationLogFilter()).first)
        #expect(row.summary == "「A.cbz」を移動")
        #expect(row.kind == .undonePartially)
        #expect(row.commandName == "MoveFilesCommand")
        #expect(row.targets == ["/Volumes/X/A.cbz", "/Volumes/X/B.cbz"])
        #expect(row.libraryUUID == uuid)
        #expect(row.detail == "成功 1 件 / 失敗 1 件")
        #expect(abs(row.date.timeIntervalSince(when)) < 0.001)
        #expect(row.truncatedTargets == 0)
    }

    @Test("日時の降順で返る")
    func newestFirst() async throws {
        let store = try store()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        try await store.append(draft("古い", date: base))
        try await store.append(draft("新しい", date: base.addingTimeInterval(60)))
        let rows = try await store.query(OperationLogFilter())
        #expect(rows.map(\.summary) == ["新しい", "古い"])
    }

    // MARK: - 対象の上限

    /// **一括リネーム 1 万件を 1 行に畳む**ので、対象を全部持つと 1 行が
    /// 数 MB になる。切り落とした件数は残して「一部である」と分かるようにする。
    @Test("対象は上限で切り、切った件数を残す")
    func targetsAreTruncatedAndCounted() async throws {
        let store = try store()
        let limit = AppLimits.Operations.maxTargetsPerEntry
        let many = (0..<(limit + 7)).map { "/Volumes/X/\($0).cbz" }
        try await store.append(draft("大量", targets: many))
        let row = try #require(try await store.query(OperationLogFilter()).first)
        #expect(row.targets.count == limit)
        #expect(row.truncatedTargets == 7)
        // 先頭から残す（末尾を残すと「最初に何をしたか」が読めない）。
        #expect(row.targets.first == "/Volumes/X/0.cbz")
    }

    // MARK: - 絞り込み [OH-02]

    @Test("種別の区画で絞れる")
    func filtersByGroup() async throws {
        let store = try store()
        try await store.append(draft("実行", kind: .executed))
        try await store.append(draft("やり直し", kind: .redone))
        try await store.append(draft("取り消し", kind: .undone))
        try await store.append(draft("失敗", kind: .failed))
        // `.executed` の区画には `.redone` も入る（どちらも「実行した」）。
        let executed = try await store.query(OperationLogFilter(group: .executed))
        #expect(Set(executed.map(\.summary)) == ["実行", "やり直し"])
        let undone = try await store.query(OperationLogFilter(group: .undone))
        #expect(undone.map(\.summary) == ["取り消し"])
    }

    /// **中断は失敗と同じ区画に入れない**——ユーザー自身の意思であって
    /// 失敗ではない（`CommandStack.isCancellation` と同じ線引き）。
    @Test("中断は失敗と別の区画")
    func cancellationIsNotAFailure() async throws {
        let store = try store()
        try await store.append(draft("中断", kind: .cancelled))
        try await store.append(draft("失敗", kind: .failed))
        #expect(try await store.query(OperationLogFilter(group: .unsuccessful))
            .map(\.summary) == ["失敗"])
        #expect(try await store.query(OperationLogFilter(group: .cancelled))
            .map(\.summary) == ["中断"])
    }

    @Test("期間で絞れる")
    func filtersByPeriod() async throws {
        let store = try store()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        try await store.append(draft("内", date: base))
        try await store.append(draft("外", date: base.addingTimeInterval(-86_400)))
        let period = DateInterval(start: base.addingTimeInterval(-60),
                                  end: base.addingTimeInterval(60))
        #expect(try await store.query(OperationLogFilter(period: period))
            .map(\.summary) == ["内"])
    }

    /// **全角で打っても半角に当たる** [1-16 の実測]。SQL の `LIKE` では
    /// 表せないので Swift 側（`NameFilter`）で判定している。
    @Test("キーワードは幅に依存しない [OH-02]")
    func keywordIsWidthInsensitive() async throws {
        let store = try store()
        try await store.append(draft("「STUDIO abc」を移動"))
        #expect(try await store.query(OperationLogFilter(keyword: "ＡＢＣ")).count == 1)
        #expect(try await store.query(OperationLogFilter(keyword: "xyz")).isEmpty)
    }

    /// **対象のパスも検索対象**——「あのファイルに何をしたか」を探すのが、
    /// この画面を開く主な動機のひとつ。
    @Test("対象のパスでも検索できる")
    func keywordMatchesTargets() async throws {
        let store = try store()
        try await store.append(draft("移動", targets: ["/Volumes/X/作品名A.cbz"]))
        #expect(try await store.query(OperationLogFilter(keyword: "作品名A")).count == 1)
    }

    // MARK: - 掃除 [HS-04]

    @Test("期限切れを落とす")
    func purgesByAge() async throws {
        let store = try store()
        try await store.append(draft("古い", date: Date().addingTimeInterval(-100 * 86_400)))
        try await store.append(draft("新しい"))
        try await store.purgeExpired(retentionDays: 90, maxCount: 0)
        #expect(try await store.query(OperationLogFilter()).map(\.summary) == ["新しい"])
    }

    @Test("上限超過を落とす（新しいほうを残す）")
    func purgesByCount() async throws {
        let store = try store()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        for i in 0..<5 {
            try await store.append(draft("\(i)", date: base.addingTimeInterval(Double(i))))
        }
        try await store.purgeExpired(retentionDays: 0, maxCount: 2)
        #expect(try await store.query(OperationLogFilter()).map(\.summary) == ["4", "3"])
    }

    /// **`0` 以下は「無制限」。** 環境設定で選べるので、素直に 0 を渡すと
    /// 全件消える実装になっていないことを固定する。
    @Test("0 以下の上限では 1 件も消さない")
    func zeroMeansUnlimited() async throws {
        let store = try store()
        try await store.append(draft("古い", date: Date().addingTimeInterval(-1000 * 86_400)))
        try await store.purgeExpired(retentionDays: 0, maxCount: 0)
        #expect(try await store.count() == 1)
    }

    // MARK: - 壊れた行への耐性

    /// **壊れた JSON でも行そのものは捨てない。** 内容と日時は列にあるので、
    /// 対象を失っても「いつ何をしたか」は読める。
    @Test("壊れた対象 JSON でも行は残る")
    func brokenTargetsJSONKeepsTheRow() async throws {
        let database = try QooDatabase.inMemory()
        let store = SQLiteOperationLogStore(database: database)
        try await store.append(draft("壊す", targets: ["/a"]))
        try await database.writer.write { db in
            try db.execute(sql: "UPDATE operationLog SET targetsJSON = '{壊れている'")
        }
        let row = try #require(try await store.query(OperationLogFilter()).first)
        #expect(row.summary == "壊す")
        #expect(row.targets.isEmpty)
    }

    /// 未知の種別も**捨てない**——行を落とすと「いつ何をしたか」が丸ごと消える。
    @Test("未知の種別は実行として読む")
    func unknownKindFallsBackToExecuted() async throws {
        let database = try QooDatabase.inMemory()
        let store = SQLiteOperationLogStore(database: database)
        try await store.append(draft("未知"))
        try await database.writer.write { db in
            try db.execute(sql: "UPDATE operationLog SET kind = 'somethingNew'")
        }
        let row = try #require(try await store.query(OperationLogFilter()).first)
        #expect(row.kind == .executed)
        #expect(row.summary == "未知")
    }
}

@Suite("操作履歴の CSV [OH-02]")
struct OperationLogCSVTests {

    private func entry(_ summary: String, targets: [String] = [],
                       detail: String? = nil,
                       truncated: Int = 0) -> OperationLogEntry {
        OperationLogEntry(id: OperationLogID(rawValue: 1),
                          date: Date(timeIntervalSince1970: 0),
                          commandName: "X", kind: .executed, targets: targets,
                          libraryUUID: nil, summary: summary, detail: detail,
                          truncatedTargets: truncated)
    }

    /// **切り落としを書き出しにも出す**［レビューで発見］。画面には
    /// 「ほか N 件」が出るのに CSV に無いと、**残った分が全件のように読める**
    /// ——棚卸しに使う書き出しでそれは危うい。
    @Test("切り落とした件数を詳細に書く")
    func writesTruncationNote() {
        let data = OperationLogCSV.encode(
            [entry("一括", targets: ["/a"], detail: "元の詳細", truncated: 950)],
            header: ["日時", "種別", "内容", "対象", "詳細"],
            kindName: { $0.rawValue }, dateFormatter: { _ in "2026-01-01" },
            truncationNote: { "ほか \($0) 件" })
        let text = String(decoding: data.dropFirst(3), as: UTF8.self)
        #expect(text.contains("元の詳細"))
        #expect(text.contains("ほか 950 件"))
    }

    /// **BOM を付ける**——付けないと Excel が UTF-8 と判定せず日本語が化ける。
    @Test("BOM 付きで書き出す")
    func startsWithBOM() {
        let data = OperationLogCSV.encode([entry("a")], header: ["日時", "種別", "内容", "対象", "詳細"],
                                          kindName: { $0.rawValue },
                                          dateFormatter: { _ in "2026-01-01" },
                                          truncationNote: { "ほか \($0) 件" })
        #expect(data.prefix(3) == Data([0xEF, 0xBB, 0xBF]))
    }

    /// **CSV には対象を全部書く**——画面の列は読みやすさのために畳むが、
    /// 書き出しは棚卸しに使うものなので省略しない。
    @Test("対象を省略せずに書く")
    func writesEveryTarget() {
        let data = OperationLogCSV.encode(
            [entry("移動", targets: ["/a/1.cbz", "/a/2.cbz"])],
            header: ["日時", "種別", "内容", "対象", "詳細"],
            kindName: { $0.rawValue }, dateFormatter: { _ in "2026-01-01" },
            truncationNote: { "ほか \($0) 件" })
        let text = String(decoding: data.dropFirst(3), as: UTF8.self)
        #expect(text.contains("/a/1.cbz"))
        #expect(text.contains("/a/2.cbz"))
    }
}

@Suite("CSV の共通書式 [NW-07][OH-02]")
struct CSVDocumentTests {
    @Test("引用符・カンマ・改行を囲む（RFC 4180）")
    func escaping() {
        #expect(CSVDocument.escape("素") == "素")
        #expect(CSVDocument.escape("a,b") == "\"a,b\"")
        #expect(CSVDocument.escape("a\"b") == "\"a\"\"b\"")
        #expect(CSVDocument.escape("a\nb") == "\"a\nb\"")
    }

    @Test("見出しだけでも行末は CRLF")
    func headerOnly() {
        let data = CSVDocument.encode(header: ["a", "b"], rows: [])
        #expect(String(decoding: data.dropFirst(3), as: UTF8.self) == "a,b\r\n")
    }
}
