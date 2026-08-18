import Testing
@testable import QooApplication

/// メニューの出し分け [フェーズ 2 の結線]。
///
/// **実機検証で踏んだ欠陥の回帰テスト。** 「無効化」をオンライン条件で
/// 塞いでいたため、**ボリュームを失ったライブラリを二度と片付けられなく
/// なっていた**——縮退状態でこそ困る形だった。
@Suite("ライブラリ機能のメニューの出し分け")
struct LibraryMenuVisibilityTests {

    @Test("未有効・オンライン → 有効化だけ")
    func notEnabledAndOnline() {
        #expect(LibraryMenuVisibility.items(isEnabled: false, isOnline: true) == [.enable])
    }

    /// 有効化は `resolvedPath`/`volumeUUID` を実測するのでオンラインを要る [1-17]。
    @Test("未有効・オフライン → 何も出さない")
    func notEnabledAndOffline() {
        #expect(LibraryMenuVisibility.items(isEnabled: false, isOnline: false).isEmpty)
    }

    @Test("有効・オンライン → 再スキャンと無効化")
    func enabledAndOnline() {
        #expect(LibraryMenuVisibility.items(isEnabled: true, isOnline: true) == [.rescan, .disable])
    }

    /// **この 1 件が本命。** 無効化は DB の行を消すだけでボリュームを要らない。
    @Test("有効・オフライン → 無効化は必ず出す（再スキャンは出さない）")
    func enabledAndOfflineStillOffersDisable() {
        let items = LibraryMenuVisibility.items(isEnabled: true, isOnline: false)
        #expect(items.contains(.disable), "ボリュームを失っても片付けられなければならない")
        #expect(!items.contains(.rescan), "実ファイルを列挙できないので再スキャンは出さない")
        #expect(!items.contains(.enable))
    }

    /// 有効なライブラリに「有効にする」を出さない（二重登録の入口を作らない）。
    @Test("有効なら有効化は出さない")
    func enabledNeverOffersEnable() {
        for online in [true, false] {
            #expect(!LibraryMenuVisibility.items(isEnabled: true, isOnline: online).contains(.enable))
        }
    }
}
