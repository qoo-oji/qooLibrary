import AppKit
import SwiftUI

/// 保存済みの分割位置を、ウインドウに実際に表示された直後に一度だけ
/// `NSSplitView.setPosition(_:ofDividerAt:)` で強制適用する [UI-02]。
///
/// `HSplitView`（SwiftUI）は `.frame(idealWidth:)` を初期レイアウトのヒント
/// として事実上使わない（実機検証で確認: 常に等幅で開始する）。`minWidth` を
/// 初回だけ一時的に引き上げてあとで戻す方式も試したが、`minWidth` を戻した
/// 瞬間に再レイアウトが走り、しかもそのたびに違う中途半端な幅へ収束する
/// （実機検証で複数回にわたり値が変動し続けることを確認）という、さらに悪い
/// 結果になった。`.frame()` の制約をいじる SwiftUI 側のアプローチはどれも
/// 信頼できないと判断し、AppKit の確定的な API を直接呼ぶ方式に切り替えた。
/// この view はゼロサイズで、`superview` を遡って実際の `NSSplitView` を
/// 見つけたら一度だけ位置を設定する。
///
/// 縦分割（`VSplitView`、ペインが上下に積まれる形）にも同じ仕組みが使える。
/// `NSSplitView` から見ると違いは「仕切りが縦か横か」だけで、`setPosition` に
/// 渡すのは前者なら左端からの x、後者なら上端からの y になる。
enum SplitPaneAxis {
    /// ペインが左右に並ぶ（`HSplitView`・`NSSplitView.isVertical == true`）。
    case horizontal
    /// ペインが上下に積まれる（`VSplitView`・`NSSplitView.isVertical == false`）。
    case vertical
}

final class SplitPositionApplierView: NSView {
    var dividerIndex = 0
    /// 先頭側ペイン（左／上）の大きさ。
    var targetSize: CGFloat = 0
    var axis: SplitPaneAxis = .horizontal
    /// `false`: 自分の左端からの幅として直接使う（左ペイン向け）。
    /// `true`: 分割ビュー全体の幅から逆算する（右ペイン向け。`setPosition` の
    /// 引数はウインドウ左端からのx座標であり、「右ペインの幅」そのものでは
    /// ないため）。
    var anchorsToTrailingEdge = false
    /// 仕切りが動いたときに、**先頭側ペインの実寸**を知らせる。
    ///
    /// **観測も AppKit 側で行うのが要点**［実機検証で発見］。SwiftUI の
    /// `GeometryReader` で測ったペインの高さは、`setPosition` に渡す
    /// 「分割ビュー上端からの位置」と 44pt ほどずれていた（ツールバー分の
    /// 余白が分割ビューの座標には含まれ、ペインの可視領域には含まれないため）。
    /// 保存する量と適用する量が違うと、**起動のたびにその差だけ縮んでいく**
    /// （実測: 537 → 493 → …）。同じ量を扱えばこの手のずれは起こり得ない。
    var onDividerMoved: ((CGFloat) -> Void)?
    private var hasApplied = false
    private var observation: NSObjectProtocol?

    override var intrinsicContentSize: NSSize { NSSize(width: 0, height: 0) }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyIfNeeded()
    }

    /// ウインドウから外れたら購読をやめる。**`deinit` では外せない** —
    /// Swift 6 では非分離の `deinit` からメインアクタ隔離のプロパティに
    /// 触れられないため（`NSView` は `@MainActor`）。
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        guard newWindow == nil, let observation else { return }
        NotificationCenter.default.removeObserver(observation)
        self.observation = nil
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        applyIfNeeded()
    }

    private func applyIfNeeded() {
        guard window != nil, !hasApplied, let splitView = enclosingSplitView else { return }
        hasApplied = true
        // レイアウトパスの最中に呼ぶと上書きされることがあるため、
        // 現在のレイアウトが確定してから次の実行サイクルで適用する。
        // `splitView.bounds.width` もこの時点でようやく実際の値になる。
        DispatchQueue.main.async { [weak self, weak splitView] in
            guard let self, let splitView else { return }
            let total = self.axis == .horizontal ? splitView.bounds.width : splitView.bounds.height
            let position: CGFloat = self.anchorsToTrailingEdge
                ? total - splitView.dividerThickness - self.targetSize
                : self.targetSize
            splitView.setPosition(position, ofDividerAt: self.dividerIndex)
            self.observeDividerMoves(of: splitView)
        }
    }

    private func observeDividerMoves(of splitView: NSSplitView) {
        guard onDividerMoved != nil, observation == nil else { return }
        observation = NotificationCenter.default.addObserver(
            forName: NSSplitView.didResizeSubviewsNotification,
            object: splitView, queue: .main
        ) { [weak self, weak splitView] _ in
            guard let self, let splitView, let first = splitView.arrangedSubviews.first else { return }
            let size = self.axis == .horizontal ? first.frame.width : first.frame.height
            // ウインドウ全体のリサイズでも届く。そのときの値も「今の実寸」
            // なので、そのまま覚えてよい。
            if size > 0 { self.onDividerMoved?(size) }
        }
    }

    /// **向きが一致する最初の分割ビュー**を探す。単に最初の `NSSplitView` を
    /// 取ると、分割が入れ子になっている場面（左サイドバーの中に上下分割が
    /// ある等）で意図しない側を掴む。
    private var enclosingSplitView: NSSplitView? {
        let wantsVertical = axis == .horizontal // isVertical == true は左右分割
        var view: NSView? = superview
        while let current = view {
            if let splitView = current as? NSSplitView, splitView.isVertical == wantsVertical {
                return splitView
            }
            view = current.superview
        }
        return nil
    }
}

