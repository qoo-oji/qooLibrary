import AppKit
import SwiftUI

/// マウスのサイドボタン（戻る/進む）・トラックパッドの2本指/3本指スワイプによる
/// 戻る/進む [ユーザー要望、要件定義書には無い。1-8 の実機検証時に要望があり、
/// `docs/Specifications/13_UI_共通基盤.md` §13.6「将来検討」に記録していたものを
/// ここで実装する]。SwiftUI に対応する modifier が無いため、`NSEvent` の
/// ローカルモニタ（自分のウインドウ宛のイベントのみを受け取る、`Info.plist`/
/// entitlement の追加や Accessibility 権限が不要なモニタ種別）で低レベルに検出する。
///
/// `WindowState.goBack()`/`goForward()`（1-8 で実装済み）は履歴が無いときは
/// 何もしない安全な no-op のため、ここでは `canGoBack`/`canGoForward` の
/// チェックをせずそのまま呼ぶ。
///
/// **根本原因と最終的な解決（詳細な試行錯誤は git 履歴参照）**: 「2本指で左右に
/// スクロール」（ページ間をスワイプの既定設定）は専用イベント種別ではなく通常の
/// `.scrollWheel` イベント列として届く。当初はこの値を自前で積算し固定の
/// ピクセルしきい値と比較する方式で実装したが、ごく軽いスワイプでは合計移動量が
/// 実測 1〜14px 程度しか記録されず、しきい値をどれだけ下げても検出できなかった。
/// 一方でユーザーからの指摘により、その軽いスワイプ中に中央ペインの `Table`
/// （`NSScrollView` 内包）が実際に横スクロールしようとしていることが判明し、
/// 「物理的な信号はもっと大きく、その大半を `Table` 自身が消費してしまって
/// おり、こちらのモニタに残っていたのは消費されなかったわずかな余りだった」
/// ことが分かった。ローカルモニタのハンドラで横方向優位のイベントに対して
/// `nil` を返す（＝ `Table` を含め以降どの view にも配送しない）ことで解決し、
/// 同じ操作で実測 500〜700px 規模の正しい移動量が積算されるようになった
/// （`handleTrackpadScrollGesture` 内、`viewDidMoveToWindow` のモニタ登録部分
/// 参照）。`NSTouch`（生のマルチタッチ座標）・`NSEvent.trackSwipeEvent`（Safari
/// 相当の正規化スワイプ API）も検討したが、前者は「2本指で左右にスクロール」が
/// 既にジェスチャーとして専有されており生のタッチイベント経路に流れてこず、
/// 後者は正規化された振れ幅がウインドウ幅に対して相対的で必要移動量が安定しな
/// かったため、いずれも採用しなかった。
private final class BackForwardGestureView: NSView {
    var onGoBack: (() -> Void)?
    var onGoForward: (() -> Void)?
    /// `true`（既定）: 2本指の横スワイプを戻る/進むとして扱い、`Table` 等の
    /// 通常の横スクロールには渡さない。`false`: 2本指の横スワイプは通常の
    /// 横スクロールとして扱い、戻る/進むには一切使わない（3本指スワイプ
    /// `handleSwipe` のみが戻る/進むの手段になる。OS 側の「ページ間をスワイプ」
    /// 設定を3本指に変更する必要があり、その案内は呼び出し側の UI で行う）。
    /// [ユーザー要望: 2本指横スワイプの用途を戻る/進むと通常のスクロールの
    /// どちらに使うか選べるようにしたい。トレードオフをユーザー自身に選ばせる、
    /// という原則に基づく]。
    var twoFingerSwipeForNavigation: Bool = true
    /// ウインドウ幅に依存しない固定のピクセル数。かつては個人差を吸収するため
    /// ユーザーが調整できるスライダーを設けていたが、根本原因（`Table` が横
    /// スクロールとして信号の大半を消費してしまっていたこと、上記型コメント
    /// 参照）を解決した結果、通常のスワイプで実測 500〜700px 規模の移動量が
    /// 安定して積算されるようになったため、調整 UI 自体が不要になり削除した
    /// [ユーザー判断]。
    private static let swipeThreshold: CGFloat = 60

