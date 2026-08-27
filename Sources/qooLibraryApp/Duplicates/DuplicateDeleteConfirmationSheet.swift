//
//  重複の削除の確認 [DU-24][DU-27][PD-05]。
//
//  **この確認だけが「取り消せるかどうか」を利用者に伝える場所。**
//  `CompositeCommand.isUndoable` は子の `allSatisfy` なので、ゴミ箱を使えない
//  場所では自動的に取り消せなくなる——文言がそれに追随していないと、
//  **いちばん取り返しのつかない場面で嘘をつく**（`FileVaultModel` の
//  `makeDeleteCommand` に同じ注意がある）。
//
import QooApplication
import QooKit
import SwiftUI

struct DuplicateDeleteConfirmationSheet: View {
    @Environment(\.locale) private var locale
    let plan: DuplicateDeletePlan
    @Binding var inheritMetadata: Bool
    let onConfirm: @MainActor @Sendable () -> Void
    let onCancel: @MainActor @Sendable () -> Void

    var body: some View {
        DialogScaffold(
            width: 460,
            confirm: DialogButton(
                title: String(localized: "duplicates.confirmButton", locale: locale),
                role: .destructive, action: onConfirm),
            cancel: DialogButton(
                title: String(localized: "common.cancel", locale: locale),
                role: .cancel, action: onCancel)
        ) {
            VStack(alignment: .leading, spacing: Tokens.spacing.m) {
                Text(String(format: String(localized: "duplicates.confirmBody", locale: locale),
                            plan.doomed.count,
                            DuplicateResolutionModel.subjectName(plan.keeper)))
                    .fixedSize(horizontal: false, vertical: true)

                // 捨てる側の一覧。**件数だけでは何が消えるか分からない。**
                // 高さは抑える——固定サイズのウインドウで可変高さの領域を
                // 2 つ持つと、片方が伸びたときにもう片方が黙って潰れる
                // （有効化ウインドウで 3 度直している形）。
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(plan.doomed) { row in
                            Text(row.file.filename)
                                .font(.system(size: Tokens.fontSize.caption))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 96)

                // [DU-27] 失われるものがあるときだけ出す。**無いときに
                // 出すと、押しても何も起きない選択肢を見せることになる。**
                if plan.loss.hasAnythingToInherit {
                    Toggle(isOn: $inheritMetadata) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("duplicates.inheritMetadata")
                            Text(inheritanceSummary)
                                .font(.system(size: Tokens.fontSize.caption))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                // [DU-24][PD-05] ゴミ箱か完全削除か。**取り消せないなら必ず言う。**
                Label {
                    Text(plan.usesTrash ? "duplicates.movesToTrash"
                                        : "duplicates.deletesPermanently")
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: plan.usesTrash ? "trash" : "exclamationmark.triangle.fill")
                        .foregroundStyle(plan.usesTrash ? Color.secondary : Color.orange)
                }
                .font(.system(size: Tokens.fontSize.caption))
            }
        }
    }

    /// 何が引き継がれるかを具体的に書く——「メタデータ」だけでは伝わらない。
    private var inheritanceSummary: String {
        var parts: [String] = []
        if !plan.loss.labelsOnlyOnDoomed.isEmpty {
            let names = plan.loss.labelsOnlyOnDoomed.values
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            parts.append(names.joined(separator: " · "))
        }
        if plan.loss.keeperRating == 0, plan.loss.bestDoomedRating > 0 {
            parts.append(String(repeating: "★", count: plan.loss.bestDoomedRating))
        }
        return parts.joined(separator: " / ")
    }
}
