//
//  右ペインの保管庫 [FA-01][FA-07][DT-11]。
//
//  判定は `VaultEditorModel`（`QooApplication`）が持つ。この View は描くだけ
//  ——`InspectorRatingSection` と同じ分け方で、そうしないと「オフラインでは
//  押せない」「保管庫の中なら戻す側を出す」を自動テストで固定できない。
//
import QooApplication
import QooKit
import SwiftUI

struct InspectorVaultSection: View {
    let model: VaultEditorModel

    @Environment(\.locale) private var locale

    var body: some View {
        switch model.state {
        case .notApplicable, .notInLibrary, .loading:
            // **枠ごと出さない。** 評価 [RA-01] は「星を付けられない理由」を
            // 出す価値があるが、保管庫は蔵書だけの機能で、ここから取り込ませる
            // 操作が無い——理由を書いても次の手が示せない。
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
                if subject.isArchived {
                    // [DT-11] 保管庫にあることと、元の場所を出す [FA-04]。
                    Text("inspector.vault.inVault")
                        .font(.system(size: Tokens.fontSize.caption))
                        .foregroundStyle(.secondary)
                    if let from = subject.archivedFromPath {
                        LabeledContent("inspector.vault.originalLocation") {
                            Text(from)
                                .font(.system(size: Tokens.fontSize.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .lineLimit(3)
                        }
                    }
                }
                Button(subject.isArchived ? "folder.restoreFromVault" : "folder.moveToVault",
                       systemImage: subject.isArchived ? "arrow.up.bin" : "archivebox") {
                    move(archived: subject.isArchived)
                }
                .buttonStyle(.link)
                // **オフラインでは押せない。** 実ファイルを `.qooarchive` へ
                // 動かす操作なので、ボリュームが要る。
                .disabled(!subject.isOnline)
                if !subject.isOnline {
                    Text("inspector.vault.offline")
                        .font(.system(size: Tokens.fontSize.caption))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// **失敗を握り潰さない** [ER-01]［レビューで発見: `try?` で捨てていた］。
    /// 実ファイルを動かす操作なので、ボリュームが `isOnline` の確認のあとで
    /// 抜かれた・書き込めない・容量が足りない、はどれも実際に起こる
    /// ——何も言わずにボタンが効かないように見えるのが最悪の壊れ方になる。
    /// 提示は評価・ラベルと同じ `NotificationRouter` 経由 [ER-01]。
    private func move(archived: Bool) {
        Task {
            do {
                try await model.toggleArchived()
            } catch {
                guard !CommandStack.isCancellation(error) else { return }
                await NotificationRouter.shared.presentError(
                    error,
                    whatHappened: String(localized: archived
                                         ? "error.vaultRestoreFailed"
                                         : "error.vaultArchiveFailed", locale: locale))
            }
        }
    }

    @ViewBuilder
    private func section(@ViewBuilder _ content: () -> some View) -> some View {
        Divider()
        VStack(alignment: .leading, spacing: Tokens.spacing.xs) {
            Text("inspector.vault")
                .font(.system(size: Tokens.fontSize.caption))
                .foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
