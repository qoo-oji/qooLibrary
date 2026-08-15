import Foundation
import QooKit
import Testing

@testable import QooInfrastructure

/// 一時停止がコピーの経路まで実際に効くこと [ユーザー要望]。
///
/// **クリックによる実機確認では捕まえられない**ため自動テストにしている —
/// 一時停止できる長さの転送を用意しても、押すまでの数秒で終わってしまう
/// （実機では実際にそれで取り逃した）。ここでは**先に止めてから始める**ことで
/// 競争を排除する。
///
/// この経路が特に大事なのは、コピーだけは `copyfile(3)` の status コールバック
/// （同期の C 関数）の中で待つ形になっており、他の 2 つ（圧縮・展開は自前の
/// ループ）と仕組みが違うため。
///
/// ディスクイメージを作れない環境では静かに飛ばす（`FreeSpacePreflightTests`
/// と同じ `TinyVolume` を使う）。
/// **`.serialized`**: この suite の各検証は使い捨てのディスクイメージを
/// 作って外す。並列に走らせると `hdiutil` が同時に何本も動いてディスクを
/// 圧迫し、FSEvents の到達を待つ別の検証（`DirectoryWatchIntegrationTests`）が
/// 10 秒の猶予でも間に合わなくなることがある。I/O 律速でそもそも並列にする
/// 価値が無いため直列にする。
@Suite(.serialized) struct PauseIntegrationTests {
    @Test func pausedCopyDoesNotMoveAnyBytesUntilResumed() async throws {
        guard let volume = TinyVolume.make(megabytes: 300) else { return }
        defer { volume.destroy() }

        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("qoo-pause-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: source) }
        let payload = 80 * 1_000 * 1_000
        try Data(count: payload).write(to: source)

        let observed = ByteWatcher()
        let token = PauseToken()
        token.pause() // **始める前に止めておく**

        let service = FileOperationService()
        let options = OpOptions(
            conflictPolicy: .keepBoth,
            progress: ProgressReporter { observed.note($0.completedBytes) },
            pauseToken: token
        )
        let copying = Task { try await service.copy([source], to: volume.mountPoint, options: options) }

        // 止めたまま待っても 1 バイトも進まないこと。
        try await Task.sleep(for: .milliseconds(700))
        #expect(observed.max == 0, "一時停止中なのに \(observed.max) バイト進んだ")
        #expect(token.isPaused)

        token.resume()
        let receipts = try await copying.value
        #expect(receipts.count == 1)
        let copied = volume.mountPoint.appendingPathComponent(source.lastPathComponent)
        let size = (try? copied.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
        #expect(size == payload, "再開後に最後まで運べていない")
    }

    /// 止めたままでも取り消せること。**これが無いと、一時停止した処理を
    /// 二度と止められない**（`PauseToken` の設計の要）。
    @Test func pausedCopyCanStillBeCancelled() async throws {
        guard let volume = TinyVolume.make(megabytes: 300) else { return }
        defer { volume.destroy() }

        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("qoo-pause-cancel-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: source) }
        try Data(count: 80 * 1_000 * 1_000).write(to: source)

        let token = PauseToken()
        token.pause()
        let service = FileOperationService()
        let options = OpOptions(conflictPolicy: .keepBoth, pauseToken: token)
        let copying = Task { try await service.copy([source], to: volume.mountPoint, options: options) }

        try await Task.sleep(for: .milliseconds(400))
        copying.cancel()

        // 取り消しから数秒のうちに終わること（終わらなければ、止めた処理を
        // 止められないという最悪の状態なので、見張りを付けて明示的に失敗させる）。
        let finished = await withTaskGroup(of: Bool.self) { group in
            group.addTask { _ = try? await copying.value; return true }
            group.addTask {
                try? await Task.sleep(for: .seconds(5))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        #expect(finished, "一時停止中に取り消しても終わらない")
        // 中断した項目は運ばれていない（`copyfile` が書きかけを片付ける）。
        let copied = volume.mountPoint.appendingPathComponent(source.lastPathComponent)
        #expect(!FileManager.default.fileExists(atPath: copied.path))
    }

    /// **中断したフォルダのコピーは、書きかけを残さない。**
    ///
    /// `copyfile(3)` は 1 ファイルなら書きかけの宛先を自分で片付けるが、
    /// **再帰的なフォルダコピーを中断した場合は途中まで作った木を残す**
    /// （1.1GB のアーカイブ展開を止めたあと 134MB の中途半端なフォルダが
    /// 残って発覚）。運び終えていない項目は受領書も返らない＝ Undo にも
    /// 残らないので、`transfer` が消さなければ誰も片付けられない。
    ///
    /// **一時停止を使って「途中で止まった状態」を確実に作る。** 素朴に
    /// 「コピー中に取り消す」と書くと、速いディスクではコピーが先に
    /// 終わってしまい、何も検証しないまま通る。
    @Test func cancellingAPausedFolderCopyLeavesNoPartialTree() async throws {
        guard let volume = TinyVolume.make(megabytes: 300) else { return }
        defer { volume.destroy() }

        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("qoo-partial-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: source) }
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        for index in 0..<40 {
            try Data(count: 2_000_000).write(to: source.appendingPathComponent("page\(index).bin"))
        }

        let observed = ByteWatcher()
        let token = PauseToken()
        let service = FileOperationService()
        // **最初のバイトが報告された「その場で」止める。**
        //
        // 以前は「バイトが動き出すのをポーリングで待ってから `pause()`」と
        // していたが、それでは 80MB のコピーが気づくより先に終わってしまう
        // ことがあり、`.completed`（正しく残る）と `.cancelled`（消えるべき）を
        // 取り違えて不定期に落ちていた。報告はコピーと同じスレッドから同期的に
        // 来るので、ここで止めれば以降は最大 1 チャンクしか進まない。
        //
        // **`completedBytes > 0` を条件にする。** 進捗は開始時と項目の
        // 切り替わりでも報告され、そのときはまだ 0 バイト。0 で止めると
        // 1 バイトも書かれず、「途中の状態」自体が作れない。
        let options = OpOptions(
            conflictPolicy: .keepBoth,
            progress: ProgressReporter { progress in
                guard progress.completedBytes > 0 else { return }
                if observed.max == 0 { token.pause() }
                observed.note(progress.completedBytes)
            },
            pauseToken: token
        )
        let copying = Task { try await service.copy([source], to: volume.mountPoint, options: options) }

        for _ in 0..<600 where observed.max == 0 {
            try? await Task.sleep(for: .milliseconds(10))
        }
        try? await Task.sleep(for: .milliseconds(200))
        // 止まっていること（＝まだ終わっていないこと）をここで確かめておく。
        // これが崩れると、以降の検証は「消えるべきものが消えたか」ではなく
        // 「完了したものが残っているか」を見てしまう。
        #expect(!copying.isCancelled)
        let midway = observed.max
        try? await Task.sleep(for: .milliseconds(150))
        #expect(observed.max == midway, "一時停止が効いておらず、コピーが進み続けている")

        let destination = volume.mountPoint.appendingPathComponent(source.lastPathComponent)
        #expect(FileManager.default.fileExists(atPath: destination.path), "途中の状態を作れていない")

        copying.cancel()
        _ = try? await copying.value
        #expect(
            !FileManager.default.fileExists(atPath: destination.path),
            "中断したのに書きかけのフォルダが残っている"
        )
    }

    /// 報告されたバイト数の最大値を覚えるだけの箱（報告は任意のスレッドから来る）。
    private final class ByteWatcher: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Int64 = 0
        var max: Int64 {
            lock.lock(); defer { lock.unlock() }
            return value
        }
        func note(_ bytes: Int64) {
            lock.lock(); defer { lock.unlock() }
            value = Swift.max(value, bytes)
        }
    }
}
