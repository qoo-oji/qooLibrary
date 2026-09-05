import Foundation
import Testing

@testable import QooApplication
@testable import QooKit

@MainActor
@Suite struct NotificationRouterTests {
    @Test func presentingAModalSeverityShowsCurrentModalItem() async {
        let router = NotificationRouter()
        let item = NotificationItem(category: .error, severity: .sheet, title: "失敗", body: "詳細")

        async let result: RecoveryAction? = router.present(item)
        // `present` は resolve が呼ばれるまで中断するため、先に currentModalItem が
        // 立っていることを確認してから resolve する。
        try? await Task.sleep(for: .milliseconds(20))
        #expect(router.currentModalItem?.id == item.id)

        router.resolve(nil)
        let resolved = await result
        #expect(resolved == nil)
        #expect(router.currentModalItem == nil)
    }

    @Test func resolveReturnsTheChosenAction() async {
        let router = NotificationRouter()
        let action = RecoveryAction(id: "retry", title: "再試行", kind: .retry)
        let item = NotificationItem(category: .error, severity: .appModal, title: "失敗", body: "詳細", actions: [action])

        async let result: RecoveryAction? = router.present(item)
        try? await Task.sleep(for: .milliseconds(20))
        router.resolve(action)

        #expect(await result == action)
    }

    @Test func transientAndLogOnlySeverityDoNotShowAModal() async {
        let router = NotificationRouter()
        let transientItem = NotificationItem(category: .info, severity: .transient, title: "情報", body: "詳細")

        let result = await router.present(transientItem)

        #expect(result == nil)
        #expect(router.currentModalItem == nil)
    }

    /// **強度を問わずすべて記録する**［ユーザー判断、2026-08］。要件 NT-01 は
    /// 「強度 4 以上」と定めていたが、実測すると `.sheet` が 70 箇所超に対し
    /// `.transient` は 3 箇所しかなく、そのままでは履歴が常に空になる。
    @Test func everySeverityIsRecordedInHistory() async {
        let router = NotificationRouter()
        let store = FakeNotificationHistoryStore()
        await router.attachHistoryStore(store, retentionDays: 0, maxCount: 0)

        _ = await router.present(NotificationItem(category: .info, severity: .transient, title: "A", body: ""))
        _ = await router.present(NotificationItem(category: .info, severity: .logOnly, title: "B", body: ""))

        async let modalResult: RecoveryAction? = router.present(
            NotificationItem(category: .error, severity: .sheet, title: "C", body: "")
        )
        try? await Task.sleep(for: .milliseconds(20))
        router.resolve(nil)
        _ = await modalResult
        try? await Task.sleep(for: .milliseconds(50))

        #expect(await store.titles() == ["A", "B", "C"])
    }

    /// **未読に数えるのは強度 4 以上だけ** [NT-02]。シートを目の前で閉じた
    /// 直後にバッジが立つと、「まだ見ていないものがある」というバッジの
    /// 意味そのものが失われる。
    @Test func onlyWeakSeveritiesCountAsUnread() async {
        let router = NotificationRouter()
        let store = FakeNotificationHistoryStore()
        await router.attachHistoryStore(store, retentionDays: 0, maxCount: 0)

        _ = await router.present(NotificationItem(category: .info, severity: .transient, title: "A", body: ""))
        _ = await router.present(NotificationItem(category: .info, severity: .logOnly, title: "B", body: ""))
        try? await Task.sleep(for: .milliseconds(50))

        async let modalResult: RecoveryAction? = router.present(
            NotificationItem(category: .error, severity: .sheet, title: "C", body: "")
        )
        try? await Task.sleep(for: .milliseconds(20))
        router.resolve(nil)
        _ = await modalResult
        try? await Task.sleep(for: .milliseconds(50))

        #expect(router.unreadCount == 2)
    }

    /// **ストアが繋がる前の通知を取りこぼさない。** 退避記録の復旧 [NV-92]・
    /// 登録フォルダの読み込み失敗は `LibraryServices.bootstrap()` より前に走る。
    @Test func notificationsRaisedBeforeTheStoreIsAttachedAreFlushed() async {
        let router = NotificationRouter()
        _ = await router.present(NotificationItem(category: .warning, severity: .transient,
                                                  title: "起動中", body: ""))
        let store = FakeNotificationHistoryStore()
        await router.attachHistoryStore(store, retentionDays: 0, maxCount: 0)

        #expect(await store.titles() == ["起動中"])
        #expect(router.unreadCount == 1)
    }

