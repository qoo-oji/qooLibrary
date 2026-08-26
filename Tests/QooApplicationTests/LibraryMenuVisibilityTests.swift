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

    @Test("有効・オンライン → 設定・ラベル編集・保管庫・孤立の整理・再スキャン・無効化")
    func enabledAndOnline() {
        #expect(LibraryMenuVisibility.items(isEnabled: true, isOnline: true)
                == [.settings, .labels, .labelVault, .orphanCleanup, .rescan, .disable])
    }

    /// **この 1 件が本命。** 無効化は DB の行を消すだけでボリュームを要らない。
    @Test("有効・オフライン → 無効化は必ず出す（再スキャンは出さない）")
    func enabledAndOfflineStillOffersDisable() {
        let items = LibraryMenuVisibility.items(isEnabled: true, isOnline: false)
        #expect(items.contains(.disable), "ボリュームを失っても片付けられなければならない")
        // 設定は DB しか触らない。**縮退状態でこそ見直したい**（登録し直す前に
        // 型を直しておく等）ので、無効化と同じくオンライン条件で塞がない [LS-01]。
        #expect(items.contains(.settings), "設定は DB しか触らないので開けなければならない")
        // ラベルの編集も DB しか触らない [LE-07]。**外付けが無い間に表記ゆれを
        // 片付けたい**のはむしろ普通なので、ここも塞がない。
        #expect(items.contains(.labels), "ラベル編集は DB しか触らないので開けなければならない")
        // 保管庫の整理も同じ [LAW-01〜03][15.3 節]。アーカイブ属性を書き換える
        // だけなので、外付けが無い間にこそ片付けたいことがある。
        #expect(items.contains(.labelVault), "保管庫の整理は DB しか触らないので開けなければならない")
        // 孤立の整理も DB しか触らない [OR-01〜05][15.7 節]。そのライブラリの
        // 一覧は出せない [OR2-06] が、**ウインドウは全ライブラリを持つので
        // 行き止まりにならず**、「オフラインの間は孤立と判定していない」ことを
        // 読み取れること自体に意味がある [R-01]。
        #expect(items.contains(.orphanCleanup),
                "孤立の整理は DB しか触らないので開けなければならない")
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
