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
        let hosting = DeferredFitHostingView(rootView: OperationProgressWindowContent().appLanguageOverride())
        // **ホスティングビューの制約でウインドウを駆動させない** [クラッシュ
        // 修正の水平展開、`DialogWindowPresenter` のコメント参照]。既定の
        // sizingOptions（intrinsic 制約）は中身の高さが変わるたびに表示サイクルの
        // 中でパネルをリサイズする（実測: 480×160 で作ったパネルが 138pt や
        // 100pt に勝手に縮んでいた）。コピー中にユーザーがメニューを開いている
        // 瞬間（入れ子イベントループ）に行の増減・詳細行の出現が重なると、
        // 入力ダイアログで実際に起きたのと同じ「レイアウトパス超過」例外で
        // 即死し得る。追従は `DeferredFitHostingView` がレイアウト確定後に
        // 1 サイクル遅らせて行う。
        hosting.sizingOptions = []
        let panel = NSPanel(
            // 初期サイズは実測で与える（制約による自動サイズはもう無いため）。
            contentRect: NSRect(origin: .zero, size: hosting.fittingSize),
            styleMask: [.titled, .utilityWindow, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = String(localized: "progress.windowTitle", locale: AppLanguage.effectiveLocale)
        panel.contentView = hosting
        hosting.onDeferredLayout = { [weak panel, weak hosting] in
            guard let panel, let hosting else { return }
            Self.fit(panel, to: hosting.fittingSize)
        }
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

    /// 中身の実寸へパネルを合わせる（上端固定）。`DialogHostingController.
    /// fitWindowToContent` と同じ規約: 一致していれば何もしない（`setFrame`
    /// 自身が再レイアウトを起こすため、この打ち切りが無いと自己増殖する）。
    private static func fit(_ panel: NSPanel, to target: NSSize) {
        guard target.width > 1, target.height > 1 else { return }
        let content = panel.contentRect(forFrameRect: panel.frame)
        guard abs(content.width - target.width) > 0.5
            || abs(content.height - target.height) > 0.5 else { return }
        var newContent = content
        newContent.origin.y += content.height - target.height
        newContent.size = target
        panel.setFrame(panel.frameRect(forContentRect: newContent), display: true)
    }
}

/// レイアウトのたびに、**表示サイクルの外で** 1 回だけ通知するホスティング
/// ビュー。ウインドウ追従をレイアウトパスの中で行わないための橋渡し
/// （`DialogHostingController.viewDidLayout` と同じパターンの NSView 版）。
private final class DeferredFitHostingView<Content: View>: NSHostingView<Content> {
    var onDeferredLayout: (@MainActor () -> Void)?
    private var isNotifyScheduled = false

    override func layout() {
        super.layout()
        guard !isNotifyScheduled else { return }
        isNotifyScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isNotifyScheduled = false
                self.onDeferredLayout?()
            }
        }
    }
}
