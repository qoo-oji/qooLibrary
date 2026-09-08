#if DEBUG
import AppKit
import ApplicationServices
import Foundation

/// 右クリックのコンテキストメニューを、プロセス内から組み立てて読む・押す
/// [MT-33]。
///
/// **外部の AX クライアントからは見えないが、プロセス内からは取れる** ——
/// SwiftUI の `.contextMenu` は最終的に `NSView.menu(for:)` へ橋渡しされる
/// ので、合成した右クリックのイベントを渡せば本物の `NSMenu` が返る
/// （⌥ 代替項目の調査で確かめてある手法を、恒久的な口として据えたもの）。
/// これで**破壊的操作のほぼ全部の入口**（登録解除・ラベルの付け外し・保管庫へ
/// 移動・重複を比較・以後無視する）が GUI 無しで通せるようになる。
///
/// **格子状に走査してはならない** ［実測］。1 点ごとに SwiftUI がメニューを
/// 組み立てるので、約 12,500 点を走査したところ AttributeGraph のデータゾーンが
/// 枯渇して `AG::precondition_failure` で異常終了した（約 180 点なら問題ない）。
/// この口は**1 回に 1 点だけ**を見る。
@MainActor
enum ControlContextMenu {
    static func run(_ command: String, _ args: [String: Any]) -> Data {
        switch command {
        case "ctx:dump": return dump(args)
        case "ctx:invoke": return invoke(args)
        default: return ControlResponse.failure("知らないコマンドです: \(command)")
        }
    }

    // MARK: - 読み出し

    private static func dump(_ args: [String: Any]) -> Data {
        switch build(args) {
        case .failure(let response): return response
        case .success(let found):
            let depth = args["depth"] as? Int ?? 3
            return ControlResponse.success([
                "view": String(describing: type(of: found.view)),
                "point": [Int(found.pointInWindow.x), Int(found.pointInWindow.y)],
                "items": ControlMenuTree.dump(found.menu, path: [], depth: depth),
            ])
        }
    }

    // MARK: - 操作

    private static func invoke(_ args: [String: Any]) -> Data {
        guard let components = ControlMenuTree.pathComponents(args["path"]) else {
            return ControlResponse.failure("path がありません（配列か \" > \" 区切りの文字列）")
        }
        switch build(args) {
        case .failure(let response): return response
        case .success(let found):
            ControlMenuTree.warm(found.menu, depth: components.count)
            guard let item = ControlMenuTree.resolve(components, in: found.menu) else {
                return ControlResponse.failure(
                    "項目が見つかりません: \(components.joined(separator: " > "))")
            }
            return ControlMenuTree.invoke(item)
        }
    }

    // MARK: - 組み立て

    private struct Found {
        let menu: NSMenu
        let view: NSView
        let pointInWindow: NSPoint
    }

    private enum Outcome {
        case success(Found)
        case failure(Data)
    }

    /// 対象の 1 点を決め、そこに右クリックが来たものとしてメニューを組み立てる。
    ///
    /// **対象は AX の要素で指定するのが既定で、座標は補助にとどめる。** 一覧の
    /// 行位置は項目の増減・スクロール・並べ替えで動くので、座標を控えておくと
    /// 次に押したときには別の行を指す［記録済みの教訓］。
    private static func build(_ args: [String: Any]) -> Outcome {
        guard let target = locate(args) else {
            return .failure(ControlResponse.failure("対象が見つかりません"))
        }
        let window = target.window
        guard let contentView = window.contentView else {
            return .failure(ControlResponse.failure("ウインドウに contentView がありません"))
        }
        let pointInWindow = target.pointInWindow
        // `hitTest` は「受け手の superview の座標系」を要求する。contentView の
        // superview はウインドウの枠なので、ウインドウ座標をそのまま渡せる。
        guard let hit = contentView.hitTest(pointInWindow) else {
            return .failure(ControlResponse.failure(
                "その位置にビューがありません: (\(Int(pointInWindow.x)), \(Int(pointInWindow.y)))"))
        }
        let event = NSEvent.mouseEvent(
            with: .rightMouseDown, location: pointInWindow, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1)
        guard let event else {
            return .failure(ControlResponse.failure("イベントを作れませんでした"))
        }
        // **祖先方向へ辿る。** `hitTest` が返す最深のビューはメニューを持たず、
        // 実際に持っているのは SwiftUI がホストしている祖先であることが多い。
        var view: NSView? = hit
        while let current = view {
            if let menu = current.menu(for: event), !menu.items.isEmpty {
                return .success(Found(menu: menu, view: current, pointInWindow: pointInWindow))
            }
            view = current.superview
        }
        return .failure(ControlResponse.failure(
            "その位置にコンテキストメニューがありません（\(String(describing: type(of: hit))) から祖先まで）"))
    }

