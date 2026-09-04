//
//  畳んだ組の件数バッジ [DU-06][DG-01][VM3-02]。
//
//  一覧が組を畳むと代表 1 行だけが出る [DU-04][VM3-01]。**畳んだことが
//  見えないと「本が減った」ように読める**ので、代表の右上に「あと何件
//  あるか」を出す。
//
//  **重複の組とシリーズのスタックで同じ部品を使う** [VM3-02 が名指しで
//  「同じ視覚部品を流用」と定める]。違うのはツールチップの文だけ——
//  「同じ本が 2 ファイル」と「違う巻が 12 冊」は、印の意味がまるで違う。
//
//  **リストとアイコンで実装を分けない**——`bookFolderBadge` [IF-17] と同じ
//  理由（このリポジトリが繰り返し踏んでいる「同じに見えるものに独立した
//  実装を 2 つ作る」を避ける）。印の位置は右上で、ブックフォルダの印
//  （右下）と重ならない——1 冊が**ブックフォルダかつ重複**でありうる。
//
import QooApplication
import SwiftUI

private struct GroupCountBadgeModifier: ViewModifier {
    /// 代表している組。**`.none` なら何も出さない**——「畳んでいない」は
    /// 印の不在で表す。
    let group: LibraryContentModel.RowGroup
    /// 印を載せるアイコンの一辺。寸法はここから導く（`bookFolderBadge` と同じ）。
    let iconSize: Double

    /// ツールチップ。**組の種類で文を変える**——同じ「×12」でも
    /// 「同じ本が 12 ファイル」と「12 巻ある」では意味が正反対に近い。
    private var helpKey: LocalizedStringKey? {
        switch group {
        case .none:      return nil
        case .duplicate: return "folder.duplicateGroupIndicator"
        case .series:    return "folder.seriesStackIndicator"
        }
    }

    func body(content: Content) -> some View {
        content.overlay(alignment: .topTrailing) {
            if group.count > 1, let helpKey {
                Text(verbatim: "×\(group.count)")
                    .font(.system(size: max(7, iconSize * 0.26), weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .padding(.horizontal, max(2, iconSize * 0.08))
                    .padding(.vertical, max(1, iconSize * 0.03))
                    .background(Capsule().fill(Color.accentColor))
                    // 縁を付けてカバー画像の上でも輪郭が消えないようにする。
                    .overlay(Capsule().strokeBorder(.background,
                                                    lineWidth: max(0.5, iconSize * 0.02)))
                    .help(Text(helpKey))
                    // 印そのものはクリックを受け取らない——行の選択・
                    // ダブルクリックを妨げてはならない。
                    .allowsHitTesting(false)
            }
        }
    }
}

extension View {
    /// 畳んだ組の件数を右上へ載せる [DU-06][VM3-02]。
    func groupCountBadge(_ group: LibraryContentModel.RowGroup,
                         iconSize: Double) -> some View {
        modifier(GroupCountBadgeModifier(group: group, iconSize: iconSize))
    }
}
