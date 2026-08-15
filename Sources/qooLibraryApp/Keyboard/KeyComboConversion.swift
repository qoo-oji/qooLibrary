import QooKit
import SwiftUI

/// `KeyCombo`（QooKit、SwiftUI 非依存）を `SwiftUI.KeyboardShortcut` に
/// 変換する。この変換は View 層でのみ行う [13章 §13.6、A-01 との整合]。
extension KeyCombo {
    var swiftUIModifiers: SwiftUI.EventModifiers {
        var result: SwiftUI.EventModifiers = []
        if modifiers.contains(.command) { result.insert(.command) }
        if modifiers.contains(.shift) { result.insert(.shift) }
        if modifiers.contains(.option) { result.insert(.option) }
        if modifiers.contains(.control) { result.insert(.control) }
        return result
    }

    var swiftUIKeyEquivalent: KeyEquivalent? {
        switch key {
        case "space": .space
        case "return", "enter": .return
        case "delete": .delete
        case "up": .upArrow
        case "down": .downArrow
        case "left": .leftArrow
        case "right": .rightArrow
        case "escape": .escape
        case "tab": .tab
        default:
            key.count == 1 ? KeyEquivalent(key.first!) : nil
        }
    }

    var swiftUIShortcut: KeyboardShortcut? {
        guard let equivalent = swiftUIKeyEquivalent else { return nil }
        return KeyboardShortcut(equivalent, modifiers: swiftUIModifiers)
    }
}

/// `KeyPress`（`.onKeyPress` で捕捉した実際のキー入力）から `KeyCombo` への
/// 逆変換 [1-12 環境設定「キーボード」タブのキーレコーダー向け、`KeyComboRecorder.swift`
/// 参照]。上の `swiftUIKeyEquivalent` と対になる、名前付きキーの逆引き。
extension KeyPress {
    var qooKeyCombo: KeyCombo {
        let keyString: String
        switch key {
        case .space: keyString = "space"
        case .return: keyString = "return"
        case .delete: keyString = "delete"
        case .upArrow: keyString = "up"
        case .downArrow: keyString = "down"
        case .leftArrow: keyString = "left"
        case .rightArrow: keyString = "right"
        case .escape: keyString = "escape"
        case .tab: keyString = "tab"
        default: keyString = String(key.character)
        }
        var mods: KeyModifiers = []
        if modifiers.contains(.command) { mods.insert(.command) }
        if modifiers.contains(.shift) { mods.insert(.shift) }
        if modifiers.contains(.option) { mods.insert(.option) }
        if modifiers.contains(.control) { mods.insert(.control) }
        return KeyCombo(key: keyString, modifiers: mods)
    }
}

/// `action` に割り当てられた**最初の**キーを `.onKeyPress` で捕捉する。
///
/// `KeyBindingButtons`（不可視ボタン＋`.keyboardShortcut`）が使えない操作用
/// ——`Enter`（開く）や `Space`（クイックルック）のように修飾キーを伴わない
/// キーは、`.keyboardShortcut` にするとテキスト入力やボタンの既定動作と
/// competing してしまうため、フォーカスされている一覧自身が `.onKeyPress` で
/// 受け取る必要がある。
///
/// **修飾キーも照合する**。`.onKeyPress(_ key:)`（キーだけを見て修飾キーを
/// 無視する版）ではなく `.onKeyPress(keys:phases:)` を使うのは、環境設定
/// 「キーボード」タブでユーザーが修飾キー付きの割り当て（例: ⌘Y）に変更した
/// とき、修飾キー無しの `y` でも発火してしまうのを避けるため。キーそのものでの
/// 絞り込みは SwiftUI 側に任せたまま（＝無関係なキー入力を横取りしない）、
/// 修飾キーの一致だけを自分で確かめる。
///
/// 照合するのは ⌘⇧⌥⌃ の 4 つだけで、Caps Lock やテンキー由来のフラグは
/// 無視する（それらまで一致を要求すると環境によって発火しなくなる）。
/// 一致しなければ `.ignored` を返し、`Table` 標準の行移動など AppKit 側の
/// 既定処理へそのまま渡す。未割り当て（`combos` が空）なら何も捕捉しない。
struct KeyBindingPress: ViewModifier {
    let action: ActionID
    let store: KeyBindingStore
    let perform: () -> Void

    /// 照合の対象にする修飾キー。
    private static let significantModifiers: EventModifiers = [.command, .shift, .option, .control]

    func body(content: Content) -> some View {
        if let combo = store.binding(for: action).combos.first,
           let key = combo.swiftUIKeyEquivalent {
            content.onKeyPress(keys: [key], phases: .down) { keyPress in
                guard keyPress.modifiers.intersection(Self.significantModifiers) == combo.swiftUIModifiers
                else { return .ignored }
                perform()
                return .handled
            }
        } else {
            content
        }
    }
}

extension View {
    func onKeyBindingPress(_ action: ActionID, store: KeyBindingStore, perform: @escaping () -> Void) -> some View {
        modifier(KeyBindingPress(action: action, store: store, perform: perform))
    }
}

/// `action` に登録されているキーの組み合わせぶんだけ、不可視のボタンを生成する
/// [KB-01: 1つの操作に複数のショートカットを割り当てられる。例: 戻る = ⌘[ と
/// ⌘←]。可視要素を持たないボタンとして配線する標準的な SwiftUI のパターン。
struct KeyBindingButtons: View {
    let action: ActionID
    let store: KeyBindingStore
    var isDisabled = false
    var role: ButtonRole?
    /// 1 つ目のキーをメニュー項目側の `.keyboardShortcut` が登録している場合に
    /// `true` にする。同じキーを二重登録しないため、ここでは 2 つ目以降だけを
    /// 配線する（`goBack` = ⌘[ と ⌘← のように複数キーを持つ操作向け）。
    var skipsPrimaryCombo = false
    let perform: () -> Void

    var body: some View {
        let combos = store.binding(for: action).combos
        let wired = skipsPrimaryCombo ? Array(combos.dropFirst()) : combos
        ForEach(Array(wired.enumerated()), id: \.offset) { _, combo in
            if let shortcut = combo.swiftUIShortcut {
                Button("", role: role, action: perform)
                    .keyboardShortcut(shortcut)
            }
        }
        .disabled(isDisabled)
    }
}

extension View {
    /// **Finder と同じキーに揃えてある操作**のメニュー項目にショートカットを
    /// 付ける [ユーザー要望: メニューにキーを表示したい]。
    ///
    /// `KeyBindingButtons`（不可視ボタン）経由ではメニューにキーが表示されず、
    /// 「キーを知っている人にしか分からない」状態になってしまうため、これらは
    /// メニュー項目自身にショートカットを持たせる。同じキーが二重に登録される
    /// のを防ぐため、**対象の操作は `isCustomizable == false` にして
    /// `KeyBindingButtons` から外してある**。
    ///
    /// キーの定義は `DefaultKeyBindings` に一本化したままなので、ここで
    /// ハードコードすることはない。複数キーを持つ操作は 1 つ目を表示する。
    @ViewBuilder
    func fixedKeyboardShortcut(_ action: ActionID) -> some View {
        if let shortcut = DefaultKeyBindings.binding(for: action).combos.first?.swiftUIShortcut {
            keyboardShortcut(shortcut)
        } else {
            self
        }
    }
}