    // MARK: - 対象の解決

    private struct Target {
        let window: NSWindow
        let pointInWindow: NSPoint
    }

    private static func locate(_ args: [String: Any]) -> Target? {
        // 座標で指すときだけ、どのウインドウかを呼び出し側が決める。
        if let x = args["x"] as? Double, let y = args["y"] as? Double {
            guard let window = namedWindow(args) ?? NSApp.keyWindow
                    ?? NSApp.windows.first(where: \.isVisible) else { return nil }
            return Target(window: window, pointInWindow: NSPoint(x: x, y: y))
        }
        // **要素とウインドウを別々に決めてはならない** [CT-11]。要素は AX で
        // アプリ全体から探せてしまうので、別々に決めるとウインドウが 2 枚
        // あるときに**別のウインドウの座標系へ変換**され、`ctx:invoke` が
        // 見当違いの行へ破壊的操作（登録解除・保管庫へ移動・ゴミ箱）を
        // 掛けうる。**点を含むウインドウを点から選ぶ。**
        guard let center = axCenterInScreen(args) else { return nil }
        let candidates = NSApp.windows.filter { $0.isVisible && $0.frame.contains(center) }
        // 重なっているときは、呼び出し側が名前で指したものを優先し、
        // 無ければキーウインドウ、それも無ければ最前面のものを採る。
        let named = namedWindow(args)
        let window = candidates.first { $0 === named }
            ?? candidates.first { $0.isKeyWindow }
            ?? candidates.min { $0.orderedIndex < $1.orderedIndex }
        guard let window else { return nil }
        return Target(window: window, pointInWindow: window.convertPoint(fromScreen: center))
    }

    private static func namedWindow(_ args: [String: Any]) -> NSWindow? {
        guard let wanted = args["window"] as? String else { return nil }
        return NSApp.windows.first {
            $0.isVisible && ControlMenuTree.matches($0.title, wanted)
        }
    }

    /// AX の要素の中心を Cocoa の画面座標で返す。
    ///
    /// **AX は左上原点、Cocoa は左下原点** なので、主ディスプレイの高さで
    /// 折り返す。ここを取り違えると、画面の上下が逆さの位置を押すことになる。
    private static func axCenterInScreen(_ args: [String: Any]) -> NSPoint? {
        let app = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        guard let element = ControlAXBridge.locate(app, args) else { return nil }
        guard let position: CGPoint = axValue(element, kAXPositionAttribute, .cgPoint),
              let size: CGSize = axValue(element, kAXSizeAttribute, .cgSize),
              let primary = NSScreen.screens.first
        else { return nil }
        let topLeftY = position.y + size.height / 2
        return NSPoint(x: position.x + size.width / 2,
                       y: primary.frame.maxY - topLeftY)
    }

    private static func axValue<T>(_ element: AXUIElement, _ attribute: String,
                                   _ type: AXValueType) -> T? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success,
              let raw, CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        let result = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { result.deallocate() }
        guard AXValueGetValue(raw as! AXValue, type, result) else { return nil }
        return result.pointee
    }
}
#endif
