//
//  利用者に見える文字列の解決 [A-01: Foundation のみ]。
//
//  **`String(localized:locale:)` を使ってはならない。** `locale:` 引数は
//  数値・日付の**書式**にしか効かず、**どの `.lproj` から読むかには一切
//  影響しない**［実測 2026-09-06］。実アプリのバンドルに対して
//  `locale: Locale(identifier: "ja")` を渡しても英語が返る:
//
//      String(localized: key, bundle: app, locale: ja) → "About zip / …"   ← 英語
//      ja.lproj のバンドルを直接開く                    → "zip / … について" ← 日本語
//
//  SwiftUI の `Text` が表示言語の切り替えに追随するのは、SwiftUI 自身が
//  `.environment(\.locale)` を見て `.lproj` を選び直すからで、その仕組みは
//  View の外（`NSAlert` の通知・Undo メニュー・エラー文言）には及ばない。
//  **View の外で文字列を組み立てるときは、必ずここを通すこと。**
//
//  リソースの形式は各層とも `Resources/<lang>.lproj/Localizable.strings`。
//  **`.xcstrings`（Xcode の String Catalog）は使えない**——SwiftPM は
//  この形式をコンパイルせず、バンドルへ生のままコピーする［実測］ので、
//  `swift build` / `swift test` では 1 件も解決できない（`xcodebuild` では
//  動くため、アプリ本体だけを見ていると気づけない）。
//
import Foundation

public enum LocalizedStrings {
    /// `bundle` の `locale` 向けの訳を引く。訳が無ければ鍵をそのまま返す
    /// （`Bundle.localizedString` の既定の挙動）。
    public static func string(_ key: String, bundle: Bundle, locale: Locale) -> String {
        let target = localizedBundle(for: locale, in: bundle) ?? bundle
        return target.localizedString(forKey: key, value: nil, table: nil)
    }

    /// 書式引数を伴う訳。`String(format:)` の引数順序を訳ごとに変えられる
    /// よう、`%1$@` 等の位置指定をそのまま通す。
    public static func string(_ key: String, bundle: Bundle, locale: Locale,
                              _ arguments: any CVarArg...) -> String {
        String(format: string(key, bundle: bundle, locale: locale), arguments: arguments)
    }

    // MARK: - `.lproj` バンドルの解決

    /// 解決済みの `.lproj` バンドル。**引き直しは高くつく**（`Bundle(path:)` は
    /// 実 I/O を伴う）ので、バンドルのパスと言語コードの組で覚える。
    private static let cache = Cache()

    private static func localizedBundle(for locale: Locale, in bundle: Bundle) -> Bundle? {
        guard let code = locale.language.languageCode?.identifier else { return nil }
        return cache.bundle(forLanguage: code, in: bundle)
    }

    /// **`nonisolated` な場所から呼ばれる**（`FileOperationError.errorDescription`
    /// は任意のスレッドで評価されうる）ので、素の辞書ではなくロックで守る。
    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String: Bundle?] = [:]

        func bundle(forLanguage code: String, in bundle: Bundle) -> Bundle? {
            let key = "\(bundle.bundlePath)\u{1F}\(code)"
            lock.lock()
            if let hit = storage[key] {
                lock.unlock()
                return hit
            }
            lock.unlock()

            // **ロックの外で解決する**——`Bundle(path:)` は実 I/O で、
            // ネットワーク上のバンドルなら待たされうる [NV6-02 と同じ判断]。
            let resolved = bundle.path(forResource: code, ofType: "lproj").flatMap(Bundle.init(path:))

            lock.lock()
            storage[key] = resolved
            lock.unlock()
            return resolved
        }
    }
}
