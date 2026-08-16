import SwiftUI

/// 圧縮時のパスワード設定・展開時のパスワード入力を兼ねる共通ダイアログ
/// [環境設定「圧縮／展開」タブ]。**パスワード自体は `UserDefaults` に一切
/// 保存しない**（`CompressionOptions` のコメント参照）— 圧縮・展開のたびに
/// ここで都度入力させる設計。
///
/// Finder はパスワード系だけはシート（`CompressionPasswordSheet` 等）だが、
/// 入力ダイアログの見た目を揃える方を優先して独立したウインドウにしている
/// ［ユーザー判断、`DialogWindowPresenter` 参照］。
enum ArchivePasswordDialogMode {
    /// 圧縮時、新しいパスワードを設定する。入力ミス防止のため確認欄を出す。
    case setPassword
    /// 展開時、既存のアーカイブのパスワードを尋ねる。`retryErrorMessage` が
    /// 非 `nil` なら「誤ったパスワードです」等を表示する（再入力を促す）。
    case unlock(retryErrorMessage: String?)
}

struct ArchivePasswordDialog: View {
    @Environment(\.locale) private var locale
    @Environment(\.dialogDismiss) private var dismiss
    let mode: ArchivePasswordDialogMode
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
        DialogScaffold(
            width: 320,
            confirm: DialogButton(title: String(localized: "common.ok", locale: locale)) {
                // 先に閉じてから返す（`NameInputDialog.commit()` と同じ順序）。
                let value = password
                dismiss()
                onSubmit(value)
            },
            cancel: DialogButton(
                title: String(localized: "common.cancel", locale: locale), role: .cancel
            ) { dismiss() },
            confirmDisabled: !canSubmit
        ) {
            if case .unlock(let retryErrorMessage) = mode, let retryErrorMessage {
                Text(retryErrorMessage)
                    .font(.system(size: Tokens.fontSize.caption))
                    .foregroundStyle(.red)
            }

            SecureField("archivePassword.passwordField", text: $password)
                .editableFieldChrome()
                .focused($isPasswordFieldFocused)
            if isSetMode {
                SecureField("archivePassword.confirmField", text: $confirmPassword)
                    .editableFieldChrome()
                if !confirmPassword.isEmpty && password != confirmPassword {
                    Text("archivePassword.mismatch")
                        .font(.system(size: Tokens.fontSize.caption))
                        .foregroundStyle(.red)
                }
            }
        }
        .onAppear { isPasswordFieldFocused = true }
    }
}
