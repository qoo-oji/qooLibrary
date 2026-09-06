import Foundation
import Testing
@testable import QooKit

@Suite("利用者可視文字列のロケール解決")
struct LocalizedStringsTests {
    private let en = Locale(identifier: "en")
    private let ja = Locale(identifier: "ja")

    @Test("言語ごとに別の訳が返る")
    func resolvesPerLanguage() {
        let e = LocalizedStrings.string("fileName.error.empty", bundle: QooKitStrings.bundle, locale: en)
        let j = LocalizedStrings.string("fileName.error.empty", bundle: QooKitStrings.bundle, locale: ja)
        #expect(e == "Enter a name.")
        #expect(j == "名前を入力してください。")
        #expect(e != j)
    }

    @Test("鍵が引けなければ鍵そのものが返る（黙って空にしない）")
    func missingKeyFallsBackToTheKey() {
        let s = LocalizedStrings.string("no.such.key", bundle: QooKitStrings.bundle, locale: en)
        #expect(s == "no.such.key")
    }

    @Test("地域つきロケールでも言語で解決する")
    func resolvesRegionalLocale() {
        let s = LocalizedStrings.string("fileName.error.empty",
                                        bundle: QooKitStrings.bundle,
                                        locale: Locale(identifier: "ja_JP"))
        #expect(s == "名前を入力してください。")
    }

    /// **対照実験。** これが失敗するようになったら Foundation 側の挙動が変わった
    /// ということで、`LocalizedStrings` の迂回をやめられる合図になる
    /// ［実測 2026-09-06: `locale:` は書式にしか効かず `.lproj` を選ばない］。
    @Test("String(localized:locale:) は .lproj を選ばない（この前提が崩れたら気づく）")
    func foundationLocaleArgumentStillDoesNotSelectLproj() {
        let viaFoundation = String(localized: "fileName.error.empty",
                                   bundle: QooKitStrings.bundle, locale: ja)
        let viaHelper = LocalizedStrings.string("fileName.error.empty",
                                                bundle: QooKitStrings.bundle, locale: ja)
        #expect(viaHelper == "名前を入力してください。")
        #expect(viaFoundation != viaHelper,
                "Foundation が locale: で .lproj を選ぶようになったなら LocalizedStrings は不要になる")
    }

    @Test("エラー文言がカタログから引かれる（鍵が素通りしない）")
    func failureUsesTheCatalog() {
        let text = FileNameValidation.Failure.empty.errorDescription
        #expect(text != nil)
        #expect(text?.contains("fileName.error") == false)
    }
}
