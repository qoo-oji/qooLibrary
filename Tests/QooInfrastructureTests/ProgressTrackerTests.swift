import Foundation
import QooKit
import Testing

@testable import QooInfrastructure

/// 進捗の間引き（`ProgressTracker`）の境界挙動。
@Suite struct ProgressTrackerTests {
    /// **項目の最初のバイトは間引かずに送る（leading edge）。**
    ///
    /// `startItem` が `lastReportedAt` を更新するため、素朴な間引きだと項目
    /// 開始から 100ms 以内のバイト報告はすべて捨てられる——速いディスクでは
    /// 1 項目のコピー全体がその窓に収まり、**「コピーの最中」の報告が 1 度も
    /// 出ない**。CI（ページキャッシュに乗ったスパースイメージ）で実際に起き、
    /// 「最中を観測する」統合テスト 2 件が「最初に届く `completedBytes > 0` の
    /// 報告＝完了報告」を最中と取り違えて落ちた。
    @Test func theFirstBytesOfAnItemAreReportedImmediately() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("qoo-progress-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let item = dir.appendingPathComponent("a.bin")
        try Data(count: 8).write(to: item)

        let collected = CollectedReports()
        let tracker = ProgressTracker(
            reporter: ProgressReporter { collected.note($0) }, items: [item], destination: dir
        )
        tracker.begin()
        tracker.startItem(item)
        tracker.addBytes(1) // startItem の直後（100ms 未満）——それでも届くこと
        tracker.addBytes(1) // こちらは通常の間引きで捨てられること

        let bytes = collected.completedBytesValues()
        #expect(bytes.contains(1), "項目の最初のバイト報告が間引かれている")
        #expect(!bytes.contains(2), "2 回目のバイト報告まで素通ししている（間引きが死んでいる）")
    }

    /// 項目が切り替わったら、次の項目の最初のバイトもまた即時に送る。
    @Test func theLeadingEdgeResetsForEachItem() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("qoo-progress-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = dir.appendingPathComponent("a.bin")
        let second = dir.appendingPathComponent("b.bin")
        try Data(count: 8).write(to: first)
        try Data(count: 8).write(to: second)

        let collected = CollectedReports()
        let tracker = ProgressTracker(
            reporter: ProgressReporter { collected.note($0) }, items: [first, second], destination: dir
        )
        tracker.begin()
        tracker.startItem(first)
        tracker.addBytes(1)
        tracker.finishItem()
        tracker.startItem(second)
        tracker.addBytes(1) // 前の報告から 100ms 経っていなくても、新しい項目の最初なので届く

        #expect(collected.completedBytesValues().contains(2), "2 項目目の最初のバイト報告が間引かれている")
    }

    /// **バイトを書かない操作（同一ボリューム内の移動）は総量を数えない**
    /// [フェーズ1完了時の監査で追加]。`requiredBytes` が nil であることが
    /// 「空き容量の事前検査を掛けない」ことの根拠になる — 同一ボリューム内の
    /// 移動は `rename(2)` で 1 バイトも書かないのに、クローン非対応の
    /// ボリューム（exFAT/SMB）では総量と空きを比べて誤って断っていた。
    @Test func writesNoBytesSkipsMeasurementAndFreeSpaceRequirement() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("qoo-tracker-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("payload.bin")
        try Data(count: 1_000_000).write(to: file)

        let measured = ProgressTracker(reporter: nil, items: [file], destination: dir)
        let notMeasured = ProgressTracker(reporter: nil, items: [file], destination: dir, writesNoBytes: true)

        // 対照: 通常の経路では実サイズが数えられる（この環境の一時ディレクトリは
        // クローン対応の APFS なので、`willBeInstant` が効くと両方 nil になり
        // 比較にならない。その場合はこの対照を諦める）。
        if measured.requiredBytes != nil {
            #expect(measured.requiredBytes == 1_000_000)
        }
        #expect(notMeasured.requiredBytes == nil)
        #expect(notMeasured.deepestRelativePath == nil)
        #expect(notMeasured.largestFile == nil)
    }
}

/// 報告を集めるだけの箱（報告は任意のスレッドから来る）。
private final class CollectedReports: @unchecked Sendable {
    private let lock = NSLock()
    private var reports: [OperationProgress] = []

    func note(_ progress: OperationProgress) {
        lock.lock()
        reports.append(progress)
        lock.unlock()
    }

    func completedBytesValues() -> [Int64] {
        lock.lock()
        defer { lock.unlock() }
        return reports.map(\.completedBytes)
    }
}
