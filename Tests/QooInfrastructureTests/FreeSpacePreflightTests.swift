import Foundation
import QooKit
import Testing

@testable import QooInfrastructure

/// **空きが足りないと分かっているなら、1 バイトも書かずに断る** [ER-03]。
///
/// 実機で 4GB のファイルを空き 2.8GB のボリュームへコピーしたとき、そのまま
/// 書き始めて 2.91GB まで進んでから失敗していた。中途半端に書いた分は
/// `copyfile` が後始末するので残骸は出ないが、**数分待たせた末に失敗する**うえ、
/// その間ボリュームの空きを食い潰す。Finder は開始前に確かめて断る。
///
/// この検証は実際に小さなボリューム（ディスクイメージ）を作って行う —
/// 空き容量の判定は「同一ボリュームならクローンで済むので数えない」という
/// 分岐と組み合わさっており、一時ディレクトリ（＝同じボリューム）では
/// そもそも検査が走らないため、偽物では確かめられない。
///
/// ディスクイメージを作れない環境では静かに飛ばす（CI の実行環境に
/// `hdiutil` の可否を前提として持ち込まない）。
@Suite struct FreeSpacePreflightTests {
    @Test func refusesBeforeWritingAnythingWhenTheDestinationIsTooSmall() async throws {
        guard let volume = TinyVolume.make(megabytes: 20) else { return }
        defer { volume.destroy() }

        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("qoo-preflight-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: source) }
        try Data(count: 40 * 1_000 * 1_000).write(to: source)

        let service = FileOperationService()
        var thrown: (any Error)?
        do {
            _ = try await service.copy([source], to: volume.mountPoint, options: OpOptions(conflictPolicy: .keepBoth))
        } catch {
            thrown = error
        }

        let error = try #require(thrown as? FileOperationError)
        guard case let .insufficientFreeSpace(required, available, _) = error else {
            Issue.record("容量不足として断られなかった: \(error)")
            return
        }
        #expect(required >= 40 * 1_000 * 1_000)
        #expect(available < required)
        // 理由がそのまま読める文言であること（「エラー2」に潰れない）[ER-03]。
        #expect(error.localizedDescription.contains("空き容量"))

        // **1 バイトも書いていない**こと。これがこの検証の主眼。
        let written = try FileManager.default.contentsOfDirectory(
            at: volume.mountPoint, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )
        #expect(written.isEmpty, "書き込み先に残骸がある: \(written.map(\.lastPathComponent))")
    }

    /// 逆方向の固定 — 余裕があれば当然通る。事前検査が厳しすぎて正当な
    /// コピーまで断る退行（余裕の見積もりを大きくしすぎる等）を捕まえる。
    @Test func allowsACopyThatFitsWithRoomToSpare() async throws {
        guard let volume = TinyVolume.make(megabytes: 200) else { return }
        defer { volume.destroy() }

        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("qoo-preflight-fits-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: source) }
        try Data(count: 20 * 1_000 * 1_000).write(to: source)

        let service = FileOperationService()
        let receipts = try await service.copy(
            [source], to: volume.mountPoint, options: OpOptions(conflictPolicy: .keepBoth)
        )
        #expect(receipts.count == 1)
        #expect(FileManager.default.fileExists(atPath: volume.mountPoint.appendingPathComponent(source.lastPathComponent).path))
    }
}

/// 検証用の小さなボリューム。`hdiutil` のディスクイメージを一時的に
/// マウントする。作れなければ `nil`（呼び出し側は検証を飛ばす）。
struct TinyVolume {
    let mountPoint: URL
    private let imagePath: URL

    static func make(megabytes: Int) -> TinyVolume? {
        let name = "QooTest\(UUID().uuidString.prefix(8))"
        let image = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).dmg")
        guard run("/usr/bin/hdiutil", [
            "create", "-quiet", "-size", "\(megabytes)m", "-fs", "APFS", "-volname", name, image.path,
        ]) else { return nil }
        guard run("/usr/bin/hdiutil", ["attach", "-quiet", "-nobrowse", image.path]) else {
            try? FileManager.default.removeItem(at: image)
            return nil
        }
        let mountPoint = URL(fileURLWithPath: "/Volumes/\(name)", isDirectory: true)
        guard FileManager.default.fileExists(atPath: mountPoint.path) else {
            try? FileManager.default.removeItem(at: image)
            return nil
        }
        return TinyVolume(mountPoint: mountPoint, imagePath: image)
    }

    func destroy() {
        _ = Self.run("/usr/bin/hdiutil", ["detach", "-quiet", "-force", mountPoint.path])
        try? FileManager.default.removeItem(at: imagePath)
    }

    @discardableResult
    private static func run(_ path: String, _ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}
