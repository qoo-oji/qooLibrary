import Foundation
import QooKit

/// 細かい進捗報告を間引き、totals（総数・総バイト数）を後から足す包み。
///
/// アーカイブのバックエンドは「今何件目・何バイト目か」しか知らない
/// （総数を知るには別途一覧を読む必要があり、二重に走査させたくない）。
/// 総数を知っているのは呼び出し側（`SecureExtractor`/`ArchiveCompressor`）
/// なので、そちらでここに包んでから渡す。
///
/// 間引きは `ProgressTracker` と同じ 10 回/秒。1000 ページの cbz を展開すると
/// エントリ単位で 1000 回、バイト単位ではさらに桁が増えるため、そのまま
/// メインアクタへ流すと更新だけで忙しくなる。
enum ProgressThrottle {
    /// 報告の最短間隔。`ProgressTracker.updateInterval` と揃える。
    private static let interval: Duration = .milliseconds(100)

    /// - Parameters:
    ///   - totalItems: 総項目数（0 なら埋めない）
    ///   - totalBytes: 総バイト数（0 なら不定進捗のまま）
    static func wrap(
        _ inner: ProgressReporter,
        totalItems: Int,
        totalBytes: Int64
    ) -> ProgressReporter {
        let gate = Gate()
        return ProgressReporter { partial in
            var value = partial
            if totalItems > 0 { value.totalItems = totalItems }
            if totalBytes > 0 { value.totalBytes = totalBytes }
            // 最後の 1 件は必ず通す（「999/1000 で止まったまま終わった」を防ぐ）。
            let isFinal = totalItems > 0 && value.completedItems >= totalItems
            guard gate.allows(force: isFinal) else { return }
            inner.report(value)
        }
    }

    /// 時刻を持つだけの箱。`ProgressReporter` のクロージャは `@Sendable` で、
    /// バックエンドは任意のスレッドから報告し得るので鍵で守る。
    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var lastReportedAt: ContinuousClock.Instant?

        func allows(force: Bool) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            let now = ContinuousClock.now
            if !force, let last = lastReportedAt, now - last < ProgressThrottle.interval { return false }
            lastReportedAt = now
            return true
        }
    }
}
