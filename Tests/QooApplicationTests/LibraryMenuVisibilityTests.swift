//
//  ライブラリ機能のメニュー出し分けの検証 [19章 §19.6]。
//
//  **有効なライブラリの右クリックは「設定」だけ**［ユーザー指示: 登録解除と
//  設定以外は通常のフォルダと同じでよい。再スキャンは自動実行に任せる］。
//
import Testing
@testable import QooApplication

struct LibraryMenuVisibilityTests {

    @Test("未有効・オンラインでは有効化だけを出す")
    func notEnabledAndOnline() {
        #expect(LibraryMenuVisibility.items(isEnabled: false, isOnline: true) == [.enable])
    }

    @Test("未有効・オフラインでは何も出さない（実測できないため有効化できない）")
    func notEnabledAndOffline() {
        #expect(LibraryMenuVisibility.items(isEnabled: false, isOnline: false).isEmpty)
    }

    @Test("有効なら設定だけ——登録解除と設定以外は通常のフォルダと同じ [§19.6]")
    func enabledOffersOnlySettings() {
        for online in [true, false] {
            #expect(LibraryMenuVisibility.items(isEnabled: true, isOnline: online)
                    == [.settings],
                    "オンライン \(online) でも設定だけ。設定は DB しか触らないのでオフラインでも開けなければならない")
        }
    }

    @Test("有効なら有効化は二度と出ない")
    func enabledNeverOffersEnable() {
        for online in [true, false] {
            #expect(!LibraryMenuVisibility.items(isEnabled: true, isOnline: online).contains(.enable))
        }
    }
}
