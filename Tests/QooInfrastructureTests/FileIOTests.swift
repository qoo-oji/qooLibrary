import Foundation
import QooKit
import Testing

@testable import QooInfrastructure

/// **ブロッキング I/O が協調スレッドプールを枯渇させないこと** [NV6-01]。
///
/// 1-16b の実測（論理コア 10 の機）では、コア数ぶんの同期ブロッキング I/O を
/// 素の `Task` で走らせると、**ごく普通の `Task` が 5 秒間一度も動かなかった**。
/// `Task.detached` も同じプールを使うので逃げ場にならない。
/// ネットワークでは無応答が日常で、**NFS の hard マウント（既定）では
/// スレッドが永久に失われる**。
///
/// この suite はその性質を固定する。`FileIO.perform` を経由する限り、
/// 何本塞いでもアプリの async 処理は動き続けなければならない。
@Suite struct FileIOTests {
    /// **この suite の主眼。**
    ///
    /// コア数を超える数のブロッキング処理を `FileIO.perform` で走らせても、
    /// ごく普通の `Task` は即座に動く。
    ///
    /// - Note: 「素の `Task` で同じことをすると枯渇する」という**逆方向の
    ///   確認はテストにしない** — 実際に枯渇させるとテストプロセス全体が
    ///   止まり、他の suite を道連れにするため。枯渇することは
    ///   使い捨てのプローブで実測済み（8章 §8.11.6）。
    @Test func blockingWorkDoesNotStarveTheCooperativeThreadPool() async throws {
        let cores = ProcessInfo.processInfo.activeProcessorCount
        // コア数より多く塞ぐ。素の `Task` ならここで確実に枯渇する数。
        let blockerCount = cores + 4
        let release = DispatchSemaphore(value: 0)
        let allBlocked = DispatchSemaphore(value: 0)

        var blockers: [Task<Void, Error>] = []
        for _ in 0..<blockerCount {
            blockers.append(Task {
                try await FileIO.perform {
                    allBlocked.signal()
                    // 解放されるまで戻らない＝応答しないサーバの再現。
                    release.wait()
                }
            })
        }
        // 全部が実際にブロックに入るまで待つ（入る前に測っても意味が無い）。
        let allEntered = await FileIO.perform {
            waitRepeatedly(allBlocked, times: blockerCount, timeout: 10)
        }
        #expect(allEntered, "ブロックに入れなかった")

        // ここからが本題。ごく普通の `Task` が動くか。
        //
        // **待つのはディスパッチスレッド側で行う。** 協調プールの上で
        // `await` して待つと、枯渇していた場合にこのテスト自身が固まり、
        // 「失敗」ではなく「ハング」になってしまう。
        let canaryRan = DispatchSemaphore(value: 0)
        Task { canaryRan.signal() }
        let observed = await FileIO.perform {
            canaryRan.wait(timeout: .now() + 5) == .success
        }

        // 後始末は判定の前に済ませる——失敗しても塞いだままにしない。
        for _ in 0..<blockerCount { release.signal() }
        for blocker in blockers { _ = try await blocker.value }

        #expect(observed, "\(blockerCount) 本のブロッキング I/O で協調プールが枯渇した")
    }

    /// メインスレッドから呼んでも、本体はメインスレッドで走らない。
    @MainActor
    @Test func performLeavesTheMainThread() async throws {
        #expect(isRunningOnMainThread())
        let ranOnMain = await FileIO.perform { isRunningOnMainThread() }
        #expect(!ranOnMain, "メインスレッドでブロッキング処理を走らせている")
        // 戻ってきたらメインへ帰っていること（呼び出し側の隔離は保たれる）。
        #expect(isRunningOnMainThread())
    }

    /// `actor` から呼ぶと、待っている間その actor は解放される。
    ///
    /// **これが「1 件のハングが他のファイル操作を巻き添えにしない」ことの
    /// 土台**になる。`FileOperationService` は状態を持たない `actor` なので、
    /// I/O 中に手放しても正しさを損なわない。
    @Test func awaitingInsideAnActorReleasesIt() async throws {
        let probe = ActorReleaseProbe()
        let gate = DispatchSemaphore(value: 0)

        let slow = Task { await probe.slow(1, until: gate) }
        // 1 が I/O に入るのを待ってから 2 を投げる。
        try await Task.sleep(for: .milliseconds(200))
        await probe.quick(2)

        gate.signal()
        await slow.value

        // 2 が先に終わっている＝ actor は待っている間に手放されていた。
        #expect(await probe.results() == [2, 1], "actor が I/O 中に解放されていない")
    }

