import Foundation
import QooKit
import Testing

@testable import QooInfrastructure

/// **書き込み先が扱えない大きさのファイルは、運び始める前に断る** [ER-03]。
///
/// FAT32 の上限は 4GB 弱。動画ファイルでは普通に超えるため、USB メモリへ
/// 運ぼうとして 4GB 書いたところで失敗する、という無駄が現実に起こる。
///
/// ## 実測
/// - `volumeMaximumFileSize` は FAT32 で **4.29 GB** を返す（OS が答えるので
///   推測は要らない）。APFS は 36 PB、HFS+/exFAT は 9.2 EB。
/// - 上限を超える大きさへ `ftruncate` すると **`EFBIG`（27, File too large）**
///   で拒否される。4.0 GB は通る。
///
/// ## 4GB のファイルを作らずに検証する
/// 実際に 4GB を書くと時間もディスクも食う。**スパースファイル**なら、
/// 論理サイズだけ大きくして実占有はほぼ 0 にできる。事前検査が見るのは
/// `fileSize`（論理サイズ）なので、これで十分に確かめられる。
/// スパースにできない環境では静かに飛ばす。
/// **`.serialized`**: この suite の各検証は使い捨てのディスクイメージを
/// 作って外す。並列に走らせると `hdiutil` が同時に何本も動いてディスクを
/// 圧迫し、FSEvents の到達を待つ別の検証（`DirectoryWatchIntegrationTests`）が
/// 10 秒の猶予でも間に合わなくなることがある。I/O 律速でそもそも並列にする
/// 価値が無いため直列にする。
@Suite(.serialized) struct FileSizeLimitPreflightTests {
    /// 論理サイズだけ大きいファイルを作る（実占有はほぼ 0）。
    private func makeSparseFile(at url: URL, logicalSize: Int64) -> Bool {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { return false }
        guard let handle = try? FileHandle(forWritingTo: url) else { return false }
        defer { try? handle.close() }
        do { try handle.truncate(atOffset: UInt64(logicalSize)) } catch { return false }
        let actual = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        return Int64(actual) == logicalSize
    }

    @Test func refusesAFileLargerThanTheDestinationCanHold() async throws {
        guard let volume = TinyVolume.make(megabytes: 60, fileSystem: "MS-DOS FAT32") else { return }
        defer { volume.destroy() }
        // この形式が実際に上限を申告することを前提にする（申告しないなら検査対象外）。
        let limit = (try? volume.mountPoint.resourceValues(forKeys: [.volumeMaximumFileSizeKey]))?
            .volumeMaximumFileSize ?? 0
        guard limit > 0, limit < 100 * 1_000_000_000 else { return }

        // 上限を超える「論理サイズ」のファイルを、実占有ほぼ 0 で作る。
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("qoo-huge-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: source) }
        guard makeSparseFile(at: source, logicalSize: Int64(limit) + 1_000_000) else { return }

        let service = FileOperationService()
        var thrown: (any Error)?
        do {
            _ = try await service.copy([source], to: volume.mountPoint, options: OpOptions(conflictPolicy: .keepBoth))
        } catch {
            thrown = error
        }

        let error = try #require(thrown as? FileOperationError)
        guard case let .fileTooLargeForDestination(_, size, reportedLimit, _) = error else {
            Issue.record("大きさの上限として断られなかった: \(error)")
            return
        }
        #expect(size > reportedLimit)
        // 理由と次の手が読める文言であること [ER-03]。
        #expect(error.localizedDescription.contains("上限"))
        #expect(error.localizedDescription.contains("exFAT"))

        // **1 バイトも書いていない**こと。これがこの検証の主眼。
        let written = try FileManager.default.contentsOfDirectory(
            at: volume.mountPoint, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )
        #expect(written.isEmpty, "書き込み先に残骸がある: \(written.map(\.lastPathComponent))")
    }

    /// 逆方向の固定 — 上限に収まるファイルは当然通ること。
    /// 検査が厳しすぎて正当なコピーまで断る退行を捕まえる。
    @Test func allowsAFileWithinTheLimit() async throws {
        guard let volume = TinyVolume.make(megabytes: 60, fileSystem: "MS-DOS FAT32") else { return }
        defer { volume.destroy() }

        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("qoo-small-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: source) }
        try Data(count: 1_000_000).write(to: source)

        let service = FileOperationService()
        let receipts = try await service.copy(
            [source], to: volume.mountPoint, options: OpOptions(conflictPolicy: .keepBoth)
        )
        #expect(receipts.count == 1)
    }

    /// 上限の大きい形式（APFS）では、同じ大きさでも当然通ること。
    /// 「大きいファイルはいつも断られる」という取り違えを防ぐ。
    @Test func theSameFileIsAcceptedOnAVolumeWithNoPracticalLimit() async throws {
        guard let volume = TinyVolume.make(megabytes: 60) else { return }
        defer { volume.destroy() }
        let limit = (try? volume.mountPoint.resourceValues(forKeys: [.volumeMaximumFileSizeKey]))?
            .volumeMaximumFileSize ?? 0
        // APFS は実測で 36 PB。ここが小さいなら前提が変わっている。
        #expect(limit > 1_000_000_000_000)

        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("qoo-sparse-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: source) }
        guard makeSparseFile(at: source, logicalSize: 5_000_000_000) else { return }

        // 大きさの上限では断られないこと（空き容量では断られる — それは別の検査）。
        let service = FileOperationService()
        var thrown: (any Error)?
        do {
            _ = try await service.copy([source], to: volume.mountPoint, options: OpOptions(conflictPolicy: .keepBoth))
        } catch {
            thrown = error
        }
        if case .fileTooLargeForDestination = thrown as? FileOperationError {
            Issue.record("上限の大きいボリュームで、大きさを理由に断られた")
        }
    }
}
