// 協調スレッドプールが枯渇したとき、どの実行先なら仕事を始められるかを測る。
//
//   xcrun swiftc -O -parse-as-library Scripts/thread-starvation-probe.swift -o /tmp/probe && /tmp/probe
//
// **何を確かめるためのものか**
// `FileIOExecutor`（8章 §8.11.6、NV6-01）が「投入ごとに直列キュー 1 本」である
// 理由はこの測定にある。以前は 1 本の `.concurrent` queue だったが、それでは
// **協調プールが塞がっているときに 1 件も走り出せない** — ちょうど助けが
// 要る場面で助けが来ない。あわせて `FileIO.withDeadline` の期限を
// `Task.sleep` で計ってはいけない理由（同じく発火しない）も確かめる。
//
// **測定ごとに新しいプロセスで走らせること。** 1 プロセスで続けて測ると、
// 前の測定が起こしたスレッドが workqueue に残り、結果が汚れる。
// 引数無しで起動すると、自分自身を各モードで呼び直してそれを担保する。
//
// sudo は要らない。外部に一切触れない（ファイルもネットワークも使わない）。

import Foundation

@main
struct Probe {
    static let modes = ["concurrent", "serialpool", "thread", "timers", "qos"]

    static func main() {
        let arguments = CommandLine.arguments
        guard arguments.count > 1 else { return orchestrate(binary: arguments[0]) }
        run(mode: arguments[1])
    }