    // `deinit` は nonisolated で呼ばれるため `nonisolated(unsafe)` にしている
    // [`WindowFrameAutosave.swift` と同じ理由]。`NSEvent.removeMonitor` は
    // どのスレッドからでも安全に呼べる。
    nonisolated(unsafe) private var monitor: Any?

    /// 「3本指で左右にスワイプ」設定向け（`NSEvent.EventType.swipe`）。
    /// 1回のフリックで `.swipe` イベントが複数回発生する可能性があるため、
    /// 連続発火を防ぐクールダウンを設ける [qooViewer `handleSwipe` と同じ設計]。
    private var lastSwipeTriggerAt: Date?
    private static let swipeCooldown: TimeInterval = 0.5

    /// 「2本指で左右にスクロール」（ページ間をスワイプの既定設定）向け。
    /// ジェスチャー全体（`.began`/`.mayBegin` 〜 `.ended`/`.cancelled`）を通して
    /// 積算し、終了時に一度だけ方向を判定する。
    private var gestureDeltaX: CGFloat = 0
    private var gestureDeltaY: CGFloat = 0
    /// 実機検証で判明: 非常に軽いタッチだと `.ended`/`.cancelled` が一度も
    /// 届かないまま `.began` だけで終わることがある（OS 側がジェスチャーとして
    /// 完了させていないと考えられる）。このタイマーで最後のイベントから一定時間
    /// （`gestureTimeout`）新しいイベントが来なければ、その時点で強制的に
    /// ジェスチャー終了とみなして判定する。
    nonisolated(unsafe) private var gestureTimeoutTimer: Timer?
    private static let gestureTimeout: TimeInterval = 0.2

    /// 現在ジェスチャーを積算中かどうか。`.began`/`.mayBegin` が1回の
    /// ジェスチャー中に複数回届くことがあるため、リセットは最初の1回だけに
    /// 限定するために使う（上記メソッドのコメント参照）。
    private var isInGesture = false

