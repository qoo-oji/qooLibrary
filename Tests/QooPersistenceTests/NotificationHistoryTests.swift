//
//  通知履歴ストア [NT-01〜NT-07][NW-03][NW-05][NW-06][02章 §2.4]。
//
//  **未読の定義（強度 4 以上）が最も壊れやすい。** ここを緩めると、シートを
//  目の前で閉じた直後にバッジが立ち、「まだ見ていないものがある」という
//  バッジの意味そのものが失われる——本当に見てほしいときに読み飛ばされる。
//
import Foundation
import Testing
import QooKit
@testable import QooPersistence

@Suite("通知履歴ストア [NT-01][NW-05]")
struct NotificationHistoryTests {

    private func store() throws -> SQLiteNotificationHistoryStore {
        SQLiteNotificationHistoryStore(database: try QooDatabase.inMemory())
    }

    private func item(_ title: String,
                      category: NotificationItem.Category = .warning,
                      severity: NotificationSeverity = .transient,
                      target: NotificationTarget? = nil,
                      body: String = "",
                      technicalDetail: String? = nil,
                      actions: [RecoveryAction] = [],
                      date: Date = Date()) -> NotificationItem {
        NotificationItem(date: date, category: category, severity: severity, target: target,
                         title: title, body: body, technicalDetail: technicalDetail,
                         actions: actions)
    }

    // MARK: - 記録の範囲 [NT-01、ユーザー判断 2026-08]

    @Test("強度を問わずすべて記録する")
    func everySeverityIsRecorded() async throws {
        let store = try store()
        for severity in NotificationSeverity.allCases {
            try await store.append(item("強度\(severity.rawValue)", severity: severity))
        }
        let rows = try await store.query(NotificationHistoryFilter())
        #expect(rows.count == NotificationSeverity.allCases.count)
    }

    @Test("未読に数えるのは強度 4 以上だけ [NT-02]")
    func onlyTransientAndWeakerCountAsUnread() async throws {
        let store = try store()
        for severity in NotificationSeverity.allCases {
            try await store.append(item("x", severity: severity))
        }
        // `.transient`(4) と `.logOnly`(5) の 2 件だけ。
        #expect(try await store.unreadCount() == 2)
    }

    /// **一覧の太字とバッジは同じ判定を使う** [NW-03][NT-02]。`isRead` だけで
    /// 太字にすると、記録は全強度なので**シートを閉じた行まで太字**になり、
    /// 一方「すべて既読にする」はバッジが 0 のとき無効になる——画面が
    /// 太字だらけなのにボタンが押せない、という食い違いが出る。
    @Test("シートは未読として太字にならない [NW-03]")
    func sheetsAreNeverShownAsUnread() async throws {
        let store = try store()
        try await store.append(item("シート", severity: .sheet))
        try await store.append(item("一時通知", severity: .transient))
        let rows = try await store.query(NotificationHistoryFilter())
        #expect(rows.first { $0.title == "シート" }?.isUnread == false)
        #expect(rows.first { $0.title == "一時通知" }?.isUnread == true)
    }

    /// **未知の強度は SQL の判定と食い違わせない**［レビューで発見］。
    /// `unreadCount()` は生の数値を `severity >= 4` で数えるので、Swift 側で
    /// 一律に倒すと「バッジは立っているのに一覧では太字にならない」という、
    /// 原因の分かりにくい食い違いになる。
    @Test("未知の強度でもバッジと一覧が一致する")
    func anUnknownSeverityAgreesBetweenSQLAndSwift() async throws {
        let store = try store()
        try await store.database.writer.write { db in
            try db.execute(sql: """
                INSERT INTO notificationRecord (date, category, severity, title, body, isRead)
                VALUES (?, 'warning', 99, '未知', '', 0)
                """, arguments: [Date().timeIntervalSince1970])
        }
        let rows = try await store.query(NotificationHistoryFilter())
        #expect(try await store.unreadCount() == 1)
        #expect(rows.first?.isUnread == true)
    }

    // MARK: - 対象と導線 [NT-04][NT-05]

    @Test("対象と技術詳細が往復する")
    func targetAndDetailSurviveARoundTrip() async throws {
        let store = try store()
        let uuid = UUID()
        try await store.append(item(
            "題", target: .library(uuid: uuid, name: "蔵書A"),
            technicalDetail: "errno=28"))
        let row = try #require(try await store.query(NotificationHistoryFilter()).first)
        #expect(row.target?.libraryUUID == uuid)
        #expect(row.target?.displayName == "蔵書A")
        #expect(row.technicalDetail == "errno=28")
    }

