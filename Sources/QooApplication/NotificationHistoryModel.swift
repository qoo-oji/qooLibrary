//
//  通知履歴ウインドウのモデル [NW-01〜NW-07][NT-02〜NT-05][15章 §15.11]。
//
//  **`qooLibraryApp` ではなく `QooApplication` に置く**——アプリターゲットの
//  コードは `swift test` から触れないため、判定（絞り込み・既読の粒度・
//  期間の解釈）を自動テストで固定できなくなる（`FileVaultModel` と同じ理由）。
//  SwiftUI に依存しない。
//
import Foundation
import Observation
import QooKit

@MainActor
@Observable
public final class NotificationHistoryModel {

    public enum State: Sendable, Equatable {
        case notReady
        case loading
        case ready
        case failed(String)
    }

    /// 期間での絞り込み [NW-05]。
    ///
    /// **自由な日付範囲ではなくプリセットにしてある**［設計判断］。履歴を
    /// 遡る動機は「さっき何が出たか」「この 1 週間で何が起きたか」がほとんどで、
    /// 保持期間の既定は 30 日 [NT-07]——つまり選べる幅がもともと狭い。
    /// 日付ピッカーを 2 つ置くほうが操作が重くなる。
    public enum Period: String, Sendable, CaseIterable, Identifiable {
        case all, today, last7Days, last30Days
        public var id: String { rawValue }

        /// - Parameter now: 「今日」の起点。**引数で受ける**——固定の日時を
        ///   渡してテストできるようにするため（`Date()` を直に読むと、
        ///   日付が変わる瞬間にだけ落ちるテストになる）。
        public func interval(now: Date = Date(),
                             calendar: Calendar = .current) -> DateInterval? {
            switch self {
            case .all:
                return nil
            case .today:
                let start = calendar.startOfDay(for: now)
                // **終わりは「明日の 0 時」**。`now` にすると、判定した瞬間より
                // あとに届いた通知が同じ「今日」の絞り込みから外れる。
                let end = calendar.date(byAdding: .day, value: 1, to: start) ?? now
                return DateInterval(start: start, end: end)
            case .last7Days, .last30Days:
                let days = self == .last7Days ? 7 : 30
                let today = calendar.startOfDay(for: now)
                let start = calendar.date(byAdding: .day, value: -(days - 1), to: today) ?? today
                let end = calendar.date(byAdding: .day, value: 1, to: today) ?? now
                return DateInterval(start: start, end: end)
            }
        }
    }

    public private(set) var state: State = .notReady
    public private(set) var rows: [StoredNotification] = []
    /// 左ペインの「対象ライブラリ」に並べるもの [NW-01]。
    public private(set) var libraries: [LibrarySummary] = []

    /// 区分での絞り込み。`nil` は「すべて」[NW-01]。
    public var category: NotificationItem.Category? { didSet { reloadIfChanged(oldValue != category) } }
    /// 対象ライブラリでの絞り込み。`nil` は「すべて」[NW-01]。
    public var libraryUUID: UUID? { didSet { reloadIfChanged(oldValue != libraryUUID) } }
    public var period: Period = .all { didSet { reloadIfChanged(oldValue != period) } }
    public var keyword: String = "" { didSet { reloadIfChanged(oldValue != keyword) } }

    /// 一覧の選択。**削除 [NW-06] と詳細表示 [NW-04] の両方が使う。**
    public var selection: Set<NotificationID> = []

    private var store: (any NotificationHistoryStore)?
    private let router: NotificationRouter
    /// 期間の起点。テストから固定できるようにしてある。
    private let now: () -> Date

    public init(router: NotificationRouter = .shared, now: @escaping () -> Date = { Date() }) {
        self.router = router
        self.now = now
    }

    // MARK: - 表示（純粋関数）

    /// 選択中の 1 件。複数選択のときは詳細を出さない [NW-04]。
    ///
    /// **「1 件だけ選ばれているとき」に限る**——複数選んでいるのは削除のため
    /// であって、そのうちどれかの詳細を見たいわけではない。
    public var detail: StoredNotification? {
        Self.detail(in: rows, selection: selection)
    }

    /// **判定はここ 1 箇所。** View に書くとテストで固定できない。
    nonisolated public static func detail(in rows: [StoredNotification],
                                          selection: Set<NotificationID>) -> StoredNotification? {
        guard selection.count == 1, let id = selection.first else { return nil }
        return rows.first { $0.id == id }
    }

    /// 絞り込みが 1 つでも効いているか。空状態の文言を出し分ける
    /// [`FileVaultModel.vaultIsEmpty` と同じ判断]——「履歴がありません」と
    /// 「一致するものがありません」は次の一手が違う。
    public var isFiltering: Bool {
        category != nil || libraryUUID != nil || period != .all
            || !keyword.trimmingCharacters(in: .whitespaces).isEmpty
    }