    /// 上限時間は、本体が戻ってこなくても効く。
    @Test func aDeadlineStopsWaitingEvenIfTheWorkNeverReturns() async throws {
        let release = DispatchSemaphore(value: 0)
        let started = Date()
        var thrown: (any Error)?
        do {
            _ = try await FileIO.perform(waitingAtMost: .milliseconds(300)) {
                release.wait() // 解放するまで戻らない
            }
        } catch {
            thrown = error
        }
        let elapsed = Date().timeIntervalSince(started)
        release.signal() // 塞いだスレッドを解放してから判定する

        let error = try #require(thrown as? FileOperationError)
        guard case .timedOut = error else {
            Issue.record("上限超過として返らなかった: \(error)")
            return
        }
        #expect(elapsed < 3, "上限を過ぎても待ち続けた（\(elapsed) 秒）")
    }

    /// 期限つきの実行を繰り返しても、タイマーの後片付けで落ちないこと。
    ///
    /// - Note: **これは「順序の退行」を捕まえるテストではない。** 一度は
    ///   そのつもりで書いたが、変異（`resume()` を本体の後ろへ動かす）を
    ///   当てても通ってしまい、**空振りだと分かった** — 順序ではなく
    ///   「`resume()` に到達すること」だけが効いているため（実測）。
    ///   早期 return を挟む退行は静的には捕まえられないので、
    ///   `withDeadline` のコメントで釘を刺してある。ここに残しているのは
    ///   期限つき経路をひととおり通す安価な煙探知器としての価値だけ。
    @Test func repeatedDeadlinesTearDownCleanly() async throws {
        for _ in 0..<200 {
            let value = try await FileIO.perform(waitingAtMost: .seconds(30)) { 42 }
            #expect(value == 42)
        }
    }

    /// 本体が投げたエラーはそのまま伝わる（握り潰さない）。
    @Test func errorsPropagate() async {
        await #expect(throws: FileIOTestFailure.self) {
            try await FileIO.perform { throw FileIOTestFailure() }
        }
    }

    /// 失敗しない糖衣も同じスレッド規則に従う。
    @Test func theNonThrowingOverloadAlsoLeavesTheCallersThread() async {
        let ranOnMain = await FileIO.perform { isRunningOnMainThread() }
        #expect(!ranOnMain)
    }

    // MARK: - 取り消しが借りたスレッドまで届くこと [NV6-01][NV6-03]

    /// **`Task.isCancelled` はここでは効かない**、という事実の記録。
    ///
    /// これがこの一連の仕組みの存在理由そのものなので、性質として固定する。
    /// もし将来 `perform` の実装が変わって Task の文脈が保たれるように
    /// なったなら、このテストが落ちて気づける（そのときは `Cancellation`
    /// ごと不要になる）。
    @Test func taskCancellationIsInvisibleOnTheBorrowedThread() async {
        let task = Task {
            await FileIO.perform { () -> Bool in
                // 呼び出し元は下で必ず取り消されるが、ここには Task の
                // 文脈が無いので `Task.isCancelled` は false のまま。
                waitUntil(timeout: 1) { Task.isCancelled }
            }
        }
        task.cancel()
        #expect(await task.value == false, "借りたスレッドで Task.isCancelled が効いてしまっている")
    }

    /// **`Cancellation.isRequested` なら届く。**
    ///
    /// これが無いと、`PauseToken` の待ちも `FileCopyEngine` のキャンセルも
    /// `ProgressTracker` の走査の打ち切りも、すべて静かに効かなくなる
    /// （実測でテストが永久にハングした）。
    @Test func cancellationReachesTheBorrowedThread() async {
        let entered = DispatchSemaphore(value: 0)
        let task = Task {
            await FileIO.perform { () -> Bool in
                entered.signal()
                return waitUntil(timeout: 5) { Cancellation.isRequested }
            }
        }
        // 本体が走り出してから取り消す（走り出す前だと下のテストと同じ経路になる）。
        _ = await FileIO.perform { entered.wait(timeout: .now() + 5) == .success }
        task.cancel()
        #expect(await task.value, "取り消しが借りたスレッドへ届かなかった")
    }

    /// 走り出す**前**に取り消されていた場合も届く。
    /// `withTaskCancellationHandler` は既に取り消された状態で入ると
    /// `onCancel` を即座に呼ぶ、という Swift の保証に依存している。
    @Test func cancellationBeforeTheWorkStartsIsAlsoVisible() async {
        let task = Task {
            // 走り出す前に確実に取り消されているよう、少し待ってから入る。
            try? await Task.sleep(for: .milliseconds(50))
            return await FileIO.perform { Cancellation.isRequested }
        }
        task.cancel()
        #expect(await task.value, "開始前の取り消しが伝わらなかった")
    }

    /// 範囲の外では `Task.isCancelled` に委ねる。
    /// これがあるので、呼ばれる側は**どちらの世界にいるかを知らずに済む**。
    @Test func outsideAScopeItFallsBackToTheTask() async {
        #expect(!Cancellation.isRequested)
        let task = Task { () -> Bool in
            waitUntil(timeout: 1) { Cancellation.isRequested }
        }
        task.cancel()
        #expect(await task.value, "範囲の外で Task.isCancelled へ委ねていない")
    }

    /// 入れ子にしても、外側の範囲が壊れない。
    @Test func nestedScopesRestoreTheOuterFlag() async {
        let outer = Cancellation.Flag()
        outer.request()
        let observed = await FileIO.perform { () -> (inner: Bool, afterInner: Bool) in
            Cancellation.withScope(outer) {
                let inner = Cancellation.withScope(Cancellation.Flag()) { Cancellation.isRequested }
                return (inner, Cancellation.isRequested)
            }
        }
        #expect(observed.inner == false, "内側の範囲が外側の旗を見てしまっている")
        #expect(observed.afterInner, "内側を抜けたあと外側の旗へ戻っていない")
    }
}

