import SwiftUI

/// 一覧と、その項目を増減するボタンを 1 つの枠にまとめる [UI-01][CP-01]。
///
/// ［ユーザー指摘: 追加ボタンと削除ボタンがスクロール範囲に含まれているのは
/// おかしい］素直に `VStack { List; HStack { 追加; 削除 } }` と並べると、
/// **外側のスクロールでボタンが一覧から離れて流れていく**——どの一覧に対する
/// ボタンなのかも、押せる場所がどこなのかも分からなくなる。
///
/// macOS のシステム設定（「ログイン項目」等）と同じく、**一覧の枠に接した
/// 下端のバー**に置く。枠ごと 1 つの部品なので、外側がスクロールしても
/// 一覧とボタンの関係は崩れない。
///
/// - Note: 高さは呼び出し側が決める。**内容にあわせて伸びる造りにしない**
///   ——項目が増えるほど下の編集欄が押し出され、`ScrollView` の外へ出て
///   「編集する手段が見当たらない」状態になる（実機でそうなった）。
struct EditableListChrome<Content: View, Buttons: View>: View {
    var height: CGFloat = 150
    @ViewBuilder let content: Content
    @ViewBuilder let buttons: Buttons

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(height: height)
                .scrollContentBackground(.hidden)
            Divider()
            HStack(spacing: Tokens.spacing.xs) {
                buttons
                Spacer(minLength: 0)
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, Tokens.spacing.xs)
            .padding(.vertical, 4)
        }
        .background(
            RoundedRectangle(cornerRadius: Tokens.radius.m, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Tokens.radius.m, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor))
        )
        .clipShape(RoundedRectangle(cornerRadius: Tokens.radius.m, style: .continuous))
    }
}

/// 一覧の下端バーに置く「＋」「−」[CP-01]。
///
/// 文字のボタンではなく記号にする——macOS の一覧はどれもこの形で、
/// 幅を取らないぶん一覧そのものを広く使える。何をするボタンかは
/// ツールチップで補う。
struct ListEditButton: View {
    enum Kind { case add, remove }
    let kind: Kind
    let help: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: kind == .add ? "plus" : "minus")
                .frame(width: 20, height: 16)
                .contentShape(Rectangle())
        }
        .help(Text(help))
    }
}
