//
//  「見つからないファイル」の記録を削除する確認 [OR-04][15章 §15.7]。
//
//  **削除は ⌘Z で戻せるが、確認は挟む**——覚えていたラベルがまとめて外れる
//  操作である。何を失うか（延べ件数）と、**実ファイルには触れない**ことの
//  両方を出す（「削除」という語だけだと、まだ残っている実体まで消すと読める）。
//
import QooApplication
import QooKit
import SwiftUI

/// 削除の確認 [OR-04]。
struct DeleteOrphansDialog: View {
    @Environment(\.locale) private var locale
    @Environment(\.dialogDismiss) private var dismiss

    let files: [OrphanedFile]
    let onConfirm: () -> Void

    /// 覚えていたラベルの延べ件数。**これを出すのが要点**——0 件なら気軽に
    /// 消せるし、多ければ手が止まる（`DeleteLabelsDialog` と同じ）。
    private var affected: Int { files.reduce(0) { $0 + $1.labelCount } }

    var body: some View {
        DialogScaffold(
            width: 460,
            confirm: DialogButton(title: String(localized: "orphanCleanup.delete", locale: locale),
                                  role: .destructive) {
                onConfirm()
                dismiss()
            },
            cancel: DialogButton(title: String(localized: "common.cancel", locale: locale),
                                 role: .cancel) { dismiss() }
        ) {
            VStack(alignment: .leading, spacing: Tokens.spacing.s) {
                Text(files.count == 1
                     ? String(format: String(localized: "orphanCleanup.deleteOne", locale: locale),
                              files[0].row.filename)
                     : String(format: String(localized: "orphanCleanup.deleteMany", locale: locale),
                              files.count))
                    .fixedSize(horizontal: false, vertical: true)

                if affected > 0 {
                    Text(String(format: String(localized: "orphanCleanup.deleteAffects",
                                               locale: locale), affected))
                        .foregroundStyle(Color("DangerText"))
                        .fixedSize(horizontal: false, vertical: true)
                }
                // **実ファイルは消えない**ことを明示する——「削除」という語だけ
                // だと、まだ残っている実体まで消すと読める。
                Text("orphanCleanup.deleteRecordOnly")
                    .font(.system(size: Tokens.fontSize.caption))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("labelEditor.deleteUndoable")
                    .font(.system(size: Tokens.fontSize.caption))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
