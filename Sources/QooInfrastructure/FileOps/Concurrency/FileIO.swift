import Foundation

/// **ブロッキングなファイル I/O を実行する、ただ 1 つの窓口** [NV6-01〜03]。
///
/// `FileOperationService` が「ファイルシステムを変更する経路」を 1 箇所に
/// 集めている [FO-01] のと同じ考え方で、こちらは**「どのスレッドで待つか」**を
/// 1 箇所に集める。
///
/// ## 守るべき 2 つの禁止
/// | 場所 | 破ったときに起きること |
/// |---|---|
/// | **メインスレッド** | ビーチボール。サーバが応答しなければ分単位、NFS なら無限 |
/// | **協調スレッドプール** | コア数ぶん塞ぐと**アプリの async 処理が全部止まる**（実測）|
///
/// ``perform(_:)`` は呼び出し元を**必ず中断させて**別スレッドへ渡すので、
/// メインアクタから呼べばメインスレッドが空き、`actor` から呼べば
/// **その actor も解放される**——後者は重要で、`FileOperationService` は
/// 状態を持たない `actor` なので、I/O 中に手放しても正しさを損なわず、
/// **1 件のハングが他のファイル操作を巻き添えにしなくなる。**
///
/// ## タイムアウトの意味
/// **macOS に中断可能なファイル I/O は存在しない。** `Task.cancel()` は
/// ブロック中の syscall を割り込まない。したがって ``perform(waitingAtMost:_:)``
/// が行うのは**「待つのをやめる」ことだけ**で、走っている I/O は止まらない
/// [NV6-03]。塞がったスレッドは戻ってこない前提で設計すること——それでも
/// 「アプリが二度と動かない」よりはるかに良い。
public enum FileIO {
    /// 同期のブロッキング処理を、協調プールとメインスレッドの外で実行する。
    ///
    /// - Important: `body` の中で `await` はできない（同期クロージャ）。
    ///   これは制約ではなく**意図**で、「ここは 1 かたまりのブロッキング
    ///   処理である」という境界を型で示している。
    public static func perform<T: Sendable>(
        _ body: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            FileIOExecutor.shared.queue.async {
                continuation.resume(with: Result { try body() })
            }
        }
    }

    /// 失敗しない処理向けの糖衣。`try` を書かずに済ませるためだけのもの。
    public static func perform<T: Sendable>(
        _ body: @escaping @Sendable () -> T
    ) async -> T {
        await withCheckedContinuation { continuation in
            FileIOExecutor.shared.queue.async {
                continuation.resume(returning: body())
            }
        }
    }

    /// 上限時間つきで実行する。**待つのをやめるだけで、I/O は止まらない。**
    ///
    /// 上限を過ぎたら `FileOperationError.timedOut` を投げ、`body` の結果は
    /// 捨てる。捨てた側で処理が進む可能性はあるので、**副作用のある処理に
    /// 使うときは「やり直しても壊れない」ことを確かめてから**使うこと。
    ///
    /// - Note: **構造化並行性で書いてはいけない。** `withThrowingTaskGroup` で
    ///   本体とスリープを競争させると、**本体を抜ける際にグループが全子タスクの
    ///   完了を暗黙に待つ**ため上限が効かない。しかも継続はキャンセルに
    ///   反応しないので `cancelAll()` も無効（1-15 のアプリ終了処理で実際に
    ///   踏んだ）。独立した 2 本の非構造化タスクが**先着 1 回だけ応答する**形にする。
    public static func perform<T: Sendable>(
        waitingAtMost limit: Duration,
        _ body: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await withDeadline(limit) { try await perform(body) }
    }

    /// 任意の async 処理に上限時間を付ける。``perform(waitingAtMost:_:)`` の
    /// 中身であり、`NSWorkspace.recycle` のように**完了ハンドラが呼ばれない
    /// かもしれない** API を待つ場面でも使う [NV4-04]。
    public static func withDeadline<T: Sendable>(
        _ limit: Duration,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let box = SingleResume<T>()
        return try await withCheckedThrowingContinuation { continuation in
            box.arm(continuation)
            Task {
                do { box.resume(.success(try await operation())) }
                catch { box.resume(.failure(error)) }
            }
            Task {
                try? await Task.sleep(for: limit)
                let seconds = Double(limit.components.seconds)
                box.resume(.failure(FileOperationError.timedOut(seconds: seconds)))
            }
        }
    }

    /// 1 度だけ再開できる継続の入れ物。二重再開は `CheckedContinuation` が
    /// クラッシュとして検出するため、ロックで確実に 1 回に絞る。
    private final class SingleResume<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T, Error>?

        func arm(_ continuation: CheckedContinuation<T, Error>) {
            lock.lock(); defer { lock.unlock() }
            self.continuation = continuation
        }

        func resume(_ result: Result<T, Error>) {
            lock.lock()
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume(with: result)
        }
    }
}
