//
//  「ピン留めのある一覧」の並べ方 [PN-02][PN-03][PN-05][PN-06][RL-04][RL-05]。
//
//  **ラベルフィルタ（左ペイン下半分）と右ペインのラベル設定は、同じ規則で
//  ラベルを並べる。** 要件がそう定めている——RL-04 は「ラベルフィルタと同様に、
//  ピン留めのある一覧表示から…チェックボックスで設定する」と名指しで書いて
//  いる。同じに見える一覧に独立した実装を 2 つ作ると、片方だけ直して取り残す
//  （1-12 のアプリ関連付けで実際に踏んだ形）。
//
//  ここに置いてあるのは**純粋関数だけ**で、状態は呼び出し側（`LabelFilterModel`
//  / `LabelEditorModel`）が持つ。両者で違うのは「必ず含める」の判定だけなので、
//  それを述語として受け取る。
//
import Foundation

public enum PinnedLabelListing {
    /// そのグループで実際に並べるラベル。
    ///
    /// - 展開中（「もっと見る」）は全件。検索文字列があれば絞る [PN-05]
    /// - ピン留めがあればピン留めだけ [PN-02]
    /// - 無ければ上位 `collapsedLimit` 件 [PN-03]
    /// - **`mustInclude` が真のものはピン対象外でも必ず含める** [PN-06][RL-05]
    ///
    /// - Parameter all: 既に「ピン留め優先・名前順」で並んでいること。
    ///   この関数は並べ替えない——順序はリポジトリが決めており、ここで
    ///   並べ直すと DB の並びと画面の並びが食い違う。
    public static func visible(
        _ all: [LabelSummary],
        collapsedLimit: Int,
        isRevealed: Bool,
        searchText: String,
        mustInclude: (LabelSummary) -> Bool
    ) -> [LabelSummary] {
        if isRevealed {
            guard !searchText.isEmpty else { return all }
            return all.filter { NameFilter.matches(name: $0.name, query: searchText) }
        }
        let pinned = all.filter(\.isPinned)
        let base = pinned.isEmpty ? Array(all.prefix(collapsedLimit)) : pinned
        let required = all.filter(mustInclude)
        var seen = Set<LabelID>()
        // `all` の順序を保ったまま重複を落とすだけでよい [PN-06]。
        return (base + required).filter { seen.insert($0.id).inserted }
    }

    /// 「もっと見る」を出すべきか [PN-02][PN-03]。
    public static func hasMore(
        _ all: [LabelSummary],
        collapsedLimit: Int,
        isRevealed: Bool,
        mustInclude: (LabelSummary) -> Bool
    ) -> Bool {
        guard !isRevealed else { return false }
        let shown = visible(all, collapsedLimit: collapsedLimit,
                            isRevealed: false, searchText: "", mustInclude: mustInclude)
        return all.count > shown.count
    }
}
