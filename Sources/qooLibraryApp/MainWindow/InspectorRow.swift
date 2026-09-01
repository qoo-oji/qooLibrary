//
//  右ペインの「ラベル＋値」の 1 行 [DT-01〜DT-11]。
//
//  **値の左端をすべて揃える**［ユーザー指摘、2026-09-02］。素の
//  `LabeledContent` はラベルの文字幅ぶんだけ値の位置が動くので、「種類」
//  「サイズ」「含まれるファイル数」で 3 通りの位置になり、縦に読めない。
//
//  節をまたいで揃える必要がある（基本情報・保管庫・未整理はそれぞれ別の
//  View）ため、**幅はここ 1 箇所の定数で決める**——`Grid` や alignment guide は
//  同じ器の中でしか揃えられない。
//
import SwiftUI

enum InspectorRowMetrics {
    /// ラベル列の幅。**実測で決める**（11pt システムフォントでの ja/en の
    /// 最長が「近いフォーマット」＝ 82pt）——目測で決めない［既記録の教訓］。
    ///
    /// これより長いラベルを足すときは、**ラベルのほうを短くする**こと。
    /// 幅を広げると、右ペインは 265pt しかないので値の側が読めなくなる。
    static let labelWidth: CGFloat = 86
}

struct InspectorRow<Content: View>: View {
    let label: LocalizedStringKey
    @ViewBuilder let content: () -> Content

    init(_ label: LocalizedStringKey, @ViewBuilder content: @escaping () -> Content) {
        self.label = label
        self.content = content
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Tokens.spacing.s) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: InspectorRowMetrics.labelWidth, alignment: .leading)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        // **右ペインの字の大きさは 1 つ**［ユーザー指摘、2026-09-02］。
        // ファイル名（`title2`）だけが大きく、それ以外はすべて `caption`
        // ——ラベルと値は色（`secondary` と既定）で区別する。
        .font(.system(size: Tokens.fontSize.caption))
    }
}

extension InspectorRow where Content == Text {
    init(_ label: LocalizedStringKey, value: String) {
        self.init(label) { Text(value) }
    }
}
