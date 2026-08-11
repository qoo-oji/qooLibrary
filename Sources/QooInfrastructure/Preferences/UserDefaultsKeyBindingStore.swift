import Foundation
import QooKit

/// `KeyBindingStore` の既定実装 [13章 §13.6]。既定値からの差分だけを
/// `UserDefaults` に JSON で保存する（既定に戻した操作は保存領域から消える、
/// KB-05 の「既定に戻す」を単純化する設計）。
///
/// 保存領域は `[ActionID: [KeyCombo]]`。「上書きが無い（既定値を使う）」は
/// キー自体が無いことで、「明示的に未割り当てにした」は空配列で表す
/// （どちらも配列という同じ型なので、以前の `KeyCombo?` 版であった
/// 「nil の代入がキー削除と区別できない」問題は起きない）。
public final class UserDefaultsKeyBindingStore: KeyBindingStore, @unchecked Sendable {
    public static let shared = UserDefaultsKeyBindingStore()

    private let defaults: UserDefaults
    private let storageKey: String
    /// 複数の Task/スレッドから呼ばれても `overrides` の読み書きを直列化する。
    private let lock = NSLock()

    public init(defaults: UserDefaults = .standard, storageKey: String = "qoo.keyBindings.overrides") {
        self.defaults = defaults
        self.storageKey = storageKey
    }

    public func binding(for action: ActionID) -> KeyBinding {
        let defaultBinding = DefaultKeyBindings.binding(for: action)
        if let overrideCombos = loadOverrides()[action] {
            return KeyBinding(id: action, combos: overrideCombos, isDestructive: defaultBinding.isDestructive)
        }
        return defaultBinding
    }

    public func setBinding(_ combos: [KeyCombo], for action: ActionID) throws {
        lock.lock()
        defer { lock.unlock() }
        var overrides = loadOverridesUnlocked()
        let defaultCombos = DefaultKeyBindings.binding(for: action).combos
        if combos == defaultCombos {
            // 既定値と同じなら上書き保存を持たない（KB-05 で自然に戻る）。
            overrides.removeValue(forKey: action)
        } else {
            overrides[action] = combos
        }
        saveOverridesUnlocked(overrides)
    }

    public func conflicts(of combo: KeyCombo) -> [ActionID] {
        ActionID.allCases.filter { binding(for: $0).combos.contains(combo) }
    }

    public func resetToDefaults() {
        lock.lock()
        defer { lock.unlock() }
        defaults.removeObject(forKey: storageKey)
    }

    // MARK: - 内部

    private func loadOverrides() -> [ActionID: [KeyCombo]] {
        lock.lock()
        defer { lock.unlock() }
        return loadOverridesUnlocked()
    }

    private func loadOverridesUnlocked() -> [ActionID: [KeyCombo]] {
        guard let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([ActionID: [KeyCombo]].self, from: data)
        else { return [:] }
        return decoded
    }

    private func saveOverridesUnlocked(_ overrides: [ActionID: [KeyCombo]]) {
        guard let data = try? JSONEncoder().encode(overrides) else { return }
        defaults.set(data, forKey: storageKey)
    }
}
