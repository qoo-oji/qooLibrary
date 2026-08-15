import AppKit
import SwiftUI

/// 新しく開いたウインドウを macOS ネイティブのタブグループへ合流させる
/// [ネイティブタブ移行、ユーザー要望「Finder と同じタブおよびタブバーの
/// 外観・仕様にしたい」]。
///
/// **なぜこの管理役が要るのか（使い捨ての検証アプリで実測した結果）**:
/// - `openWindow()` を呼ぶだけでは**別ウインドウとして開く**。タブになるかは
///   システム設定「書類を開くときはタブで開く」に左右され、既定
///   （`AppleWindowTabbingMode` 未設定＝フルスクリーン時のみ）では別ウインドウ。
/// - `window.tabbingMode = .preferred` を**ウインドウが画面に出た後**に設定しても
///   間に合わない。タブ化の判定はウインドウが順序付けされる時点で終わっている。
/// - 確実なのは、新しく現れたウインドウを既存グループへ
///   `addTabbedWindow(_:ordered:)` で**明示的に合流させる**こと。これは実測で
///   タブ 2→3→4→5 と安定して増えることを確認した。
/// - **合流後はネイティブタブバーの ＋ ボタンが素で機能する**（AppKit の
///   `newWindowForTab` を SwiftUI の `WindowGroup` 側が処理し、既定の行き先で
///   新しいタブが開く）。こちらで受け口を用意する必要は無い——一度
///   「＋ が効かない」と誤診してアプリデリゲートに `newWindowForTab` を
///   足しかけたが、実際には**合成クリックが外れていただけ**で、ユーザーが
///   手で押すと最初から動いていた [実機で判明、追加した回避策は撤回済み]。
///
/// **「タブとして開く」と「ウインドウとして開く」を区別する**必要がある
/// （コンテキストメニューに両方あるため）。新しいウインドウが現れる前に
/// `prepareToOpenAsTab(from:)` で合流先を予約し、実際に現れたウインドウを
/// `register(_:)` が受け取って合流させる。予約が無ければ独立したウインドウの
/// まま残す。ウインドウ生成はメインアクタ上で順に進むため、この受け渡しで
/// 取り違えは起きない。
@MainActor
final class WindowTabJoiner {
    static let shared = WindowTabJoiner()

    private init() {}

    /// 次に現れるウインドウの合流先。`prepareToOpenAsTab(from:)` で設定し、
    /// `register(_:)` が 1 回だけ消費する。
    private weak var pendingHost: NSWindow?

    /// 「新規タブで開く」系の操作の直前に呼ぶ。`host` は今アクティブな
    /// ウインドウ（＝そのタブグループへ入れる）。
    func prepareToOpenAsTab(from host: NSWindow?) {
        pendingHost = host ?? NSApp.keyWindow
    }

    /// 「新規ウインドウで開く」の直前に呼ぶ。予約を明示的に捨てて、直前の
    /// タブ操作の予約が残っていても巻き込まれないようにする。
    func prepareToOpenAsWindow() {
        pendingHost = nil
    }

    /// 各ウインドウが現れたときに 1 回だけ呼ばれる（`WindowTabJoinerView`）。
    func register(_ window: NSWindow) {
        // タブグループの識別子を揃えておく。これが違うウインドウ同士は
        // ユーザーが「すべてのウインドウを結合」しても混ざらない。
        window.tabbingIdentifier = "com.qoolibrary.main"
        defer { pendingHost = nil }
        guard let host = pendingHost, host !== window, host.isVisible else { return }
        // 既に同じグループにいるなら何もしない（ネイティブの ＋ ボタン経由で
        // 開いた場合は AppKit が先に合流させている）。
        if let group = window.tabGroup, group === host.tabGroup { return }
        host.addTabbedWindow(window, ordered: .above)
        window.makeKeyAndOrderFront(nil)
    }
}

/// ウインドウが実際に画面へ出た時点で `WindowTabJoiner` に知らせるための
/// 目に見えないブリッジ [`PaneWindows.swift`/`WindowFrameAutosave.swift` と
/// 同じ「ゼロサイズの `NSView` から `superview` を辿って `NSWindow` を掴む」
/// パターン]。
struct WindowTabJoinerView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        // `makeNSView` の時点ではまだ `window` が nil のため、1 サイクル
        // 遅らせてから掴む（`SplitPositionApplierView` と同じ理由）。
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            WindowTabJoiner.shared.register(window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

extension View {
    func windowTabJoiner() -> some View {
        background(WindowTabJoinerView().frame(width: 0, height: 0))
    }
}