// MARK: - テスト用の補助型
//
// **`@Test` の本体の中で型を宣言しない。** マクロ展開の中にローカル型宣言を
// 置くとコンパイラが `fatalError` で落ちることを確認したため、ファイル
// スコープへ出してある。

/// I/O 中に actor が解放されるかを観測するための小さな actor。
actor ActorReleaseProbe {
    private var finished: [Int] = []

    func slow(_ id: Int, until gate: DispatchSemaphore) async {
        await FileIO.perform { gate.wait() }
        finished.append(id)
    }

    func quick(_ id: Int) { finished.append(id) }
    func results() -> [Int] { finished }
}

struct FileIOTestFailure: Error, Equatable {}

/// **実行先が「必ずスレッドを貰える」形であること** [NV6-01]。
///
/// ## なぜ構造を見張るのか
/// 本当に確かめたい性質は「協調プールが枯渇していても仕事を始められる」だが、
/// **それを直接テストにはできない** — 協調プールはプロセスに 1 つしか無く、
/// 実際に枯渇させると他の suite を道連れにする（`FileIOTests` の主眼の
/// 注記と同じ理由）。
///
/// そこで、実測で分かった**因果の手前側**を固定する。独立プロセスでの実測
/// （論理コア 10、協調プールを `.userInitiated` のブロッキング 10 本で
/// 塞いだ状態。枯渇は QoS の高いほうから低いほうへしか流れないので、
/// **塞ぐ側の QoS を下げると再現しない**）:
///
/// | 実行先 | 4 件のブロッキングを始められるか |
/// |---|---|
/// | private **concurrent** queue | **0/4。10 秒待っても始まらない** |
/// | `DispatchQueue.global()` へ target した concurrent | **0/4** |
/// | private **serial** queue の束 | **4/4 が 0 ms で開始** |
///
/// 差は overcommit かどうかで、**直列であることがその条件**である。
/// したがって「レーンが直列であること」を見張れば、
/// 枯渇を再現しなくても退行を捕まえられる。
///
/// 実測そのものをやり直したいときは `Scripts/thread-starvation-probe.swift`。
@Suite struct FileIOExecutorShapeTests {
    /// 実行先が直列であること。**`.concurrent` に変えると落ちる。**
    ///
    /// 同じ実行先へ 2 件投げ、重ならないことで直列を確かめる。
    @Test func aLaneIsSerialSoItIsGuaranteedAThread() async {
        let lane = FileIOExecutor.makeLane()
        let overlapping = Counter()
        let sawOverlap = Counter()
        let done = DispatchSemaphore(value: 0)

        for _ in 0..<8 {
            lane.async {
                if overlapping.increment() > 1 { _ = sawOverlap.increment() }
                Thread.sleep(forTimeInterval: 0.01)
                _ = overlapping.decrement()
                done.signal()
            }
        }
        let finished = await waitOffThePool { waitRepeatedly(done, times: 8, timeout: 5) }
        #expect(finished, "実行先の処理が終わらない")
        #expect(sawOverlap.value == 0, "実行先が直列でない（concurrent になっている）")
    }

