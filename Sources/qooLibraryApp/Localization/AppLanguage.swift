import SwiftUI

/// アプリの表示言語の上書き設定 [ユーザー要望: 日本語/英語のローカライズ対応、
/// 環境設定「一般」タブ最上部で「システムに従う」「日本語」「英語」を選べる
/// ようにしたい]。
///
/// `AppleLanguages`（`UserDefaults`）を書き換える伝統的な方式は次回起動まで
/// 反映されないため、代わりに SwiftUI の `.environment(\.locale:)` を各シーンの
/// ルートに適用する方式にした。`Text` の `LocalizedStringKey` 解決はこの
/// environment 値を見るため、設定を変えた瞬間に再描画される（再起動不要）。
enum AppLanguage: String, CaseIterable {
    case system
    case japanese = "ja"
    case english = "en"

    /// `nil` は「上書きしない（システム設定に従う）」を意味する。
    var locale: Locale? {
        switch self {
        case .system: nil
        case .japanese: Locale(identifier: "ja")
        case .english: Locale(identifier: "en")
        }
    }

    private static let storageKey = "qoo.preferences.appLanguage"

    /// View 階層の外（`@Environment` を使えない `static`/`enum` 経由の処理、
    /// および `NotificationItem`/`NSAlert` 等 SwiftUI の environment を
    /// そもそも継承しない経路）から現在の言語設定を読むためのヘルパー
    /// [1-12 ローカライズ方針、CLAUDE.md 参照]。`NotificationRouter` が
    /// 提示する通知は AppKit の `NSAlert` を直接使っており（
    /// `NotificationRouterPresenterController` 参照）、SwiftUI の
    /// `.environment(\.locale)` を継承しないため、こちらを使う必要がある。
    static var effectiveLocale: Locale {
        let raw = UserDefaults.standard.string(forKey: storageKey) ?? AppLanguage.system.rawValue
        return AppLanguage(rawValue: raw)?.locale ?? Locale.autoupdatingCurrent
    }
}

extension View {
    /// `qooLibraryApp.swift` の各シーン（メインウインドウ・環境設定・
    /// アバウト）のルートに1回ずつ適用する。
    func appLanguageOverride() -> some View {
        modifier(AppLanguageOverrideModifier())
    }
}

private struct AppLanguageOverrideModifier: ViewModifier {
    @AppStorage("qoo.preferences.appLanguage") private var appLanguage = AppLanguage.system.rawValue

    func body(content: Content) -> some View {
        if let locale = AppLanguage(rawValue: appLanguage)?.locale {
            content.environment(\.locale, locale)
        } else {
            content
        }
    }
}
