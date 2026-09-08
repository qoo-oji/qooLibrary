#if DEBUG
import AppKit
import Foundation

/// 制御口が受けた 1 行を、メインスレッドで実行してから応答を返す [MT-33]。
///
/// **`Task { @MainActor in … }` でも `DispatchQueue.main.async` でもなく
/// `RunLoop.main.perform(inModes: [.common])` を使う。** どちらもメインキューの
/// ドレインを必要とするので、AppKit が入れ子のイベントループを回している間
/// （`terminate:` の返答待ち、モーダルの追跡）は一度も走らない — 口が
/// いちばん要る場面で応答しなくなる。ランループのブロックなら共通モードで
/// 実行されるので、その穴に落ちない（`BackupRestoreAction` が
/// `NSApp.terminate` で踏んだ穴と同じもの）。
enum ControlDispatcher {
    /// メインが応答しないときにワーカーを永久に待たせないための上限。
    /// 走査のような時間のかかる操作は、コマンド側が非同期に投げて即座に
    /// 返す形にすること（この上限を伸ばして待つのではない）。
    static let mainHopTimeout: TimeInterval = 10

    static func dispatchOnMain(_ line: Data) -> Data {
        let box = ResponseBox()
        let semaphore = DispatchSemaphore(value: 0)
        RunLoop.main.perform(inModes: [.common]) {
            let response = MainActor.assumeIsolated { ControlCommands.run(line) }
            box.store(response)
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + mainHopTimeout) == .success else {
            return ControlResponse.failure(
                "メインスレッドが \(Int(mainHopTimeout)) 秒以内に応答しませんでした")
        }
        return box.take() ?? ControlResponse.failure("応答が空でした")
    }
}

/// ワーカースレッドとメインスレッドの間で `Data` を 1 つ受け渡す器。
/// 上限時間で見捨てたあとにメイン側が書いても安全なように、ロックで守る。
private final class ResponseBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Data?

    func store(_ data: Data) {
        lock.lock()
        value = data
        lock.unlock()
    }

    func take() -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
#endif