    /// **`.openWindow` 以外は写さない。** 「再試行」は当時の文脈（どのファイルを、
    /// どの設定で）を失っているので、後から履歴で押しても意味を持たない。
    @Test("導線として残るのは `.openWindow` だけ [NT-05]")
    func onlyOpenWindowActionsBecomeLinks() async throws {
        let store = try store()
        try await store.append(item("題", actions: [
            RecoveryAction(id: "retry", title: "再試行", kind: .retry),
            RecoveryAction(id: "go", title: "整理する…", kind: .openWindow("go")),
            RecoveryAction(id: "close", title: "閉じる", kind: .dismiss),
        ]))
        let row = try #require(try await store.query(NotificationHistoryFilter()).first)
        #expect(row.links.map(\.actionID) == ["go"])
        #expect(row.links.first?.title == "整理する…")
    }

    /// **壊れた JSON でも行そのものは捨てない。** 題と本文は列にあるので、
    /// 対象と導線を失っても「いつ何が起きたか」は読める。
    @Test("payload が壊れていても行は読める")
    func aBrokenPayloadStillYieldsTheRow() throws {
        let record = NotificationRecord(id: 7, date: 0, category: "error", severity: 2,
                                        targetJSON: "{ これは JSON ではない",
                                        title: "題", body: "本文", isRead: false,
                                        operationLogID: nil)
        let row = try #require(SQLiteNotificationHistoryStore.stored(from: record))
        #expect(row.title == "題")
        #expect(row.target == nil)
        #expect(row.links.isEmpty)
    }

    // MARK: - 絞り込み [NW-05][NW-01]

    @Test("区分で絞る")
    func filtersByCategory() async throws {
        let store = try store()
        try await store.append(item("e", category: .error))
        try await store.append(item("w", category: .warning))
        try await store.append(item("i", category: .info))
        let rows = try await store.query(NotificationHistoryFilter(category: .error))
        #expect(rows.map(\.title) == ["e"])
    }

    @Test("期間で絞る")
    func filtersByPeriod() async throws {
        let store = try store()
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
        try await store.append(item("古い", date: now.addingTimeInterval(-10_000)))
        try await store.append(item("新しい", date: now))
        let period = DateInterval(start: now.addingTimeInterval(-100),
                                  end: now.addingTimeInterval(100))
        let rows = try await store.query(NotificationHistoryFilter(period: period))
        #expect(rows.map(\.title) == ["新しい"])
    }

    @Test("対象ライブラリで絞る [NW-01]")
    func filtersByLibrary() async throws {
        let store = try store()
        let a = UUID(), b = UUID()
        try await store.append(item("A", target: .library(uuid: a, name: "蔵書A")))
        try await store.append(item("B", target: .library(uuid: b, name: "蔵書B")))
        try await store.append(item("無関係"))
        let rows = try await store.query(NotificationHistoryFilter(libraryUUID: a))
        #expect(rows.map(\.title) == ["A"])
    }

    /// **全角で打っても半角に当たる。** このアプリ全体の約束 [1-16 の実測] で、
    /// SQL の `LIKE` では表せないため Swift 側（`NameFilter`）で判定している。
    @Test("キーワードは幅を区別しない [NW-05]")
    func keywordSearchIsWidthInsensitive() async throws {
        let store = try store()
        try await store.append(item("スキャン結果", body: "unresolved が 3 件"))
        let rows = try await store.query(NotificationHistoryFilter(keyword: "ＵＮＲＥＳＯＬＶＥＤ"))
        #expect(rows.count == 1)
    }

    @Test("キーワードは対象名にも当たる")
    func keywordSearchesTheTargetName() async throws {
        let store = try store()
        try await store.append(item("題", target: .library(uuid: UUID(), name: "蔵書A")))
        #expect(try await store.query(NotificationHistoryFilter(keyword: "蔵書A")).count == 1)
    }

    @Test("新しい順に返す")
    func returnsNewestFirst() async throws {
        let store = try store()
        let base = Date(timeIntervalSinceReferenceDate: 0)
        try await store.append(item("1", date: base))
        try await store.append(item("2", date: base.addingTimeInterval(60)))
        let rows = try await store.query(NotificationHistoryFilter())
        #expect(rows.map(\.title) == ["2", "1"])
    }

    // MARK: - 既読 [NW-03]

    @Test("選んだものだけ既読にする")
    func marksOnlyTheGivenRowsRead() async throws {
        let store = try store()
        try await store.append(item("A"))
        try await store.append(item("B"))
        let rows = try await store.query(NotificationHistoryFilter())
        try await store.markRead([rows[0].id])
        #expect(try await store.unreadCount() == 1)
    }

