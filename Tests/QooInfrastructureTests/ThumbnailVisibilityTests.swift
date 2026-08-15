import Foundation
import Testing

@testable import QooInfrastructure

/// [DS-01][DS-03] サムネイル表示の全体トグル。
///
/// `ThumbnailVisibility.shared`（`UserDefaults.standard`）は**触らない**。
/// テストは既定で並行実行されるため、プロセス共有の設定を書き換えると
/// 他のスイートに干渉する（`DiagnosticLog` がテスト中の出力先を振り替えて
/// いるのと同じ問題意識）。専用のスイート名で独立した `UserDefaults` を
/// 用意し、そちらを注入する。
@Suite @MainActor struct ThumbnailVisibilityTests {
    private func makeDefaults() throws -> (defaults: UserDefaults, suiteName: String) {
        let suiteName = "qoo-thumbnail-visibility-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        return (defaults, suiteName)
    }

    @Test func defaultsToShowingThumbnails() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(ThumbnailVisibility(defaults: defaults).isGloballyHidden == false)
    }

    @Test func toggleFlipsTheValue() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let visibility = ThumbnailVisibility(defaults: defaults)

        visibility.toggleGlobal()
        #expect(visibility.isGloballyHidden)

        visibility.toggleGlobal()
        #expect(visibility.isGloballyHidden == false)
    }

    /// アプリを再起動しても設定が残ること。パスバー・ステータスバーの表示状態と
    /// 同じ扱いで、性能上の理由で切った人が毎回切り直さずに済むようにする。
    @Test func persistsAcrossInstances() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        ThumbnailVisibility(defaults: defaults).setGloballyHidden(true)

        #expect(ThumbnailVisibility(defaults: defaults).isGloballyHidden)
    }

    /// 同じ値の再設定で `UserDefaults` へ書きに行かない（`@Observable` の
    /// 変更通知も起こさない）。全ウインドウが監視している状態 [DS-03] なので、
    /// 無変化での通知は無駄な再描画に直結する。
    @Test func settingTheSameValueIsANoOp() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let visibility = ThumbnailVisibility(defaults: defaults)

        visibility.setGloballyHidden(false)

        #expect(defaults.object(forKey: ThumbnailVisibility.globallyHiddenKey) == nil)
    }
}
