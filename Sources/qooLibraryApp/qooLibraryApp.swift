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
    var body: some Scene {
        WindowGroup {
            MainWindowView()
        }
    }
}
