//
//  保管庫のファイルを削除する確認 [FAW-03]。
//
//  `DeleteLabelsDialog` と同じ形——**何が失われるかを数えてから決めさせる。**
//  ここで見せるのは 2 つ: 外れるラベルの件数と、**実ファイルがゴミ箱へ行く**
//  こと［ユーザー判断］。
//
//  「記録だけ消す」（§15.7 の孤立一覧と同じ形）を採らなかったのは、
//  `.qooarchive` が走査の対象 [SY-10] だから——記録だけ消すと**次の走査で
//  必ず復活し、しかもラベルを失った状態で戻ってくる。**
//
import QooApplication
import QooKit
import SwiftUI

struct DeleteVaultFilesDialog: View {
    @Environment(\.locale) private var locale
    @Environment(\.dialogDismiss) private var dismiss

    let files: [ArchivedFile]
    let onConfirm: () -> Void

    /// 紐づけが外れるファイルの延べ件数。
    private var affectedLabels: Int { files.reduce(0) { $0 + $1.labelCount } }

    var body: some View {
        DialogScaffold(
            width: 460,
            confirm: DialogButton(title: String(localized: "labelEditor.delete", locale: locale),
                                  role: .destructive) {
                onConfirm()
                dismiss()
            },
            cancel: DialogButton(title: String(localized: "common.cancel", locale: locale),
                                 role: .cancel) { dismiss() }
        ) {
            VStack(alignment: .leading, spacing: Tokens.spacing.s) {
                Text(files.count == 1
                     ? String(format: String(localized: "fileVault.deleteOne", locale: locale),
                              files[0].row.filename)
                     : String(format: String(localized: "fileVault.deleteMany", locale: locale),
                              files.count))
                    .fixedSize(horizontal: false, vertical: true)

                Text("fileVault.deleteMovesToTrash")
                    .foregroundStyle(Color("DangerText"))
                    .fixedSize(horizontal: false, vertical: true)

                if affectedLabels > 0 {
                    Text(String(format: String(localized: "fileVault.deleteAffectsLabels",
                                               locale: locale), affectedLabels))
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
