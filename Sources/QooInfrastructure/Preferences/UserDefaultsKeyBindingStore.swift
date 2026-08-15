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

    /// **`[ActionID: [KeyCombo]]` として直接読み書きしない** [1-16 で発見・修正]。
    ///
    /// `ActionID` は将来ケースが増減する（実際に 1-16 で `toggleDisplayMode` を
    /// `displayAsIcons`/`displayAsList` へ置き換えた）。`Codable` な enum を
    /// 辞書のキーにすると**未知のキーが 1 つでもあるとデコード全体が失敗し**、
    /// `try?` に握りつぶされて**ユーザーのキー設定が丸ごと消える**。ケースを
    /// 1 つ廃止しただけで無関係な割り当てまで失われるのは受け入れられない。
    ///
    /// そこで保存形式を `[String（rawValue）: [KeyCombo]]` にして、解釈できる
    /// キーだけを残す（廃止されたキーは黙って捨て、それ以外は保つ）。旧形式
    /// （`ActionID` をキーにした辞書）は、Swift の `Codable` が
    /// `CodingKeyRepresentable` でないキーの辞書を**キーと値が交互に並ぶ平坦な
    /// 配列**として書き出すため JSON オブジェクトではない。読み込み時に一度だけ
    /// その形も解釈して引き継ぐ（次の保存で新形式に置き換わる）。
    private func loadOverridesUnlocked() -> [ActionID: [KeyCombo]] {
        guard let data = defaults.data(forKey: storageKey) else { return [:] }
        if let decoded = try? JSONDecoder().decode([String: [KeyCombo]].self, from: data) {
            return Self.mapKnownActions(decoded)
        }
        return Self.mapKnownActions(Self.decodeLegacyFlatArray(data))
    }

    private func saveOverridesUnlocked(_ overrides: [ActionID: [KeyCombo]]) {
        let storable = overrides.reduce(into: [String: [KeyCombo]]()) { $0[$1.key.rawValue] = $1.value }
        guard let data = try? JSONEncoder().encode(storable) else { return }
        defaults.set(data, forKey: storageKey)
    }

    private static func mapKnownActions(_ raw: [String: [KeyCombo]]) -> [ActionID: [KeyCombo]] {
        raw.reduce(into: [:]) { result, pair in
            guard let action = ActionID(rawValue: pair.key) else { return }
            result[action] = pair.value
        }
    }

    /// 旧形式（キーと値が交互に並ぶ平坦な JSON 配列）を読む。壊れていたり
    /// 想定と違う形なら空を返す（＝既定キーバインドで始まる）。
    private static func decodeLegacyFlatArray(_ data: Data) -> [String: [KeyCombo]] {
        guard let array = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return [:] }
        var result: [String: [KeyCombo]] = [:]
        for index in stride(from: 0, to: array.count - 1, by: 2) {
            guard let key = array[index] as? String,
                  let combosJSON = try? JSONSerialization.data(withJSONObject: array[index + 1]),
                  let combos = try? JSONDecoder().decode([KeyCombo].self, from: combosJSON)
            else { continue }
            result[key] = combos
        }
        return result
    }
}
