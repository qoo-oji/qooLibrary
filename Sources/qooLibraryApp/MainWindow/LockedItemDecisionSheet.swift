import QooInfrastructure
import SwiftUI

/// ロック済み項目に遭遇したときの判断を求めるシート [PD-06][ER-11][FM-18]。
///
/// ER-11 は「都度尋ねる対象は、ユーザーの選択によって結果が変わるものに
/// 限る」と定めており、完全削除でこれに該当するのがロック済み項目。
/// Finder も同じくロックされた項目だけを個別に確認する。
///
/// **「以降すべてに適用」を必ず設ける** [ER-11]。判断は 1 回の完全削除操作の
/// 間だけ引き継がれる（`FolderOperations.lockedItemBlanketDecision`）。
struct LockedItemDecisionSheet: View {
    @Environment(\.locale) private var locale
    @Environment(\.dismiss) private var dismiss

    let request: PendingLockedItem

    @State private var applyToAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.spacing.m) {
            HStack(alignment: .top, spacing: Tokens.spacing.s) {
                Image(systemName: "lock.fill")
                    .font(.system(size: Tokens.fontSize.title2))
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: Tokens.spacing.xs) {
                    Text(String(
                        format: String(localized: "permanentDelete.lockedTitle", locale: locale),
                        request.url.lastPathComponent
                    ))
                    .font(.system(size: Tokens.fontSize.title2, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    Text("permanentDelete.lockedBody")
                        .font(.system(size: Tokens.fontSize.caption))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Toggle("permanentDelete.applyToAll", isOn: $applyToAll) // [ER-11]

            QooDialogFooter(
                confirm: DialogButton(
                    title: String(localized: "permanentDelete.deleteAnyway", locale: locale),
                    role: .destructive
                ) {
                    request.resolve(.delete, applyToAll: applyToAll)
                    dismiss()
                },
                cancel: DialogButton(title: String(localized: "permanentDelete.skipItem", locale: locale)) {
                    request.resolve(.skip, applyToAll: applyToAll)
                    dismiss()
                }
            )
        }
        .padding(Tokens.spacing.l)
        .frame(width: 400)
        // 「表示されないまま終わった」場合の保険を無効化する印
        // [`PendingLockedItem.didAppear` 参照]。
        .onAppear { request.didAppear = true }
        // **安全網**: Esc やウインドウ外クリックでシートが閉じられ、どちらの
        // ボタンのコールバックも呼ばれないまま終わると、削除処理側で待って
        // いる `CheckedContinuation` が永久に返らずアプリが固まる。
        // `PendingLockedItem.resolve` は一度きりしか通らないため、ボタンで
        // 既に解決済みならこれは何もしない。
        .onDisappear { request.resolve(.skip, applyToAll: false) }
    }
}
