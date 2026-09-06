import AppKit
import QooApplication
import QooInfrastructure

/// アプリ全体のライフサイクルのうち、SwiftUI の `App`/`Scene` に対応する
/// 宣言的 API が無いものを受け持つ最小限の `NSApplicationDelegate`。
///
/// 1. **「すべてのウインドウが閉じたら終了」** [ユーザー要望、要件定義書には
///    無い]。既定は `false`（macOS の一般的なアプリと同じく、ウインドウを
///    すべて閉じてもアプリ自体は常駐し続け、Dock からの再オープンや `⌘Q` を
///    ユーザーの意思に委ねる）。
/// 2. **終了時の診断ログの確実な書き出し** [LG2-01、1-15]。
/// 3. **終了時の差分スキャンの起点の保存** [SY-02][WA-02、2-2]。
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let quitWhenAllWindowsClosedKey = "qoo.preferences.quitWhenAllWindowsClosed"

    /// 終了保留（`.terminateLater`）を二重に返さないための印。
    private var isFinishingUp = false

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        UserDefaults.standard.bool(forKey: Self.quitWhenAllWindowsClosedKey)
    }

    /// 終了直前に、まだディスクへ届いていないログを書き切る [LG2-01]。
    ///
    /// **`applicationWillTerminate` でセマフォを使って待つ方式は採らない** —
    /// メインスレッドを止めることになる。AppKit が用意している
    /// `.terminateLater` + `reply(toApplicationShouldTerminate:)` の非同期
    /// 経路を使う。
    ///
    /// **上限時間を「構造化並行性の外」で持つ**のが要点。`withTaskGroup` で
    /// 競争させると、本体が返っても**グループはすべての子タスクの完了を
    /// 暗黙に待つ**ため、`flush()` が返ってこない状況（ディスクが固まった等）
    /// では結局終了できない。`flush()` は `withCheckedContinuation` で待つ
    /// 構造上キャンセルにも反応しないので、`cancelAll()` も効かない。
    /// そのため、後始末（`Task`）と上限時間（ランループのタイマー）を
    /// 独立に走らせ、**先に着いた方が 1 回だけ**返答する形にしている。
    /// 取り残された方はプロセスの終了とともに消える。
    ///
    /// **上限時間をメインキューへ直に載せるのが要点**——`terminate:` は
    /// 入れ子のイベントループでメインスレッドを占有したまま返答を待つので、
    /// 呼び出し元がメインアクタのジョブの中だと `Task` は 1 つも走れない
    /// （実測、2026-09-06。詳しくは `BackupRestoreAction.restore`）。
    ///
    /// ログの消費側は 1 レコードずつ即座に書き込んでいるため、ここで待つのは
    /// 待ち行列に残った僅かな分だけで、通常は一瞬で返る。
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isFinishingUp else { return .terminateNow }
        isFinishingUp = true

        let reply = OneShotTerminationReply()
        Task {
            // **ログを書き切る前に**差分の起点を保存する [SY-02][WA-02]
            // ——保存の記録もログに残したいので順序が要る。次回起動時は
            // ここで保存した起点から差分を取る [SY-03]。
            await LibraryServices.shared.stopSync()
            await Log.endSession()
            reply.fire()
        }
        // **上限時間はランループのタイマーで持つ**［実機検証で修正、2026-09-06］。
        // `terminate:` は `.terminateLater` を返すと入れ子のイベントループで
        // 返答を待つが、そのループは**メインキューを再入ドレインできない**
        // （`BackupRestoreAction.restore` の注記）。`Task` も
        // `DispatchQueue.main.asyncAfter` もメインキュー経由なので、
        // 呼び出し元がドレインの中だと**上のタスクも、この上限時間も走れない**
        // ——上限時間が要るのはまさにその状況である。ランループのタイマーは
        // 入れ子のループがそのまま発火させるので、そこを通らない。
        //
        // `.common` へ入れるのは、待ちループのモードが既定とは限らないため。
        let deadline = Timer(timeInterval: 2, repeats: false) { _ in
            MainActor.assumeIsolated { reply.fire() }
        }
        RunLoop.main.add(deadline, forMode: .common)
        return .terminateLater
    }
}

/// `reply(toApplicationShouldTerminate:)` を 2 回呼ばないための一度きりの門。
/// `AppDelegate` と同じくメインアクター上でのみ使う。
@MainActor
private final class OneShotTerminationReply {
    private var didFire = false

    func fire() {
        guard !didFire else { return }
        didFire = true
        NSApp.reply(toApplicationShouldTerminate: true)
    }
}
