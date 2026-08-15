import SwiftUI

/// 入力欄に「ここは入力できる場所だ」と分かる見た目を与える [UI-01][CP-01]。
///
/// ［ユーザー指摘: ダークモードだと、どこが入力可能な欄なのか分からない］
/// SwiftUI の既定（プレーン）はもちろん、`.roundedBorder` でも暗い背景では
/// **細い枠線が見えるだけ**で、フォーカスするまで欄だと気づけない
/// （実機で比べて確認した）。入力欄だと分かるのは枠ではなく**地の色**なので、
/// `NSColor.textBackgroundColor` を敷く — macOS のシステム設定や Finder の
/// 入力欄と同じ色で、ライト／ダークの切り替えにも自動で追随する。
///
/// フォーカスの表示は SwiftUI（AppKit）に任せる。この見た目は「入力欄が
/// そこにある」ことだけを伝える。
struct EditableFieldChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .padding(.horizontal, Tokens.spacing.s)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: Tokens.radius.m, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Tokens.radius.m, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor))
            )
    }
}

extension View {
    /// 入力欄の見た目。**ダイアログ・シート・環境設定の `TextField` は
    /// これを使う**（個々の画面で `.textFieldStyle` を選ばない）。
    func editableFieldChrome() -> some View {
        modifier(EditableFieldChrome())
    }
}