    @Test("すべて既読にする")
    func marksEverythingRead() async throws {
        let store = try store()
        for i in 0..<3 { try await store.append(item("\(i)")) }
        try await store.markAllRead()
        #expect(try await store.unreadCount() == 0)
    }

    // MARK: - 削除 [NW-06]

    @Test("選んだものを削除する")
    func deletesSelected() async throws {
        let store = try store()
        try await store.append(item("A"))
        try await store.append(item("B"))
        let rows = try await store.query(NotificationHistoryFilter())
        try await store.delete([rows[0].id])
        #expect(try await store.query(NotificationHistoryFilter()).map(\.title) == ["A"])
    }

    @Test("すべて削除する")
    func deletesAll() async throws {
        let store = try store()
        for i in 0..<3 { try await store.append(item("\(i)")) }
        try await store.deleteAll()
        #expect(try await store.query(NotificationHistoryFilter()).isEmpty)
    }

    // MARK: - 掃除 [NT-07]

    @Test("保持期間を過ぎたものを落とす")
    func purgesByAge() async throws {
        let store = try store()
        try await store.append(item("古い", date: Date().addingTimeInterval(-40 * 86_400)))
        try await store.append(item("新しい"))
        try await store.purgeExpired(retentionDays: 30, maxCount: 0)
        #expect(try await store.query(NotificationHistoryFilter()).map(\.title) == ["新しい"])
    }

    @Test("上限を超えたぶんは古いものから落とす")
    func purgesByCount() async throws {
        let store = try store()
        let base = Date(timeIntervalSinceReferenceDate: 0)
        for i in 0..<5 {
            try await store.append(item("\(i)", date: base.addingTimeInterval(Double(i) * 60)))
        }
        try await store.purgeExpired(retentionDays: 0, maxCount: 2)
        #expect(try await store.query(NotificationHistoryFilter()).map(\.title) == ["4", "3"])
    }

    /// **期限と件数の両方を見る。** 片方だけだと、1 日で 1 万件出た日は期限では
    /// 減らず、逆に静かな月は上限に触れないまま何年分も溜まる。
    @Test("`0` 以下はその条件を無効にする")
    func zeroDisablesEachLimit() async throws {
        let store = try store()
        try await store.append(item("古い", date: Date().addingTimeInterval(-400 * 86_400)))
        try await store.purgeExpired(retentionDays: 0, maxCount: 0)
        #expect(try await store.query(NotificationHistoryFilter()).count == 1)
    }
}

// MARK: - CSV [NW-07]

@Suite("通知履歴の CSV 書き出し [NW-07]")
struct NotificationCSVTests {

    private func row(title: String, body: String = "", target: String? = nil) -> StoredNotification {
        StoredNotification(id: NotificationID(rawValue: 1),
                           date: Date(timeIntervalSinceReferenceDate: 0),
                           category: .warning, severity: .transient,
                           target: target.map { NotificationTarget(libraryName: $0) },
                           title: title, body: body, technicalDetail: nil,
                           links: [], isRead: false)
    }

    private func text(_ rows: [StoredNotification]) -> String {
        let data = NotificationCSV.encode(rows, header: ["日時", "区分", "対象", "件名", "本文", "詳細"],
                                          categoryName: { _ in "警告" },
                                          dateFormatter: { _ in "2001-01-01 00:00:00" })
        return String(decoding: data, as: UTF8.self)
    }

    /// **BOM を付ける。** 付けないと Excel が UTF-8 と判定せず日本語が化ける
    /// ——利用者が最初に開くのはたいてい表計算である。
    @Test("先頭に BOM が付く")
    func startsWithABOM() {
        let data = NotificationCSV.encode([], header: ["a"], categoryName: { _ in "" },
                                          dateFormatter: { _ in "" })
        #expect(Array(data.prefix(3)) == [0xEF, 0xBB, 0xBF])
    }

    @Test("カンマ・引用符・改行を含む値を囲む")
    func quotesFieldsThatNeedIt() {
        #expect(NotificationCSV.escape("素") == "素")
        #expect(NotificationCSV.escape("a,b") == "\"a,b\"")
        #expect(NotificationCSV.escape("a\"b") == "\"a\"\"b\"")
        #expect(NotificationCSV.escape("a\nb") == "\"a\nb\"")
    }

    @Test("見出しと本文が並ぶ")
    func writesHeaderAndRows() {
        let output = text([row(title: "題", body: "本文", target: "蔵書A")])
        #expect(output.contains("日時,区分,対象,件名,本文,詳細\r\n"))
        #expect(output.contains("2001-01-01 00:00:00,警告,蔵書A,題,本文,\r\n"))
    }
}
