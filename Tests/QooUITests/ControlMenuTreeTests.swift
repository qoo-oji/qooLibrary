#if DEBUG
import AppKit
import Testing
@testable import QooUI

/// 制御口のメニュー走査 [MT-33]。
///
/// `NSMenu` は画面を出さずに組み立てて動かせるので、経路の選び方・伏字・
/// 押した結果までを `swift test` で固定できる。
@MainActor
struct ControlMenuTreeTests {
    private func withAllowed(_ words: [String], _ body: () -> Void) {
        let previous = ControlRedaction.extraAllowed
        ControlRedaction.isEnabled = true
        ControlRedaction.extraAllowed = words
        body()
        ControlRedaction.extraAllowed = previous
        ControlRedaction.isEnabled = true
    }

    private func makeMenu() -> NSMenu {
        let root = NSMenu(title: "root")
        let file = NSMenuItem(title: "ファイル", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "ファイル")
        submenu.addItem(NSMenuItem(title: "開く", action: nil, keyEquivalent: "o"))
        submenu.addItem(.separator())
        let disabled = NSMenuItem(title: "閉じる", action: nil, keyEquivalent: "")
        disabled.isEnabled = false
        submenu.addItem(disabled)
        file.submenu = submenu
        root.addItem(file)
        // 自動での有効/無効の判定を切る——ここで試したいのは走査であって
        // AppKit の検証ではない。
        root.autoenablesItems = false
        submenu.autoenablesItems = false
        return root
    }

    // MARK: - 走査

    @Test func 木として書き出せる() {
        ControlRedaction.isEnabled = false
        defer { ControlRedaction.isEnabled = true }
        let items = ControlMenuTree.dump(makeMenu(), path: [], depth: 3)
        #expect(items.count == 1)
        let children = items[0]["children"] as? [[String: Any]]
        #expect(children?.count == 3)
        #expect(children?[0]["title"] as? String == "開く")
        #expect(children?[0]["key"] as? String == "o")
        #expect(children?[1]["separator"] as? Bool == true)
        #expect(children?[2]["enabled"] as? Bool == false)
    }

    @Test func 経路は区切りを含めて示される() {
        ControlRedaction.isEnabled = false
        defer { ControlRedaction.isEnabled = true }
        let items = ControlMenuTree.dump(makeMenu(), path: [], depth: 3)
        let children = items[0]["children"] as? [[String: Any]]
        #expect(children?[0]["path"] as? String == "ファイル > 開く")
    }

    /// **メニューの題は静的とは限らない**——Undo の題や「(名前)に展開」には
    /// 利用者のファイル名が入る [CT-13]。素通しにすると口が漏洩経路になる。
    @Test func 題は伏字を通る() {
        let root = NSMenu(title: "root")
        root.autoenablesItems = false
        root.addItem(NSMenuItem(title: "「作品名A 第01巻」を移動を取り消す",
                                action: nil, keyEquivalent: ""))
        withAllowed(["を移動を取り消す"]) {
            let items = ControlMenuTree.dump(root, path: [], depth: 1)
            #expect(items[0]["title"] as? String != "「作品名A 第01巻」を移動を取り消す")
            #expect((items[0]["title"] as? String)?.hasPrefix("⟨") == true)
        }
    }

    /// 呼ぶ側が読めた題（＝許可語）をそのまま渡せるように、**照合は伏せる前の
    /// 生の題**で行う。
    @Test func 経路の照合は伏字より前の題で行う() {
        let root = makeMenu()
        withAllowed([]) {  // 何も許可しない＝すべて伏字になる状態
            let item = ControlMenuTree.resolve(["ファイル", "開く"], in: root)
            #expect(item?.title == "開く")
        }
    }

    // MARK: - 経路の選び方

    @Test func 部分一致でも届く() {
        #expect(ControlMenuTree.resolve(["ファイル", "開"], in: makeMenu())?.title == "開く")
    }

    @Test func 見つからなければ空を返す() {
        #expect(ControlMenuTree.resolve(["ファイル", "存在しない"], in: makeMenu()) == nil)
    }

    @Test func 区切り文字列でも配列でも同じに読める() {
        #expect(ControlMenuTree.pathComponents("ファイル > 開く") == ["ファイル", "開く"])
        #expect(ControlMenuTree.pathComponents(["ファイル", "開く"]) == ["ファイル", "開く"])
        #expect(ControlMenuTree.pathComponents("") == nil)
        #expect(ControlMenuTree.pathComponents(nil) == nil)
    }

    /// **伏字で題が読めない項目も指せること。** AppKit の標準文言のように
    /// 許可語から作れない題は `⟨N 文字⟩` になるので、添字で指す道が無いと
    /// **読めた項目しか押せない**。
    @Test func 添字でも項目を指せる() {
        let root = makeMenu()
        #expect(ControlMenuTree.resolve(["#0", "#0"], in: root)?.title == "開く")
        #expect(ControlMenuTree.resolve(["ファイル", "#2"], in: root)?.title == "閉じる")
        #expect(ControlMenuTree.resolve(["ファイル", "#9"], in: root) == nil)
    }

    // MARK: - 押す

    @Test func 無効な項目は押さない() {
        let root = makeMenu()
        let item = ControlMenuTree.resolve(["ファイル", "閉じる"], in: root)!
        let reply = try! JSONSerialization.jsonObject(
            with: ControlMenuTree.invoke(item)) as! [String: Any]
        #expect(reply["ok"] as? Bool == false)
    }

    @Test func 有効な項目は動作が実際に呼ばれる() {
        // `performActionForItem` は `NSApplication.sendAction` を通るので、
        // `NSApp` が居ないと黙って何も起きない。
        _ = NSApplication.shared
        let root = NSMenu(title: "root")
        root.autoenablesItems = false
        let target = ActionSpy()
        let item = NSMenuItem(title: "実行", action: #selector(ActionSpy.fire), keyEquivalent: "")
        item.target = target
        root.addItem(item)
        let reply = try! JSONSerialization.jsonObject(
            with: ControlMenuTree.invoke(item)) as! [String: Any]
        #expect(reply["ok"] as? Bool == true)
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        #expect(target.count == 1)
    }
}

@MainActor
private final class ActionSpy: NSObject {
    var count = 0
    @objc func fire() { count += 1 }
}
#endif
