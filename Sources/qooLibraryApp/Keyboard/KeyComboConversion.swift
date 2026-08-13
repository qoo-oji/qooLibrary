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

/// `action` に登録されているキーの組み合わせぶんだけ、不可視のボタンを生成する
/// [KB-01: 1つの操作に複数のショートカットを割り当てられる。例: 戻る = ⌘[ と
/// ⌘←]。可視要素を持たないボタンとして配線する標準的な SwiftUI のパターン。
struct KeyBindingButtons: View {
    let action: ActionID
    let store: KeyBindingStore
    var isDisabled = false
    var role: ButtonRole?
    let perform: () -> Void

    var body: some View {
        ForEach(Array(store.binding(for: action).combos.enumerated()), id: \.offset) { _, combo in
            if let shortcut = combo.swiftUIShortcut {
                Button("", role: role, action: perform)
                    .keyboardShortcut(shortcut)
            }
        }
        .disabled(isDisabled)
    }
}
