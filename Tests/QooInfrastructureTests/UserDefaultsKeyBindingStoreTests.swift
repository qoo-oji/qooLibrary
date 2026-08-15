import Foundation
import Testing

@testable import QooInfrastructure
@testable import QooKit

/// `UserDefaults(suiteName:)` は OS レベルのグローバルな `CFPreferences`
/// ドメイン登録を伴うため、Swift Testing の既定の並列実行下で複数のスイート
/// インスタンスを同時に作成すると、稀に別テストが作った直後のドメインの
/// 内容を拾ってしまうことがある（実機検証ではなく `swift test` のフル
/// スイート実行でのみ再現、単独実行や少数実行では再現しない）。
/// `ArchiveCompressor`/`SecureExtractor` のステージングディレクトリ競合
/// （1-7 で対処）とは異なり、こちらは注入可能なルートパスを与える形の
/// 根本修正ができない（`UserDefaults` 自体が OS 側の共有リソースのため）。
/// そのためテスト側で直列実行に固定する。
@Suite(.serialized) struct UserDefaultsKeyBindingStoreTests {
    /// テストごとに独立した `UserDefaults` スイートを使い、実際のアプリの
    /// 設定や他のテストと干渉しないようにする。
    private func makeStore() -> UserDefaultsKeyBindingStore {
        let suiteName = "qoo-keybinding-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        return UserDefaultsKeyBindingStore(defaults: defaults, storageKey: "overrides")
    }

    @Test func bindingReturnsDefaultWhenNoOverrideSet() {
        let store = makeStore()
        #expect(store.binding(for: .rename).combos == [KeyCombo(key: "r", modifiers: .command)])
    }

    @Test func setBindingPersistsOverride() throws {
        let store = makeStore()
        try store.setBinding([KeyCombo(key: "e", modifiers: .command)], for: .rename)
        #expect(store.binding(for: .rename).combos == [KeyCombo(key: "e", modifiers: .command)])
    }

    /// 対象は**変更可能な**操作にする（`.newFolder` 等の Finder 標準は
    /// 上書きを受け付けないため、ストアの汎用挙動の検証には使えない）。
    @Test func setBindingToEmptyUnassignsAction() throws {
        let store = makeStore()
        try store.setBinding([], for: .toggleThumbnails)
        #expect(store.binding(for: .toggleThumbnails).combos.isEmpty)
    }

    @Test func settingBackToDefaultClearsOverride() throws {
        let store = makeStore()
        try store.setBinding([KeyCombo(key: "e", modifiers: .command)], for: .rename)
        try store.setBinding([KeyCombo(key: "r", modifiers: .command)], for: .rename) // 既定値と同じ
        #expect(store.binding(for: .rename).combos == [KeyCombo(key: "r", modifiers: .command)])
    }

    @Test func conflictsDetectsCollisionAcrossActions() throws {
        let store = makeStore()
        // newFolder の既定は ⇧⌘N。rename を同じキーに変更したら衝突するはず。
        try store.setBinding([KeyCombo(key: "n", modifiers: [.command, .shift])], for: .rename)

        let conflicts = store.conflicts(of: KeyCombo(key: "n", modifiers: [.command, .shift]))

        #expect(Set(conflicts) == Set([.rename, .newFolder]))
    }

    @Test func setBindingAllowsMultipleCombosForOneAction() throws {
        // 1つの操作に複数のキーを割り当てられる（KB-01 拡張、戻る/進むの実例）。
        let store = makeStore()
        try store.setBinding([KeyCombo(key: "e", modifiers: .command), KeyCombo(key: "left", modifiers: .command)], for: .rename)

        let binding = store.binding(for: .rename)

        #expect(binding.combos == [KeyCombo(key: "e", modifiers: .command), KeyCombo(key: "left", modifiers: .command)])
        #expect(Set(store.conflicts(of: KeyCombo(key: "left", modifiers: .command))) == Set([.rename, .goBack]))
    }

    @Test func resetToDefaultsRemovesAllOverrides() throws {
        let store = makeStore()
        try store.setBinding([KeyCombo(key: "e", modifiers: .command)], for: .rename)
        try store.setBinding([], for: .newFolder)

        store.resetToDefaults()

        #expect(store.binding(for: .rename).combos == [KeyCombo(key: "r", modifiers: .command)])
        #expect(store.binding(for: .newFolder).combos == [KeyCombo(key: "n", modifiers: [.command, .shift])])
    }

