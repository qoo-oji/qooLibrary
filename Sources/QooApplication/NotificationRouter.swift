import Foundation
import QooInfrastructure
import QooKit

/// エラー・通知の提示ルーティング [13.1 節、ER-01]。**機能ごとに独自の提示
/// 方法を作らない** — `severity` に応じてどう見せるか（アプリモーダル／
/// シート／インライン／一時通知／ログのみ）を決めるのはこの型の中だけで行う。
///
/// 実際のアラート描画は AppKit が必要なため `qooLibraryApp` 側
/// （`NotificationRouterPresenterController`）が担うが、**いつ・どの強度で
/// 出すかの判断はこちら（`QooApplication`、AppKit/SwiftUI 非依存）に
/// 閉じている**。`currentModalItem` を `@Observable` で公開し、プレゼンタ側は
/// それを監視して描画するだけの薄い橋渡しにする（`CommandStack` の
/// `undoTitle`/`redoTitle` と同じ「状態はここ、描画は View 側」という分離）。
/// プレゼンタ側は SwiftUI の `.alert` ではなく `NSAlert` を直接使う
/// （`NotificationRouterPresenterController` のコメント参照: 複数ウインドウ
/// への宣言的バインディングでは重複表示・表示漏れの両方を実機で確認した）。
///
/// フェーズ1で実装していないもの: `BatchNotificationSession`（ER-10〜16、
/// 「以降すべてに適用」・結果サマリ）は、現時点でこれを必要とする一括処理
/// フロー自体がまだ無い（既存の一括処理は単純な「最初の失敗で中断」処理に
/// 留まっている）ため、具体的な呼び出し元が無いまま作る投機的な実装になって
/// しまう。`NotificationHistoryStore`（SwiftData 版）・通知履歴ウインドウ
/// （NW-01〜08）・`SystemNotificationGate`（ER-30〜34）もフェーズ2以降。
@MainActor
@Observable
public final class NotificationRouter {
    public static let shared = NotificationRouter()

    /// 現在表示中の通知（`.appModal`/`.sheet`/`.inline` のみ）。
    public private(set) var currentModalItem: NotificationItem?

    /// [CB-11 の簡易版] DB（`NotificationHistoryStore`、07章）がまだ無い
    /// フェーズ1では永続化しない、メモリのみの履歴。強度4以上（見逃されうる
    /// 一時通知／ログのみ）だけを記録する。専用の履歴ウインドウ（NW-01〜08）
    /// はまだ無く、閲覧 UI は無い。
    public private(set) var history: [NotificationItem] = []
    private let historyLimit = 500

    private var pendingContinuation: CheckedContinuation<RecoveryAction?, Never>?
    private var queue: [(item: NotificationItem, continuation: CheckedContinuation<RecoveryAction?, Never>)] = []

    public init() {}

    /// [CB-10] `severity` に応じて提示手段を自動選択する。呼び出し側は
    /// 提示手段を指定できない。
    @discardableResult
    public func present(_ item: NotificationItem) async -> RecoveryAction? {
        logToConsole(item)
        recordIfNeeded(item)

        switch item.severity {
        case .appModal, .sheet, .inline:
            // 専用の「一時通知（トースト）」UI がまだ無いため、フェーズ1では
            // この3段階すべてを同じアラートで表示する（データモデル上は
            // 区別を保持しており、UI が揃い次第 severity で描き分けられる）。
            return await presentModally(item)
        case .transient, .logOnly:
            return nil
        }
    }

    /// `UserPresentableError` に準拠していない素の `Error` から最小限の
    /// `NotificationItem` を組み立てる橋渡し。既存のエラー型
    /// （`FileOperationError`/`ExtractError`/`RegisteredFolderError` 等）を
    /// ER-03 の三要素文言（何が/なぜ/次に何ができるか）に完全準拠させるのは
    /// 別途の作業として残している。
    @discardableResult
    public func presentError(
        _ error: Error,
        whatHappened: String,
        severity: NotificationSeverity = .sheet,
        category: NotificationItem.Category = .error
    ) async -> RecoveryAction? {
        if let presentable = error as? any UserPresentableError {
            return await present(NotificationItem(
                category: category,
                severity: presentable.severity,
                title: presentable.whatHappened,
                body: presentable.whyItHappened,
                technicalDetail: presentable.technicalDetail,
                actions: presentable.recoverySuggestions
            ))
        }
        return await present(NotificationItem(
            category: category,
            severity: severity,
            title: whatHappened,
            body: error.localizedDescription
        ))
    }

    private func presentModally(_ item: NotificationItem) async -> RecoveryAction? {
        guard currentModalItem == nil else {
            return await withCheckedContinuation { continuation in
                queue.append((item, continuation))
            }
        }
        currentModalItem = item
        return await withCheckedContinuation { continuation in
            pendingContinuation = continuation
        }
    }

    /// `qooLibraryApp` 側（`NotificationRouterPresenterController`）の
    /// ボタン操作・アラートの dismiss から呼ばれる。
    public func resolve(_ action: RecoveryAction?) {
        pendingContinuation?.resume(returning: action)
        pendingContinuation = nil
        currentModalItem = nil
        advanceQueue()
    }

    private func advanceQueue() {
        guard !queue.isEmpty else { return }
        let next = queue.removeFirst()
        currentModalItem = next.item
        pendingContinuation = next.continuation
    }

    /// [CB-11] 強度4以上（一時通知／ログのみ）だけを履歴に残す。アプリ
    /// モーダル・シート・インラインはその場でユーザーが直接見ているため、
    /// 別途の履歴を必要としない [13.1 節の判断軸]。
    private func recordIfNeeded(_ item: NotificationItem) {
        guard item.severity >= .transient else { return }
        history.append(item)
        if history.count > historyLimit {
            history.removeFirst()
        }
    }

    /// [ER-04] 強度を問わずすべてログには残す（無言で握りつぶさない）。
    /// 1-15 以降は `OSLog` に加えて診断ログのファイルにも残るため
    /// [LG2-01]、ユーザーが「エラーが出た」と報告した際に、実際に表示された
    /// 文言と提示強度をそのまま確認できる。
    private func logToConsole(_ item: NotificationItem) {
        let message = "[強度\(item.severity.rawValue)] \(item.title): \(item.body)"
        switch item.category {
        case .error: Log.ui.error(message)
        case .warning: Log.ui.warning(message)
        case .info: Log.ui.info(message)
        }
    }
}
