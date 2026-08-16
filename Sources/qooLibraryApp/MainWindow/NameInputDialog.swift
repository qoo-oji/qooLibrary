import SwiftUI

/// 「名前を 1 つ入力して決定する」ダイアログ。
///
/// 新規フォルダ [FM-01]・実フォルダ名の変更 [FM-05]・登録フォルダの表示名の
/// 変更 [RG-05] は、見出しと決定ボタンの文言が違うだけで中身は同じなので
/// 1 つにまとめている。以前は中央ペイン側とフォルダツリー側にそれぞれ別の
/// `.alert` があり、同じものが 2 か所で別々に書かれていた。
///
/// Finder の `NewFolderWindow` に相当する独立したウインドウとして出す
/// （`DialogWindowPresenter` 参照）。中央ペインでのファイル名変更は
/// 従来どおり Finder 流のインライン編集で、こちらは通らない。
struct NameInputDialog: View {
    @Environment(\.locale) private var locale
    @Environment(\.dialogDismiss) private var dismiss

    let placeholder: String
    let confirmTitle: String
    /// 前後の空白を除いた名前が渡る。空文字では呼ばれない。
    let onCommit: (String) -> Void

    @State private var name: String
    @FocusState private var isFieldFocused: Bool

    init(
        placeholder: String,
        confirmTitle: String,
        initialName: String,
        onCommit: @escaping (String) -> Void
    ) {
        self.placeholder = placeholder
        self.confirmTitle = confirmTitle
        self.onCommit = onCommit
        _name = State(initialValue: initialName)
    }

    /// 空白だけの名前は作らせない。`/` と `.`・`..` の扱いなど実際に使える
    /// 名前かどうかの判定は `FileOperationService` 側が行い、駄目なら
    /// 理由付きのエラーになる [ER-03] ため、ここでは先回りして弾かない
    /// （macOS のファイル名は `/` と NUL 以外を許すので、ここで独自の
    /// 禁止文字を増やすと実際には作れる名前を拒むことになる）。
    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        DialogScaffold(
            width: 360,
            confirm: DialogButton(title: confirmTitle) { commit() },
            cancel: DialogButton(
                title: String(localized: "common.cancel", locale: locale), role: .cancel
            ) { dismiss() },
            confirmDisabled: trimmedName.isEmpty
        ) {
            TextField(placeholder, text: $name)
                .editableFieldChrome()
                .focused($isFieldFocused)
        }
        // 開いたらすぐ打ち始められるようにする。**アプリが前面にあることが
        // 前提** — 非アクティブだとフォーカスは移らない [実測]。
        .onAppear { isFieldFocused = true }
    }

    private func commit() {
        let value = trimmedName
        guard !value.isEmpty else { return }
        // 先に閉じてから実行する。`onCommit` の中身はいずれも `Task` を
        // 起こすだけで即座に返るため、モーダルループを抜ける妨げにならない。
        dismiss()
        onCommit(value)
    }
}