    /// 各モードを別プロセスで順に走らせる。
    static func orchestrate(binary: String) {
        let cores = ProcessInfo.processInfo.activeProcessorCount
        print("論理コア: \(cores)  — 協調プールを \(cores) 本のブロッキングで塞いだ状態で測ります\n")
        // 子プロセスの出力と混ざらないよう、ここで必ず吐き出す
        // （パイプへ繋ぐと親の stdout はブロックバッファになる）。
        fflush(stdout)
        for mode in modes {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: binary)
            process.arguments = [mode]
            try? process.run()
            process.waitUntilExit()
        }
        print("""

        まとめ:
          concurrent … 現行より前の FileIOExecutor。non-overcommit なので枯渇する
          serialpool … 現行の FileIOExecutor。直列キューは overcommit
          thread     … 参考（必ずスレッドを貰えるが、寿命を自分で管理することになる）
          timers     … withDeadline が DispatchSource を使う理由
        """)
    }

    static func run(mode: String) {
        let cores = ProcessInfo.processInfo.activeProcessorCount

        // QoS の測定だけは自分で塞ぎ方を変えるので、共通の枯渇を使わない。
        if mode == "qos" { return measureQoSMatrix(cores) }

        let hold = saturateCooperativePool(cores)
        defer { for _ in 0..<cores { hold.signal() }; Thread.sleep(forTimeInterval: 0.2) }

        switch mode {
        case "concurrent":
            measureStart("concurrent queue（旧 FileIOExecutor）") { started, release in
                let q = DispatchQueue(label: "p.c", qos: .userInitiated, attributes: .concurrent)
                for _ in 0..<4 { q.async { started.signal(); release.wait() } }
            }
        case "serialpool":
            measureStart("serial queue を投入ごとに（現行 FileIOExecutor）") { started, release in
                for i in 0..<4 {
                    DispatchQueue(label: "p.s.\(i)", qos: .userInitiated)
                        .async { started.signal(); release.wait() }
                }
            }
        case "thread":
            measureStart("Thread を直接起こす") { started, release in
                for _ in 0..<4 {
                    let t = Thread { started.signal(); release.wait() }
                    t.qualityOfService = .userInitiated
                    t.start()
                }
            }
        case "timers":
            measureTimers()
        default:
            print("mode: \(modes.joined(separator: " | "))")
        }
    }

    /// 枯渇中に 4 件のブロッキングを始められるか。
    static func measureStart(_ label: String, _ submit: (DispatchSemaphore, DispatchSemaphore) -> Void) {
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let t0 = Date()
        submit(started, release)

        var got = 0
        for _ in 0..<4 where started.wait(timeout: .now() + 8) == .success { got += 1 }
        let ms = Date().timeIntervalSince(t0) * 1000
        print(got == 4
              ? String(format: "  %-42@ 4/4 が %.0f ms で開始 ✅", label as NSString, ms)
              : String(format: "  %-42@ %d/4 しか始められない ★★", label as NSString, got))
        for _ in 0..<4 { release.signal() }
    }

    /// 枯渇は QoS バケットをまたぐか。
    ///
    /// **またぐのは「高い→低い」方向だけ**なので、`FileIOExecutor` を
    /// `.userInitiated` に置いておくと、`.utility` のサムネイル生成が
    /// 詰まっても巻き添えにならない。逆に、SwiftUI の `.task` から生えた
    /// `.userInitiated` の `Task` がブロッキング I/O をすると直撃する。
    static func measureQoSMatrix(_ cores: Int) {
        print("  【QoS をまたぐか】塞ぐ QoS → 試す QoS（concurrent queue で 4 件）")
        for blocker in [TaskPriority.userInitiated, .medium, .utility, .background] {
            let hold = DispatchSemaphore(value: 0)
            let saturated = DispatchSemaphore(value: 0)
            for _ in 0..<cores {
                Task.detached(priority: blocker) { saturated.signal(); hold.wait() }
            }
            for _ in 0..<cores { saturated.wait() }

            var line = "    塞ぐ=\(name(blocker))".padding(toLength: 26, withPad: " ", startingAt: 0)
            for target in [DispatchQoS.userInitiated, .default, .utility] {
                let queue = DispatchQueue(label: "t", qos: target, attributes: .concurrent)
                let started = DispatchSemaphore(value: 0)
                let release = DispatchSemaphore(value: 0)
                for _ in 0..<4 { queue.async { started.signal(); release.wait() } }
                var got = 0
                for _ in 0..<4 where started.wait(timeout: .now() + 4) == .success { got += 1 }
                for _ in 0..<4 { release.signal() }
                line += "  \(name(target))=\(got)/4\(got == 4 ? "✅" : "★★")"
            }
            print(line)
            for _ in 0..<cores { hold.signal() }
            Thread.sleep(forTimeInterval: 0.3)
        }
    }

    static func name(_ p: TaskPriority) -> String {
        switch p {
        case .userInitiated: "userInitiated"
        case .utility: "utility"
        case .background: "background"
        default: "medium"
        }
    }

    static func name(_ q: DispatchQoS) -> String {
        switch q {
        case .userInitiated: "UI"
        case .utility: "Ut"
        default: "Df"
        }
    }

    /// 枯渇中に 300 ms の期限が発火するか。
    static func measureTimers() {
        let limitMS = 300

        let dispatchDone = DispatchSemaphore(value: 0), dispatchMS = Box()
        let td = Date()
        DispatchQueue.global(qos: .userInitiated)
            .asyncAfter(deadline: .now() + .milliseconds(limitMS)) {
                dispatchMS.value = Date().timeIntervalSince(td) * 1000; dispatchDone.signal()
            }

        let sourceDone = DispatchSemaphore(value: 0), sourceMS = Box()
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "p.timer"))
        let ts = Date()
        timer.schedule(deadline: .now() + .milliseconds(limitMS))
        timer.setEventHandler {
            sourceMS.value = Date().timeIntervalSince(ts) * 1000; sourceDone.signal(); timer.cancel()
        }
        timer.resume()

        let sleepDone = DispatchSemaphore(value: 0), sleepMS = Box()
        let tt = Date()
        Task.detached(priority: .userInitiated) {
            try? await Task.sleep(for: .milliseconds(limitMS))
            sleepMS.value = Date().timeIntervalSince(tt) * 1000; sleepDone.signal()
        }

        let dispatchOK = dispatchDone.wait(timeout: .now() + 5) == .success
        let sourceOK = sourceDone.wait(timeout: .now() + 5) == .success
        let sleepOK = sleepDone.wait(timeout: .now() + 5) == .success

        func verdict(_ ok: Bool, _ ms: Double) -> String {
            guard ok else { return "5 秒待っても発火せず ★★" }
            let over = ms - Double(limitMS)
            return String(format: "%.0f ms（期限 +%.0f ms）%@", ms, over, over > 200 ? " ★遅延" : " ✅")
        }
        print("  Task.sleep（協調プール）                   : \(verdict(sleepOK, sleepMS.value))")
        print("  DispatchQueue.asyncAfter（non-overcommit） : \(verdict(dispatchOK, dispatchMS.value))")
        print("  DispatchSource タイマー（serial queue）     : \(verdict(sourceOK, sourceMS.value))")
    }

    /// 協調プールをちょうどコア数ぶんのブロッキングで塞ぐ。
    ///
    /// - Important: **`.userInitiated` で塞ぐこと。** 枯渇は QoS の高いほうから
    ///   低いほうへしか流れない（`qos` モードの表）ので、`.utility` で塞いでも
    ///   `.userInitiated` の `FileIOExecutor` は平気で走り、**再現しない**。
    ///   実際、この probe は最初 `.utility` で塞いでいて「穴は無い」という
    ///   誤った結果を出した。
    /// - Important: 多く投げてはいけない——走り出せなかったぶんの合図を
    ///   待って自滅する。
    static func saturateCooperativePool(_ cores: Int) -> DispatchSemaphore {
        let hold = DispatchSemaphore(value: 0)
        let saturated = DispatchSemaphore(value: 0)
        for _ in 0..<cores {
            Task.detached(priority: .userInitiated) { saturated.signal(); hold.wait() }
        }
        for _ in 0..<cores { saturated.wait() }
        return hold
    }

    final class Box: @unchecked Sendable { var value: Double = 0 }
}
