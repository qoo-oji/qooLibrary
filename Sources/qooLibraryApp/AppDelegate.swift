import AppKit

/// [ユーザー要望、要件定義書には無い] 「すべてのウインドウが閉じたら終了」
/// 環境設定（`GeneralPreferencesTab`）用。SwiftUI の `App`/`Scene` には
/// `applicationShouldTerminateAfterLastWindowClosed` に相当する宣言的 API が
/// 無いため、`NSApplicationDelegateAdaptor` で最小限の `NSApplicationDelegate`
/// を導入する。既定は `false`（macOS の一般的なアプリと同じく、ウインドウを
/// すべて閉じてもアプリ自体は常駐し続け、Dock からの再オープンや `⌘Q` を
/// ユーザーの意思に委ねる）。
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let storageKey = "qoo.preferences.quitWhenAllWindowsClosed"

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        UserDefaults.standard.bool(forKey: Self.storageKey)
    }
}
