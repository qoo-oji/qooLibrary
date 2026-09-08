#if DEBUG
import AppKit
import Foundation

/// `NSMenu` を木として読み、経路で 1 項目を選び、実際に押す [MT-33]。
///
/// **メニューバーとコンテキストメニューで実装を分けない。** どちらも素の
/// `NSMenu` で、違うのは根の取り方だけ——分けると片方だけ直して取り残す
/// （このリポジトリが繰り返し踏んでいる形）。
@MainActor
enum ControlMenuTree {
    /// 木として書き出す。
    ///
    /// **走査の前に `NSMenu.update()` を呼ぶ。** 項目の有効/無効は「メニューが
    /// 開かれたとき」に検証されるので、呼ばずに読むと古い状態が返る。
    ///
    /// **題は伏字を通す** [CT-13]。メニューの題は静的とは限らない——Undo の
    /// 題（「「作品名A」を移動を取り消す」）や「(名前)に展開」には**利用者の
    /// ファイル名がそのまま入る**。ここを素通しにすると、口が漏洩経路になる。
    static func dump(_ menu: NSMenu, path: [String], depth: Int) -> [[String: Any]] {
        menu.update()
        return menu.items.enumerated().map { index, item in
            let title = ControlRedaction.apply(item.title)
            var node: [String: Any] = [
                "index": index,
                "title": title,
                "enabled": item.isEnabled,
                "path": (path + [title]).joined(separator: " > "),
            ]
            if item.isSeparatorItem { node["separator"] = true }
            if item.state == .on { node["state"] = "on" }
            if item.state == .mixed { node["state"] = "mixed" }
            if item.isAlternate { node["alternate"] = true }
            if item.isHidden { node["hidden"] = true }
            if !item.keyEquivalent.isEmpty {
                node["key"] = item.keyEquivalent
                node["modifiers"] = modifierNames(item.keyEquivalentModifierMask)
            }
            if let submenu = item.submenu {
                if depth > 1 {
                    node["children"] = dump(submenu, path: path + [title], depth: depth - 1)
                } else {
                    node["hasChildren"] = true
                }
            }
            return node
        }
    }

    static func modifierNames(_ mask: NSEvent.ModifierFlags) -> [String] {
        var names: [String] = []
        if mask.contains(.command) { names.append("command") }
        if mask.contains(.shift) { names.append("shift") }
        if mask.contains(.option) { names.append("option") }
        if mask.contains(.control) { names.append("control") }
        return names
    }

    /// メニューを実体化する。
    ///
    /// **SwiftUI が組むサブメニューは `update()` の 1 度では効かない**
    /// ［実測］。項目そのものは 1 度目で現れるのに、押しても何も起きない
    /// ——動作の結び付けが後の周回で入るためと見られる。**`menu:dump` を
    /// 先に走らせると押せるようになる**という食い違いを実際に踏んだので、
    /// 押す側でも同じだけ温めてから押す [CT-18]。
    ///
    /// 走査は経路の深さぶんに留める（**格子状に舐めない**——`ctx:*` の
    /// 注記と同じく、SwiftUI の組み立てを大量に走らせると重い）。
    static func warm(_ menu: NSMenu, depth: Int) {
        guard depth > 0 else { return }
        menu.update()
        for item in menu.items {
            if let submenu = item.submenu { warm(submenu, depth: depth - 1) }
        }
    }

    /// 経路で 1 項目を選ぶ。完全一致 → 前方一致 → 部分一致 の順に探す。
    ///
    /// **メニューの題は状態で変わる**（「シリーズごとにまとめる」↔「巻ごとに
    /// 表示」、「〜を表示」↔「〜を隠す」）ので、呼ぶ側が完全な題を知らなくても
    /// 届くようにしてある。
    ///
    /// **照合は伏字を通す前の生の題で行う。** 伏せた題（`⟨9 文字⟩`）で照合
    /// させると、呼ぶ側が読めた題をそのまま渡せなくなる——読めたということは
    /// 許可語なので、生の題と一致する。
    static func resolve(_ components: [String], in root: NSMenu) -> NSMenuItem? {
        var menu: NSMenu? = root
        var found: NSMenuItem?
        for component in components {
            guard let current = menu else { return nil }
            current.update()
            guard let item = current.items.enumerated().first(where: {
                matchesComponent($0.element, component, index: $0.offset)
            })?.element else {
                return nil
            }
            found = item
            menu = item.submenu
        }
        return found
    }

    /// 押す。**`performActionForItem(at:)` は target/action を送る**ので、
    /// 利用者がクリックしたのと同じ経路を通る。
    static func invoke(_ item: NSMenuItem) -> Data {
        guard let owner = item.menu else {
            return ControlResponse.failure("項目が親メニューを持ちません")
        }
        owner.update()
        guard item.isEnabled else {
            return ControlResponse.failure("項目が無効です: \(ControlRedaction.apply(item.title))")
        }
        let index = owner.index(of: item)
        owner.performActionForItem(at: index)
        return ControlResponse.success([
            "invoked": ControlRedaction.apply(item.title),
            "index": index,
        ])
    }

    /// 経路の 1 段の照合。**`#3` のように書くと添字で指す** ——伏字で題が
    /// 読めない項目（AppKit の標準文言など、許可語から作れないもの）を指す
    /// 唯一の手段。木の `index` をそのまま渡せる。
    static func matchesComponent(_ item: NSMenuItem, _ component: String, index: Int) -> Bool {
        if component.hasPrefix("#"), let wanted = Int(component.dropFirst()) {
            return wanted == index
        }
        return matches(item.title, component)
    }

    static func pathComponents(_ raw: Any?) -> [String]? {
        if let array = raw as? [String], !array.isEmpty { return array }
        if let text = raw as? String, !text.isEmpty {
            return text.components(separatedBy: ">").map {
                $0.trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    static func matches(_ title: String, _ wanted: String) -> Bool {
        if title == wanted { return true }
        if title.hasPrefix(wanted) { return true }
        return title.localizedCaseInsensitiveContains(wanted)
    }
}
#endif