struct SplitPositionApplier: NSViewRepresentable {
    let dividerIndex: Int
    let targetSize: CGFloat
    var axis: SplitPaneAxis = .horizontal
    var anchorsToTrailingEdge = false
    /// 仕切りが動いたら先頭側ペインの実寸を知らせる（省略すると観測しない）。
    var onDividerMoved: ((CGFloat) -> Void)?

    func makeNSView(context: Context) -> SplitPositionApplierView {
        let view = SplitPositionApplierView()
        view.dividerIndex = dividerIndex
        view.targetSize = targetSize
        view.axis = axis
        view.anchorsToTrailingEdge = anchorsToTrailingEdge
        view.onDividerMoved = onDividerMoved
        return view
    }

    func updateNSView(_ nsView: SplitPositionApplierView, context: Context) {
        // 位置の適用は初回きり。以後は `targetSize` の変化（＝自分が保存した
        // 値の書き戻し）でユーザーの操作を上書きしないよう、何もしない。
        nsView.onDividerMoved = onDividerMoved
    }
}

/// ペインの実測幅を `GeometryReader` で観測し `UserDefaults`
/// （`@AppStorage`）へ書き戻す。書き込みだけを担当し、初期表示への反映は
/// `SplitPositionApplier` が別途行う（役割を分離: こちらは「幅が変わったら
/// 覚える」、あちらは「起動時に覚えた幅を1回だけ適用する」）。
private struct WidthPersistingModifier: ViewModifier {
    @Binding var storedWidth: Double

    func body(content: Content) -> some View {
        content.background {
            GeometryReader { geometry in
                Color.clear
                    .onChange(of: geometry.size.width) { _, newValue in
                        if newValue > 0 {
                            storedWidth = newValue
                        }
                    }
            }
        }
    }
}

/// 3 ペイン構成ウインドウ。3 ペイン／2 ペインは必ずこの共通コンポーネントを使い、
/// 個別実装を禁止する [UI-02][CP-01]。
public struct ThreePaneWindow<Left: View, Center: View, Right: View>: View {
    private let id: String
    private let left: Left
    private let center: Center
    private let right: Right
    /// 右ペインをたたむ（隠す）[実機検証時のユーザー要望]。中央ペインが
    /// そのぶん広がり、ウインドウ全体の幅は変わらない。
    ///
    /// あえて `@AppStorage` ではなく呼び出し側から渡される単純な `Bool` に
    /// している。この値は `HSplitView` 内で右ペインを含めるかどうかの `if`
    /// 条件に使われるが、タブバーの表示/非表示を同様の `if` 条件の中で
    /// `@AppStorage` を直接読む形にした際、SwiftUI の Observation が無限に
    /// 再評価を繰り返しアプリがハングする不具合が実機検証で見つかっている
    /// （`CLAUDE.md` 参照）。同じ危険なパターンを踏まないよう、永続化するなら
    /// 呼び出し側（`@State` 等）で行い、ここでは受け取った値をそのまま使うだけ
    /// にとどめる。
    private let isRightPaneCollapsed: Bool

    @AppStorage private var leftWidth: Double
    @AppStorage private var rightWidth: Double

    public init(
        id: String,
        isRightPaneCollapsed: Bool = false,
        @ViewBuilder left: () -> Left,
        @ViewBuilder center: () -> Center,
        @ViewBuilder right: () -> Right
    ) {
        self.id = id
        self.isRightPaneCollapsed = isRightPaneCollapsed
        self.left = left()
        self.center = center()
        self.right = right()
        self._leftWidth = AppStorage(wrappedValue: 220, "qoo.threePane.\(id).leftWidth")
        self._rightWidth = AppStorage(wrappedValue: 280, "qoo.threePane.\(id).rightWidth")
    }

    public var body: some View {
        HSplitView {
            left
                .frame(minWidth: 180, maxWidth: 400)
                .modifier(WidthPersistingModifier(storedWidth: $leftWidth))
                .background(SplitPositionApplier(dividerIndex: 0, targetSize: leftWidth))
            center
                .frame(minWidth: 360)
            if !isRightPaneCollapsed {
                right
                    .frame(minWidth: 220, maxWidth: 420)
                    .modifier(WidthPersistingModifier(storedWidth: $rightWidth))
                    .background(SplitPositionApplier(dividerIndex: 1, targetSize: rightWidth, anchorsToTrailingEdge: true))
            }
        }
        .accessibilityIdentifier("ThreePaneWindow.\(id)")
    }
}

/// 2 ペイン構成 [UI-03][CP-01]
public struct TwoPaneWindow<Left: View, Right: View>: View {
    private let id: String
    private let left: Left
    private let right: Right

    @AppStorage private var leftWidth: Double

    public init(
        id: String,
        @ViewBuilder left: () -> Left,
        @ViewBuilder right: () -> Right
    ) {
        self.id = id
        self.left = left()
        self.right = right()
        self._leftWidth = AppStorage(wrappedValue: 240, "qoo.twoPane.\(id).leftWidth")
    }

    public var body: some View {
        HSplitView {
            left
                .frame(minWidth: 180, maxWidth: 420)
                .modifier(WidthPersistingModifier(storedWidth: $leftWidth))
                .background(SplitPositionApplier(dividerIndex: 0, targetSize: leftWidth))
            right
                .frame(minWidth: 360)
        }
        .accessibilityIdentifier("TwoPaneWindow.\(id)")
    }
}
