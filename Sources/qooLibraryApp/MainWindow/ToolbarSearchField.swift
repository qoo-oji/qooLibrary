import AppKit
import SwiftUI

/// ツールバーに置く検索欄 [1-16 検索、ユーザー要望「Finder 風に普段はボタンで、
/// クリックすると検索ボックスになる」]。
///
/// **SwiftUI の `TextField` ではなく `NSSearchField` を包む** [実機検証で判明]。
/// 最初は `TextField` + `@FocusState` で実装したが、**ツールバー項目の中では
/// `.focused()` が効かず、⌘F でも虫めがねを押しても文字が一切入らなかった**
/// （プレースホルダのまま。ツールバーの中身は View 本体とは別の場所でホストされる
/// ため、フォーカススコープが繋がっていないと考えられる）。`NSSearchField` なら
/// 実体を自分で握れるので `makeFirstResponder` で確実にフォーカスできる。
///
/// 副産物として、macOS 標準の検索欄そのものになる——虫めがねのアイコン、
/// クリアボタン（×）、Esc でのキャンセルがすべて素で手に入る。
///
/// なお **`.searchable` は使えない**: macOS 26 の
/// `searchToolbarBehavior(.minimize)`（まさにこの「普段はボタン」の挙動）は
/// `SearchToolbarBehavior.minimize` が `@available(macOS, unavailable)` で
/// iOS/visionOS 専用（SDK の `SwiftUI.swiftinterface` で確認）。加えて
/// `.searchable` が挿し込むツールバー項目は位置を選べず、「表示切替の左」という
/// 配置指定も満たせない。
struct ToolbarSearchField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    /// Esc が押されたとき。呼び出し側が内容を消して畳む。
    let onCancel: () -> Void
    /// 入力が空のままフォーカスを失ったとき。呼び出し側が畳む。
    let onEndEditingWhileEmpty: () -> Void

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.delegate = context.coordinator
        field.placeholderString = placeholder
        field.stringValue = text
        field.sendsWholeSearchString = false
        field.sendsSearchStringImmediately = true
        // 生成直後はまだウインドウに載っていないため 1 サイクル待ってから
        // フォーカスする（`InlineRenameSupport`/`SplitPositionApplierView` と
        // 同じ理由）。**この View は「開いている間だけ」生成されるので、
        // ここでフォーカスすれば「開いたら即入力できる」が成立する。**
        DispatchQueue.main.async {
            field.window?.makeFirstResponder(field)
        }
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.parent = self
        // 外から変わった場合（フォルダ移動で絞り込みが解除される等）だけ反映する。
        // 入力のたびに書き戻すとカーソル位置が飛ぶ。
        if field.stringValue != text {
            field.stringValue = text
        }
        if field.placeholderString != placeholder {
            field.placeholderString = placeholder
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: ToolbarSearchField

        init(parent: ToolbarSearchField) {
            self.parent = parent
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSSearchField else { return }
            parent.text = field.stringValue
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            guard let field = obj.object as? NSSearchField, field.stringValue.isEmpty else { return }
            parent.onEndEditingWhileEmpty()
        }

        /// Esc（`cancelOperation`）を横取りする。`NSSearchField` の既定は
        /// 「入力を消す」だけで欄は残るが、Finder は畳むところまで行う。
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
            parent.onCancel()
            return true
        }
    }
}
