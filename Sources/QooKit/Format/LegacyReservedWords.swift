//
//  予約語の改名の変換表 [MF-23]。
//
//  **DB の移行（v19）と文書の取り込み（JSON バックアップ・ユーザー定義テンプレート）が
//  同じ表を使う。** 片方だけ直すと、以前書き出した文書と DB とで変換結果が食い違う
//  ——`LegacyVolumeNotation`（旧記法の巻数）で同じ判断をしている。
//
import Foundation

public enum LegacyReservedWords {
    /// 旧綴り → 新綴り。**長い順に並べる**——短い綴りが長い綴りの一部を先に
    /// 書き換えると、残りが宙に浮く。
    public static let renames: [(old: String, new: String)] = [
        // 2026-09-08、見直しの段 B。どちらも意味が特定のドメインに寄っていた
        // ——`@circle`（同人のサークル）は実質「団体としての制作主体」、
        // `@booktype`（本の種別）は「作品の形態」で、映像にも同じ軸がある。
        ("@booktype", "@mediatype"),
        ("@circle", "@studio"),
    ]

    /// フォーマット文字列・JSON 文字列の中の旧綴りを新綴りへ写す。
    ///
    /// **部分一致で置き換える。** `semanticBindings` の鍵（`"@circle"`）も
    /// フォーマットの中の参照（`[@circle (@author)]`）も同じ経路で直る。
    public static func migrate(_ text: String) -> String {
        var out = text
        for (old, new) in renames { out = out.replacingOccurrences(of: old, with: new) }
        return out
    }
}
