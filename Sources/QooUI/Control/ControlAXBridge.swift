#if DEBUG
import AppKit
import ApplicationServices
import Foundation

/// 自分自身のプロセスへ AX（`AXUIElement`）で問い合わせる [MT-33]。
///
/// **なぜ `NSAccessibilityProtocol` を直に読む経路と別に要るのか**: SwiftUI の
/// ビューは `accessibilityTitle()` 等を実装しておらず、プロセス内から素直に
/// 読むと役割が `Unknown`・題が空の木しか取れない［実測］。外部の AX クライアント
/// （検証で使ってきた `uitool`）が正しい題を読めていたのは、**AX サーバー層が
/// SwiftUI の要素を解決している**ため。同じ層へ届くにはこの API を通るしかない。
///
/// **必ずメインスレッドから呼ぶこと** ［実測］。同一プロセスへの AX は
/// プロセス間のメッセージにならず、**呼んだスレッドでそのまま実行される** ——
/// ワーカーから `AXUIElementPerformAction` を呼んだところ、SwiftUI の
/// `ButtonAction` が `MainActor.assumeIsolated` を実行して隔離の表明が破れ、
/// `dispatch_assert_queue_fail` → `SIGTRAP` でプロセスごと落ちた。
/// 「別プロセスへ問い合わせるのだからワーカーから呼ぶべき」という直感は、
/// 相手が自分自身のときには当てはまらない。
@MainActor
enum ControlAXBridge {
    /// メインが応答しないときに永久に待たないための上限（秒）。
    private static let messagingTimeout: Float = 5

    static func run(_ command: String, _ args: [String: Any]) -> Data {
        let app = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        AXUIElementSetMessagingTimeout(app, messagingTimeout)
        switch command {
        case "ax:dump": return dump(app, args)
        case "ax:press": return press(app, args)
        case "ax:setValue": return setValue(app, args)
        case "ax:select": return select(app, args)
        case "ax:attributes": return attributes(app, args)
        default: return ControlResponse.failure("知らないコマンドです: \(command)")
        }
    }

    // MARK: - 読み出し

    private static func dump(_ app: AXUIElement, _ args: [String: Any]) -> Data {
        let depth = args["depth"] as? Int ?? 12
        guard let windows = value(app, kAXWindowsAttribute) as? [AXUIElement] else {
            return ControlResponse.failure("ウインドウを読めませんでした")
        }
        let wanted = args["window"] as? String
        let targets = wanted.map { name in
            windows.filter { matches(title(of: $0) ?? "", name) }
        } ?? windows
        guard !targets.isEmpty else {
            return ControlResponse.failure("ウインドウが見つかりません: \(wanted ?? "")")
        }
        return ControlResponse.success([
            "windows": targets.map { node($0, depth: depth) },
        ])
    }

    private static func node(_ element: AXUIElement, depth: Int) -> [String: Any] {
        var result: [String: Any] = [:]
        if let role = value(element, kAXRoleAttribute) as? String {
            result["role"] = role.replacingOccurrences(of: "AX", with: "")
        }
        if let title = title(of: element), !title.isEmpty {
            result["title"] = ControlRedaction.apply(title)
        }
        if let description = value(element, kAXDescriptionAttribute) as? String, !description.isEmpty {
            result["description"] = ControlRedaction.apply(description)
        }
        if let raw = value(element, kAXValueAttribute) {
            if let text = raw as? String, !text.isEmpty {
                result["value"] = ControlRedaction.apply(text)
            }
            else if let number = raw as? NSNumber { result["value"] = number }
        }
        if let enabled = value(element, kAXEnabledAttribute) as? Bool, !enabled {
            result["enabled"] = false
        }
        if let identifier = value(element, kAXIdentifierAttribute) as? String, !identifier.isEmpty {
            result["id"] = identifier
        }
        if let selected = value(element, kAXSelectedAttribute) as? Bool, selected {
            result["selected"] = true
        }
        if depth > 1, let children = value(element, kAXChildrenAttribute) as? [AXUIElement],
           !children.isEmpty {
            result["children"] = children.map { node($0, depth: depth - 1) }
        }
        return result
    }

    // MARK: - 操作

