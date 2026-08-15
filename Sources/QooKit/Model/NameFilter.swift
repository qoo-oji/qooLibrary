import Foundation

/// 一覧を名前で絞り込むときの一致判定 [1-16 検索]。
///
/// **[NM-01] の正規化（`TextNormalizer`）とは別の関心事** [設計判断]。
/// `TextNormalizer` は「保存・比較の基準となる値そのものを NFC 化・全角半角
/// 統一・空白畳み込みして作り直す」ドメインのルールで、ラベル抽出やリネームの
/// 土台になる。こちらは**文字列を一切作り変えず**、`String.range(of:options:)` に
/// 比較オプションを渡して「その場の見た目の一致」を判定するだけ。§3.8 の
/// 「正規化は 1 箇所にしか実装しない」に抵触しない（正規化を行っていない）。
public enum NameFilter {
    /// `name` が `query` を含むか。
    ///
    /// **`localizedStandardContains` を使わない** [実測で判明]。あれは Finder
    /// 流の自然順比較（`localizedStandardCompare`）と同じ「標準」を名乗るが、
    /// **幅は区別する**——実測:
    ///
    /// | 対象 `…サンプルプレビュー.cbz` に対する入力 | `localizedStandardContains` |
    /// |---|---|
    /// | `cbz` | true |
    /// | `ｃｂｚ`（全角） | **false** |
    /// | `サンプ` | true |
    /// | `ｻﾝﾌﾟ`（半角カナ） | **false** |
    ///
    /// 日本語入力がオンのまま英数字を打つと全角になるのはごく普通のことで、
    /// 半角カナを含むファイル名も実在する。**入力の幅までユーザーに合わせさせる
    /// のは「機械が人間に合わせる」という本アプリの大原則に反する**ため、
    /// `.widthInsensitive` を明示的に指定する。
    ///
    /// **`.diacriticInsensitive` は意図的に外している** [設計判断]。付けると
    /// 日本語では濁点・半濁点まで無視され、「ハンター」で「バンター」が
    /// 出るなど、絞り込みとしてはかえって分かりにくくなるため。
    public static func matches(name: String, query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return true }
        return name.range(of: trimmed, options: [.caseInsensitive, .widthInsensitive]) != nil
    }

    /// `name` が `prefix` で始まるか。キー入力で項目へ飛ぶ type-select 用。
    ///
    /// 一致の緩さは ``matches(name:query:)`` と揃える — 同じ「見た目で一致」の
    /// 判断が、絞り込みとキー入力で食い違ってはいけない。日本語入力のまま
    /// 打った全角英数でも飛べる必要があるのは、こちらも同じ。
    public static func hasPrefix(name: String, prefix: String) -> Bool {
        guard !prefix.isEmpty else { return false }
        guard let range = name.range(of: prefix, options: [.caseInsensitive, .widthInsensitive, .anchored]) else {
            return false
        }
        return range.lowerBound == name.startIndex
    }
}
