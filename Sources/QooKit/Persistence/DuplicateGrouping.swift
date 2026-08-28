//
//  重複ファイルの判定 [DU-01〜DU-05][DU-08][DU-13]。
//
//  **「同じ作品のファイルが複数ある」を見つけるための規則を、ここ 1 箇所で
//  決める。** 実際のグループ化は SQL の窓関数が行う（`SQLiteManagedFileRepository`
//  の `duplicateGroups`）が、**鍵の材料を作るのはこのファイルだけ**である
//  ——規則を 2 か所に持つと、一覧に出るグループと比較ビューに出るメンバーが
//  食い違い、しかも画面からは理由が読み取れない。
//
import Foundation

/// 何を「同じ作品」とみなすか [DU-02]。**既定は `.off`** [DU-01]。
public enum DuplicateGrouping: String, Sendable, Codable, Hashable, CaseIterable {
    /// グループ化しない。すべて個別に表示する。
    case off
    /// 正規化済みタイトルのみ一致。
    case byTitle
    /// 正規化済みタイトル + 巻数が一致。
    case byTitleAndVolume

    public var isEnabled: Bool { self != .off }

    /// 壊れた値・未知の値は `.off`（＝何もしない側）へ倒す。
    ///
    /// **グループ化は表示を畳む機能**なので、判断できないときに畳むより
    /// 畳まないほうが害が小さい。
    public init(storedValue: String?) {
        self = DuplicateGrouping(rawValue: storedValue ?? "") ?? .off
    }
}

/// グループ化の鍵の材料。
public enum DuplicateGroupKey {
    /// 正規化済みタイトル（`managedFile.titleKey` に入れる値）。
    ///
    /// **`nil` は「グループ化の対象にしない」**という意味であって、
    /// 「鍵が空」ではない——`nil` どうしを同じ鍵とみなすと、**タイトルを
    /// 取れなかったファイル全部が 1 つの巨大なグループになる**。未解決
    /// ファイル [AL-30] は蔵書によっては数千件あるので、これは実害になる。
    ///
    /// 正規化は N-01〜N-03 + WS-06 [DU-03]。**`TextNormalizer.searchKey` では
    /// なく `normalize` を使う**——searchKey はひらがな→カタカナの畳み込みも
    /// 行うので、`DU-03` が定める範囲より広い。
    public static func titleKey(title: String?) -> String? {
        guard let title else { return nil }
        let normalized = TextNormalizer.normalize(title)
        return normalized.isEmpty ? nil : normalized
    }

    /// 巻数の鍵。`byTitleAndVolume` のときだけ鍵に混ぜる。
    ///
    /// **巻数を持たないもの（`.none`）どうしは同じ鍵にする**——「第01巻」と
    /// 「第02巻」は別だが、巻数の無い読み切り 2 冊は同じ作品でありうる。
    public static func volumeKey(_ volume: VolumeValue) -> String {
        switch volume.kind {
        case .numeric:
            guard let n = volume.number else { return "n" }
            // 3.0 と 3 を同じ鍵にする。SQL 側は REAL のまま比較するので、
            // どちらの経路でも同じ組になる。
            return n == n.rounded() && abs(n) < 1e15
                ? String(Int64(n))
                : String(n)
        case .none:
            return "-"
        }
    }

    /// 単一の文字列としての鍵。**テストと診断のための表現**で、実際の
    /// グループ化は SQL が `titleKey`（＋巻数の 2 列）で行う。
    ///
    /// `nil` はグループ化の対象外。
    public static func make(title: String?, volume: VolumeValue,
                            mode: DuplicateGrouping) -> String? {
        guard mode.isEnabled else { return nil }
        guard let key = titleKey(title: title) else { return nil }
        switch mode {
        case .off:             return nil
        case .byTitle:         return key
        case .byTitleAndVolume: return key + "#" + volumeKey(volume)
        }
    }
}
