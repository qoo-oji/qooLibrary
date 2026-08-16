import AppKit
import SwiftUI

/// `OperationProgressCenter` に処理が現れたら小さな窓を出し、無くなったら
/// 閉じる［ユーザー要望: 進捗はウインドウ上のオーバーレイではなく別の窓に］。
///
/// ## なぜ SwiftUI の `Window` シーンではなく `NSPanel` なのか
/// 進捗の窓に欲しい性質は「小さく浮いていて、**前面のウインドウから
/// キーボードフォーカスを奪わない**」こと。`NSPanel` の
/// `.nonactivatingPanel` + `becomesKeyOnlyIfNeeded` がまさにそれで、
/// SwiftUI の `Window` では表現できない（開いた瞬間にキーウインドウを奪い、
/// ファイル一覧のキーボード操作が途切れる）。中身は `NSHostingView` で
/// SwiftUI のまま描く。
///
/// 宣言的なウインドウ束縛を使わないので、ウインドウを複数開いていても窓が
/// 二重に出ることが構造的に無い（`NotificationRouterPresenterController` と
/// 同じ考え方）。ただし**変化の受け取りに `withObservationTracking` は
/// 使わない** — 理由は `OperationProgressCenter.onActivityChanged` 参照。
@MainActor
final class OperationProgressWindowController {
    static let shared = OperationProgressWindowController()

    private var panel: NSPanel?
    private var isObserving = false

    private init() {}

    /// アプリ起動時に一度だけ呼ぶ（`QooLibraryApp.init()` 参照）。
    func start() {
        guard !isObserving else { return }
        isObserving = true
        // 処理の増減だけを直接受け取る（`withObservationTracking` を使わない
        // 理由は `OperationProgressCenter.onActivityChanged` のコメント参照）。
        OperationProgressCenter.shared.onActivityChanged = { [weak self] in
            self?.syncVisibility()
        }
    }

    private func syncVisibility() {
        if OperationProgressCenter.shared.isEmpty {
            panel?.orderOut(nil)
            panel = nil
        } else {
            showIfNeeded()
        }
    }

    private func showIfNeeded() {
        guard panel == nil else { return }
        let hosting = NSHostingView(rootView: OperationProgressWindowContent().appLanguageOverride())
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 160),
            styleMask: [.titled, .utilityWindow, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = String(localized: "progress.windowTitle", locale: AppLanguage.effectiveLocale)
        panel.contentView = hosting
        // **フローティングにしない**［ユーザー指摘: 衝突シートより進捗の窓が
        // 手前に出るのはおかしい］。`isFloatingPanel = true` はフローティング
        // レベル（通常ウインドウ・シート・入力ダイアログのすべてより上）に
        // なるため、回答待ちのシートを覆ってしまう。通常レベルなら
        // シート・ダイアログが自然に手前へ来る。Finder のコピーウインドウも
        // 通常ウインドウで、他のウインドウの後ろに回る。
        panel.isFloatingPanel = false
        panel.hidesOnDeactivate = false
        // **キーウインドウを奪わない。** 奪うと、コピー中に一覧の選択や
        // キーボード操作が中断される。
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        // 閉じるボタンは出さない — 処理が終われば自動的に消えるし、閉じても
        // 処理は止まらないので「閉じる」に意味のある動作を与えられない
        // （止めたい場合は行ごとの「キャンセル」を使う）。
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.center()
        panel.orderFront(nil)
        self.panel = panel
    }
}
