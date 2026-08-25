//
//  ブックフォルダのインジケータ [IF-17][BF-08]。
//
//  ブックフォルダはフォルダ表示モードでは**通常のフォルダとして表示・操作
//  できる**（中へ降りられるし、移動もリネームもできる）ので、印が無いと
//  「これは 1 冊として DB に載っているフォルダだ」と分からない。
//
//  **リストとアイコンで実装を分けない。** 見た目が食い違うと、同じ印が別の
//  意味に見える——このリポジトリが繰り返し踏んでいる「同じに見えるものに
//  独立した実装を 2 つ作る」の形を避ける（`LabelChip` [CP-02]・`RatingStars` と
//  同じ扱い）。
//
import SwiftUI

private struct BookFolderBadgeModifier: ViewModifier {
    let isBookFolder: Bool
    /// 印を載せるアイコンの一辺。**印の寸法をこれから導く**——アイコンサイズは
    /// スライダーで変わるので、固定値だと小さいときに潰れ、大きいときに
    /// 目立ちすぎる。
    let iconSize: Double

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottomTrailing) {
            if isBookFolder {
                Image(systemName: "book.closed.fill")
                    // 下限を設けて、アイコンが小さいときも形が残るようにする。
                    .font(.system(size: max(6, iconSize * 0.26)))
                    .foregroundStyle(.white)
                    .padding(max(1.5, iconSize * 0.05))
                    .background(Circle().fill(Color.accentColor))
                    // 縁を付けてカバー画像の上でも輪郭が消えないようにする。
                    .overlay(Circle().strokeBorder(.background, lineWidth: max(0.5, iconSize * 0.02)))
                    .help(Text("folder.bookFolderIndicator"))
                    // 印そのものはクリックを受け取らない——行の選択・
                    // ダブルクリックを妨げてはならない。
                    .allowsHitTesting(false)
            }
        }
    }
}

extension View {
    /// ブックフォルダの印を右下へ載せる [IF-17]。
    func bookFolderBadge(_ isBookFolder: Bool, iconSize: Double) -> some View {
        modifier(BookFolderBadgeModifier(isBookFolder: isBookFolder, iconSize: iconSize))
    }
}
