import SwiftUI
import QooKit

/// アプリの表示言語の上書き設定 [ユーザー要望: 環境設定「一般」タブ最上部で
/// 「システムに従う」「日本語」「英語」を選べるようにしたい]。
///
/// **実体は `AppLanguagePreference`（`QooKit`）へ移した**——利用者に見える
/// 文字列は下位 3 層にもあり（エラー文言・Undo メニューの文言・操作履歴の
/// 要約）、それらは View の外で組み立てられるので同じ設定を読む必要がある。
/// 別々に持つと、片方を直したときに静かに食い違う。
typealias AppLanguage = AppLanguagePreference

extension View {
    /// `qooLibraryApp.swift` の各シーン（メインウインドウ・環境設定・
    /// アバウト）のルートに1回ずつ適用する。
    ///
    /// **これで切り替わるのは `Text` の `LocalizedStringKey` 解決だけ**——
    /// SwiftUI がこの environment 値を見て `.lproj` を選び直すため。
    /// View の外で組み立てる文字列（`NSAlert` の通知・Undo メニュー・
    /// ステータスバー）はこの仕組みに乗らないので、`AppStrings` を通すこと。
    func appLanguageOverride() -> some View {
        modifier(AppLanguageOverrideModifier())
    }
}

private struct AppLanguageOverrideModifier: ViewModifier {
    @AppStorage(AppLanguagePreference.storageKey) private var appLanguage = AppLanguage.system.rawValue

    func body(content: Content) -> some View {
        if let locale = AppLanguage(rawValue: appLanguage)?.locale {
            content.environment(\.locale, locale)
        } else {
            content
        }
    }
}
