import QooKit
import SwiftUI

/// 次のキー入力を捕捉して `KeyCombo` に変換する小さなボタン
/// [1-12 環境設定「キーボード」タブ、KB2-03]。既存コードに前例が無いため
/// 新規に実装した。`KeyPress.qooKeyCombo`（`KeyComboConversion.swift`）で
/// `KeyCombo` へ変換する。
///
/// クリックすると `isRecording` を立てて自身にキーボードフォーカスを移し、
/// 次に届いた `.onKeyPress` を確定させる。Esc も含め、押されたキーはそのまま
/// `onCapture` に渡す（Esc をショートカットとして割り当てたい操作が
/// 将来あり得るため、特別扱いで「キャンセル」の意味を持たせていない。
/// 誤って記録した場合は追加後にチップの ✕ で削除すればよい）。
struct KeyComboRecorder: View {
    @Binding var isRecording: Bool
    let onCapture: (KeyCombo) -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        Button(isRecording ? "preferences.keyboard.pressAKey" : "preferences.keyboard.addCombo") {
            isRecording = true
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .focusable()
        .focused($isFocused)
        .onChange(of: isRecording) { _, newValue in
            isFocused = newValue
        }
        .onKeyPress(phases: .down) { press in
            guard isRecording else { return .ignored }
            isRecording = false
            onCapture(press.qooKeyCombo)
            return .handled
        }
    }
}
