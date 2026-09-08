#if DEBUG
import AppKit
import Foundation
import QooApplication
import QooKit

/// 制御口が受け付けるコマンド [MT-33]。**すべてメインスレッドで走る。**
///
/// **どのレイヤを叩くかで、検証できるものが変わる。**
/// - `menu.*` は `NSApp.mainMenu` を辿るので、SwiftUI の `.commands` が組んだ
///   **本物の配線**（target/action）を通る。メニューから起こせる操作は、
///   実機でクリックしたのと同じ経路になる。
/// - それ以外は アプリ層の `*Action` / `*Navigation` / `WindowState` を直接
///   呼ぶ。**UI が押すのと同じ関数**だが、ボタンがその関数を呼ぶかまでは
///   検証しない（そこは実機に残る）。
@MainActor
enum ControlCommands {
    static func run(_ line: Data) -> Data {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            return ControlResponse.failure("JSON として読めませんでした")
        }
        guard let command = object["cmd"] as? String else {
            return ControlResponse.failure("cmd がありません")
        }
        let args = object["args"] as? [String: Any] ?? [:]
        switch command {
        case "ping": return ControlResponse.success(["pong": true])
        case "help": return ControlResponse.success(["commands": names])
        case "status": return status()
        case "menu:dump": return menuDump(args)
        case "menu:invoke": return menuInvoke(args)
        case "window:list": return windowList()
        case "quit": return quit(args)
        case let ax where ax.hasPrefix("ax:"): return ControlAXBridge.run(ax, args)
        default: return ControlResponse.failure("知らないコマンドです: \(command)")
        }
    }

    /// **名前空間の区切りにドットを使わない。** `menu.dump` のような綴りは
    /// 文字列カタログの鍵とまったく同じ形で、`check-localization-keys` が
    /// 「定義されていない鍵」として拾う（実際に拾われた）。検査を緩めると、
    /// この配下で本物の鍵を書いたときに黙るようになる——先例
    /// （`RecoveryAction` の識別子）と同じく、**紛らわしい側の綴りを変える**。
    static let names = [
        "ping", "help", "status",
        "menu:dump", "menu:invoke",
        "window:list",
        "ax:dump", "ax:press", "ax:setValue",
        "quit",
    ]

    // MARK: - 状態

    private static func status() -> Data {
        let services = LibraryServices.shared
        let bundle = Bundle.main
        var result: [String: Any] = [
            "pid": ProcessInfo.processInfo.processIdentifier,
            "version": bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?",
            "build": bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?",
            "headless": ControlServer.isHeadless,
            "sandboxed": NSHomeDirectory().contains("/Containers/"),
            "home": NSHomeDirectory(),
            "activationPolicy": String(describing: NSApp.activationPolicy()),
            "windows": NSApp.windows.count,
            "visibleWindows": NSApp.windows.filter(\.isVisible).count,
            "locale": AppLanguagePreference.effectiveLocale.identifier,
            "storeReady": services.isReady,
            "libraries": services.libraries.count,
            "storeHealth": String(describing: services.storeHealth),
        ]
        if let failure = services.startupFailure {
            result["startupFailure"] = String(describing: failure)
        }
        return ControlResponse.success(result)
    }

    // MARK: - メニュー

    /// メニューバーを木として書き出す。
    ///
    /// **走査の前に `NSMenu.update()` を呼ぶ。** 項目の有効/無効は「メニューが
    /// 開かれたとき」に検証されるので、呼ばずに読むと古い状態が返る。
    private static func menuDump(_ args: [String: Any]) -> Data {
        guard let root = NSApp.mainMenu else {
            return ControlResponse.failure("メニューバーがありません")
        }
        let depth = args["depth"] as? Int ?? 3
        if let wanted = args["menu"] as? String {
            guard let item = root.items.first(where: { matches($0.title, wanted) }),
                  let submenu = item.submenu else {
                return ControlResponse.failure("「\(wanted)」というメニューがありません")
            }
            return ControlResponse.success([
                "menu": item.title,
                "items": dump(submenu, path: [item.title], depth: depth),
            ])
        }
        return ControlResponse.success(["items": dump(root, path: [], depth: depth)])
    }

    private static func dump(_ menu: NSMenu, path: [String], depth: Int) -> [[String: Any]] {
        menu.update()
        return menu.items.enumerated().map { index, item in
            var node: [String: Any] = [
                "index": index,
                "title": item.title,
                "enabled": item.isEnabled,
                "path": (path + [item.title]).joined(separator: " > "),
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
                    node["children"] = dump(submenu, path: path + [item.title], depth: depth - 1)
                } else {
                    node["hasChildren"] = true
                }
            }
            return node
        }
    }

    private static func modifierNames(_ mask: NSEvent.ModifierFlags) -> [String] {
        var names: [String] = []
        if mask.contains(.command) { names.append("command") }
        if mask.contains(.shift) { names.append("shift") }
        if mask.contains(.option) { names.append("option") }
        if mask.contains(.control) { names.append("control") }
        return names
    }

    /// メニュー項目を実際に押す。**`performActionForItem(at:)` は target/action を
    /// 送るので、利用者がクリックしたのと同じ経路を通る。**
    private static func menuInvoke(_ args: [String: Any]) -> Data {
        guard let components = pathComponents(args["path"]) else {
            return ControlResponse.failure("path がありません（配列か \" > \" 区切りの文字列）")
        }
        guard let root = NSApp.mainMenu else {
            return ControlResponse.failure("メニューバーがありません")
        }
        guard let item = resolve(components, in: root) else {
            return ControlResponse.failure("項目が見つかりません: \(components.joined(separator: " > "))")
        }
        guard let owner = item.menu else {
            return ControlResponse.failure("項目が親メニューを持ちません")
        }
        owner.update()
        guard item.isEnabled else {
            return ControlResponse.failure("項目が無効です: \(item.title)")
        }
        let index = owner.index(of: item)
        owner.performActionForItem(at: index)
        return ControlResponse.success(["invoked": item.title, "index": index])
    }

    private static func pathComponents(_ raw: Any?) -> [String]? {
        if let array = raw as? [String], !array.isEmpty { return array }
        if let text = raw as? String, !text.isEmpty {
            return text.components(separatedBy: ">").map {
                $0.trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    /// 完全一致 → 前方一致 → 部分一致 の順に探す。**メニューの題は状態で
    /// 変わる**（「シリーズごとにまとめる」↔「巻ごとに表示」、「〜を表示」↔
    /// 「〜を隠す」）ので、呼ぶ側が完全な題を知らなくても届くようにしてある。
    private static func resolve(_ components: [String], in root: NSMenu) -> NSMenuItem? {
        var menu: NSMenu? = root
        var found: NSMenuItem?
        for component in components {
            guard let current = menu else { return nil }
            current.update()
            guard let item = current.items.first(where: { matches($0.title, component) }) else {
                return nil
            }
            found = item
            menu = item.submenu
        }
        return found
    }

    private static func matches(_ title: String, _ wanted: String) -> Bool {
        if title == wanted { return true }
        if title.hasPrefix(wanted) { return true }
        return title.localizedCaseInsensitiveContains(wanted)
    }

    // MARK: - ウインドウ

    private static func windowList() -> Data {
        let windows = NSApp.windows.map { window -> [String: Any] in
            var node: [String: Any] = [
                "title": window.title,
                "visible": window.isVisible,
                "key": window.isKeyWindow,
                "main": window.isMainWindow,
                "sheet": window.isSheet,
                "class": String(describing: type(of: window)),
                "frame": [
                    Int(window.frame.origin.x), Int(window.frame.origin.y),
                    Int(window.frame.size.width), Int(window.frame.size.height),
                ],
            ]
            if let identifier = window.identifier?.rawValue { node["id"] = identifier }
            return node
        }
        return ControlResponse.success(["windows": windows])
    }

    // MARK: - 終了

    /// **応答を返してから終了する。** `NSApp.terminate` はこの場で呼ぶと
    /// `.terminateLater` の返答待ちに入り、応答を書く前にワーカーが取り残される。
    /// ランループのタイマーで次の周回へ回す（`AppDelegate` の上限時間と同じ形）。
    private static func quit(_ args: [String: Any]) -> Data {
        // **`Timer.scheduledTimer` を使ってはならない** ［実測］。あれは
        // 既定モードにしか入らず、モーダルのウインドウが出ている間は発火
        // しない——実際、ダイアログを開いたまま `quit` を送ったら終了せず、
        // 以後どのコマンドを送っても生き続けた。`AppDelegate` が終了の
        // 上限時間を `.common` に入れているのとまったく同じ理由である。
        let force = args["force"] as? Bool ?? false
        let timer = Timer(timeInterval: 0.2, repeats: false) { _ in
            MainActor.assumeIsolated {
                if force {
                    // 検証では「確実に終わる」ことが要る——終われないまま
                    // 残ると、次の起動が古いプロセスと衝突する。診断ログの
                    // 書き切りは捨てる。
                    exit(0)
                }
                NSApp.terminate(nil)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        return ControlResponse.success(["terminating": true, "force": force])
    }
}

#endif
