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
private final class SplitPositionApplierView: NSView {
    var dividerIndex = 0
    var targetWidth: CGFloat = 0
    /// `false`: 自分の左端からの幅として直接使う（左ペイン向け）。
    /// `true`: 分割ビュー全体の幅から逆算する（右ペイン向け。`setPosition` の
    /// 引数はウインドウ左端からのx座標であり、「右ペインの幅」そのものでは
    /// ないため）。
    var anchorsToTrailingEdge = false
    private var hasApplied = false

    override var intrinsicContentSize: NSSize { NSSize(width: 0, height: 0) }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyIfNeeded()
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
            let position: CGFloat = self.anchorsToTrailingEdge
                ? splitView.bounds.width - splitView.dividerThickness - self.targetWidth
                : self.targetWidth
            splitView.setPosition(position, ofDividerAt: self.dividerIndex)
        }
    }

    private var enclosingSplitView: NSSplitView? {
        var view: NSView? = superview
        while let current = view {
            if let splitView = current as? NSSplitView { return splitView }
            view = current.superview
        }
        return nil
    }
}

private struct SplitPositionApplier: NSViewRepresentable {
    let dividerIndex: Int
    let targetWidth: CGFloat
    var anchorsToTrailingEdge = false

    func makeNSView(context: Context) -> SplitPositionApplierView {
        let view = SplitPositionApplierView()
        view.dividerIndex = dividerIndex
        view.targetWidth = targetWidth
        view.anchorsToTrailingEdge = anchorsToTrailingEdge
        return view
    }

    func updateNSView(_ nsView: SplitPositionApplierView, context: Context) {}
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

    @AppStorage private var leftWidth: Double
    @AppStorage private var rightWidth: Double

    public init(
        id: String,
        @ViewBuilder left: () -> Left,
        @ViewBuilder center: () -> Center,
        @ViewBuilder right: () -> Right
    ) {
        self.id = id
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
                .background(SplitPositionApplier(dividerIndex: 0, targetWidth: leftWidth))
            center
                .frame(minWidth: 360)
            right
                .frame(minWidth: 220, maxWidth: 420)
                .modifier(WidthPersistingModifier(storedWidth: $rightWidth))
                .background(SplitPositionApplier(dividerIndex: 1, targetWidth: rightWidth, anchorsToTrailingEdge: true))
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
                .background(SplitPositionApplier(dividerIndex: 0, targetWidth: leftWidth))
            right
                .frame(minWidth: 360)
        }
        .accessibilityIdentifier("TwoPaneWindow.\(id)")
    }
}
