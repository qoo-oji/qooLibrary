import QooApplication
import QooInfrastructure
import QooKit
import QooPersistence
import SwiftUI

/// アプリのエントリポイント。
///
/// `WindowGroup` は新規ウインドウ（⌘N）のたびに新しい `MainWindowView`
/// インスタンス（＝新しい `WindowState`）を作る。永続状態（DB）とセッション
/// 一時状態（`SessionState`）はまだフェーズ 1 の対象外の型に依存する部分
/// （ラベル・Undo 等）を除き、器だけをこの段階で用意している
/// [11章 §11.4 状態の 3 分類]。
@main
struct QooLibraryApp: App {
    init() {
        // 異常終了後に残ったステージングディレクトリを削除する
        // [RB-07][EX-03]。`Scene` は `.task` を持てないため `init()` から
        // 起動時に一度だけ実行する。
        Task {
            await SecureExtractor.cleanupResidualStaging()
        }
    }

    var body: some Scene {
        // `for: URL.self` にすることで、右クリックの「新規ウインドウで開く」から
        // `openWindow(value: url)` で特定のフォルダを初期表示にした新規ウインドウを
        // 開ける（⌘N・Dock アイコンからの起動など、値を指定しない経路は
        // 引き続き `nil` → 既定の仮想ホームになる）。
        WindowGroup(for: URL.self) { $initialFolder in
            MainWindowView(initialFolder: initialFolder)
        }
        .commands {
            CommandGroup(replacing: .appInfo) {
                AboutMenuButton()
            }
        }

        Window("qooLibrary について", id: "about") {
            AboutView()
        }
        .windowResizability(.contentSize)
    }
}

private struct AboutMenuButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("qooLibrary について") {
            openWindow(id: "about")
        }
    }
}
