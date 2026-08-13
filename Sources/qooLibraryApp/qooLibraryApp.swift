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
        // 登録済みライブラリ／テンポラリフォルダを読み込み、Security-Scoped
        // Bookmark へのアクセスをアプリ終了まで開始したままにする [1-13、
        // `RegisteredFolderStore.loadAndActivateAll()` のコメント参照]。
        Task {
            await RegisteredFolderStore.shared.loadAndActivateAll()
        }
        // [ER-01] エラー・通知の提示はこのコントローラ1箇所からのみ行う
        // （`NotificationRouterPresenterController` のコメント参照）。
        NotificationRouterPresenterController.shared.start()
    }

    var body: some Scene {
        // `for: URL.self` にすることで、右クリックの「新規ウインドウで開く」から
        // `openWindow(value: url)` で特定のフォルダを初期表示にした新規ウインドウを
        // 開ける（⌘N・Dock アイコンからの起動など、値を指定しない経路は
        // 引き続き `nil` → 既定の仮想ホームになる）。
        WindowGroup(for: URL.self) { $initialFolder in
            MainWindowView(initialFolder: initialFolder)
        }
        .windowResizability(.automatic)
        .defaultSize(width: 900, height: 560)
        // ゾンビウインドウ対策 [設計判断、qooViewer（姉妹プロジェクト）の実機
        // バグ報告を踏まえた予防的対応]。SwiftUI の `WindowGroup` 標準の状態
        // 復元（ウインドウが無い状態から再アクティブ化されたとき等に前回の
        // ウインドウを復元しようとする仕組み）が、閉じたはずの古い `NSWindow`
        // を再利用してしまい中身が正しく描画されない・`onAppear` が意図せず
        // 再発火するなどの不具合を招くことがあると報告されている。ウインドウの
        // 位置・サイズの記憶は `windowFrameAutosave`（自前の `UserDefaults`
        // ベースの仕組み）で行っており、この標準の状態復元には依存していない
        // ため、無効化しても既存機能に影響しない。
        .restorationBehavior(.disabled)
        .commands {
            CommandGroup(replacing: .appInfo) {
                AboutMenuButton()
            }
            CommandGroup(replacing: .undoRedo) {
                UndoRedoMenuCommands()
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

/// Edit メニューの「取り消す」/「やり直す」[UD-06]。実際のキーボード
/// ショートカット（⌘Z/⇧⌘Z）はここでは付けない
/// — `DefaultKeyBindings`/`KeyBindingButtons`（`MainWindowView` の
/// `.background` 参照）がアプリの唯一の配線経路になるようにするため
/// [設計判断、1-8 以来の他のショートカットと同じ仕組みに揃える]。ここは
/// 動的なタイトルを出す発見可能なメニュー項目としての役割のみを持つ。
private struct UndoRedoMenuCommands: View {
    var body: some View {
        let stack = CommandStack.shared
        Button(stack.undoTitle.map { "\($0)を取り消す" } ?? "取り消す") {
            Task {
                await CommandStack.shared.undo()
                SessionState.shared.reloadToken += 1 // [実機検証で発見: 一覧再読み込みの伝達漏れ]
            }
        }
        .disabled(!stack.canUndo)

        Button(stack.redoTitle.map { "\($0)をやり直す" } ?? "やり直す") {
            Task {
                await CommandStack.shared.redo()
                SessionState.shared.reloadToken += 1
            }
        }
        .disabled(!stack.canRedo)
    }
}