    public var currentFilter: NotificationHistoryFilter {
        NotificationHistoryFilter(category: category, libraryUUID: libraryUUID,
                                  period: period.interval(now: now()),
                                  keyword: keyword)
    }

    // MARK: - 読み込み

    public func prepare(services: LibraryServices) async {
        guard let store = router.historyStore else {
            libraries = services.libraries
            state = .notReady
            return
        }
        await prepare(store: store, libraries: services.libraries)
    }

    /// `LibraryServices` を経由しない入口。**テストが独立したストアを渡す**
    /// ためにある——`NotificationRouter.shared` はアプリ全体で 1 つなので、
    /// テストが共有ルーターへ繋ぐと互いに干渉する。
    public func prepare(store: any NotificationHistoryStore,
                        libraries: [LibrarySummary]) async {
        self.store = store
        self.libraries = libraries
        state = .loading
        await reload()
    }

    public func reload() async {
        guard let store else { state = .notReady; return }
        do {
            let loaded = try await store.query(currentFilter)
            rows = loaded
            // 一覧から消えたものを選択に残さない（削除・絞り込みの変更のあと）。
            let alive = Set(loaded.map(\.id))
            selection = selection.filter { alive.contains($0) }
            state = .ready
        } catch {
            // **取り消しは失敗ではない**——`.task(id:)` の鍵（`historyRevision`）が
            // 続けて変わると前の読み込みが取り消される。そのまま出すと画面に
            // 「CancellationError()」という意味の無い赤字が残る [2-9 の実機検証]。
            guard !CommandStack.isCancellation(error) else { return }
            state = .failed(String(describing: error))
        }
    }

    private func reloadIfChanged(_ changed: Bool) {
        guard changed, state != .notReady else { return }
        Task { await reload() }
    }

    // MARK: - 既読 [NW-03]

    /// 選択された行を既読にする。
    ///
    /// **「開いた時点で既読」[NW-03] の「開いた」は、ウインドウではなく
    /// 個々の通知**［設計判断］。ウインドウを開いただけで全部既読にすると、
    /// **同じ NW-03 が並べて要求している「すべて既読にする」が意味を失う**
    /// ——押す前に既に全部既読になっているのだから。加えて、開いた瞬間に
    /// 「どれをまだ見ていなかったか」が消えるのは、この画面を開く動機
    /// （見逃したものを探す）そのものを壊す。
    public func markSelectedRead() async {
        guard let store else { return }
        let unread = rows.filter { selection.contains($0.id) && !$0.isRead }
        guard !unread.isEmpty else { return }
        do {
            try await store.markRead(unread.map(\.id))
            applyReadLocally(ids: Set(unread.map(\.id)))
            await router.noteHistoryChanged()
        } catch {
            state = .failed(String(describing: error))
        }
    }

    public func markAllRead() async {
        guard let store else { return }
        do {
            try await store.markAllRead()
            applyReadLocally(ids: Set(rows.map(\.id)))
            await router.noteHistoryChanged()
        } catch {
            state = .failed(String(describing: error))
        }
    }

    /// **書き戻しは手元の行にも当てる。** 読み直しに任せると、既読になった
    /// 瞬間に一覧が作り直されてスクロール位置と選択が跳ねる。
    private func applyReadLocally(ids: Set<NotificationID>) {
        for index in rows.indices where ids.contains(rows[index].id) {
            rows[index].isRead = true
        }
    }

    // MARK: - 削除 [NW-06]

    /// **Undo に載せない**［設計判断］。`CommandStack` はファイルと DB の
    /// 実体を戻すための仕組みで、そこに「読み終えた記録を捨てた」を混ぜると、
    /// ⌘Z が何を戻すのか読めなくなる（同じ ⌘Z が、押した文脈によって
    /// ファイルの移動を戻したり通知を戻したりする）。**全削除には確認を
    /// 挟む**ことで、取り返しのつかない側の安全網とする——呼び出し側の責務。
    public func deleteSelected() async {
        guard let store, !selection.isEmpty else { return }
        let ids = Array(selection)
        do {
            try await store.delete(ids)
            selection = []
            await router.noteHistoryChanged()
            await reload()
        } catch {
            state = .failed(String(describing: error))
        }
    }

    public func deleteAll() async {
        guard let store else { return }
        do {
            try await store.deleteAll()
            selection = []
            await router.noteHistoryChanged()
            await reload()
        } catch {
            state = .failed(String(describing: error))
        }
    }
}
