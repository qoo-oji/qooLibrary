import Foundation
import QooKit

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
///
/// ## 取り消しは `Cancellation` 経由でしか見えない【重要】
/// **借りたスレッドには Task の文脈が無いので、`body` の中の
/// `Task.isCancelled` は常に `false` を返す。** そこにあった取り消し判定は
/// エラーも警告も出さずに死ぬ（実測で `PauseToken` が永久にハングした）。
///
/// ``perform(_:)`` は呼び出し元タスクの取り消しを ``QooKit/Cancellation/Flag``
/// へ橋渡しし、`body` をその範囲の中で走らせる。**`body` の中とその先では
/// `Task.isCancelled` ではなく `Cancellation.isRequested` を読むこと**
/// （`QooInfrastructure/FileOps/` 配下では静的検査が強制する）。
public enum FileIO {
    /// 同期のブロッキング処理を、協調プールとメインスレッドの外で実行する。
    ///
    /// - Important: `body` の中で `await` はできない（同期クロージャ）。
    ///   これは制約ではなく**意図**で、「ここは 1 かたまりのブロッキング
    ///   処理である」という境界を型で示している。
    /// - Important: `body` の中で取り消しを見るときは
    ///   `Cancellation.isRequested` を使う（`Task.isCancelled` は効かない）。
    ///
    /// 取り消されても**待つのをやめるのではなく、旗を立てて `body` に伝える**
    /// だけである。`body` は最後まで走り、その結果がそのまま返る——中断できる
    /// 処理なら `body` 自身が早く戻る。「待つのをやめたい」場合は
    /// ``perform(waitingAtMost:_:)`` を使う。
    public static func perform<T: Sendable>(
        _ body: @escaping @Sendable () throws -> T
    ) async throws -> T {
        let flag = Cancellation.Flag()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                FileIOExecutor.shared.submit {
                    continuation.resume(with: Result { try Cancellation.withScope(flag) { try body() } })
                }
            }
        } onCancel: {
            // 既に取り消されている状態で入った場合もここが呼ばれる（Swift の
            // 保証）ので、`body` が走り出す前に旗が立つ経路も塞がっている。
            flag.request()
        }
    }

    /// 失敗しない処理向けの糖衣。`try` を書かずに済ませるためだけのもの。
    public static func perform<T: Sendable>(
        _ body: @escaping @Sendable () -> T
    ) async -> T {
        let flag = Cancellation.Flag()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                FileIOExecutor.shared.submit {
                    continuation.resume(returning: Cancellation.withScope(flag) { body() })
                }
            }
        } onCancel: {
            flag.request()
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
    ///
    /// - Note: **期限を `Task.sleep` で計ってはいけない**［実測で書き直した］。
    ///   `Task.sleep` は協調プールの上で目を覚ますので、**協調プールが
    ///   塞がっていると発火しない**——期限が要るのはまさにその場面である。
    ///   独立プロセスでの実測（協調プールを論理コア数ぶんのブロッキングで
    ///   塞ぎ、300 ms の期限を計る）:
    ///
    ///   | 計り方 | 結果 |
    ///   |---|---|
    ///   | `Task.sleep` | **5 秒待っても発火せず** |
    ///   | `DispatchQueue.asyncAfter`（global＝non-overcommit）| **5 秒待っても発火せず** |
    ///   | `DispatchSource` タイマー（serial queue）| **304 ms で発火** ✅ |
    ///
    ///   この穴は `FileIOTests` の期限テストが「単独なら 0.32 秒・全体テストと
    ///   並列だと 4.5 秒」という形で既に捕まえていた。フレークに見えるが、
    ///   原因は製品側にあった。
    public static func withDeadline<T: Sendable>(
        _ limit: Duration,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let box = SingleResume<T>()
        let timer = DispatchSource.makeTimerSource(queue: FileIOExecutor.shared.timerQueue)
        return try await withCheckedThrowingContinuation { continuation in
            box.arm(continuation)
            let work = Task {
                // 先に終わったならタイマーは用済み。`cancel()` がハンドラを
                // 解放し、ハンドラがタイマー自身を捕らえている循環も切れる。
                defer { timer.cancel() }
                do { box.resume(.success(try await operation())) }
                catch { box.resume(.failure(error)) }
            }
            timer.schedule(deadline: .now() + limit.inSeconds)
            timer.setEventHandler {
                timer.cancel()
                let failure = FileOperationError.timedOut(seconds: limit.inSeconds)
                guard box.resume(.failure(failure)) else { return }
                // 待つのはやめたが、**中断できる処理なら中断は伝える**。
                // 走っている syscall は止まらない [NV6-03] ものの、区切りを
                // 持つ処理（`FileIO.perform` に載った走査など）はここで降りる。
                work.cancel()
            }
            // **`resume()` へ必ず到達すること。ここに早期 return を挟まない。**
            // `DispatchSource` は一度も `resume()` されないまま解放されると
            // `SIGTRAP` で落ちる（[実測] 「cancel だけして解放」「何もせず解放」
            // はどちらも落ち、「resume してから cancel」は落ちない）。
            //
            // 逆に、`work` が即座に終わって `defer` の `cancel()` が
            // ここを追い越すのは**問題ない**（[実測] cancel → resume → 解放は
            // 500 回繰り返しても落ちない）。順序ではなく、
            // **`resume()` に必ず到達すること**だけが効いている。
            timer.resume()
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

        /// - Returns: この呼び出しが実際に応答したか（＝先着だったか）。
        @discardableResult
        func resume(_ result: Result<T, Error>) -> Bool {
            lock.lock()
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume(with: result)
            return pending != nil
        }
    }
}

extension Duration {
    /// 秒数（小数を含む）。
    ///
    /// **`components.seconds` を直に使ってはいけない。** あれは整数部だけなので、
    /// 1 秒未満の期限が**すべて 0 になる**（`.milliseconds(300)` が「0 秒で
    /// 上限超過」と表示されていた）。
    var inSeconds: Double {
        let (seconds, attoseconds) = components
        return Double(seconds) + Double(attoseconds) / 1e18
    }
}
