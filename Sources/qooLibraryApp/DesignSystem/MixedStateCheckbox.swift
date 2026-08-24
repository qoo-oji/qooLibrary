import AppKit
import SwiftUI

/// 三状態のチェックボックス（`NSButton` の薄いラッパ）。
///
/// **SwiftUI の `Toggle` は三状態を表せない**——`isOn: Bool` しか受け取らず、
/// 「一部に付いている」を描く手段が無い。複数選択でのラベルの一括付与／削除
/// [RP-02] はこの中間状態が要（`FixedWidthPopUp` と同じ理由で AppKit を使う）。
///
/// **クリックの巡回は AppKit に任せてよい。** `allowsMixedState` を立てた
/// `NSButton` は 中間 → オン → オフ → オン… と巡回する——中間からオンへ進む
/// のは、こちらが決めた「`.some` を押したら全部に付ける」[RP-02] と同じ向き。
/// ただし**押された後の見た目はモデルから描き直す**（`onChange` の中で DB へ
/// 書き、その結果を読み直す）ので、ボタン自身の状態は当てにしない。
struct MixedStateCheckbox: NSViewRepresentable {
    enum State: Equatable { case off, mixed, on }

    let state: State
    /// 押されたときに呼ぶ。**新しい状態は渡さない**——次に何になるかは
    /// 呼び出し側（モデル）が決めることで、ボタンの巡回結果ではない。
    let onToggle: () -> Void

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(checkboxWithTitle: "", target: context.coordinator,
                              action: #selector(Coordinator.didClick(_:)))
        button.allowsMixedState = true
        button.setContentHuggingPriority(.required, for: .horizontal)
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.parent = self
        // `allowsMixedState` は「巡回に中間を含めるか」も兼ねる。中間でない
        // ときに真のままだと、オフ → 中間 → オン と 3 回押す羽目になる。
        button.allowsMixedState = state == .mixed
        button.state = switch state {
        case .off: .off
        case .mixed: .mixed
        case .on: .on
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor
    final class Coordinator: NSObject {
        var parent: MixedStateCheckbox
        init(_ parent: MixedStateCheckbox) { self.parent = parent }

        @objc func didClick(_ sender: NSButton) {
            parent.onToggle()
        }
    }
}
