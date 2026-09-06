//
//  表示言語の上書き設定 [1-12 ローカライズ方針]。
//
//  **`QooKit` に置いてあるのは、全層から読む必要があるため。** 利用者に
//  見える文字列は下位 3 層にもあり（エラー文言・Undo メニューの文言・
//  操作履歴の要約）、それらは View の外で組み立てられるので
//  `@Environment(\.locale)` を受け取れない。
//
//  `UserDefaults` を読むのは `QooKit` の「純粋関数のみ」という方針の例外に
//  見えるが、同じ形の前例が既にある（`SetupWizard` / `CompressionOptions`）。
//  外部状態の読み取りであってファイルシステムには触れない。
//
import Foundation

public enum AppLanguagePreference: String, CaseIterable, Sendable {
    case system
    case japanese = "ja"
    case english = "en"

    /// 環境設定「一般」タブが読み書きする鍵。**綴りをここ 1 箇所に持つ**
    /// ——UI 側と下層で別々に書くと、片方を直したときに静かに食い違う。
    public static let storageKey = "qoo.preferences.appLanguage"

    /// `nil` は「上書きしない（システム設定に従う）」。
    public var locale: Locale? {
        switch self {
        case .system: nil
        case .japanese: Locale(identifier: "ja")
        case .english: Locale(identifier: "en")
        }
    }

    /// View 階層の外から現在の言語設定を読む。
    ///
    /// **この値を `String(localized:locale:)` へ渡してはならない**——効かない。
    /// `LocalizedStrings.string(_:bundle:locale:)` を通すこと（理由はそちらの
    /// 型コメント）。
    /// 既定の `UserDefaults` から読む形。**製品コードはこちらを使う。**
    public static var effectiveLocale: Locale { effectiveLocale(.standard) }

    /// テストが差し替えるための形。
    public static func effectiveLocale(_ defaults: UserDefaults) -> Locale {
        let raw = defaults.string(forKey: storageKey) ?? AppLanguagePreference.system.rawValue
        return AppLanguagePreference(rawValue: raw)?.locale ?? Locale.autoupdatingCurrent
    }
}