    /// 指を離した後の慣性スクロール（`momentumPhase`）中の移動量も積算に含める
    /// （`handleTrackpadScrollGesture` 参照）。軽いスワイプは指が触れている間の
    /// 移動量自体は小さくても、指を離した後の慣性スクロールが一定時間続くことが
    /// あるため。
    override var intrinsicContentSize: NSSize { NSSize(width: 0, height: 0) }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeMonitor()
        guard let window else { return }
        Self.log("installed for window=\(window)")
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.otherMouseDown, .scrollWheel, .swipe]) { [weak self, weak window] event in
            guard let self, event.window === window else { return event }
            switch event.type {
            case .otherMouseDown:
                self.handleMouseButton(event)
            case .scrollWheel:
                Self.log("scroll phase=\(event.phase.rawValue) momentum=\(event.momentumPhase.rawValue) dx=\(event.scrollingDeltaX) dy=\(event.scrollingDeltaY) locationInWindow=\(event.locationInWindow)")
                // `twoFingerSwipeForNavigation` が false の場合、2本指の横スワイプは
                // 通常の横スクロールとして扱いたいため、戻る/進むの判定自体を行わず
                // 配送も妨げない（下の `return event` へそのまま進む）。
                guard self.twoFingerSwipeForNavigation else { break }
                self.handleTrackpadScrollGesture(event)
                // 横方向優位のイベントはここで握りつぶし（`nil` を返す）、
                // `Table`（`NSScrollView`）を含め以降どの view にも配送しない。
                // ローカルモニタは通常の配送より前に実行されるため、これで
                // 確実に阻止できる [ユーザー指摘で判明: 中央ペインが実際に
                // 横スクロールしようとしていた＝物理的な信号は元々もっと
                // 大きく、その大半を `Table` 自身が消費していた。`Table` の
                // 内部スクロールビューを直接いじる方式（isa 差し替え等）は
                // private な内部実装への依存でリスクが大きいため、配送そのもの
                // を止めるこちらを採用した]。縦方向優位のイベントは通常通り
                // 配送し、`Table`/`List` の縦スクロールに影響しない。
                if abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) {
                    return nil
                }
            case .swipe:
                Self.log("swipe deltaX=\(event.deltaX) locationInWindow=\(event.locationInWindow)")
                self.handleSwipe(event)
            default:
                break
            }
            return event
        }
    }

    // ミリ秒精度のタイムスタンプ（`ProcessInfo.systemUptime`、単調増加でシステム
    // 時刻変更の影響を受けない）。実機検証でイベント間の実際の時間間隔を確認する
    // 際に必要になったため付けている。
    private static func log(_ message: String) {
        let ms = Int(ProcessInfo.processInfo.systemUptime * 1000)
        FileHandle.standardError.write("[BackForwardGesture] t=\(ms)ms \(message)\n".data(using: .utf8)!)
    }

    /// 多くのマウスで「戻る」= ボタン3、「進む」= ボタン4 [13章 §13.6「将来検討」の記録通り]。
    ///
    /// **既知の制約**: Logitech Options+ など、サイドボタンをアプリ側で独自にリマップする
    /// メーカー製ユーティリティを使っている場合、生の `otherMouseDown`（ボタン3/4）
    /// イベント自体がこのアプリに一切届かないことを実機検証で確認した（ユーティリティ側が
    /// ボタンを横取りするため）。この場合は OS レベルでの回避策が無く、ユーティリティ側の
    /// 設定で対象ボタンを「戻る」「進む」相当のキーボードショートカット（`⌘[`/`⌘]` または
    /// `⌘←`/`⌘→`、1-8 で実装済み）に割り当ててもらう必要がある。
    private func handleMouseButton(_ event: NSEvent) {
        switch event.buttonNumber {
        case 3: onGoBack?()
        case 4: onGoForward?()
        default: break
        }
    }

    /// 「ページ間をスワイプ」が2本指設定の場合、専用イベント種別（`.swipe`）ではなく
    /// 通常の `.scrollWheel` イベントの並びとして届く。指が触れてから離れるまで
    /// （`phase` が `.began`/`.mayBegin` で始まり `.ended`/`.cancelled` で終わる
    /// 一連のイベント）を1回のジェスチャーとしてまとめ、その間の
    /// `scrollingDeltaX`/`Y` を積算しておいて、ジェスチャーが終わった時点で
    /// 初めて「横方向優位だったか」を判定する。`NSEvent.Phase` は `OptionSet`
    /// のため `switch` の厳密一致ではなく `.contains()`/`.isEmpty` で判定する
    /// （実機検証で判明した重要事項、詳細は上記型コメント参照）。
    private func handleTrackpadScrollGesture(_ event: NSEvent) {
        let phase = event.phase
        let momentumPhase = event.momentumPhase
        // 実機検証で判明: 1回の物理的なジェスチャーの中で `.began` が複数回
        // （`.mayBegin`/`.began` を挟みながら）届くことがあり、「`.began` を
        // 見るたびにリセットする」実装だと、そのたびに積算が0に戻ってしまい
        // 実質的に一度も閾値へ到達できなかった。「まだジェスチャー中でない
        // ときだけ」リセットするようにし、ジェスチャー中かどうかは
        // `isInGesture` で追跡する。
        if (phase.contains(.began) || phase.contains(.mayBegin)) && !isInGesture {
            gestureDeltaX = 0
            gestureDeltaY = 0
            isInGesture = true
        }
        guard isInGesture else { return }
        // 指が触れている間（`phase`）だけでなく、指を離した後の慣性スクロール
        // （`momentumPhase`）中の移動量も積算に含める（上記型コメント参照、
        // 除外していた以前の設計から変更）。どちらも空でなければ積算対象。
        if !phase.isEmpty || !momentumPhase.isEmpty {
            gestureDeltaX += event.scrollingDeltaX
            gestureDeltaY += event.scrollingDeltaY
            scheduleGestureTimeout()
        }
        // 指を離した瞬間（`phase.ended`）では確定させない。慣性スクロールが
        // このあと始まる可能性があり、それも積算に含めたいため。慣性が実際に
        // 終わった（`momentumPhase.ended`）時点、またはキャンセル時点で確定する。
        // 慣性が一度も始まらない（`momentumPhase` が来ないまま終わる）場合は、
        // `scheduleGestureTimeout` のタイムアウトが最終的な確定手段になる
        // （以前から同じ役割だったタイマーをそのまま流用）。
        if momentumPhase.contains(.ended) || phase.contains(.cancelled) {
            finishGesture()
        }
    }

    /// 最後にイベントを受け取ってから `gestureTimeout` の間、新しいイベントが
    /// 来なければ強制的にジェスチャー終了とみなす（上記プロパティのコメント参照）。
    private func scheduleGestureTimeout() {
        gestureTimeoutTimer?.invalidate()
        gestureTimeoutTimer = Timer.scheduledTimer(withTimeInterval: Self.gestureTimeout, repeats: false) { [weak self] _ in
            Self.log("gesture timed out without .ended/.cancelled")
            self?.finishGesture()
        }
    }

    private func finishGesture() {
        gestureTimeoutTimer?.invalidate()
        gestureTimeoutTimer = nil
        guard isInGesture else { return }
        isInGesture = false
        let dx = gestureDeltaX
        let dy = gestureDeltaY
        gestureDeltaX = 0
        gestureDeltaY = 0
        Self.log("gesture ended: totalDx=\(dx) totalDy=\(dy)")
        guard abs(dx) >= Self.swipeThreshold else { return }
        // 縦方向優位だった場合（2本指の通常の縦スクロール）は無視する。
        guard abs(dx) > abs(dy) else { return }
        if dx > 0 {
            onGoBack?()
        } else {
            onGoForward?()
        }
    }

    /// 「ページ間をスワイプ」が3本指/4本指設定の場合の専用イベント種別。
    /// 1回のフリックで複数回発火しうるためクールダウンを設ける
    /// [qooViewer `handleSwipe` と同じ設計]。
    private func handleSwipe(_ event: NSEvent) {
        let now = Date()
        if let lastSwipeTriggerAt, now.timeIntervalSince(lastSwipeTriggerAt) < Self.swipeCooldown { return }
        lastSwipeTriggerAt = now
        if event.deltaX > 0 {
            onGoBack?()
        } else if event.deltaX < 0 {
            onGoForward?()
        }
    }

    private func removeMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
        gestureTimeoutTimer?.invalidate()
    }
}

