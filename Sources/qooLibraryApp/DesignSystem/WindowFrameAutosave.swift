import AppKit
import SwiftUI

/// ウインドウの**サイズ**をアプリ再起動をまたいで復元し、同じ名前を使う
/// 複数のウインドウ間でも揃える [UI-08 相当、実機検証時のユーザー要望:
/// ⌘N で開いた新規ウインドウを既存ウインドウのサイズに合わせたい]。
///
/// **位置（origin）は、アプリ起動後に最初に開くウインドウにだけ復元する**
/// [設計判断、2 段階のユーザーフィードバックを踏まえた結論]。
/// 当初は位置を一切復元しない方針だった — 位置も含めて復元していたところ、
/// ⌘N で開いた新規ウインドウが既存ウインドウとまったく同じ位置・サイズに
/// なり、完全に重なって見た目上「消えた」（実際は閉じておらず背後に重なって
/// いただけ）というユーザー報告があったため。その後、**アプリを何度も
/// 再起動するとウインドウ位置がそのたびにずれる**という別のユーザー指摘が
/// あり、「起動直後の1本目のウインドウだけ位置も復元し、セッション中に
/// ⌘N で追加されるウインドウは従来どおり位置復元の対象外（AppKit 標準の
/// カスケード配置に任せる）」という折衷案に決着した。`hasRestoredPositionThisLaunch`
/// （プロセス全体で共有する静的フラグ）で「このプロセスで最初の1本かどうか」
/// を判定する。
///
/// 当初 `NSWindow.setFrameAutosaveName(_:)`（1 回呼ぶだけで復元・以後の自動
/// 保存の両方をやってくれるはずの AppKit 標準 API）を使ったが、実機検証で
/// ウインドウ幅が揃わないことが判明した（リサイズ後に ⌘N しても新規ウインドウ
/// に反映されない＝自動保存が期待通り働いていない）。原因を深追いするより、
/// `PaneWindows.swift` のペイン幅永続化で既に実績のある方式
/// （`NSWindowDidResize` 通知を自分で監視して `UserDefaults` へ明示的に
/// 書き込み、新規ウインドウでは明示的に読み込んで 1 回だけ適用する）に統一
/// した方が確実と判断し、そちらへ切り替えた [設計判断]。位置の監視・保存も
/// 同じパターン（`NSWindowDidMoveNotification`）で行う。
private final class WindowFrameAutosaveView: NSView {
    var name = ""
    private var hasApplied = false
    // `deinit` は nonisolated で呼ばれるため `nonisolated(unsafe)` にしている。
    // `NotificationCenter.removeObserver` はどのスレッドからでも安全に呼べる。
    nonisolated(unsafe) private var observerTokens: [NSObjectProtocol] = []
    /// アプリ起動後、最初に開いたウインドウにだけ位置を復元する
    /// [型のコメント参照]。プロセス全体で 1 つ（ウインドウ名をまたいで
    /// 共有）。
    nonisolated(unsafe) private static var hasRestoredPositionThisLaunch = false

    override var intrinsicContentSize: NSSize { NSSize(width: 0, height: 0) }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard !hasApplied, let window else { return }
        hasApplied = true
        applySavedFrame(to: window)
        observeFrameChanges(of: window)
    }

    private func applySavedFrame(to window: NSWindow) {
        let isFirstWindowThisLaunch = !Self.hasRestoredPositionThisLaunch
        Self.hasRestoredPositionThisLaunch = true

        let savedSize = UserDefaults.standard.string(forKey: Self.sizeDefaultsKey(for: name)).map(NSSizeFromString)
        let savedOrigin = isFirstWindowThisLaunch
            ? UserDefaults.standard.string(forKey: Self.originDefaultsKey(for: name)).map(NSPointFromString)
            : nil
        guard savedSize != nil || savedOrigin != nil else { return }

        // `PaneWindows.swift` の `SplitPositionApplierView` と同じ理由:
        // SwiftUI 自身のウインドウサイズ決定ロジックがこの直後に走り、
        // 即座に適用したフレームを上書きしてしまうことがある。次の実行
        // サイクルまで遅らせて適用する。
        DispatchQueue.main.async { [weak window] in
            guard let window else { return }
            var frame = window.frame
            if let savedSize, savedSize.width > 0, savedSize.height > 0 {
                // 上端（タイトルバー側）を固定して高さを変える。AppKit の
                // 座標系は左下原点のため、そのままだと下端基準で伸び縮み
                // してしまう。
                frame.origin.y -= savedSize.height - frame.height
                frame.size = savedSize
            }
            if let savedOrigin {
                frame.origin = savedOrigin
            }
            window.setFrame(frame, display: true)
        }
    }

    private func observeFrameChanges(of window: NSWindow) {
        let sizeKey = Self.sizeDefaultsKey(for: name)
        let originKey = Self.originDefaultsKey(for: name)
        let resizeToken = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: window, queue: .main
        ) { notification in
            guard let changedWindow = notification.object as? NSWindow else { return }
            UserDefaults.standard.set(NSStringFromSize(changedWindow.frame.size), forKey: sizeKey)
        }
        let moveToken = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: window, queue: .main
        ) { notification in
            guard let changedWindow = notification.object as? NSWindow else { return }
            UserDefaults.standard.set(NSStringFromPoint(changedWindow.frame.origin), forKey: originKey)
        }
        observerTokens.append(resizeToken)
        observerTokens.append(moveToken)
    }

    private static func sizeDefaultsKey(for name: String) -> String {
        "qoo.windowSize.\(name)"
    }

    private static func originDefaultsKey(for name: String) -> String {
        "qoo.windowOrigin.\(name)"
    }

    deinit {
        observerTokens.forEach { NotificationCenter.default.removeObserver($0) }
    }
}

private struct WindowFrameAutosave: NSViewRepresentable {
    let name: String

    func makeNSView(context: Context) -> WindowFrameAutosaveView {
        let view = WindowFrameAutosaveView()
        view.name = name
        return view
    }

    func updateNSView(_ nsView: WindowFrameAutosaveView, context: Context) {}
}

extension View {
    /// 同じ `name` を使うウインドウ同士でサイズを揃え、アプリ再起動後も復元する。
    /// 位置は起動直後の最初の1本にだけ復元し、セッション中に追加されるウインドウは
    /// AppKit 標準のカスケード配置に任せる（型のコメント参照）。
    public func windowFrameAutosave(_ name: String) -> some View {
        background(WindowFrameAutosave(name: name))
    }
}
