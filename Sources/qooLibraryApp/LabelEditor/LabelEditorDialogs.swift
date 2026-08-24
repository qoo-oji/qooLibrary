//
//  ラベル編集の確認ダイアログ [LE-08][LB-05][LB-07]。
//
//  どちらも ⌘Z で戻せる操作だが、**何が起きるかを実行前に見せる**
//  ——「使われていないつもり」で消す・統合するのを防ぐ。完全削除の確認
//  [PD-01〜06] と同じ考え方で、影響する件数を先に出す。
//
import QooKit
import SwiftUI

/// 削除の確認 [LE-07][LE-08][LB-05]。
struct DeleteLabelsDialog: View {
    @Environment(\.locale) private var locale
    @Environment(\.dialogDismiss) private var dismiss

    let labels: [LabelSummary]
    let onConfirm: () -> Void

    /// 紐づけが外れるファイルの延べ件数。**これを出すのが要点**——0 件なら
    /// 気軽に消せるし、多ければ手が止まる。
    private var affected: Int { labels.reduce(0) { $0 + $1.fileCount } }

    var body: some View {
        DialogScaffold(
            width: 440,
            confirm: DialogButton(title: String(localized: "labelEditor.delete", locale: locale),
                                  role: .destructive) {
                onConfirm()
                dismiss()
            },
            cancel: DialogButton(title: String(localized: "common.cancel", locale: locale),
                                 role: .cancel) { dismiss() }
        ) {
            VStack(alignment: .leading, spacing: Tokens.spacing.s) {
                Text(labels.count == 1
                     ? String(format: String(localized: "labelEditor.deleteOne", locale: locale),
                              labels[0].name)
                     : String(format: String(localized: "labelEditor.deleteMany", locale: locale),
                              labels.count))
                    .fixedSize(horizontal: false, vertical: true)

                if affected > 0 {
                    Text(String(format: String(localized: "labelEditor.deleteAffects",
                                               locale: locale), affected))
                        .foregroundStyle(Color("DangerText"))
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("labelEditor.deleteAffectsNone")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text("labelEditor.deleteUndoable")
                    .font(.system(size: Tokens.fontSize.caption))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// 統合の確認 [LB-07][LE-11]。
struct MergeLabelsDialog: View {
    @Environment(\.locale) private var locale
    @Environment(\.dialogDismiss) private var dismiss

    let source: LabelSummary
    let target: LabelSummary
    let onConfirm: () -> Void

    var body: some View {
        DialogScaffold(
            width: 440,
            confirm: DialogButton(title: String(localized: "labelEditor.merge", locale: locale)) {
                onConfirm()
                dismiss()
            },
            cancel: DialogButton(title: String(localized: "common.cancel", locale: locale),
                                 role: .cancel) { dismiss() }
        ) {
            VStack(alignment: .leading, spacing: Tokens.spacing.s) {
                Text(String(format: String(localized: "labelEditor.mergeBody", locale: locale),
                            source.name, target.name))
                    .fixedSize(horizontal: false, vertical: true)
                Text(String(format: String(localized: "labelEditor.mergeCounts", locale: locale),
                            source.fileCount, target.fileCount))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("labelEditor.mergeUndoable")
                    .font(.system(size: Tokens.fontSize.caption))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
