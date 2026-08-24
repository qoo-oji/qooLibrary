import AppKit

/// 入力欄にフォーカスがあるときは、編集の標準キーをそちらへ渡す［ユーザー指定］。
///
/// ## なぜ要るのか
/// qooLibrary は ⌘A / ⌘C / ⌘V / ⌘X を **Edit メニュー項目の
/// `.fixedKeyboardShortcut`** で配線している。**メニューのキー等価は、
/// ウインドウのレスポンダチェーンより先に評価される**ので、テキストを打っている
/// 最中でもファイル側の操作が走ってしまう——⌘A は「すべてのファイルを選択」、
/// **⌘V に至っては「クリップボードのファイルをフォルダへ貼り付ける」**。
/// 打鍵の途中で実ファイルが増える形なので、単なる使い勝手の話では済まない。
///
/// AppKit の標準の Edit メニューはこうならない。`selectAll:` などを
/// **target = nil** で送り、レスポンダチェーンの先頭（編集中ならフィールド
/// エディタ）に処理させるからである。SwiftUI の `Button` はクロージャを直接
/// 呼ぶのでその調停が無い——だから**アクションの入口で 1 度だけ肩代わりする。**
///
/// ## 効かせる範囲
/// **テキスト側に同じ意味の操作があるものだけ**（⌘A / ⌘C / ⌘V / ⌘X）。
/// `⌥⌘C`（パス名をコピー）・`⌥⌘V`（項目を移動）・`⌥⌘A`（選択解除）は
/// テキストに対応する操作が無いので触らない。
///
/// ## メニュー項目が無効なときは何もしなくてよい
/// `.disabled(...)` の項目はキー等価を消費しないので、そのままウインドウへ
/// 落ちてフィールドエディタが処理する。**壊れるのは「項目が有効かつ入力中」の
/// ときだけ**で、この関門はそこだけを見ている。
@MainActor
enum TextEditingKeyRouting {

    /// 編集中のテキストへ流せたら `true`。呼び出し側はそこで打ち切る。
    ///
    /// 判定は**フィールドエディタが第一応答者か**で行う。SwiftUI の `TextField`
    /// も `NSSearchField` も、編集中はウインドウのフィールドエディタ
    /// （`NSTextView`）が第一応答者になる（`InlineRenameSupport` が同じ判定で
    /// 選択範囲を操作しており、実機で確認済みの前提）。
    static func forwardToFieldEditor(_ selector: Selector) -> Bool {
        guard let editor = NSApp.keyWindow?.firstResponder as? NSText,
              editor.responds(to: selector) else { return false }
        NSApp.sendAction(selector, to: editor, from: nil)
        return true
    }

    /// 「すべてを選択」[KB-01]。
    static func handledSelectAll() -> Bool {
        forwardToFieldEditor(#selector(NSText.selectAll(_:)))
    }

    /// 「コピー」。
    static func handledCopy() -> Bool {
        forwardToFieldEditor(#selector(NSText.copy(_:)))
    }

    /// 「ペースト」。**これを取りこぼすと、打鍵の途中で実ファイルが増える。**
    static func handledPaste() -> Bool {
        forwardToFieldEditor(#selector(NSText.paste(_:)))
    }

    /// 「カット」。
    static func handledCut() -> Bool {
        forwardToFieldEditor(#selector(NSText.cut(_:)))
    }
}