    @Test func overridesSurviveANewStoreInstanceOverTheSameDefaults() throws {
        let suiteName = "qoo-keybinding-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let first = UserDefaultsKeyBindingStore(defaults: defaults, storageKey: "overrides")
        try first.setBinding([KeyCombo(key: "e", modifiers: .command)], for: .rename)

        let second = UserDefaultsKeyBindingStore(defaults: defaults, storageKey: "overrides")
        #expect(second.binding(for: .rename).combos == [KeyCombo(key: "e", modifiers: .command)])
    }

    /// 廃止された `ActionID`（アプリの更新でケースが消えた場合）が保存領域に
    /// 残っていても、**他の割り当てが道連れにならない** [1-16 で発見]。
    /// 以前は `[ActionID: [KeyCombo]]` として一括デコードしていたため、
    /// 未知のキーが 1 つあるだけでデコード全体が失敗し、`try?` に握りつぶされて
    /// ユーザーのキー設定が丸ごと既定へ戻っていた。
    @Test func unknownActionIDInStorageDoesNotDiscardTheOtherOverrides() throws {
        let suiteName = "qoo-keybinding-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let payload: [String: [KeyCombo]] = [
            "rename": [KeyCombo(key: "e", modifiers: .command)],
            "someRemovedActionFromAnOlderBuild": [KeyCombo(key: "j", modifiers: .command)],
        ]
        defaults.set(try JSONEncoder().encode(payload), forKey: "overrides")

        let store = UserDefaultsKeyBindingStore(defaults: defaults, storageKey: "overrides")
        #expect(store.binding(for: .rename).combos == [KeyCombo(key: "e", modifiers: .command)])
    }

    /// 旧形式（`ActionID` をキーにした辞書。Swift の `Codable` はこれを
    /// キーと値が交互に並ぶ平坦な配列として書き出す）で保存された設定を、
    /// 新形式へ移行しても失わない [1-16 で保存形式を変更したことへの対応]。
    @Test func legacyFlatArrayStorageIsStillReadable() throws {
        let suiteName = "qoo-keybinding-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let legacy: [ActionID: [KeyCombo]] = [.rename: [KeyCombo(key: "e", modifiers: .command)]]
        defaults.set(try JSONEncoder().encode(legacy), forKey: "overrides")

        let store = UserDefaultsKeyBindingStore(defaults: defaults, storageKey: "overrides")
        #expect(store.binding(for: .rename).combos == [KeyCombo(key: "e", modifiers: .command)])

        // 次の保存で新形式に置き換わり、以後も読めること。
        try store.setBinding([KeyCombo(key: "y", modifiers: .command)], for: .toggleThumbnails)
        let reopened = UserDefaultsKeyBindingStore(defaults: defaults, storageKey: "overrides")
        #expect(reopened.binding(for: .rename).combos == [KeyCombo(key: "e", modifiers: .command)])
        #expect(reopened.binding(for: .toggleThumbnails).combos == [KeyCombo(key: "y", modifiers: .command)])
    }
}

/// 変更不可（Finder 標準）の操作は上書きを受け付けない [ユーザー判断]。
/// 受け付けてしまうと、メニュー項目が `DefaultKeyBindings` から読む表示と
/// ストアの中身が食い違う。
@Suite struct FixedKeyBindingStoreTests {
    private func makeStore() -> (UserDefaultsKeyBindingStore, UserDefaults) {
        let suite = "qoo-fixed-binding-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (UserDefaultsKeyBindingStore(defaults: defaults), defaults)
    }

    @Test func setBindingIsIgnoredForFixedActions() throws {
        let (store, _) = makeStore()
        let original = store.binding(for: .copy).combos

        try store.setBinding([KeyCombo(key: "q", modifiers: .command)], for: .copy)

        #expect(store.binding(for: .copy).combos == original)
    }

    @Test func setBindingStillWorksForCustomizableActions() throws {
        let (store, _) = makeStore()
        let combo = KeyCombo(key: "q", modifiers: .command)

        try store.setBinding([combo], for: .rename)

        #expect(store.binding(for: .rename).combos == [combo])
    }
}
