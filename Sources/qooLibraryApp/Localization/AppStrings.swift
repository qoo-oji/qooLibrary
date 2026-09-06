//
//  アプリ本体の利用者可視文字列。**`Bundle.main` を引く唯一の入口**。
//
//  **`String(localized:locale:)` を直接呼んではならない。** `locale:` 引数は
//  数値・日付の**書式**にしか効かず、**どの `.lproj` から読むかには影響しない**
//  ［実測 2026-09-06、実アプリのバンドルで確認］。そのため、表示言語を
//  アプリ内で切り替えても、View の外で組み立てた文字列（`NSAlert` の通知・
//  Undo メニュー・ステータスバー・エラー文言）は切り替わらなかった。
//
//  SwiftUI の `Text` が追随するのは、SwiftUI 自身が `.environment(\.locale)` を
//  見て `.lproj` を選び直すからで、その仕組みは View の外には及ばない。
//
import Foundation
import QooKit

enum AppStrings {
    /// 既定は現在の表示言語設定。`@Environment(\.locale)` を持っている View から
    /// 呼ぶときは、そちらを渡すほうが正確（設定変更の反映が 1 描画早い）。
    static func text(_ key: String, locale: Locale = AppLanguagePreference.effectiveLocale) -> String {
        LocalizedStrings.string(key, bundle: .main, locale: locale)
    }

    static func format(_ key: String,
                       locale: Locale = AppLanguagePreference.effectiveLocale,
                       _ arguments: any CVarArg...) -> String {
        String(format: text(key, locale: locale), arguments: arguments)
    }
}