    /// 掃除 [NT-07] は**繋いだ時点で 1 度だけ**走る。追記のたびに走らせると、
    /// 通知が大量に出た日にその回数だけ削除が走ることになる。
    @Test func attachingPurgesOnce() async {
        let router = NotificationRouter()
        let store = FakeNotificationHistoryStore()
        await router.attachHistoryStore(store, retentionDays: 30, maxCount: 1_000)

        _ = await router.present(NotificationItem(category: .info, severity: .transient,
                                                  title: "A", body: ""))
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await store.purgeCalls() == 1)
    }

    /// **記録は投入順に書かれる。**
    ///
    /// 素の `Task { await store.append(…) }` は**開始順が投入順と一致しない**。
    /// `everySeverityIsRecordedInHistory` も並びを見ているが、3 件では偶然
    /// そろってしまう——`OperationLogRecorder` は同じ書き方で 3 回に 1 回しか
    /// 落ちず、CI で初めて表面化した。件数を増やして確実に落ちるようにする。
    @Test func historyAppendsPreserveSubmissionOrder() async {
        let router = NotificationRouter()
        let store = FakeNotificationHistoryStore()
        await router.attachHistoryStore(store, retentionDays: 0, maxCount: 0)

        let expected = (0..<50).map(String.init)
        for title in expected {
            _ = await router.present(NotificationItem(category: .info, severity: .transient,
                                                      title: title, body: ""))
        }
        for _ in 0..<150 where await store.titles().count < expected.count {
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(await store.titles() == expected)
    }

    /// **1 件の失敗で残りを失わない。** `pendingBeforeStore` は流し込む前に
    /// 空にしてあるので、ループ全体を `do/catch` で囲むと 2 件目が投げた時点で
    /// 3 件目以降が**どこにも残らずに消える**。掃除 [NT-07] も同じ catch に
    /// 入れると、追記が 1 件失敗しただけでその起動ぶんが丸ごと飛ぶ。
    @Test func oneFailureDuringFlushDoesNotDropTheRest() async {
        let router = NotificationRouter()
        for i in 0..<3 {
            _ = await router.present(NotificationItem(category: .warning, severity: .transient,
                                                      title: "\(i)", body: ""))
        }
        let store = FakeNotificationHistoryStore()
        await store.failNextAppendOnce()     // 1 件目だけ失敗させる
        await router.attachHistoryStore(store, retentionDays: 30, maxCount: 1_000)

        #expect(await store.titles() == ["1", "2"])
        #expect(await store.purgeCalls() == 1)
    }

    @Test func secondModalItemQueuesUntilFirstIsResolved() async {
        let router = NotificationRouter()
        let first = NotificationItem(category: .error, severity: .sheet, title: "1件目", body: "")
        let second = NotificationItem(category: .error, severity: .sheet, title: "2件目", body: "")

        async let firstResult: RecoveryAction? = router.present(first)
        try? await Task.sleep(for: .milliseconds(20))
        async let secondResult: RecoveryAction? = router.present(second)
        try? await Task.sleep(for: .milliseconds(20))

        #expect(router.currentModalItem?.title == "1件目") // 2件目はまだ出ない

        router.resolve(nil)
        _ = await firstResult
        try? await Task.sleep(for: .milliseconds(20))
        #expect(router.currentModalItem?.title == "2件目") // 1件目の解決で繰り上がる

        router.resolve(nil)
        _ = await secondResult
        #expect(router.currentModalItem == nil)
    }

    @Test func presentErrorBuildsAnItemFromWhatHappenedAndLocalizedDescription() async {
        let router = NotificationRouter()
        struct PlainError: Error, LocalizedError {
            var errorDescription: String? { "テスト用の理由" }
        }

        async let result: RecoveryAction? = router.presentError(PlainError(), whatHappened: "何かに失敗しました")
        try? await Task.sleep(for: .milliseconds(20))
        #expect(router.currentModalItem?.title == "何かに失敗しました")
        #expect(router.currentModalItem?.body == "テスト用の理由")
        router.resolve(nil)
        _ = await result
    }

    /// **合成の規則を固定する** [ER-03]。
    /// タイトルは呼び出し側（どの操作で失敗したか）、本文はエラー型の三要素。
    ///
    /// 以前は準拠している型だと**呼び出し側のタイトルを捨てて**いたため、
    /// 「どの操作で失敗したのか」が消えていた［棚卸しで発見］。
    @Test func presentErrorKeepsTheCallersTitleAndComposesTheThreeElements() async {
        let router = NotificationRouter()
        struct RichError: UserPresentableError {
            var whatHappened: String { "「a.cbz」を処理できませんでした。" }
            var whyItHappened: String { "書き込み先の空き容量が足りません。" }
            var recoverySuggestions: [RecoveryAction] { [] }
            var recoveryHint: String? { "不要な項目を削除してください。" }
            var technicalDetail: String? { "errno 28" }
            var severity: NotificationSeverity { .appModal }
        }

        async let result: RecoveryAction? = router.presentError(RichError(), whatHappened: "コピーできませんでした")
        try? await Task.sleep(for: .milliseconds(20))
        // タイトルは操作名（呼び出し側）のまま。
        #expect(router.currentModalItem?.title == "コピーできませんでした")
        // 本文は 何が / なぜ / 次に何ができるか。
        let body = router.currentModalItem?.body ?? ""
        #expect(body.contains("「a.cbz」を処理できませんでした。"))
        #expect(body.contains("空き容量が足りません"))
        #expect(body.contains("不要な項目を削除してください。"))
        // 技術詳細は本文へ混ぜず、別に運ぶ。
        #expect(!body.contains("errno"))
        #expect(router.currentModalItem?.technicalDetail == "errno 28")
        router.resolve(nil)
        _ = await result
    }

    /// 押して意味のある操作があるときは、助言の文章を重ねない（二重になる）。
    @Test func aButtonSuppressesTheTextualHint() async {
        let router = NotificationRouter()
        struct WithAction: UserPresentableError {
            var whatHappened: String { "アクセスできませんでした。" }
            var whyItHappened: String { "許可がありません。" }
            var recoverySuggestions: [RecoveryAction] {
                [RecoveryAction(id: "settings", title: "アクセス権を開く", kind: .dismiss)]
            }
            var recoveryHint: String? { "この文章は出さない" }
            var technicalDetail: String? { nil }
            var severity: NotificationSeverity { .sheet }
        }

        async let result: RecoveryAction? = router.presentError(WithAction(), whatHappened: "開けませんでした")
        try? await Task.sleep(for: .milliseconds(20))
        #expect(!(router.currentModalItem?.body.contains("この文章は出さない") ?? true))
        #expect(router.currentModalItem?.actions.count == 1)
        router.resolve(nil)
        _ = await result
    }

    /// **安全網** [ER-03]。`UserPresentableError` に準拠していない型が来ても、
    /// 「操作を完了できませんでした。（Module.Type エラー1）」という
    /// 原因の分からない既定文言をそのまま見せないこと。
    @Test func anUnexplainedErrorIsNotShownAsTheRawDefault() async {
        struct Bare: Error {}
        let router = NotificationRouter()
        async let result: RecoveryAction? = router.presentError(Bare(), whatHappened: "移動に失敗しました")
        try? await Task.sleep(for: .milliseconds(20))
        let item = router.currentModalItem
        #expect(item?.title == "移動に失敗しました")
        #expect(item?.body.contains("原因を特定できない") == true)
        // 型名は本文ではなく折りたたみへ。
        #expect(item?.body.contains("Bare") == false)
        #expect(item?.technicalDetail?.contains("Bare") == true)
        router.resolve(nil)
        _ = await result
    }

    /// 既定文言の判定が、まともなメッセージを誤って潰さないこと。
    @Test func aProperMessageIsLeftAlone() {
        #expect(!NotificationRouter.looksLikeTheUninformativeDefault("空き容量が足りません。"))
        #expect(NotificationRouter.looksLikeTheUninformativeDefault(
            "The operation couldn’t be completed. (QooKit.Sample error 1.)"
        ))
    }
}

