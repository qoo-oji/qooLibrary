//
//  重複グループの件数バッジ [DU-06][DG-01]。
//
//  同じ作品のファイルが複数あるとき、一覧には代表 1 行だけが出る [DU-04]。
//  **畳んだことが見えないと「本が減った」ように読める**ので、代表の右上に
//  「あと何件あるか」を出す。
//
//  **リストとアイコンで実装を分けない**——`bookFolderBadge` [IF-17] と同じ
//  理由（このリポジトリが繰り返し踏んでいる「同じに見えるものに独立した
//  実装を 2 つ作る」を避ける）。印の位置は右上で、ブックフォルダの印
//  （右下）と重ならない——1 冊が**ブックフォルダかつ重複**でありうる。
//
import SwiftUI

private struct DuplicateCountBadgeModifier: ViewModifier {
    /// 組の件数。**1 なら何も出さない**——「重複していない」は印の不在で表す。
    let count: Int
    /// 印を載せるアイコンの一辺。寸法はここから導く（`bookFolderBadge` と同じ）。
    let iconSize: Double

    func body(content: Content) -> some View {
        content.overlay(alignment: .topTrailing) {
            if count > 1 {
                Text(verbatim: "×\(count)")
                    .font(.system(size: max(7, iconSize * 0.26), weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .padding(.horizontal, max(2, iconSize * 0.08))
                    .padding(.vertical, max(1, iconSize * 0.03))
                    .background(Capsule().fill(Color.accentColor))
                    // 縁を付けてカバー画像の上でも輪郭が消えないようにする。
                    .overlay(Capsule().strokeBorder(.background,
                                                    lineWidth: max(0.5, iconSize * 0.02)))
                    .help(Text("folder.duplicateGroupIndicator"))
                    // 印そのものはクリックを受け取らない——行の選択・
                    // ダブルクリックを妨げてはならない。
                    .allowsHitTesting(false)
            }
        }
    }
}

extension View {
    /// 重複グループの件数を右上へ載せる [DU-06]。
    func duplicateCountBadge(_ count: Int, iconSize: Double) -> some View {
        modifier(DuplicateCountBadgeModifier(count: count, iconSize: iconSize))
    }
}
