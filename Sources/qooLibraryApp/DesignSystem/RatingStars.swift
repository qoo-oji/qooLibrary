//
//  星 1〜5 の並び [RA-01][RT-01]。
//
//  ラベルフィルタ（絞り込み）と右ペイン（評価の設定）は**意味の違う機能**だが、
//  見た目は同じでなければならない。片方だけ星の大きさや間隔が変わると、
//  同じ絵が 2 種類あるように見える——`LabelChip` を単一実装にしている [CP-02]
//  のと同じ理由で、描画だけをここへ集める。
//
//  **判定（何個塗るか・押されたら何をするか）は呼び出し側が持つ。**
//  フィルタの「★3 以上」と評価の「★3」は同じ絵で違う意味なので、ここへ
//  寄せても条件分岐が増えるだけで共有の利点が無い。
//
import SwiftUI

struct RatingStars: View {
    /// 左から何個を塗るか（0〜5）。
    let filled: Int
    var tint: Color = .accentColor
    var isEnabled: Bool = true
    /// 押された星（1〜5）。**`nil` なら表示専用**——一覧の列 [LV-04] のように
    /// 星そのものが操作の対象でない場所で使う。ボタンのままそこへ置くと、
    /// 星を踏んだクリックが行の選択に届かない（Finder の一覧で列の中身を
    /// クリックしても行が選ばれるのと食い違う）。
    var onSelect: ((Int) -> Void)?

    var body: some View {
        HStack(spacing: Tokens.spacing.xs) {
            ForEach(1...5, id: \.self) { star in
                if let onSelect {
                    Button {
                        onSelect(star)
                    } label: {
                        glyph(star)
                            // 星形は中央が細く抜けているので、グリフの矩形全体を
                            // 当たり判定にする。無いと「押したのに反応しない」が
                            // 起きる（1-6 で `List` 行について踏んだのと同じ形）。
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!isEnabled)
                } else {
                    glyph(star)
                }
            }
        }
        .font(.system(size: Tokens.fontSize.body))
    }

    private func glyph(_ star: Int) -> some View {
        Image(systemName: star <= filled ? "star.fill" : "star")
            .foregroundStyle(tint)
    }
}
