//
//  通知履歴ウインドウのモデル [NW-01〜NW-06][NT-02]。
//
//  **既読の粒度がいちばん壊れやすい。** ウインドウを開いただけで全部既読に
//  すると、同じ NW-03 が並べて要求する「すべて既読にする」が意味を失い、
//  「どれをまだ見ていなかったか」がこの画面を開いた瞬間に消える。
//
import Foundation
import Testing
import QooKit
@testable import QooApplication

@MainActor
@Suite("通知履歴モデル [NW-01〜NW-06]")
struct NotificationHistoryModelTests {

    private func row(_ id: Int64, title: String = "題",
                     isRead: Bool = false) -> StoredNotification {
        StoredNotification(id: NotificationID(rawValue: id),
                           date: Date(timeIntervalSinceReferenceDate: Double(id)),
                           category: .warning, severity: .transient, target: nil,
                           title: title, body: "", technicalDetail: nil,
                           links: [], isRead: isRead)
    }

    private func item(_ title: String,
                      severity: NotificationSeverity = .transient) -> NotificationItem {
        NotificationItem(category: .warning, severity: severity, title: title, body: "")
    }

    private func prepared(_ titles: [String]) async throws
        -> (NotificationHistoryModel, FakeNotificationHistoryStore) {
        let store = FakeNotificationHistoryStore()
        for title in titles { try await store.append(item(title)) }
        let model = NotificationHistoryModel(router: NotificationRouter())
        await model.prepare(store: store, libraries: [])
        return (model, store)
    }

    // MARK: - 期間 [NW-05]

    /// **「今日」の終わりは明日の 0 時。** `now` にすると、判定した瞬間より
    /// あとに届いた通知が同じ絞り込みから外れる。
    @Test("今日は 0 時から翌 0 時まで")
    func todayCoversTheWholeDay() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Asia/Tokyo"))
        let now = try #require(calendar.date(from: DateComponents(
            year: 2026, month: 8, day: 27, hour: 13, minute: 45)))
        let interval = try #require(NotificationHistoryModel.Period.today
            .interval(now: now, calendar: calendar))
        #expect(interval.start == calendar.startOfDay(for: now))
        #expect(interval.duration == 86_400)
        // 判定より後に届いた通知も入る。
        #expect(interval.contains(now.addingTimeInterval(3_600)))
    }

    @Test("過去 7 日は今日を含む 7 日間")
    func last7DaysIncludesToday() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Asia/Tokyo"))
        let now = try #require(calendar.date(from: DateComponents(
            year: 2026, month: 8, day: 27, hour: 13)))
        let interval = try #require(NotificationHistoryModel.Period.last7Days
            .interval(now: now, calendar: calendar))
        #expect(interval.duration == 7 * 86_400)
        #expect(interval.contains(now))
    }

    @Test("すべては期間で絞らない")
    func allMeansNoPeriod() {
        #expect(NotificationHistoryModel.Period.all.interval() == nil)
    }

    // MARK: - 詳細 [NW-04]

    /// **1 件だけ選ばれているときに限る。** 複数選んでいるのは削除のためで、
    /// そのうちどれかの詳細を見たいわけではない。
    @Test("詳細は単一選択のときだけ出す")
    func detailOnlyForASingleSelection() {
        let rows = [row(1, title: "A"), row(2, title: "B")]
        #expect(NotificationHistoryModel.detail(in: rows, selection: [])?.title == nil)
        #expect(NotificationHistoryModel.detail(in: rows,
                                                selection: [NotificationID(rawValue: 2)])?.title == "B")
        #expect(NotificationHistoryModel.detail(
            in: rows, selection: [NotificationID(rawValue: 1), NotificationID(rawValue: 2)]) == nil)
    }

    // MARK: - 空状態の出し分け

    /// **「履歴が無い」と「一致しない」は次の一手が違う。**
    @Test("絞り込みの有無を見分ける")
    func knowsWhetherAFilterIsActive() async throws {
        let (model, _) = try await prepared([])
        #expect(!model.isFiltering)
        model.keyword = "  "          // 空白だけは絞り込みではない
        #expect(!model.isFiltering)
        model.keyword = "エラー"
        #expect(model.isFiltering)
        model.keyword = ""
        model.category = .error
        #expect(model.isFiltering)
    }

    // MARK: - 既読 [NW-03]

    /// **選んだ行だけ既読にする。** ウインドウを開いただけでは既読にしない。
    @Test("選択した行だけ既読になる")
    func marksOnlyTheSelectedRowRead() async throws {
        let (model, store) = try await prepared(["A", "B"])
        #expect(model.rows.count == 2)
        let target = try #require(model.rows.first)
        model.selection = [target.id]
        await model.markSelectedRead()

        #expect(try await store.unreadCount() == 1)
        // 手元の行にも当てる——読み直しに任せると一覧が作り直され、
        // スクロール位置と選択が跳ねる。
        #expect(model.rows.first { $0.id == target.id }?.isRead == true)
    }

    @Test("すべて既読にする")
    func marksEverythingRead() async throws {
        let (model, store) = try await prepared(["A", "B", "C"])
        await model.markAllRead()
        #expect(try await store.unreadCount() == 0)
        // `#expect` の中に `rethrows` のクロージャを置けない（既知の罠）。
        let allRead = model.rows.allSatisfy { $0.isRead }
        #expect(allRead)
    }

    // MARK: - 削除 [NW-06]

    @Test("選択したものを削除し、選択を空にする")
    func deletesSelectedAndClearsTheSelection() async throws {
        let (model, _) = try await prepared(["A", "B"])
        model.selection = [try #require(model.rows.first).id]
        await model.deleteSelected()
        #expect(model.rows.count == 1)
        #expect(model.selection.isEmpty)
    }

    @Test("すべて削除する")
    func deletesAll() async throws {
        let (model, _) = try await prepared(["A", "B"])
        await model.deleteAll()
        #expect(model.rows.isEmpty)
    }

    /// 一覧から消えたものを選択に残さない——削除・絞り込みの変更のあと、
    /// 存在しない行を指したままの選択で操作すると何も起きない。
    @Test("読み直しで消えた選択を落とす")
    func dropsSelectionThatNoLongerExists() async throws {
        let (model, store) = try await prepared(["A"])
        let gone = try #require(model.rows.first).id
        try await store.deleteAll()
        model.selection = [gone]
        await model.reload()
        #expect(model.selection.isEmpty)
    }
}

