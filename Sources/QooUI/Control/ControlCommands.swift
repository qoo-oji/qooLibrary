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
    /// 1 行をどう実行するか。**同期で済むものと、`await` が要るものを
    /// 型で分ける** ——後者は `Task` を挟むので、AppKit が入れ子の
    /// イベントループを回している間は走らない [CT-16]。混ぜると、その
    /// 差が読めなくなる。
    enum Plan {
        case immediate(Data)
        case deferred(@MainActor () async -> Data)
    }

    static func plan(_ line: Data) -> Plan {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            return .immediate(ControlResponse.failure("JSON として読めませんでした"))
        }
        guard let command = object["cmd"] as? String else {
            return .immediate(ControlResponse.failure("cmd がありません"))
        }
        let args = object["args"] as? [String: Any] ?? [:]
        ControlRedaction.isEnabled = args["redact"] as? Bool ?? true
        ControlRedaction.extraAllowed = args["allow"] as? [String] ?? []
        if let handler = ControlExtensions.handler(for: command) {
            return .deferred {
                // **後始末はしない。** `plan` の入口で毎回上書きされるので
                // 要らないうえ、上限時間 [CT-16] を超えた `deferred` が
                // 後から空にすると、**次のコマンドの実行中に `allow` が
                // 消える**（その応答だけ伏字になる）。
                switch await handler(args) {
                case .success(let result): return ControlResponse.success(result)
                case .failure(let message): return ControlResponse.failure(message)
                }
            }
        }
        return .immediate(run(command, args))
    }

    private static func run(_ command: String, _ args: [String: Any]) -> Data {
        switch command {
        case "ping": return ControlResponse.success(["pong": true])
        case "help": return ControlResponse.success(["commands": names + ControlExtensions.names])
        case "status": return status()
        case "menu:dump": return menuDump(args)
        case "menu:invoke": return menuInvoke(args)
        case "window:list": return windowList()
        case "window:focus": return windowFocus(args)
        case "quit": return quit(args)
        case let ax where ax.hasPrefix("ax:"): return ControlAXBridge.run(ax, args)
        case let ctx where ctx.hasPrefix("ctx:"): return ControlContextMenu.run(ctx, args)
        case let db where db.hasPrefix("db:"): return ControlDatabase.run(db, args)
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
        "window:list", "window:focus",
        "ax:dump", "ax:press", "ax:setValue", "ax:select", "ax:attributes",
        "ctx:dump", "ctx:invoke",
        "db:query", "db:counts",
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
            // **ホームパスは利用者名を含む** [MT-32 の層 1]。サンドボックス下で
            // 要るのは「コンテナの中に居るか」だけなので、パスそのものは伏せる。
            "home": ControlRedaction.apply(NSHomeDirectory()),
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
            guard let item = root.items.first(where: { ControlMenuTree.matches($0.title, wanted) }),
                  let submenu = item.submenu else {
                return ControlResponse.failure("「\(wanted)」というメニューがありません")
            }
            return ControlResponse.success([
                "menu": ControlRedaction.apply(item.title),
                "items": ControlMenuTree.dump(submenu, path: [item.title], depth: depth),
            ])
        }
        return ControlResponse.success(["items": ControlMenuTree.dump(root, path: [], depth: depth)])
    }

    /// メニュー項目を実際に押す。**`performActionForItem(at:)` は target/action を
    /// 送るので、利用者がクリックしたのと同じ経路を通る。**
    private static func menuInvoke(_ args: [String: Any]) -> Data {
        guard let components = ControlMenuTree.pathComponents(args["path"]) else {
            return ControlResponse.failure("path がありません（配列か \" > \" 区切りの文字列）")
        }
        guard let root = NSApp.mainMenu else {
            return ControlResponse.failure("メニューバーがありません")
        }
        // 押す前に実体化する [CT-18]。温めずに押すと、項目は見つかるのに
        // 何も起きないことがある［実測］。
        ControlMenuTree.warm(root, depth: components.count)
        guard let item = ControlMenuTree.resolve(components, in: root) else {
            return ControlResponse.failure("項目が見つかりません: \(components.joined(separator: " > "))")
        }
        return ControlMenuTree.invoke(item)
    }

    // MARK: - ウインドウ

    private static func windowList() -> Data {
        let windows = NSApp.windows.map { window -> [String: Any] in
            var node: [String: Any] = [
                // **メインウインドウの題は現在のフォルダ名**——利用者のデータ
                // そのものなので、ここも伏字を通す [CT-06]。
                "title": ControlRedaction.apply(window.title),
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

    /// ウインドウをキーにする。
    ///
    /// **これが無いとメニューの半分が読めない** ——「移動」「表示」「編集」の
    /// 多くは `@FocusedValue` 越しに状態を受け取るので、キーウインドウが
    /// 無いと**実装が正しくても全項目が無効**として返る。ヘッドレスでは
    /// ウインドウを開いてもキーにならないため、口から明示する必要がある。
    ///
    /// **`makeKey()` だけではキーにならない** ［実測］——ウインドウがキューに
    /// なれるのはアプリがアクティブなときだけ、という AppKit の決まりによる。
    /// そのため `{"activate": true}` で**前面化を明示的に選べる**ようにして
    /// ある [CT-17]。既定は前面化しない——口の存在理由は利用者の画面を
    /// 奪わないことなので、奪うなら呼ぶ側が承知して呼ぶ形にする。
    ///
    /// 前面化せずに済ませたいなら、メニューの有効/無効を読む代わりに
    /// `ctx:*` と `ax:press` を使う——**そちらはキーウインドウが無くても
    /// 通る**［実測］。
    private static func windowFocus(_ args: [String: Any]) -> Data {
        let windows = NSApp.windows.filter(\.isVisible)
        let target: NSWindow?
        if let wanted = args["window"] as? String {
            target = windows.first { ControlMenuTree.matches($0.title, wanted) }
        } else {
            // **進捗パネルのような補助ウインドウをキーにしない。**
            // それをキーにすると `@FocusedValue` が届かず、メニューが
            // 無効のままになる。本体のウインドウだけを選び、無ければ
            // 最後に開いたものへ落とす。
            target = windows.last { !($0 is NSPanel) && $0.identifier != nil }
                ?? windows.last { !($0 is NSPanel) }
                ?? windows.last
        }
        guard let window = target else {
            return ControlResponse.failure("ウインドウが見つかりません")
        }
        if args["activate"] as? Bool ?? false {
            NSApp.activate(ignoringOtherApps: true)
        }
        window.makeKeyAndOrderFront(nil)
        window.makeMain()
        // **ウインドウの中に focus を持つビューが要る** ［文献＋実測］。
        // SwiftUI の `focusedSceneValue` は「シーンのどこかに focus がある」
        // ことを条件に配られるので、ウインドウをキーにしただけでは
        // `@FocusedValue` が nil のままになり、**実装が正しくても
        // メニューが全部無効**として読める。アプリを切り替えて戻ると同じ
        // 状態になるのは SwiftUI 側の既知の不具合として報告されている。
        if window.firstResponder == nil || window.firstResponder === window {
            _ = window.contentView.map { window.makeFirstResponder($0) }
        }
        return ControlResponse.success([
            "focused": ControlRedaction.apply(window.title),
            "isKey": window.isKeyWindow,
            "appActive": NSApp.isActive,
            "firstResponder": String(describing: type(of: window.firstResponder ?? window)),
        ])
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
