import Foundation
import Testing

@testable import QooKit

/// 一時停止 [ユーザー要望]。**「止めたまま取り消せる」ことが要**なので、
/// そこを固定する（素朴に「再開されるまで眠る」実装にすると、一時停止した
/// 処理を二度と止められなくなる）。
@Suite struct PauseTokenTests {
    @Test func doesNotWaitWhenNotPaused() {
        let token = PauseToken()
        let started = ContinuousClock.now
        token.waitWhilePaused()
        #expect(ContinuousClock.now - started < .milliseconds(100))
        #expect(token.isPaused == false)
    }

    @Test func toggleFlipsTheState() {
        let token = PauseToken()
        #expect(token.toggle() == true)
        #expect(token.isPaused == true)
        #expect(token.toggle() == false)
        #expect(token.isPaused == false)
    }

    /// 一時停止中は待ち、再開したら戻ること。
    ///
    /// **経過時間ではなく状態で判定する。** 以前は「250ms 待ってから再開し、
    /// 待ち時間が 200ms を超えたか」を見ていたが、全テストを並行実行すると
    /// `Task.detached` が走り出すのが後回しになり、再開の**後**に待ち始めて
    /// 「待っていない」と誤判定することがあった（実際に落ちた）。
    @Test func waitsWhilePausedAndReturnsAfterResume() async {
        let token = PauseToken()
        token.pause()

        let entered = Flag()
        let finished = Flag()
        let waiter = Task.detached {
            entered.set()
            token.waitWhilePaused()
            finished.set()
        }

        // 実際に待ち始めるまで待つ（走り出しの遅さに左右されないようにする）。
        for _ in 0..<200 where !entered.value {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(entered.value, "待ち手が走り出さなかった")

        // 止めている間は戻ってこないこと。
        try? await Task.sleep(for: .milliseconds(250))
        #expect(finished.value == false, "一時停止中なのに待ちを抜けた")
        #expect(token.isPaused == true)

        token.resume()
        await waiter.value
        #expect(finished.value, "再開しても戻ってこない")
    }

    /// テスト内でスレッドをまたいで立てる旗。
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var raised = false
        var value: Bool {
            lock.lock(); defer { lock.unlock() }
            return raised
        }
        func set() {
            lock.lock(); raised = true; lock.unlock()
        }
    }

    /// **一時停止中に取り消されたら、再開を待たずに戻る。**
    /// これが無いと、止めた処理をキャンセルできなくなる。
    @Test func stopsWaitingWhenTheTaskIsCancelled() async {
        let token = PauseToken()
        token.pause()

        let waiter = Task.detached {
            token.waitWhilePaused()
            return true
        }
        try? await Task.sleep(for: .milliseconds(150))
        waiter.cancel()

        // 取り消し後、起床間隔（0.1 秒）のうちに戻るはず。戻らなければ
        // ここで固まるので、時間切れの見張りを付けて明示的に失敗させる。
        let finished = await withTaskGroup(of: Bool.self) { group in
            group.addTask { await waiter.value }
            group.addTask {
                try? await Task.sleep(for: .seconds(3))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        #expect(finished, "一時停止中に取り消しても待ち続けている")
        // 一時停止の状態自体は変えない（取り消しは別の関心事）。
        #expect(token.isPaused == true)
    }
}