    /// **実行先を使い回さないこと。この suite でいちばん重要。**
    ///
    /// 決まった本数を配り回す実装（ラウンドロビン）を一度書いて、
    /// **実際にデッドロックさせた**。「全員が走り出すまで誰も終わらない」
    /// 形の I/O が同じ実行先に当たると、後の 1 件が永久に始まらない。
    /// 本数を増やしても、投入の通し番号で割り当てる限り、自分の 2 件の間に
    /// 他所から本数ぶん挟まれば衝突する（テストを並列で回して踏んだ）。
    ///
    /// ここでは**互いの開始を待ち合う**形にして、共有があれば必ず止まるようにする。
    @Test func concurrentSubmissionsNeverShareALane() async {
        let want = 24
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        for _ in 0..<want {
            FileIOExecutor.shared.submit { started.signal(); release.wait() }
        }
        // 共有していれば最初の 1 件が待ちきれずに落ちるので、上限は短くてよい。
        let allStarted = await waitOffThePool { waitRepeatedly(started, times: want, timeout: 5) }
        // 先に必ず解放する。落ちる場合でもスレッドを残さないため。
        for _ in 0..<want { release.signal() }
        #expect(allStarted, "\(want) 件が同時に走り出せない＝実行先を共有している")
    }

    /// 期限の見張り役が、見張る相手と同じ実行先に並んでいないこと。
    ///
    /// 同じところに載せると、**塞がった I/O の後ろで期限が待たされる**——
    /// 期限が要る場面でだけ効かなくなる。
    @Test func theDeadlineTimerHasItsOwnQueue() {
        #expect(FileIOExecutor.shared.timerQueue.label != FileIOExecutor.makeLane().label)
    }

    /// **被験体を使わずに待つ。**
    ///
    /// この suite の他のテストは `FileIO.perform` の中で待つ（協調プールを
    /// 塞がないため）が、**構造テストではそれをしてはいけない** — `FileIO` が
    /// まさに壊れている場合、観測者自身が走り出せず、
    /// **「失敗」ではなく「ハング」になる**（変異を当てて実際に踏んだ）。
    /// 独立した使い捨てのキューで待てば、協調プールも塞がず、
    /// 壊れていれば上限時間できちんと落ちる。
    private func waitOffThePool(_ body: @escaping @Sendable () -> Bool) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue(label: "test.waiter").async { continuation.resume(returning: body()) }
        }
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        @discardableResult func increment() -> Int { lock.lock(); n += 1; defer { lock.unlock() }; return n }
        @discardableResult func decrement() -> Int { lock.lock(); n -= 1; defer { lock.unlock() }; return n }
        var value: Int { lock.lock(); defer { lock.unlock() }; return n }
    }
}

/// メインスレッドかどうかは、Swift の `Thread.isMainThread` が並行文脈で
/// エラーになるため、C の `pthread_main_np()` で直接確かめる。
func isRunningOnMainThread() -> Bool { pthread_main_np() != 0 }

/// セマフォを `times` 回待つ。**`DispatchSemaphore.wait` も非同期コンテキスト
/// から使えない**（`Await a Task handle instead`）ため、同期の関数にして
/// `FileIO.perform` 経由で呼ぶ。
func waitRepeatedly(_ semaphore: DispatchSemaphore, times: Int, timeout: TimeInterval) -> Bool {
    for _ in 0..<times where semaphore.wait(timeout: .now() + timeout) != .success {
        return false
    }
    return true
}

/// `condition` が成り立つまで短い間隔で見張る。**同期の関数**なので
/// `FileIO.perform` の中（＝ Task の文脈が無い場所）からも使える。
///
/// - Returns: 上限までに成り立ったか。
func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        Thread.sleep(forTimeInterval: 0.01)
    }
    return condition()
}
