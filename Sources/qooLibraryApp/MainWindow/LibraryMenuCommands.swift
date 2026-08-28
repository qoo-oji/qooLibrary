//
//  メニューバー「ライブラリ」[ユーザー指示、19章 §19.6]。
//
//  **ライブラリに関する操作の置き場。** 今はウィザードでの登録と、表示中の
//  ライブラリの設定だけを置く。今後の実装（Stage 3 以降）でメンテナンス・
//  フィールド編集などの入口をここへ足していく——右クリックメニューを
//  最小に保つ [ユーザー指示] ぶん、網羅的な入口はこちらが担う。
//
//  状態は `@FocusedValue(\.windowMenuActions)` から読む（File/Edit/表示/移動
//  メニューと同じ仕組み）。ウインドウが無い・ライブラリの外にいるときは
//  対象を要する項目が無効になる。
//
import QooApplication
import SwiftUI

struct LibraryMenuCommands: View {
    @FocusedValue(\.windowMenuActions) private var actions
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        // 登録＝ライブラリ化のウィザード [RG3-20]。フォルダツリーの「＋」と
        // 同じ経路（`LibraryRegistrationWizard.begin` の 2 つ目の入口）。
        Button("libraryMenu.registerEllipsis", systemImage: "plus") {
            LibraryRegistrationWizard.begin(locale: AppLanguage.effectiveLocale,
                                            openWindow: openWindow)
        }
        Divider()
        // 表示中のライブラリの設定 [LS-01]。開く手順はフォルダツリーの
        // 右クリックと同じ（受け皿 → `openWindow`、`PreferencesNavigation` と同型）。
        Button("libraryMenu.settingsEllipsis", systemImage: "gearshape") {
            guard let library = actions?.currentLibrary else { return }
            LibrarySettingsNavigation.shared.pendingLibraryID = library.id
            openWindow(id: "librarySettings")
        }
        .disabled(actions?.currentLibrary == nil)
        // 表示中のライブラリのラベル編集 [RL3-04][§19.6: Stage 3 以降の入口は
        // ここへ足す]。開く手順は左ペイン・右ペインと同じ受け皿
        // （`LabelEditorNavigation`）を通す。
        Button("labelEditor.editLabelsEllipsis", systemImage: "tag") {
            guard let library = actions?.currentLibrary else { return }
            LabelEditorNavigation.open(libraryID: library.id, openWindow: openWindow)
        }
        .disabled(actions?.currentLibrary == nil)
    }
}
