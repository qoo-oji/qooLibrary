import AppKit
import QuickLookUI
import SwiftUI

/// `QLPreviewPanel` の制御権をこのウインドウの `QuickLookController` に渡すため、
/// レスポンダチェーンへ専用のレスポンダを差し込む [QL-01]。
///
/// ## なぜ必要か
/// `QLPreviewPanel` は「レスポンダチェーンをたどり、最初に
/// `acceptsPreviewPanelControl:` へ `true` を返したオブジェクト」をコント
/// ローラとして採用する（`QLPreviewPanel.h` に明記）。AppKit のアプリなら
/// `NSViewController` がそのままチェーン上にいるので実装するだけで済むが、
/// SwiftUI にはそこへ置ける自前のレスポンダが無い。
///
/// `.background { NSViewRepresentable }` で `NSView` を置いても解決しない
/// ——チェーンは `nextResponder`（`NSView` では親ビュー）方向にしか進まず、
/// 背景として並べたビューは中央ペインの `Table` にとって「兄弟」であって
/// 祖先ではないため、一度も尋ねられない
/// [`FolderContentView.TableHorizontalScrollDisabler` のコメントで同じ構造の
/// 制約を確認済み]。
///
/// そこで**ウインドウの直後**（`NSWindow.nextResponder`）へ差し込む。
/// ファーストレスポンダからビュー階層を上りきると必ず `NSWindow` に到達し、
/// その次に尋ねられるのがここになる——どのペインにフォーカスがあっても確実に
/// 見つかる、レスポンダチェーンの正規の拡張方法。元の `nextResponder`
/// （通常は `NSWindowController`）は取りこぼさないよう自分の後ろに繋ぎ直す。
///
/// ## 実測で確かめたこと
/// 最小の AppKit アプリを組んで、`acceptsPreviewPanelControl:` が実際に
/// どの位置へ届くかを計測した（①ファーストレスポンダのビュー自身、
/// ②`window.nextResponder` への差し込み、③ウインドウデリゲート、
/// ④アプリデリゲート の 4 箇所に同時に実装して記録）。結果:
/// - パネルを前面に出した時点で探索が走る（`updateController()` を明示的に
///   呼んでも、パネルが表示されていなければ何も起きない）。
/// - ①が `true` を返すとそこで探索は止まる。
/// - **①が `false` を返すと、続いて②が尋ねられ、制御権が渡る**
///   （`beginPreviewPanelControl:` まで到達し、`currentController` も②になる）。
/// - ③④はどちらの場合も一度も尋ねられなかった。
///
/// つまりこの差し込み位置は「SwiftUI 側の誰も名乗り出なければ確実に拾える」
/// 場所であり、かつ SwiftUI が将来自前で名乗り出るようになった場合は
/// そちらが優先される（＝壊れない）位置でもある。
struct QuickLookPanelInstaller: NSViewRepresentable {
    let controller: QuickLookController

    func makeNSView(context: Context) -> QuickLookResponderHostView {
        let view = QuickLookResponderHostView()
        view.responder.controller = controller
        return view
    }

    func updateNSView(_ nsView: QuickLookResponderHostView, context: Context) {
        nsView.responder.controller = controller
        // SwiftUI がウインドウのレスポンダ構成を組み替えた場合に備え、更新の
        // たびに差し込み直しを確認する（何も変わっていなければ即座に戻る）。
        nsView.ensureInstalled()
    }
}

/// レスポンダチェーンに置く実体。`QuickLookController` 自身をチェーンへ入れず
/// この薄い層を挟むのは、`acceptsPreviewPanelControl:` 等が ObjC の
/// カテゴリメソッド（＝ `nonisolated`）としてブリッジされるため、`@MainActor`
/// のコントローラを直接チェーンに置くと `MainActor.assumeIsolated` が
/// コントローラ側の全メソッドに散るのを避けるため。
final class QuickLookPanelResponder: NSResponder {
    weak var controller: QuickLookController?

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        // AppKit は常にメインスレッドからこれらを呼ぶ。
        MainActor.assumeIsolated { controller != nil }
    }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated { controller?.beginControlling(panel) }
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated { controller?.endControlling(panel) }
    }
}

/// 差し込み・取り外しのタイミングだけを担う、大きさゼロの非表示ビュー
/// [`WindowFrameAutosaveView`/`SplitPositionApplierView` と同じパターン]。
final class QuickLookResponderHostView: NSView {
    let responder = QuickLookPanelResponder()
    private weak var installedWindow: NSWindow?

    override var intrinsicContentSize: NSSize { NSSize(width: 0, height: 0) }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            uninstall()
        } else {
            ensureInstalled()
        }
    }

    func ensureInstalled() {
        guard let window else { return }
        // 既に先頭に居るならそのまま。
        if installedWindow === window, window.nextResponder === responder { return }
        // **必ず先に取り外してから差し込む**。誰かが自分より手前へ差し込むと
        // 自分は先頭ではなくなるが依然チェーンの途中に居るため、そのまま
        // 先頭へ繋ぎ直すと `responder.nextResponder` が巡り巡って自分へ戻る
        // 輪ができ、レスポンダチェーンの走査が止まらなくなる。
        uninstall()
        responder.nextResponder = window.nextResponder
        window.nextResponder = responder
        installedWindow = window
    }

    /// チェーンの途中に居る自分自身を、前後を繋ぎ直して取り除く。
    /// 先頭に居るとは限らない（他の誰かが手前へ差し込むことがある）ため、
    /// ウインドウから順に前任者を探してから外す。
    private func uninstall() {
        guard let window = installedWindow else { return }
        defer { installedWindow = nil }
        var predecessor: NSResponder = window
        // 万一チェーンが輪になっていても抜けられるよう、走査の長さを区切る。
        for _ in 0..<64 {
            guard let next = predecessor.nextResponder else { return }
            if next === responder {
                predecessor.nextResponder = responder.nextResponder
                responder.nextResponder = nil
                return
            }
            predecessor = next
        }
    }
}