private struct BackForwardGestureSupport: NSViewRepresentable {
    let onGoBack: () -> Void
    let onGoForward: () -> Void
    let twoFingerSwipeForNavigation: Bool

    func makeNSView(context: Context) -> BackForwardGestureView {
        let view = BackForwardGestureView()
        view.onGoBack = onGoBack
        view.onGoForward = onGoForward
        view.twoFingerSwipeForNavigation = twoFingerSwipeForNavigation
        return view
    }

    func updateNSView(_ nsView: BackForwardGestureView, context: Context) {
        nsView.onGoBack = onGoBack
        nsView.onGoForward = onGoForward
        nsView.twoFingerSwipeForNavigation = twoFingerSwipeForNavigation
    }
}

extension View {
    /// マウスのサイドボタン・トラックパッドのスワイプで戻る/進むを行う
    /// [ユーザー要望]。**ウインドウ単位で安定している場所（`MainWindowView`）に
    /// 1回だけ適用すること** — タブごとに再生成されうる `FolderContentView` に
    /// 付けるとジェスチャーの途中でモニタが再設置され、イベントストリームが
    /// 途切れることを実機検証で確認した（上記型コメント参照）。
    /// `twoFingerSwipeForNavigation` は `BackForwardGestureView` 参照。
    func backForwardGestureSupport(onGoBack: @escaping () -> Void, onGoForward: @escaping () -> Void, twoFingerSwipeForNavigation: Bool) -> some View {
        background(BackForwardGestureSupport(onGoBack: onGoBack, onGoForward: onGoForward, twoFingerSwipeForNavigation: twoFingerSwipeForNavigation))
    }
}
