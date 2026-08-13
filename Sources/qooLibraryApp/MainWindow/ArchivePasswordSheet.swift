import SwiftUI

/// 圧縮時のパスワード設定・展開時のパスワード入力を兼ねる共通シート
/// [環境設定「圧縮／展開」タブ]。**パスワード自体は `UserDefaults` に一切
/// 保存しない**（`CompressionOptions` のコメント参照）— 圧縮・展開のたびに
/// このシートで都度入力させる設計。
enum ArchivePasswordSheetMode {
    /// 圧縮時、新しいパスワードを設定する。入力ミス防止のため確認欄を出す。
    case setPassword
    /// 展開時、既存のアーカイブのパスワードを尋ねる。`retryErrorMessage` が
    /// 非 `nil` なら「誤ったパスワードです」等を表示する（再入力を促す）。
    case unlock(retryErrorMessage: String?)
}

struct ArchivePasswordSheet: View {
    @Environment(\.locale) private var locale
    @Environment(\.dismiss) private var dismiss
    let mode: ArchivePasswordSheetMode
    let onSubmit: (String) -> Void

    @State private var password = ""
    @State private var confirmPassword = ""
    @FocusState private var isPasswordFieldFocused: Bool

    private var isSetMode: Bool {
        if case .setPassword = mode { return true }
        return false
    }

    private var canSubmit: Bool {
        guard !password.isEmpty else { return false }
        return isSetMode ? password == confirmPassword : true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.spacing.m) {
            Text(isSetMode ? "archivePassword.setTitle" : "archivePassword.unlockTitle")
                .font(.system(size: Tokens.fontSize.title2, weight: .semibold))

            if case .unlock(let retryErrorMessage) = mode, let retryErrorMessage {
                Text(retryErrorMessage)
                    .font(.system(size: Tokens.fontSize.caption))
                    .foregroundStyle(.red)
            }

            SecureField("archivePassword.passwordField", text: $password)
                .textFieldStyle(.roundedBorder)
                .focused($isPasswordFieldFocused)
            if isSetMode {
                SecureField("archivePassword.confirmField", text: $confirmPassword)
                    .textFieldStyle(.roundedBorder)
                if !confirmPassword.isEmpty && password != confirmPassword {
                    Text("archivePassword.mismatch")
                        .font(.system(size: Tokens.fontSize.caption))
                        .foregroundStyle(.red)
                }
            }

            QooDialogFooter(
                confirm: DialogButton(title: String(localized: "common.ok", locale: locale)) {
                    onSubmit(password)
                    dismiss()
                },
                cancel: DialogButton(title: String(localized: "common.cancel", locale: locale), role: .cancel) { dismiss() },
                confirmDisabled: !canSubmit
            )
        }
        .padding(Tokens.spacing.l)
        .frame(width: 320)
        .task { isPasswordFieldFocused = true }
    }
}
