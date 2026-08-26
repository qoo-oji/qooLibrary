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
        reapStaleVolumesOnce
        let name = "QooTest\(UUID().uuidString.prefix(8))"
        let image = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).dmg")
        guard run("/usr/bin/hdiutil", [
            "create", "-quiet", "-size", "\(megabytes)m", "-fs", fileSystem, "-volname", name, image.path,
        ]) else { return nil }
        // **マウント先を明示する。**
        // FAT（msdos）は `-volname` を無視して「NO NAME」でマウントするため、
        // 名前から推測すると一致せず `nil` を返し、**FAT を使う検証がすべて
        // 静かに飛んでいた**。さらに複数同時に作ると「NO NAME 1」「NO NAME 2」
        // …と衝突し、外し損ねたボリュームが残り続けた（実際に 5 つ残した）。
        // `-mountpoint` で場所を固定すれば、形式に関係なく確実に外せる。
        let mountPoint = URL(fileURLWithPath: "/Volumes/\(name)", isDirectory: true)
        guard run("/usr/bin/hdiutil", [
            "attach", "-quiet", "-nobrowse", "-mountpoint", mountPoint.path, image.path,
        ]), FileManager.default.fileExists(atPath: mountPoint.path) else {
            _ = run("/usr/bin/hdiutil", ["detach", "-quiet", "-force", mountPoint.path])
            try? FileManager.default.removeItem(at: image)
            return nil
        }
        return TinyVolume(mountPoint: mountPoint, imagePath: image)
    }

    /// **前の実行が残した使い捨てボリュームを片付ける。**
    ///
    /// `destroy()` は `defer` から呼ばれるので、テストが異常終了したり
    /// 中断されたりすると通らない。残ったボリュームはマウント表に居座り、
    /// `MountTable` を読む検証や実測の前提を静かに汚す——実際に **10 本
    /// （イメージ約 1 GB）溜まり、利用者に指摘されて気づいた**。しかも
    /// `ReplaceBackupJournal` の記録がそのうちの 1 本を指したまま残り、
    /// 無関係なテストが落ち続ける原因にもなった。
    ///
    /// **同じ実行中のものを巻き込まないよう、十分に古いものだけを対象にする。**
    /// テストスイートは数十秒で終わるので、1 時間あれば取り違えようがない。
    /// `SecureExtractor.cleanupResidualStaging()` と同じ考え方——後片付けを
    /// 「必ず通る場所」に置けないなら、次の起動で拾う。
    private static let reapStaleVolumesOnce: Void = {
        let fileManager = FileManager.default
        let temp = fileManager.temporaryDirectory
        let cutoff = Date().addingTimeInterval(-3600)
        guard let entries = try? fileManager.contentsOfDirectory(
            at: temp, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for image in entries where image.lastPathComponent.hasPrefix("QooTest")
            && image.pathExtension == "dmg"
        {
            let modified = (try? image.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            guard let modified, modified < cutoff else { continue }
            let name = image.deletingPathExtension().lastPathComponent
            let mount = URL(fileURLWithPath: "/Volumes/\(name)", isDirectory: true)
            if isMounted(mount) {
                _ = run("/usr/bin/hdiutil", ["detach", "-quiet", "-force", mount.path])
            }
            try? fileManager.removeItem(at: image)
        }
    }()

    /// **外れたことを確かめるまで試し直し、それでも駄目なら黙らない。**
    ///
    /// 以前は 1 回 `detach` を投げて結果を捨てていたため、外し損ねても
    /// 誰も気づけなかった。実際にこの開発機で**ボリューム 4 本
    /// （バッキングイメージ約 1 GB）が並列実行のあとに残っていた**——
    /// あとから素の `hdiutil detach` を投げると即座に成功したので、
    /// 「原理的に外せない」のではなく**その瞬間だけ busy だった**もの。
    ///
    /// これは `NetworkVolumeIntegrationTests.Workspace.deinit` が
    /// 「後片付けも試し直す」形にしてあるのと同じ理由で、同じ轍である。
    /// 残ったボリュームはマウント表に居座り、`MountTable` を読む検証や
    /// 実測の前提を静かに汚す。
    func destroy() {
        let fileManager = FileManager.default
        for attempt in 0..<5 {
            guard Self.isMounted(mountPoint) else { break }
            if attempt > 0 { Thread.sleep(forTimeInterval: 0.2) }
            _ = Self.run("/usr/bin/hdiutil", ["detach", "-quiet", "-force", mountPoint.path])
        }
        if Self.isMounted(mountPoint) {
            // **握りつぶさない。** 見えない後始末の失敗は、次に測る人の
            // 前提を狂わせる（CLAUDE.md §6.1「自分の後片付けが先に踏むことがある」）。
            FileHandle.standardError.write(
                Data("[TinyVolume] 外せませんでした（手動で detach してください）: \(mountPoint.path)\n".utf8)
            )
        }
        try? fileManager.removeItem(at: imagePath)
        if fileManager.fileExists(atPath: imagePath.path) {
            FileHandle.standardError.write(
                Data("[TinyVolume] イメージを消せませんでした: \(imagePath.path)\n".utf8)
            )
        }
    }

    /// マウント表と突き合わせるだけ。**実体は見ない** — 外れた直後の
    /// `/Volumes/<名前>` は空のフォルダとして残ることがあり、
    /// `fileExists` では「まだ付いている」と誤判定する。
    private static func isMounted(_ mountPoint: URL) -> Bool {
        let mounted = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: nil, options: []
        ) ?? []
        return mounted.contains { $0.standardizedFileURL.path == mountPoint.standardizedFileURL.path }
    }

    /// **イメージは残したまま外す。** 「ボリュームが接続されていない」状態を
    /// 作るためのもので、`destroy()` と違って後から `reattach()` で戻せる。
    /// ブックマーク解決がマウントを起こすかどうかの検証に使う [NV-91]。
    func detachKeepingImage() -> Bool {
        Self.run("/usr/bin/hdiutil", ["detach", "-quiet", "-force", mountPoint.path])
    }

    /// `detachKeepingImage()` で外したものを付け直す。
    @discardableResult
    func reattach() -> Bool {
        Self.run("/usr/bin/hdiutil", [
            "attach", "-quiet", "-nobrowse", "-mountpoint", mountPoint.path, imagePath.path,
        ])
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