    /// 押す。**AX の `AXPress` は SwiftUI の `Button` が登録したアクションを
    /// そのまま呼ぶ**ので、利用者がクリックしたのと同じ配線を通る。
    private static func press(_ app: AXUIElement, _ args: [String: Any]) -> Data {
        guard let element = locate(app, args) else {
            return ControlResponse.failure("要素が見つかりません: \(describe(args))")
        }
        let wanted = describe(args)
        if let enabled = value(element, kAXEnabledAttribute) as? Bool, !enabled {
            return ControlResponse.failure("要素が無効です: \(wanted)")
        }
        let action = args["action"] as? String ?? (kAXPressAction as String)
        let code = AXUIElementPerformAction(element, action as CFString)
        guard code == .success else {
            return ControlResponse.failure("\(action) が失敗しました（AXError \(code.rawValue)）")
        }
        return ControlResponse.success([
            "pressed": title(of: element) ?? wanted,
            "action": action,
        ])
    }

    /// テキストフィールドへ値を入れる。**合成キー入力を使わない** ——
    /// IME の状態にも画面のフォーカスにも左右されず、日本語をそのまま置ける。
    private static func setValue(_ app: AXUIElement, _ args: [String: Any]) -> Data {
        guard let text = args["value"] as? String else {
            return ControlResponse.failure("value が要ります")
        }
        guard let element = locate(app, args) else {
            return ControlResponse.failure("要素が見つかりません: \(describe(args))")
        }
        let code = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, text as CFTypeRef)
        guard code == .success else {
            return ControlResponse.failure("値を設定できませんでした（AXError \(code.rawValue)）")
        }
        return ControlResponse.success(["set": text])
    }

    /// その要素が何を支えているか（属性と動作）を返す。
    ///
    /// **「押せない」「選べない」の切り分けに要る。** SwiftUI の要素は
    /// 役割から想像できる動作を持たないことがあり、`AXError -25200`
    /// （属性が無い）を見ても**どう指せば動くのか**が分からない。祖先も
    /// 併せて返すので、実際に選べる／押せる階層をその場で見つけられる。
    private static func attributes(_ app: AXUIElement, _ args: [String: Any]) -> Data {
        guard let element = locate(app, args) else {
            return ControlResponse.failure("要素が見つかりません: \(describe(args))")
        }
        var chain: [[String: Any]] = []
        var current: AXUIElement? = element
        var depth = 0
        while let node = current, depth < 6 {
            chain.append(describeElement(node))
            current = parent(of: node)
            depth += 1
        }
        return ControlResponse.success(["chain": chain])
    }

    private static func describeElement(_ element: AXUIElement) -> [String: Any] {
        var names: CFArray?
        var actions: CFArray?
        _ = AXUIElementCopyAttributeNames(element, &names)
        _ = AXUIElementCopyActionNames(element, &actions)
        var node: [String: Any] = [
            "role": (value(element, kAXRoleAttribute) as? String) ?? "?",
            "attributes": (names as? [String] ?? []).sorted(),
            "actions": (actions as? [String] ?? []).sorted(),
        ]
        if let title = title(of: element), !title.isEmpty {
            node["title"] = ControlRedaction.apply(title)
        }
        return node
    }

    /// 一覧の行を選ぶ。
    ///
    /// **`AXPress` では選べない** ——`AXRow`／`AXCell` は押す動作を持たない
    /// ので、選択は選択状態を書くしかない。対象を決められないとその先の
    /// 操作（メニューバー経由の評価・ラベル・削除）が 1 つも起こせないため、
    /// 一覧を扱う検証ではここが入口になる。
    ///
    /// **書く先は行の親の `AXSelectedRows`** ［実測］。セル・行の
    /// `AXSelected` は属性としては在るのに書くと `kAXErrorFailure(-25200)`
    /// で失敗する——SwiftUI は設定を実装していない。親へまとめて渡す道だけが
    /// 通り、そちらは複数選択にもそのまま使える。
    private static func select(_ app: AXUIElement, _ args: [String: Any]) -> Data {
        let titles = (args["titles"] as? [String]) ?? [args["title"] as? String].compactMap { $0 }
        guard !titles.isEmpty else {
            return ControlResponse.failure("title か titles が要ります")
        }
        var rows: [AXUIElement] = []
        for wanted in titles {
            var probe = args
            probe["title"] = wanted
            probe["titles"] = nil
            guard let element = locate(app, probe) else {
                return ControlResponse.failure("要素が見つかりません: \(wanted)")
            }
            guard let row = ancestor(of: element, role: "AXRow") else {
                return ControlResponse.failure("行を辿れませんでした: \(wanted)")
            }
            rows.append(row)
        }
        guard let container = parent(of: rows[0]) else {
            return ControlResponse.failure("一覧を辿れませんでした")
        }
        let code = AXUIElementSetAttributeValue(
            container, kAXSelectedRowsAttribute as CFString, rows as CFTypeRef)
        guard code == .success else {
            return ControlResponse.failure("選択できませんでした（AXError \(code.rawValue)）")
        }
        return ControlResponse.success(["selected": rows.count])
    }

    /// 指定の役割を持つ最初の祖先（自分自身を含む）。
    private static func ancestor(of element: AXUIElement, role: String) -> AXUIElement? {
        var current: AXUIElement? = element
        var depth = 0
        while let node = current, depth < 8 {
            if (value(node, kAXRoleAttribute) as? String) == role { return node }
            current = parent(of: node)
            depth += 1
        }
        return nil
    }

    private static func parent(of element: AXUIElement) -> AXUIElement? {
        // **型を確かめてから落とす。** `kCFNull` が返ることがあり、素の `as!`
        // だとアプリごと落ちる（同じファイルの `axValue` は確かめている）。
        guard let raw = value(element, kAXParentAttribute),
              CFGetTypeID(raw as CFTypeRef) == AXUIElementGetTypeID() else { return nil }
        return (raw as! AXUIElement)
    }

    // MARK: - 探索

    /// 要素を 1 つ選ぶ。**題は省略でき、役割だけでも引ける** — SwiftUI の
    /// 入力欄は題も説明も持たず値しか持たないことがあるため。同じ役割の
    /// ものが複数あるときは `nth`（0 始まり）で選ぶ。
    static func locate(_ app: AXUIElement, _ args: [String: Any]) -> AXUIElement? {
        let root: AXUIElement
        if let wanted = args["window"] as? String {
            guard let windows = value(app, kAXWindowsAttribute) as? [AXUIElement],
                  let window = windows.first(where: { matches(title(of: $0) ?? "", wanted) })
            else { return nil }
            root = window
        } else {
            root = app
        }
        var found: [AXUIElement] = []
        collect(root, wanted: args["title"] as? String, role: args["role"] as? String, into: &found)
        let index = args["nth"] as? Int ?? 0
        return found.indices.contains(index) ? found[index] : nil
    }

    private static func describe(_ args: [String: Any]) -> String {
        let title = args["title"] as? String
        let role = args["role"] as? String
        return [role, title].compactMap { $0 }.joined(separator: " ")
    }

    /// 一致するものを**すべて**深さ優先で集める（`nth` のため）。
    private static func collect(
        _ root: AXUIElement, wanted: String?, role: String?,
        into found: inout [AXUIElement], depth: Int = 24
    ) {
        guard depth > 0, found.count < 64 else { return }
        guard let children = value(root, kAXChildrenAttribute) as? [AXUIElement] else { return }
        for child in children {
            let childRole = (value(child, kAXRoleAttribute) as? String)?
                .replacingOccurrences(of: "AX", with: "")
            let roleOK = role.map { $0 == childRole } ?? true
            let nameOK: Bool
            if let wanted, !wanted.isEmpty {
                // **`AXValue` も見る。** SwiftUI の `Text` は一覧のセルでも
                // 題を持たず**値に文字を置く**ことがあり、`ax:dump` には出るのに
                // 引けない、という食い違いになる［実測。一覧の行を title で
                // 探して 1 件も当たらなかった］。
                let names = [
                    title(of: child),
                    value(child, kAXDescriptionAttribute) as? String,
                    value(child, kAXIdentifierAttribute) as? String,
                    value(child, kAXValueAttribute) as? String,
                ].compactMap { $0 }
                nameOK = names.contains { matches($0, wanted) }
            } else {
                // 題を省いたときは、役割の指定が唯一の手がかり。役割も無ければ
                // 何にでも当たってしまうので、そこは呼び出し側の誤りとして弾く。
                nameOK = role != nil
            }
            if roleOK, nameOK { found.append(child) }
            collect(child, wanted: wanted, role: role, into: &found, depth: depth - 1)
        }
    }

    private static func title(of element: AXUIElement) -> String? {
        value(element, kAXTitleAttribute) as? String
    }

    private static func matches(_ text: String, _ wanted: String) -> Bool {
        if text == wanted { return true }
        if text.hasPrefix(wanted) { return true }
        return text.localizedCaseInsensitiveContains(wanted)
    }

    private static func value(_ element: AXUIElement, _ attribute: String) -> Any? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success else {
            return nil
        }
        return raw
    }
}
#endif
