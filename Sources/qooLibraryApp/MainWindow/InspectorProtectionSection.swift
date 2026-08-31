//
//  右ペインの「保護」節 [PR-05]。
//
import QooApplication
import QooKit
import SwiftUI

/// ファイル全体の保護をワンクリックで切り替える [PR-05]。
///
/// **スコープごとの操作はここに置かない。** 基本情報はタイトル節、フィールドは
/// ラベルの付け外し [PR-03] が担う——同じ操作に独立した経路を 2 つ作らない。
struct InspectorProtectionSection: View {
    let model: ProtectionEditorModel

    @Environment(\.locale) private var locale

    var body: some View {
        switch model.state {
        case .notApplicable, .notInLibrary:
            // ライブラリ経由で開いていない／DB に行が無い。**枠ごと出さない**
            // [LF-01 と同じ判断]。
            EmptyView()
        case .loading:
            EmptyView()
        case .failed(let reason):
            section {
                Text(reason)
                    .font(.system(size: Tokens.fontSize.caption))
                    .foregroundStyle(Tokens.Colors.dangerText)
                    .lineLimit(3)
            }
        case .ready(let subject):
            section { row(subject) }
        }
    }

    private func section(@ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: Tokens.spacing.xs) {
            Divider()
            Text("inspector.protection.header")
                .font(.system(size: Tokens.fontSize.caption))
                .foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ subject: ProtectionEditorModel.Subject) -> some View {
        VStack(alignment: .leading, spacing: Tokens.spacing.xs) {
            HStack(spacing: Tokens.spacing.xs) {
                // **三状態が要る**（複数選択で一部だけ保護されている）ので
                // `Toggle` ではなく AppKit のチェックボックスを使う [RP-02 と同じ]。
                MixedStateCheckbox(state: Self.checkboxState(subject.checkState)) {
                    Task { await toggle() }
                }
                Text("inspector.protection.all")
                    .font(.system(size: Tokens.fontSize.caption))
                Spacer(minLength: 0)
            }
            // **解除が何をするかを先に言う** [PR-04]。確認は出さない
            //［ユーザー判断］ので、押す前に読める場所に置いておく。
            Text(subject.isFullyProtected
                 ? "inspector.protection.explainProtected"
                 : "inspector.protection.explainUnprotected")
                .font(.system(size: Tokens.fontSize.caption))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private static func checkboxState(
        _ state: LabelEditorModel.CheckState
    ) -> MixedStateCheckbox.State {
        switch state {
        case .none: .off
        case .some: .mixed
        case .all: .on
        }
    }

    private func toggle() async {
        do {
            try await model.toggleAll()
        } catch {
            await NotificationRouter.shared.presentError(
                error, whatHappened: String(localized: "error.setProtectionFailed",
                                            locale: locale))
        }
    }
}