/// 自動走査の知らせを繰り返さない番人 [NT-07][OR2-05][UR2-02]。
///
/// **`ScanSummary` の件数は差分ではない**ので、これが無いと恒久的に未解決な
/// ファイルを 1 つ含むフォルダへ変更があるたび、まったく同じ行が積み上がる。
@MainActor
@Suite("走査結果の重複記録の抑制 [NT-07]")
struct ScanFindingsDigestTests {
    private let library = LibraryID(rawValue: 1)
    private let other = LibraryID(rawValue: 2)

    private func findings(orphaned: Int = 0, unresolved: Int = 0,
                          released: Int = 0) -> ScanFindingsDigest.Findings {
        .init(orphaned: orphaned, unresolved: unresolved, bookFoldersReleased: released)
    }

    @Test("何も無ければ記録しない")
    func silentWhenNothingHappened() {
        let digest = ScanFindingsDigest()
        #expect(!digest.shouldRecord(findings(), for: library))
    }

    @Test("初めての知らせは記録する")
    func recordsTheFirstFinding() {
        let digest = ScanFindingsDigest()
        #expect(digest.shouldRecord(findings(unresolved: 1), for: library))
    }

    /// 差分走査は同じ未解決ファイルを毎回数え直す——2 度目以降は黙る。
    @Test("同じ内容が続く間は黙る")
    func staysSilentWhileNothingChanges() {
        let digest = ScanFindingsDigest()
        _ = digest.shouldRecord(findings(unresolved: 1), for: library)
        #expect(!digest.shouldRecord(findings(unresolved: 1), for: library))
        #expect(!digest.shouldRecord(findings(unresolved: 1), for: library))
    }

    @Test("内容が変われば記録する")
    func recordsWhenTheFindingsChange() {
        let digest = ScanFindingsDigest()
        _ = digest.shouldRecord(findings(unresolved: 1), for: library)
        #expect(digest.shouldRecord(findings(unresolved: 2), for: library))
        #expect(digest.shouldRecord(findings(orphaned: 1, unresolved: 2), for: library))
    }

    /// **「前回記録した内容」ではなく「前回観測した内容」と比べる。**
    /// 前者だと (1) → (0) → (1) の 3 度目が握り潰される——直ったあとに
    /// 同じ件数で再発したときに黙るのがいちばん困る。
    @Test("いったん解消してから同じ件数で再発したら記録する")
    func recordsAgainAfterTheFindingsCleared() {
        let digest = ScanFindingsDigest()
        #expect(digest.shouldRecord(findings(unresolved: 1), for: library))
        #expect(!digest.shouldRecord(findings(), for: library))   // 解消（記録はしない）
        #expect(digest.shouldRecord(findings(unresolved: 1), for: library))
    }

    @Test("ライブラリごとに独立している")
    func tracksEachLibrarySeparately() {
        let digest = ScanFindingsDigest()
        #expect(digest.shouldRecord(findings(orphaned: 1), for: library))
        #expect(digest.shouldRecord(findings(orphaned: 1), for: other))
    }

    @Test("忘れると次の 1 回は記録する")
    func forgettingRestoresTheFirstRecord() {
        let digest = ScanFindingsDigest()
        _ = digest.shouldRecord(findings(orphaned: 1), for: library)
        digest.forget(library)
        #expect(digest.shouldRecord(findings(orphaned: 1), for: library))
    }
}
