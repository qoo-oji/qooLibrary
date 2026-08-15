import Foundation

/// 長時間処理の一時停止／再開 [UI-09、ユーザー要望]。
///
/// ## なぜ「待つ」形なのか
/// 一時停止させたい処理のうち、コピーは `copyfile(3)` の status コールバック
/// （同期の C 関数）の中でしか介入できない。そこから Swift の `await` で
/// 中断することはできないので、**その場で待つ**しかない。コピー本体は元々
/// 同期呼び出しで 1 スレッドを占有し続けているため、待っても占有するスレッドの
/// 本数は変わらない。
///
/// - Important: 一時停止したまま放置されると、そのスレッドは解放されない。
///   同時に走る処理の数だけしか起こらないので実害は小さいが、**待ち続ける
///   だけの実装にしてはいけない** — 下記のとおりキャンセルは必ず効くようにする。
///
/// ## 一時停止中でもキャンセルできること（この型の要）
/// 素朴に「再開されるまで眠る」実装にすると、**一時停止した処理を止められなく
/// なる**（キャンセルボタンを押しても、待っている側が目を覚まさない）。
/// そのため短い間隔で目を覚まし、`Task.isCancelled` を見て抜ける。
public final class PauseToken: @unchecked Sendable {
    /// 目を覚まして取り消しを確認する間隔。人間の操作に対する反応としては
    /// 十分速く、待っている間の負荷は無視できる。
    private static let wakeInterval: TimeInterval = 0.1

    private let condition = NSCondition()
    private var paused = false

    public init() {}

    public var isPaused: Bool {
        condition.lock()
        defer { condition.unlock() }
        return paused
    }

    public func pause() { setPaused(true) }
    public func resume() { setPaused(false) }

    /// - Returns: 変更後の状態（一時停止中なら `true`）。
    @discardableResult
    public func toggle() -> Bool {
        condition.lock()
        paused.toggle()
        let now = paused
        condition.broadcast()
        condition.unlock()
        return now
    }

    private func setPaused(_ value: Bool) {
        condition.lock()
        paused = value
        condition.broadcast()
        condition.unlock()
    }

    /// 一時停止中のあいだ待つ。取り消されたら即座に戻る（呼び出し側が
    /// いつもどおり `Task.isCancelled` を見て後始末できるようにするため、
    /// ここでは何も投げない）。
    public func waitWhilePaused() {
        condition.lock()
        while paused, !Task.isCancelled {
            condition.wait(until: Date().addingTimeInterval(Self.wakeInterval))
        }
        condition.unlock()
    }
}
