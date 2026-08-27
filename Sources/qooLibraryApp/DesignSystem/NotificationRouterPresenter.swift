import AppKit
import Observation
import QooApplication
import QooKit

/// `NotificationRouter.currentModalItem` を監視し、`NSAlert` で描画する薄い
/// 橋渡し [ER-01]。判断ロジック（何をいつ出すか）は `NotificationRouter`
/// 側に閉じており、ここは「今の状態をそのまま表示するだけ」に徹する。
///
/// **SwiftUI の `.alert(isPresented:)` をウインドウごとに（`MainWindowView`
/// 全インスタンスへ）適用する方式は2つの問題があった** [実機検証で発見]:
/// 1. `NotificationRouter.shared` はアプリ全体で単一のため、開いている
///    すべてのウインドウが同じ `currentModalItem` を見て、それぞれ自分の
///    アラートとして表示してしまい、2 ウインドウ開いていると同じエラーが
///    2 回表示された。
/// 2. `@Environment(\.controlActiveState)` でキーウインドウかどうかを
///    判定してこれを1つに絞ろうとしたところ、今度はアラート自体が
///    まったく表示されなくなった（この深いビュー階層＋複数の
///    `NSViewRepresentable` 橋渡しの組み合わせでの `controlActiveState` の
///    信頼性を安全に検証できる状況ではなかった）。
///
/// 代わりに、**宣言的な複数ウインドューバインディングを一切使わず**、
/// アプリ全体で唯一のこのコントローラが `NotificationRouter` の変化を
/// `withObservationTracking` で監視し、変化のたびに `NSApp.keyWindow` を
/// その場で問い合わせて `NSAlert.beginSheetModal` を1回だけ呼ぶ方式にした。
/// 「表示する瞬間に一度だけ、命令的にどのウインドウに出すか決める」ため、
/// 複数ウインドウでの重複や、宣言的バインディングのタイミング問題が
/// 構造的に起こり得ない。
@MainActor
final class NotificationRouterPresenterController {
    static let shared = NotificationRouterPresenterController()
    private var isObserving = false
    private var isPresentingAlert = false

    private init() {}

    /// アプリ起動時に一度だけ呼ぶ（`QooLibraryApp.init()` 参照）。
    func start() {
        guard !isObserving else { return }
        isObserving = true
        observe()
    }

    private func observe() {
        withObservationTracking {
            _ = NotificationRouter.shared.currentModalItem
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.presentIfNeeded()
                self?.observe() // `withObservationTracking` は1回きりの通知のため再登録する
            }
        }
    }

    private func presentIfNeeded() {
        guard !isPresentingAlert, let item = NotificationRouter.shared.currentModalItem else { return }
        isPresentingAlert = true

        let alert = NSAlert()
        alert.messageText = item.title
        alert.informativeText = item.body
        alert.alertStyle = item.category == .error ? .critical : .warning
        // **閉じる手段は必ずある。** 決定は `NotificationAlertButtons` が持つ
        // ——ここ（アプリターゲット）に書くと `swift test` で固定できない。
        let buttons = NotificationAlertButtons.actions(
            for: item,
            okTitle: String(localized: "action.ok", locale: AppLanguage.effectiveLocale),
            dismissTitle: String(localized: "action.close", locale: AppLanguage.effectiveLocale))
        for action in buttons {
            alert.addButton(withTitle: action.title)
        }
        // 合成した閉じるボタンには Esc も割り当てる（`NSAlert` は "Cancel" と
        // いう題のボタンにしか自動では割り当てない）。
        if buttons.last?.id == NotificationAlertButtons.dismissActionID, buttons.count > 1 {
            alert.buttons.last?.keyEquivalent = "\u{1b}"
        }
        // **技術詳細を捨てない** [ER-03]［棚卸しで発見: `NotificationItem` は
        // 運んでいるのに、ここで無視していた］。`NSAlert` に折りたたみ表示は
        // 無いので、本文を膨らませる代わりに「詳細をコピー」を足す。問い合わせ
        // のときにユーザーがそのまま貼れる形にしておくのが実際に役に立つ。
        let detailButtonIndex = item.technicalDetail == nil ? -1 : alert.buttons.count
        if item.technicalDetail != nil {
            alert.addButton(withTitle: String(localized: "action.copyDetails", locale: AppLanguage.effectiveLocale))
        }

        let handleResponse: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
            // 「詳細をコピー」はダイアログを閉じる意味を持たない。コピーだけ
            // して、同じ内容をもう一度出す（閉じたいときは他のボタンを押す）。
            if index == detailButtonIndex, let detail = item.technicalDetail {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("\(item.title)\n\(item.body)\n\n\(detail)", forType: .string)
                self?.isPresentingAlert = false
                self?.presentIfNeeded()
                return
            }
            self?.isPresentingAlert = false
            let chosen: RecoveryAction? = buttons.indices.contains(index) ? buttons[index] : nil
            if case .openSystemSettings(let urlString) = chosen?.kind, let url = URL(string: urlString) {
                NSWorkspace.shared.open(url)
            }
            NotificationRouter.shared.resolve(chosen)
        }

        // キーウインドウに対するシートとして出す。無ければ（例: 全ウインドウを
        // 閉じている状態でのエラー）独立したモーダルとして出す。
        if let window = NSApp.keyWindow ?? NSApp.windows.first(where: \.isVisible) {
            alert.beginSheetModal(for: window, completionHandler: handleResponse)
        } else {
            let response = alert.runModal()
            handleResponse(response)
        }
    }
}
