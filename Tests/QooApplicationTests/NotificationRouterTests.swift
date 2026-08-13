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

    /// [CB-11] 強度4以上（一時通知／ログのみ）だけを履歴に残す。
    @Test func onlyTransientAndLogOnlySeverityAreRecordedInHistory() async {
        let router = NotificationRouter()

        _ = await router.present(NotificationItem(category: .info, severity: .transient, title: "A", body: ""))
        _ = await router.present(NotificationItem(category: .info, severity: .logOnly, title: "B", body: ""))

        async let modalResult: RecoveryAction? = router.present(
            NotificationItem(category: .error, severity: .sheet, title: "C", body: "")
        )
        try? await Task.sleep(for: .milliseconds(20))
        router.resolve(nil)
        _ = await modalResult

        #expect(router.history.map(\.title) == ["A", "B"])
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

    @Test func presentErrorUsesUserPresentableErrorConformanceWhenAvailable() async {
        let router = NotificationRouter()
        struct RichError: UserPresentableError {
            var whatHappened: String { "リッチな失敗" }
            var whyItHappened: String { "リッチな理由" }
            var recoverySuggestions: [RecoveryAction] { [] }
            var technicalDetail: String? { "詳細情報" }
            var severity: NotificationSeverity { .appModal }
        }

        async let result: RecoveryAction? = router.presentError(RichError(), whatHappened: "無視される汎用メッセージ")
        try? await Task.sleep(for: .milliseconds(20))
        #expect(router.currentModalItem?.title == "リッチな失敗")
        #expect(router.currentModalItem?.body == "リッチな理由")
        #expect(router.currentModalItem?.technicalDetail == "詳細情報")
        router.resolve(nil)
        _ = await result
    }
}
