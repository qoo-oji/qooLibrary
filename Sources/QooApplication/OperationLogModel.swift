//
//  操作履歴ウインドウのモデル [OH-01〜OH-06][HS-01〜HS-04][15章 §15.13]。
//
//  **`qooLibraryApp` ではなく `QooApplication` に置く**——アプリターゲットの
//  コードは `swift test` から触れないため、判定（絞り込み・期間の解釈・
//  空状態の出し分け）を自動テストで固定できなくなる
//  （`NotificationHistoryModel` と同じ理由）。SwiftUI に依存しない。
//
import Foundation
import Observation
import QooKit

@MainActor
@Observable
public final class OperationLogModel {

    public enum State: Sendable, Equatable {
        case notReady
        case loading
        case ready
        case failed(String)
    }

    /// 期間での絞り込み [OH-02]。
    ///
    /// **通知履歴 [NW-05] と同じ 4 択にしてある**——自由な日付範囲より操作が
    /// 軽く、しかも保持期間の既定が 90 日 [HS-04] なので選べる幅がもともと
    /// 狭い。通知履歴（30 日）より長いぶん「過去 30 日」まで用意する。
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
                // あとに起きた操作が同じ「今日」の絞り込みから外れる。
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
    public private(set) var rows: [OperationLogEntry] = []

    /// 種別での絞り込み。`nil` は「すべて」[OH-02]。
    ///
    /// **左ペインはこれだけ。** 通知履歴は対象ライブラリでも絞れる [NW-01] が、
    /// こちらは**ファイル操作のコマンドが自分のライブラリを知らない**
    /// ——半分しか埋まらない列で絞り込みを提供すると「絞ったのに出てこない」
    /// になる（`OperationLogEntry.libraryUUID` のコメント参照）。
    public var group: OperationLogGroup? { didSet { reloadIfChanged(oldValue != group) } }
    public var period: Period = .all { didSet { reloadIfChanged(oldValue != period) } }
    public var keyword: String = "" { didSet { reloadIfChanged(oldValue != keyword) } }

    /// 一覧の選択。**詳細表示 [OH-04] のためだけ**——この画面に削除は無い
    /// （`OperationLogStore` の型コメント参照）。
    public var selection: Set<OperationLogID> = []

    private var store: (any OperationLogStore)?
    /// 期間の起点。テストから固定できるようにしてある。
    private let now: () -> Date

    public init(now: @escaping () -> Date = { Date() }) {
        self.now = now
    }

    // MARK: - 表示（純粋関数）

    /// 選択中の 1 件。複数選択のときは詳細を出さない [OH-04]。
    public var detail: OperationLogEntry? {
        Self.detail(in: rows, selection: selection)
    }

    /// **判定はここ 1 箇所。** View に書くとテストで固定できない。
    nonisolated public static func detail(in rows: [OperationLogEntry],
                                          selection: Set<OperationLogID>) -> OperationLogEntry? {
        guard selection.count == 1, let id = selection.first else { return nil }
        return rows.first { $0.id == id }
    }

    /// 絞り込みが 1 つでも効いているか。空状態の文言を出し分ける
    /// ——「履歴がありません」と「一致するものがありません」は次の一手が違う。
    public var isFiltering: Bool {
        group != nil || period != .all
            || !keyword.trimmingCharacters(in: .whitespaces).isEmpty
    }

    public var currentFilter: OperationLogFilter {
        OperationLogFilter(group: group, period: period.interval(now: now()), keyword: keyword)
    }

    // MARK: - 読み込み

    public func prepare(services: LibraryServices) async {
        guard let store = services.operationLog else {
            state = .notReady
            return
        }
        await prepare(store: store)
    }

    /// `LibraryServices` を経由しない入口。**テストが独立したストアを渡す**
    /// ためにある。
    public func prepare(store: any OperationLogStore) async {
        self.store = store
        state = .loading
        await reload()
    }

    public func reload() async {
        guard let store else { state = .notReady; return }
        do {
            let loaded = try await store.query(currentFilter)
            rows = loaded
            // 一覧から消えたものを選択に残さない（絞り込みの変更・掃除のあと）。
            let alive = Set(loaded.map(\.id))
            selection = selection.filter { alive.contains($0) }
            state = .ready
        } catch {
            // **取り消しは失敗ではない**——読み直しの合図（`revision`）が
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
}
