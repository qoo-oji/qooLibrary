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

    @Test func setBindingToEmptyUnassignsAction() throws {
        let store = makeStore()
        try store.setBinding([], for: .newFolder)
        #expect(store.binding(for: .newFolder).combos.isEmpty)
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
}
