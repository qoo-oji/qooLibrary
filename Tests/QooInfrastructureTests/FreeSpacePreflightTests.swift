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
/// **`.serialized`**: この suite の各検証は使い捨てのディスクイメージを
/// 作って外す。並列に走らせると `hdiutil` が同時に何本も動いてディスクを
/// 圧迫し、FSEvents の到達を待つ別の検証（`DirectoryWatchIntegrationTests`）が
/// 10 秒の猶予でも間に合わなくなることがある。I/O 律速でそもそも並列にする
/// 価値が無いため直列にする。
@Suite(.serialized) struct FreeSpacePreflightTests {
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

    /// - Parameter fileSystem: `hdiutil` の `-fs` に渡す形式名。既定は APFS。
    ///   `"ExFAT"` などを渡すと、永続ファイル ID を持たないボリュームを作れる
    ///   （登録の可否を確かめるのに使う）。
    static func make(megabytes: Int, fileSystem: String = "APFS") -> TinyVolume? {
        let name = "QooTest\(UUID().uuidString.prefix(8))"
        let image = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).dmg")
        guard run("/usr/bin/hdiutil", [
            "create", "-quiet", "-size", "\(megabytes)m", "-fs", fileSystem, "-volname", name, image.path,
        ]) else { return nil }
        // **マウント先を volname から推測してはいけない。**
        // FAT（msdos）はボリューム名を大文字化するため、`QooTest1a2b` を渡すと
        // `/Volumes/QOOTEST1A` にマウントされる。推測して照合していたときは
        // 一致せず `nil` を返し、**FAT を使う検証がすべて静かに飛んでいた**
        // （しかもマウントしたまま画像が残った）。`attach` の出力から実際の
        // マウント先を取る。
        guard let mountPoint = attachAndReportMountPoint(image) else {
            _ = run("/usr/bin/hdiutil", ["detach", "-quiet", "-force", "/Volumes/\(name)"])
            try? FileManager.default.removeItem(at: image)
            return nil
        }
        return TinyVolume(mountPoint: mountPoint, imagePath: image)
    }

    func destroy() {
        _ = Self.run("/usr/bin/hdiutil", ["detach", "-quiet", "-force", mountPoint.path])
        try? FileManager.default.removeItem(at: imagePath)
    }

    /// いったん外して読み取り専用で付け直す。読み取り専用ボリュームに対する
    /// 挙動（登録の拒否など）を実際のボリュームで確かめるためのもの。
    /// 付け直せなければ `nil`（呼び出し側は検証を飛ばす）。
    ///
    /// - Returns: 読み取り専用でマウントされた場所。`destroy()` はこの
    ///   マウントも同じ場所を指すため、そのまま片付けられる。
    func remountReadOnly() -> URL? {
        guard Self.run("/usr/bin/hdiutil", ["detach", "-quiet", "-force", mountPoint.path]) else { return nil }
        guard Self.run("/usr/bin/hdiutil", [
            "attach", "-quiet", "-nobrowse", "-readonly", "-mountpoint", mountPoint.path, imagePath.path,
        ]) else { return nil }
        guard FileManager.default.fileExists(atPath: mountPoint.path) else { return nil }
        return mountPoint
    }

    /// `hdiutil attach` の出力から、実際にマウントされた場所を取る。
    /// 形式によって名前が変わる（FAT は大文字化）ため、推測は当てにならない。
    private static func attachAndReportMountPoint(_ image: URL) -> URL? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["attach", "-nobrowse", image.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, let text = String(data: data, encoding: .utf8) else { return nil }
        // 各行は「デバイス \t 種別 \t マウント先」。マウント先を持つ最後の行を使う。
        let mounts = text.split(separator: "\n").compactMap { line -> String? in
            guard let range = line.range(of: "/Volumes/") else { return nil }
            return String(line[range.lowerBound...]).trimmingCharacters(in: .whitespaces)
        }
        guard let last = mounts.last, FileManager.default.fileExists(atPath: last) else { return nil }
        return URL(fileURLWithPath: last, isDirectory: true)
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
