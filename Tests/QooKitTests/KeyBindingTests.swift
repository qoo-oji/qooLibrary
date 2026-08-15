import Testing

@testable import QooKit

@Suite struct KeyBindingTests {
    @Test func defaultBindingsCoverEveryActionID() {
        for action in ActionID.allCases {
            let binding = DefaultKeyBindings.binding(for: action)
            #expect(binding.id == action)
        }
    }

    @Test func deletePermanentlyHasNoDefaultBinding() {
        // [FM-16] 完全削除は既定でキーバインドを割り当てない。
        let binding = DefaultKeyBindings.binding(for: .deletePermanently)
        #expect(binding.combos.isEmpty)
        #expect(binding.isDestructive)
    }

    @Test func openDefaultsToReturnKey() {
        // [KB-02]
        let binding = DefaultKeyBindings.binding(for: .open)
        #expect(binding.combos == [KeyCombo(key: "return")])
    }

    @Test func renameDefaultsToCommandR() {
        // [KB-03]
        let binding = DefaultKeyBindings.binding(for: .rename)
        #expect(binding.combos == [KeyCombo(key: "r", modifiers: .command)])
    }

    @Test func goBackHasBothBracketAndArrowDefaults() {
        // Finder 流の ⌘[ とブラウザ流の ⌘← の両方を既定にしている
        // （1つの操作に複数のショートカットを割り当てられる、KB-01 拡張）。
        let binding = DefaultKeyBindings.binding(for: .goBack)
        #expect(binding.combos == [
            KeyCombo(key: "[", modifiers: .command),
            KeyCombo(key: "left", modifiers: .command),
        ])
    }

    /// [Finder 対比監査] ⌥ 代替は Finder と同じキーを既定にする。主項目と
    /// 「⌥ が増えるだけ」の関係になっていることも、取り違えを防ぐため確認する。
    @Test func optionAlternatesUseFinderStandardKeys() {
        let pairs: [(primary: ActionID, alternate: ActionID, key: String)] = [
            (.copy, .copyPath, "c"),          // ⌘C  / ⌥⌘C
            (.paste, .moveItemsHere, "v"),    // ⌘V  / ⌥⌘V
            (.selectAll, .deselectAll, "a"),  // ⌘A  / ⌥⌘A
        ]
        for pair in pairs {
            #expect(DefaultKeyBindings.binding(for: pair.primary).combos
                == [KeyCombo(key: pair.key, modifiers: .command)])
            #expect(DefaultKeyBindings.binding(for: pair.alternate).combos
                == [KeyCombo(key: pair.key, modifiers: [.command, .option])])
        }
    }

    @Test func noTwoDefaultBindingsCollide() {
        // 既定値同士が最初から衝突していると KB-04 の検証が意味を成さない。
        let combos = DefaultKeyBindings.all.flatMap(\.combos)
        let uniqueCombos = Set(combos)
        #expect(combos.count == uniqueCombos.count)
    }

    @Test func keyComboEqualityIgnoresModifierOrder() {
        let a = KeyCombo(key: "n", modifiers: [.command, .shift])
        let b = KeyCombo(key: "n", modifiers: [.shift, .command])
        #expect(a == b)
    }
}

/// Finder と同じキーに揃えてある操作（`isCustomizable == false`）についての
/// 不変条件 [ユーザー要望: これらはメニューにキーを表示し、変更対象外にする]。
@Suite struct FixedKeyBindingTests {
    /// 変更不可にした操作は**必ずキーを持つ** — メニュー項目が
    /// `.fixedKeyboardShortcut(_:)` で表示するのが存在意義なので、空だと
    /// 「変更もできないしキーも無い」という無意味な状態になる。
    @Test func everyFixedBindingHasAtLeastOneCombo() {
        for binding in DefaultKeyBindings.all where !binding.isCustomizable {
            #expect(!binding.combos.isEmpty, "\(binding.id) は変更不可なのにキーが空")
        }
    }

    /// 逆に、キーを持たない操作を変更不可にしていないこと。
    @Test func bindingsWithoutCombosStayCustomizable() {
        for binding in DefaultKeyBindings.all where binding.combos.isEmpty {
            #expect(binding.isCustomizable, "\(binding.id) はキーが空なので変更可能であるべき")
        }
    }

    /// 既定値のままなら、変更不可のもの同士でキーが衝突しない
    /// （衝突しているとメニューのどちらか一方が効かなくなる）。
    @Test func fixedBindingsDoNotCollideWithEachOther() {
        var seen: [KeyCombo: ActionID] = [:]
        for binding in DefaultKeyBindings.all where !binding.isCustomizable {
            for combo in binding.combos {
                #expect(seen[combo] == nil, "\(combo) が \(binding.id) と \(seen[combo]!) で重複")
                seen[combo] = binding.id
            }
        }
    }
}
