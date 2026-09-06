//
//  `QooKit` の利用者可視文字列。**この層のリソースを引く唯一の入口**。
//
//  各層が同名の内部ヘルパーを持つ（`Bundle.module` は層ごとに別物なので
//  共有できない）。解決の規則そのものは `LocalizedStrings` が 1 つだけ持つ。
//
import Foundation

enum QooKitStrings {
    /// テストがロケールを指定して引くための入口。**製品コードは `text`/`format` を使う。**
    static var bundle: Bundle { .module }

    static func text(_ key: String) -> String {
        LocalizedStrings.string(key, bundle: .module,
                                locale: AppLanguagePreference.effectiveLocale)
    }

    static func format(_ key: String, _ arguments: any CVarArg...) -> String {
        String(format: text(key), arguments: arguments)
    }
}