//
//  アラートに出すボタン [ER-01][ER-03]。
//
//  **実機検証で見つけた回帰の回帰テスト。** 走査結果のシートへ「整理する…」を
//  足したところ `actions.isEmpty` の分岐から外れ、**閉じる手段が消えていた**
//  ——知らせを受け取っただけの利用者が窓を開くしか道が無くなる。
//
@Suite("アラートのボタン [ER-01]")
struct NotificationAlertButtonsTests {

    private func item(actions: [RecoveryAction]) -> NotificationItem {
        NotificationItem(category: .warning, severity: .sheet,
                         title: "題", body: "本文", actions: actions)
    }

    @Test("行動を促すボタンが無ければ OK だけ")
    func okOnlyWhenThereIsNothingToDo() {
        let buttons = NotificationAlertButtons.actions(
            for: item(actions: []), okTitle: "OK", dismissTitle: "閉じる")
        #expect(buttons.map(\.title) == ["OK"])
        #expect(buttons[0].kind == .dismiss)
    }

    /// **これが本命。** 行動を促すボタンだけになると、押さずに閉じる道が消える。
    @Test("行動を促すボタンがあるときも、必ず閉じる手段を足す")
    func alwaysOffersAWayOut() {
        let action = RecoveryAction(id: "review", title: "整理する…", kind: .openWindow("review"))
        let buttons = NotificationAlertButtons.actions(
            for: item(actions: [action]), okTitle: "OK", dismissTitle: "閉じる")
        #expect(buttons.map(\.title) == ["整理する…", "閉じる"])
        #expect(buttons.last?.kind == .dismiss)
        #expect(buttons.last?.id == NotificationAlertButtons.dismissActionID)
    }

