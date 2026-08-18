//
//  GRDB の非同期 I/O が「協調スレッドプールの外」で待つかを実測する。
//
//  8章 §8.11（1-16b）で確定した最重要の教訓: ブロッキング I/O を協調プールの上で
//  待つと、コア数ぶん詰まった時点でアプリ全体の async 処理が止まる。`FileIO` は
//  そのために作った逃がし先で、**逃がした先が overcommit でなければ意味が無い**
//  （FileIOExecutor が 1 本の .concurrent queue だったときに実際に破れた）。
//
//  GRDB の `try await pool.read { }` が同じ穴を持たないかを、協調プールを
//  意図的に枯渇させた状態で確かめる。
//
import Foundation
import GRDB

final class Box: @unchecked Sendable { var value: Double = 0 }

/// 協調プールをちょうどコア数ぶんのブロッキングで塞ぐ。
/// `.userInitiated` で塞ぐこと — 枯渇は QoS の高いほうから低いほうへしか流れないため、
/// 既定優先度で塞ぐと再現しない（Scripts/thread-starvation-probe.swift の記録）。
/// `DispatchSemaphore.wait()` は async 文脈から呼べないので同期関数へ閉じ込める。
/// `DispatchSemaphore.wait()` は `noasync`。同期関数へ包むと async 文脈からでも
/// 呼べる（これは「協調プールのスレッドを実際に握って離さない」ことが目的なので、
/// 意図した使い方である）。
func blockingWait(_ s: DispatchSemaphore) { s.wait() }

func saturateCooperativePool(_ cores: Int) -> DispatchSemaphore {
    let hold = DispatchSemaphore(value: 0)
    let saturated = DispatchSemaphore(value: 0)
    for _ in 0..<cores {
        Task.detached(priority: .userInitiated) { saturated.signal(); blockingWait(hold) }
    }
    for _ in 0..<cores { saturated.wait() }
    return hold
}

/// 対照: 塞いだ状態で素の協調タスクが走り出すまでの時間。
/// これが短いなら枯渇できていない＝以降の測定は空振り。
func measureCooperativeStartDelay(timeout: Double) -> Double? {
    let box = Box(); let done = DispatchSemaphore(value: 0)
    let t = DispatchTime.now().uptimeNanoseconds
    Task.detached(priority: .userInitiated) {
        box.value = Double(DispatchTime.now().uptimeNanoseconds - t) / 1_000_000
        done.signal()
    }
    return done.wait(timeout: .now() + timeout) == .success ? box.value : nil
}

func releasePool(_ hold: DispatchSemaphore, _ cores: Int) {
    for _ in 0..<cores { hold.signal() }
}

func probeConcurrency(dbPath: String) async {
    print("\n--- GRDB の待ち先（1-16b の教訓の確認） ---")
    var config = Configuration()
    config.prepareDatabase { db in try db.execute(sql: "PRAGMA journal_mode = WAL") }
    guard let pool = try? DatabasePool(path: dbPath, configuration: config) else {
        print("  DB を開けない"); return
    }

    // ① 同期 read がどのスレッドで走るか
    let syncThread = (try? await pool.read { _ -> String in Thread.current.description }) ?? "?"
    print("  read が走るスレッド: \(syncThread.prefix(70))")

    // ② 協調プールを塞ぐ（対照付き）
    let cores = ProcessInfo.processInfo.activeProcessorCount
    let hold = saturateCooperativePool(cores)
    print("  協調プールを \(cores) 本の .userInitiated タスクで塞いだ")

    if let d = measureCooperativeStartDelay(timeout: 1.0) {
        print(String(format: "  ★対照が %.0f ms で走り出した = 枯渇できていない。以下は根拠にならない", d))
    } else {
        print("  対照: 素の協調タスクは 1 秒経っても走り出さない（＝確かに枯渇している）")
    }

    // ③ その状態で GRDB の async read が返ってくるか
    let t0 = DispatchTime.now().uptimeNanoseconds
    var n = -1
    do {
        n = try await pool.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM managedFile") ?? -1 }
    } catch { print("  読み取り失敗: \(error)") }
    let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000
    print(String(format: "  枯渇中の `await pool.read`: %.0f ms（%d 件）", ms, n))
    if ms < 500 {
        print("  → 協調プールの外で待っている。FileIO と同じ性質を持つ [NV6-01][NV6-04]")
    } else {
        print("  → ★協調プールを共有している。DB アクセスも FileIO 相当の逃がし先が要る")
    }

    // 枯渇中の書き込みも確かめる（書き込みは 1 本に直列化されるため別経路）
    let t0w = DispatchTime.now().uptimeNanoseconds
    _ = try? await pool.write { db in try db.execute(sql: "UPDATE label SET fileCount = fileCount WHERE rowid = 1") }
    print(String(format: "  枯渇中の `await pool.write`: %.0f ms",
                 Double(DispatchTime.now().uptimeNanoseconds - t0w) / 1_000_000))

    releasePool(hold, cores)

    // ④ 並行読み取り（WAL のリーダー並行性）
    let t1 = DispatchTime.now().uptimeNanoseconds
    await withTaskGroup(of: Int.self) { g in
        for _ in 0..<8 {
            g.addTask {
                (try? await pool.read { db in
                    try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM managedFile WHERE rating >= 3") ?? 0
                }) ?? -1
            }
        }
        for await _ in g {}
    }
    print(String(format: "  8 本の並行 read: %.0f ms（WAL のリーダー並行性）",
                 Double(DispatchTime.now().uptimeNanoseconds - t1) / 1_000_000))

    // ⑤ 書き込み中の読み取りがブロックされないこと（WAL）
    let t2 = DispatchTime.now().uptimeNanoseconds
    async let writer: Void = { try? await pool.write { db in
        try db.execute(sql: "UPDATE managedFile SET rating = rating WHERE rowid <= 20000") } }()
    try? await Task.sleep(nanoseconds: 5_000_000)
    let readMS = await { () -> Double in
        let s = DispatchTime.now().uptimeNanoseconds
        _ = try? await pool.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM managedFile") }
        return Double(DispatchTime.now().uptimeNanoseconds - s) / 1_000_000
    }()
    await writer
    print(String(format: "  書き込み中の read: %.0f ms（書き込み全体 %.0f ms）",
                 readMS, Double(DispatchTime.now().uptimeNanoseconds - t2) / 1_000_000))
}
