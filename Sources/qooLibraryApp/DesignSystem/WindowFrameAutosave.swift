import AppKit
import SwiftUI

/// ウインドウの**サイズ**をアプリ再起動をまたいで復元し、同じ名前を使う
/// 複数のウインドウ間でも揃える [UI-08 相当、実機検証時のユーザー要望:
/// ⌘N で開いた新規ウインドウを既存ウインドウのサイズに合わせたい]。
///
/// **位置（origin）は意図的に対象外にしている**
/// [実機検証で発見: 当初は位置も含めて復元していたところ、⌘N で開いた新規
/// ウインドウが既存ウインドウとまったく同じ位置・サイズになり、完全に重なって
/// 見た目上「消えた」（実際は閉じておらず背後に重なっていただけ）という
/// ユーザー報告があった]。ユーザーが要望したのはサイズを揃えることであり、
/// 位置は AppKit 標準のカスケード配置（新規ウインドウを少しずつずらして
/// 開く）に任せたほうが実用的なため、サイズのみを保存・復元する。
///
/// 当初 `NSWindow.setFrameAutosaveName(_:)`（1 回呼ぶだけで復元・以後の自動
/// 保存の両方をやってくれるはずの AppKit 標準 API）を使ったが、実機検証で
/// ウインドウ幅が揃わないことが判明した（リサイズ後に ⌘N しても新規ウインドウ
/// に反映されない＝自動保存が期待通り働いていない）。原因を深追いするより、
/// `PaneWindows.swift` のペイン幅永続化で既に実績のある方式
/// （`NSWindowDidResize` 通知を自分で監視して `UserDefaults` へ明示的に
/// 書き込み、新規ウインドウでは明示的に読み込んで 1 回だけ適用する）に統一
/// した方が確実と判断し、そちらへ切り替えた [設計判断]。
private final class WindowFrameAutosaveView: NSView {
    var name = ""
    private var hasApplied = false
    // `deinit` は nonisolated で呼ばれるため `nonisolated(unsafe)` にしている。
    // `NotificationCenter.removeObserver` はどのスレッドからでも安全に呼べる。
    nonisolated(unsafe) private var observerTokens: [NSObjectProtocol] = []

    override var intrinsicContentSize: NSSize { NSSize(width: 0, height: 0) }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard !hasApplied, let window else { return }
        hasApplied = true
        applySavedSize(to: window)
        observeSizeChanges(of: window)
    }

    private func applySavedSize(to window: NSWindow) {
        guard let sizeString = UserDefaults.standard.string(forKey: Self.defaultsKey(for: name)) else { return }
        let size = NSSizeFromString(sizeString)
        guard size.width > 0, size.height > 0 else { return }
        // `PaneWindows.swift` の `SplitPositionApplierView` と同じ理由:
        // SwiftUI 自身のウインドウサイズ決定ロジックがこの直後に走り、
        // 即座に適用したフレームを上書きしてしまうことがある。次の実行
        // サイクルまで遅らせて適用する。
        DispatchQueue.main.async { [weak window] in
            guard let window else { return }
            var frame = window.frame
            // 上端（タイトルバー側）を固定して高さを変える。AppKit の座標系は
            // 左下原点のため、そのままだと下端基準で伸び縮みしてしまう。
            frame.origin.y -= size.height - frame.height
            frame.size = size
            window.setFrame(frame, display: true)
        }
    }

    private func observeSizeChanges(of window: NSWindow) {
        let key = Self.defaultsKey(for: name)
        let token = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: window, queue: .main
        ) { notification in
            guard let changedWindow = notification.object as? NSWindow else { return }
            UserDefaults.standard.set(NSStringFromSize(changedWindow.frame.size), forKey: key)
        }
        observerTokens.append(token)
    }

    private static func defaultsKey(for name: String) -> String {
        "qoo.windowSize.\(name)"
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
    /// 同じ `name` を使うウインドウ同士でサイズを揃え、アプリ再起動後も復元する
    /// （位置は対象外、AppKit 標準のカスケード配置に任せる）。
    public func windowFrameAutosave(_ name: String) -> some View {
        background(WindowFrameAutosave(name: name))
    }
}