    @Test("呼び出し側が自前で閉じる手段を持つなら二重に足さない")
    func doesNotDuplicateAnExistingDismiss() {
        let actions = [RecoveryAction(id: "retry", title: "再試行", kind: .retry),
                       RecoveryAction(id: "later", title: "あとで", kind: .dismiss)]
        let buttons = NotificationAlertButtons.actions(
            for: item(actions: actions), okTitle: "OK", dismissTitle: "閉じる")
        #expect(buttons.map(\.title) == ["再試行", "あとで"])
    }

    /// 合成した閉じるは、どの呼び出し側の識別子とも一致しない
    /// ——押しても「ただ閉じる」になる。
    @Test("合成した閉じるの識別子は呼び出し側と衝突しない")
    func dismissIDIsDistinct() {
        let action = RecoveryAction(id: NotificationAlertButtons.dismissActionID,
                                    title: "紛らわしい", kind: .openWindow("x"))
        let buttons = NotificationAlertButtons.actions(
            for: item(actions: [action]), okTitle: "OK", dismissTitle: "閉じる")
        // 呼び出し側が同じ識別子を使っていても、種別で見分けられる。
        #expect(buttons.count == 2)
        #expect(buttons.last?.kind == .dismiss)
    }
}


/// 通知履歴ストアの試験用実装。**`SQLiteNotificationHistoryStore` を使わない**
/// ——ここで確かめたいのはルーターの振る舞い（何を記録し、何を未読に数え、
/// いつ掃除するか）であって、SQL ではない。
actor FakeNotificationHistoryStore: NotificationHistoryStore {
    private var rows: [StoredNotification] = []
    private var nextID: Int64 = 1
    private var purges = 0
    private var failNextAppend = false

    struct AppendFailure: Error {}

    func titles() -> [String] { rows.map(\.title) }
    func purgeCalls() -> Int { purges }
    func failNextAppendOnce() { failNextAppend = true }

    @discardableResult
    func append(_ item: NotificationItem) async throws -> NotificationID {
        if failNextAppend { failNextAppend = false; throw AppendFailure() }
        let id = NotificationID(rawValue: nextID)
        nextID += 1
        rows.append(StoredNotification(
            id: id, date: item.date, category: item.category, severity: item.severity,
            target: item.target, title: item.title, body: item.body,
            technicalDetail: item.technicalDetail,
            links: item.actions.compactMap { action in
                guard case .openWindow = action.kind else { return nil }
                return NotificationLink(actionID: action.id, title: action.title)
            },
            isRead: false))
        return id
    }

    func query(_ filter: NotificationHistoryFilter) async throws -> [StoredNotification] {
        rows.reversed()
    }

    func unreadCount() async throws -> Int {
        rows.filter { !$0.isRead && StoredNotification.countsAsUnread(severity: $0.severity) }.count
    }

    func markRead(_ ids: [NotificationID]) async throws {
        for index in rows.indices where ids.contains(rows[index].id) { rows[index].isRead = true }
    }

    func markAllRead() async throws {
        for index in rows.indices { rows[index].isRead = true }
    }

    func delete(_ ids: [NotificationID]) async throws {
        rows.removeAll { ids.contains($0.id) }
    }

    func deleteAll() async throws { rows.removeAll() }

    func purgeExpired(retentionDays: Int, maxCount: Int) async throws { purges += 1 }
}
