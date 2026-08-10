import SwiftUI

/// 3 ペイン構成ウインドウ。3 ペイン／2 ペインは必ずこの共通コンポーネントを使い、
/// 個別実装を禁止する [UI-02][CP-01]。
///
/// ペイン幅の保存・復元（`id` ごとの永続化）は `WindowState`
/// （11章 §11.4、まだ未実装）が担う領域のため、ここでは構造のみを提供する。
public struct ThreePaneWindow<Left: View, Center: View, Right: View>: View {
    private let id: String
    private let left: Left
    private let center: Center
    private let right: Right

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
    }

    public var body: some View {
        HSplitView {
            left
                .frame(minWidth: 180, idealWidth: 220, maxWidth: 400)
            center
                .frame(minWidth: 360)
            right
                .frame(minWidth: 220, idealWidth: 280, maxWidth: 420)
        }
        .accessibilityIdentifier("ThreePaneWindow.\(id)")
    }
}

/// 2 ペイン構成 [UI-03][CP-01]
public struct TwoPaneWindow<Left: View, Right: View>: View {
    private let id: String
    private let left: Left
    private let right: Right

    public init(
        id: String,
        @ViewBuilder left: () -> Left,
        @ViewBuilder right: () -> Right
    ) {
        self.id = id
        self.left = left()
        self.right = right()
    }

    public var body: some View {
        HSplitView {
            left
                .frame(minWidth: 180, idealWidth: 240, maxWidth: 420)
            right
                .frame(minWidth: 360)
        }
        .accessibilityIdentifier("TwoPaneWindow.\(id)")
    }
}
