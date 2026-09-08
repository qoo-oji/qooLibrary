//
//  既定フィールド 5 種の訳語 [§19.2][RWI-02]。
//
//  `QooKit` は表示文字列を持たない [A-01] ので、既定フィールドの名前は
//  UI 層から渡す。**綴りではなく `SemanticKeyword.defaultFields` の順で
//  組み立てる**——順序を 2 箇所に持つと、予約語を足したときに名前と束縛が
//  1 つずつずれる（気づきにくく、しかも全ライブラリに波及する）。
//
import Foundation
import QooKit

enum DefaultFieldNames {
    /// `SemanticKeyword.defaultFields` と同じ並びの訳語。
    static var localized: [String] {
        SemanticKeyword.defaultFields.map { name(for: $0) }
    }

    /// **`locale:` を必ず渡す。** ここは View の外なので `@Environment(\.locale)`
    /// が無く、素の `String(localized:)` はアプリ内の表示言語ではなくシステムの
    /// 言語で解決する。しかもこの名前は**登録時に DB へ書かれて残る**ので、
    /// 取り違えると英語で使っている利用者のライブラリに日本語の名前が焼き付く。
    static func name(for keyword: SemanticKeyword) -> String {
        let locale = AppLanguage.effectiveLocale
        return switch keyword {
        case .author:  AppStrings.text("field.default.author", locale: locale)
        case .studio:  AppStrings.text("field.default.studio", locale: locale)
        case .genre:   AppStrings.text("field.default.genre", locale: locale)
        case .event:   AppStrings.text("field.default.event", locale: locale)
        case .keyword: AppStrings.text("field.default.keyword", locale: locale)
        case .series:  AppStrings.text("field.default.series", locale: locale)
        case .mediaType: AppStrings.text("field.default.mediaType", locale: locale)
        case .actor:   AppStrings.text("field.default.actor", locale: locale)
        case .season:  AppStrings.text("field.default.season", locale: locale)
        // **カスタム軸には既定の名前を持たせない** [MF-22]。何に使うかは
        // 完全に利用者次第なので、こちらが名前を決めると誤誘導になる。
        // 予約語の綴りから `@` を落としたものを置き、利用者が改名する。
        case .keyword2, .keyword3, .keyword4, .keyword5:
            String(keyword.rawValue.dropFirst())
        }
    }
}
