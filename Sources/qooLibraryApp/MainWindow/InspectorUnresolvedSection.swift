//
//  右ペインの「未整理」[UR3-04][UR2-05]。
//
//  判定は `UnresolvedHintModel`（`QooApplication`）が持つ。この View は描くだけ
//  ——`InspectorVaultSection` と同じ分け方。
//
//  **行の注記ではなくここに置く**［ユーザー判断、2026-09-01］。フォーマットの
//  本文（`(@booktype) [@circle (@author)] @title (@genre) [@keyword]`）は長く、
//  一覧の行に置くと幅を食ううえ、行には既に印が 2 つある（無視済み・タイプ
//  不一致）。1 件ずつ直すという実際の作業にも、右ペインのほうが合う。
//
import QooApplication
import QooKit
import SwiftUI

struct InspectorUnresolvedSection: View {
    let model: UnresolvedHintModel

    @Environment(\.locale) private var locale

    var body: some View {
        switch model.state {
        case .notApplicable, .loading:
            EmptyView()
        case .failed(let reason):
            section {
                Text(reason)
                    .font(.system(size: Tokens.fontSize.caption))
                    .foregroundStyle(Tokens.Colors.dangerText)
                    .lineLimit(3)
            }
        case .ready(let subject):
            section {
                // **説明文は置かない**［ユーザー指摘、2026-09-02］。右ペインは
                // 「種類」「サイズ」のような**短い値の並び**で、そこに散文を
                // 混ぜると読む場所が変わってしまう。節が出ていること自体が
                // 「このファイルは未整理である」という答えになっている。
                //
                // **フォーマットの本文だけを出す**［ユーザー判断］。
                // 「ここまで一致しました」の位置は出さない——推定は飽和しうる
                // ので、位置を見せると「全部一致した」と嘘をつく場面がある
                // （`NearestFormat` の注記を参照）。手がかりが無いときは、
                // 日付が無いときと同じ「—」にする。
                InspectorRow("inspector.unresolved.nearestFormat") {
                    Text(subject.nearestFormatSource ?? "—")
                        .font(.system(size: Tokens.fontSize.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(4)
                }
                if subject.isIgnored {
                    // 通常の一覧から選んだときは、行の印 [UR3-03] が出ない
                    // ——ここが「なぜ未整理の一覧に出てこないか」の手がかりになる。
                    Label("inspector.unresolved.ignored", systemImage: "eye.slash")
                        .font(.system(size: Tokens.fontSize.caption))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// **この節だけ見出しを残す。** 他の節（評価・ラベル・保護・保管庫）は
    /// 中身を見れば何の節か分かるので撤去したが［ユーザー指摘、2026-09-02］、
    /// ここは「近いフォーマット」という 1 行しか持たず、見出しが無いと
    /// **そのファイルが未整理であること自体が読み取れない**。
    @ViewBuilder
    private func section(@ViewBuilder _ content: () -> some View) -> some View {
        Divider()
        VStack(alignment: .leading, spacing: Tokens.spacing.xs) {
            Text("inspector.unresolved")
                .foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .font(.system(size: Tokens.fontSize.caption))
    }
}
