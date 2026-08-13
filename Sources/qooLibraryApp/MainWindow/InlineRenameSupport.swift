import AppKit

/// インライン名前編集（リスト表示・アイコン表示で共通）の補助。
/// `FolderContentView.swift`（リスト表示のセル）と `IconGridView.swift`
/// （アイコン表示のセル）の両方から使うため、小さいながらも共有ヘルパーとして
/// 独立させている。
enum InlineRenameSupport {
    /// Finder 流: リネーム開始時、拡張子を除いたファイル名部分だけを選択状態に
    /// する（すぐに拡張子以外を上書き入力できるようにするため）。フォルダ・
    /// 拡張子の無いファイルは全体を選択したままにする。
    ///
    /// [ユーザーからの要望を記録: 「拡張子を含めて選択」に切り替えられる環境
    /// 設定を将来（1-12）用意したい。現状はこの Finder 流の既定動作のみ実装
    /// しており、切り替え UI 自体はまだ無い]
    ///
    /// SwiftUI の `TextField` はフィールドエディタへの選択範囲操作を直接
    /// 公開していないため、AppKit のフィールドエディタ（`NSText`）へ直接
    /// アクセスする。`TextField` が実際にフォーカスを得てフィールドエディタが
    /// 割り当てられた**後**でないと機能しないため、呼び出し側は
    /// `.onAppear`/フォーカス設定の直後に `DispatchQueue.main.async` で
    /// 1 サイクル遅らせて呼ぶ必要がある。
    static func selectBaseNameIfApplicable(for entry: FolderEntry) {
        guard !entry.isDirectory else { return }
        let ext = (entry.name as NSString).pathExtension
        guard !ext.isEmpty else { return }
        let baseLength = entry.name.utf16.count - ext.utf16.count - 1 // 拡張子 + "."
        guard baseLength > 0 else { return }
        guard let fieldEditor = NSApp.keyWindow?.firstResponder as? NSText else { return }
        fieldEditor.selectedRange = NSRange(location: 0, length: baseLength)
    }
}
