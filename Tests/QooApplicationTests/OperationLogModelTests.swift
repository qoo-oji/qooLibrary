//
//  操作履歴ウインドウのモデル [OH-01〜OH-04][15章 §15.13]。
//
//  **判定をここで固定する。** 絞り込みの組み立て・期間の解釈・空状態の
//  出し分け・選択の後始末は View に書くと `swift test` から触れなくなる。
//
import Foundation
import QooKit
import Testing

@testable import QooApplication

/// 渡された絞り込みを覚えて、決まった行を返すだけのストア。
///
/// **本物の絞り込みは `SQLiteOperationLogStore` の側で試す**——ここで
/// 絞り込みまで真似ると、自分の偽物を試すだけになる。
final class StubOperationLogStore: OperationLogStore, @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [OperationLogFilter] = []
    private var canned: [OperationLogEntry]

    init(rows: [OperationLogEntry] = []) { canned = rows }

    var filters: [OperationLogFilter] { lock.lock(); defer { lock.unlock() }; return seen }

    func setRows(_ rows: [OperationLogEntry]) {
        lock.lock(); defer { lock.unlock() }
        canned = rows
    }

    func append(_ draft: OperationLogDraft) async throws -> OperationLogID {
        OperationLogID(rawValue: 0)
    }

    func query(_ filter: OperationLogFilter) async throws -> [OperationLogEntry] {
        querySync(filter)
    }

    private func querySync(_ filter: OperationLogFilter) -> [OperationLogEntry] {
        lock.lock(); defer { lock.unlock() }
        seen.append(filter)
        return canned
    }

    func count() async throws -> Int { 0 }
    func purgeExpired(retentionDays: Int, maxCount: Int) async throws {}
}

@MainActor
@Suite("操作履歴のモデル [OH-02][OH-04]")
struct OperationLogModelTests {

    private func entry(_ id: Int64, _ summary: String,
                       kind: OperationLogKind = .executed) -> OperationLogEntry {
        OperationLogEntry(id: OperationLogID(rawValue: id), date: Date(),
                          commandName: "X", kind: kind, targets: [],
                          libraryUUID: nil, summary: summary, detail: nil)
    }

    private let noon = Date(timeIntervalSince1970: 1_757_000_000)

    // MARK: - 絞り込みの組み立て

    @Test("種別・期間・キーワードがそのままストアへ渡る")
    func filterReachesTheStore() async throws {
        let store = StubOperationLogStore()
        let model = OperationLogModel(now: { self.noon })
        await model.prepare(store: store)
        model.group = .undone
        model.keyword = "作品"
        model.period = .today
        await model.reload()
        let filter = try #require(store.filters.last)
        #expect(filter.group == .undone)
        #expect(filter.keyword == "作品")
        #expect(filter.period != nil)
    }

    /// **「今日」の終わりは翌 0 時。** `now` にすると、判定した瞬間より
    /// あとに起きた操作が同じ絞り込みから外れる。
    @Test("「今日」は翌 0 時までを含む")
    func todayEndsAtMidnight() throws {
        let calendar = Calendar(identifier: .gregorian)
        let interval = try #require(OperationLogModel.Period.today
            .interval(now: noon, calendar: calendar))
        #expect(interval.contains(noon))
        #expect(interval.start == calendar.startOfDay(for: noon))
        #expect(interval.end == calendar.date(byAdding: .day, value: 1,
                                              to: calendar.startOfDay(for: noon)))
    }

    @Test("「すべて」は期間を絞らない")
    func allHasNoInterval() {
        #expect(OperationLogModel.Period.all.interval(now: noon) == nil)
    }

    // MARK: - 空状態の出し分け

    /// **「履歴が無い」と「一致しない」は次の一手が違う**——前者は閉じる、
    /// 後者は絞り込みを緩める。
    @Test("絞り込みが 1 つでも効いていれば「一致しない」側")
    func isFilteringDistinguishesEmptyStates() async throws {
        let model = OperationLogModel(now: { self.noon })
        #expect(!model.isFiltering)
        model.group = .scan
        #expect(model.isFiltering)
        model.group = nil
        model.keyword = "  "   // 空白だけは絞り込みとみなさない
        #expect(!model.isFiltering)
        model.keyword = "a"
        #expect(model.isFiltering)
        model.keyword = ""
        model.period = .last7Days
        #expect(model.isFiltering)
    }

    // MARK: - 詳細 [OH-04]

    /// **1 件だけ選ばれているときに限る**——複数選んでいるのは見比べる
    /// ためであって、そのうちどれかの詳細を見たいわけではない。
    @Test("詳細は単一選択のときだけ")
    func detailOnlyForSingleSelection() {
        let rows = [entry(1, "a"), entry(2, "b")]
        #expect(OperationLogModel.detail(in: rows, selection: []) == nil)
        #expect(OperationLogModel.detail(in: rows, selection: [OperationLogID(rawValue: 1)])?
            .summary == "a")
        #expect(OperationLogModel.detail(in: rows,
                                         selection: [OperationLogID(rawValue: 1),
                                                     OperationLogID(rawValue: 2)]) == nil)
    }

    // MARK: - 選択の後始末

    /// 一覧から消えたものを選択に残さない——残すと、詳細が出ないのに
    /// 「1 件選択中」のように振る舞う行が生まれる。
    @Test("一覧から消えた行は選択から外れる")
    func selectionIsPrunedOnReload() async throws {
        let store = StubOperationLogStore(rows: [entry(1, "a"), entry(2, "b")])
        let model = OperationLogModel(now: { self.noon })
        await model.prepare(store: store)
        model.selection = [OperationLogID(rawValue: 1), OperationLogID(rawValue: 2)]
        store.setRows([entry(2, "b")])
        await model.reload()
        #expect(model.selection == [OperationLogID(rawValue: 2)])
    }

    @Test("ストアが無ければ `.notReady`")
    func withoutStoreItStaysNotReady() async {
        let model = OperationLogModel(now: { self.noon })
        await model.reload()
        #expect(model.state == .notReady)
    }
}

@Suite("操作履歴の種別 [OH-02]")
struct OperationLogKindTests {

    /// 左ペインの区画は種別より粗い。**すべての種別がどれかの区画に入る**
    /// ——入らないものがあると、その行はどの絞り込みでも出てこない。
    @Test("すべての種別が区画に属する")
    func everyKindBelongsToAGroup() {
        for group in OperationLogGroup.allCases {
            #expect(OperationLogKind.allCases.contains { $0.group == group },
                    "区画 \(group.rawValue) に属する種別が 1 つも無い")
        }
    }

    /// **1 件ならファイル名、複数なら件数** [OH-01]。絶対パスをそのまま
    /// 並べると列が読めない。
    @Test("対象の列は 1 件と複数で出し分ける")
    func targetsColumn() {
        func entry(_ targets: [String]) -> OperationLogEntry {
            OperationLogEntry(id: OperationLogID(rawValue: 1), date: Date(),
                              commandName: "X", kind: .executed, targets: targets,
                              libraryUUID: nil, summary: "", detail: nil)
        }
        #expect(entry([]).targetsDisplayName { "\($0) 件" } == "")
        #expect(entry(["/Volumes/X/A.cbz"]).targetsDisplayName { "\($0) 件" } == "A.cbz")
        #expect(entry(["/a", "/b"]).targetsDisplayName { "\($0) 件" } == "2 件")
    }
}
