import Foundation
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

/// **`Thread.isMainThread` は非同期コンテキストから使えない**
/// （`NS_SWIFT_UNAVAILABLE_FROM_ASYNC`）。`#expect` の中で書くとコンパイル
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
