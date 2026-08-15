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
@Suite struct PauseIntegrationTests {
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
