import AppKit
import SwiftUI

/// 幅を固定できるポップアップ（`NSPopUpButton` の薄いラッパ）。
///
/// SwiftUI のメニュー式 `Picker` は `.frame` を与えても**ボタン自体は内容幅の
/// まま**で、枠の中での位置が変わるだけ（実測。固定幅にできる Picker スタイルは
/// 存在しない、という既知の制限）。隣接する行のドロップダウンどうしの幅を
/// 揃える用途（一括リネームの「区切り文字」「桁数」［ユーザー要望］）のために、
/// AppKit の `NSPopUpButton` を直接使う。幅は SwiftUI 側の `.frame(width:)` に
/// 素直に従う。
struct FixedWidthPopUp<Tag: Hashable>: NSViewRepresentable {
    struct Item {
        let title: String
        let tag: Tag
    }

    let items: [Item]
    @Binding var selection: Tag
    /// 選択中の値の表示位置。`.right` で右揃え（数値・短い値の列を
    /// 揃えたいとき）。メニュー内の項目には影響しない。
    var titleAlignment: NSTextAlignment = .natural

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.target = context.coordinator
        button.action = #selector(Coordinator.didSelect(_:))
        button.alignment = titleAlignment
        // 内容幅への吸着をやめ、SwiftUI が提案する幅（`.frame`）に従わせる。
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.parent = self
        // 項目の同期。`addItem(withTitle:)` は**同名の既存項目を黙って消す**
        // という既知の罠があるため、メニューへ直接足す。
        let titles = items.map(\.title)
        if button.itemTitles != titles {
            button.menu?.removeAllItems()
            for item in items {
                button.menu?.addItem(NSMenuItem(title: item.title, action: nil, keyEquivalent: ""))
            }
        }
        if let index = items.firstIndex(where: { $0.tag == selection }) {
            button.selectItem(at: index)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor
    final class Coordinator: NSObject {
        var parent: FixedWidthPopUp
        init(_ parent: FixedWidthPopUp) { self.parent = parent }

        @objc func didSelect(_ sender: NSPopUpButton) {
            let index = sender.indexOfSelectedItem
            guard parent.items.indices.contains(index) else { return }
            parent.selection = parent.items[index].tag
        }
    }
}
