import CoreGraphics
import Foundation
import Testing

@testable import QooInfrastructure
@testable import QooKit

/// フェーズ1完了時のリソースリーク・ファイル安全性監査 [CLAUDE.md §6] で
/// 修正した欠陥の回帰テスト。**標本は「実際に起こる形」にする**（§6.1）。
@Suite struct Phase1AuditRegressionTests {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("qoo-phase1-audit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 条件が満たされるまで待つ（時間ではなく状態で判定する既存方針）。
    private func waitUntil(
        _ what: Comment, timeout: Duration = .seconds(5), _ condition: () async -> Bool
    ) async {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
        Issue.record(what)
    }

    // MARK: - VolumeAccessStore: 取り消し時のスコープ解放 [監査 F-G]

    /// 解決の成否を後から切り替えられるフェイク（ボリュームの取り外しを模す）。
    final class FlippableBookmarkResolver: BookmarkResolving, @unchecked Sendable {
        private let lock = NSLock()
        private var failing = false

        func setFailing(_ value: Bool) {
            lock.lock()
            failing = value
            lock.unlock()
        }

        func makeBookmark(for url: URL) throws -> Data { Data(url.path.utf8) }

        func resolve(_ data: Data) -> BookmarkResolution {
            lock.lock()
            let failing = self.failing
            lock.unlock()
            guard !failing, let path = String(data: data, encoding: .utf8) else {
                return .offline(reason: .volumeNotMounted)
            }
            return .resolved(url: URL(fileURLWithPath: path), isStale: false)
        }

        func resolveAllowingMount(_ data: Data) -> BookmarkResolution { resolve(data) }

        func withAccess<T: Sendable>(
            _ data: Data, _ body: @Sendable (URL) async throws -> T
        ) async throws -> T {
            guard case .resolved(let url, _) = resolve(data) else {
                throw BookmarkAccessError.offline(.volumeNotMounted)
            }
            return try await body(url)
        }
    }

    /// 許可したボリュームが**外れている間に**取り消しても、開始したときの
    /// スコープが確実に閉じること。以前は取り消し時にブックマークを解決し直して
    /// おり、解決できないとスコープと参照カウントが取り残されていた。
    @Test func revokingAnUnresolvableGrantStillClosesItsScope() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("Target", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let resolver = FlippableBookmarkResolver()
        let store = VolumeAccessStore(
            storageURL: root.appendingPathComponent("state.json"), bookmarks: resolver
        )

        let granted = try await store.grantAccess(to: target, displayName: nil)
        #expect(await store.activeAccessCount() == 1)

        resolver.setFailing(true) // ボリュームが外れた
        try await store.revokeAccess(granted.id)

        #expect(await store.activeAccessCount() == 0)
        #expect(await store.grantedAccess().isEmpty)
    }

    // MARK: - ThumbnailService: キャンセルされた待機者が幻のスロットを得ない [監査 F-H]

    /// ローダーの中で待たせて「実行中」という状態を作るゲート。
    final class GatedVideoLoader: VideoThumbnailLoading, @unchecked Sendable {
        private let lock = NSLock()
        private var active = 0
        private var peak = 0
        private var waiters: [CheckedContinuation<Void, Never>] = []

        var maxObservedConcurrency: Int {
            lock.lock()
            defer { lock.unlock() }
            return peak
        }

        var activeCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return active
        }

        // `NSLock.lock()` は async 関数本体から呼べない（noasync）ため、
        // 同期ヘルパーへ退避する [1-16b で踏んだ既知の教訓]。
        private func enter() {
            lock.lock()
            active += 1
            peak = max(peak, active)
            lock.unlock()
        }

        private func park(_ continuation: CheckedContinuation<Void, Never>) {
            lock.lock()
            waiters.append(continuation)
            lock.unlock()
        }

        private func leave() {
            lock.lock()
            active -= 1
            lock.unlock()
        }

        func makeThumbnail(for url: URL, maxPixelSize: Int) async -> CGImage? {
            enter()
            await withCheckedContinuation { continuation in
                park(continuation)
            }
            leave()
            return nil
        }

        func releaseOne() {
            lock.lock()
            let continuation = waiters.isEmpty ? nil : waiters.removeFirst()
            lock.unlock()
            continuation?.resume()
        }
    }

    /// スロット待ちの途中でキャンセルされたリクエストが、幻のスロットを
    /// 獲得して後続の待機者を上限超過で走らせないこと。以前は
    /// `maxConcurrent + キャンセル数` 本のデコードが同時に走り得た
    /// （高速スクロールで実際に起こる形）。
    @Test func cancelledWaiterDoesNotGrantAPhantomSlot() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["a.mp4", "b.mp4", "c.mp4"] {
            try Data("video".utf8).write(to: root.appendingPathComponent(name))
        }
        let loader = GatedVideoLoader()
        let service = ThumbnailService(
            maxConcurrent: 1,
            cache: DefaultCoverImageCache(baseDirectory: root.appendingPathComponent("cache")),
            videoThumbnailLoader: loader
        )

        // A がスロットを取り、ローダーの中で止まる。
        let taskA = Task { await service.thumbnail(for: root.appendingPathComponent("a.mp4"), maxPixelSize: 50) }
        await waitUntil("A がローダーに入らない") { loader.activeCount == 1 }

        // B・C がスロット待ちに並ぶ。
        let taskB = Task { await service.thumbnail(for: root.appendingPathComponent("b.mp4"), maxPixelSize: 50) }
        await waitUntil("B が待ちに並ばない") { await service.pendingWaiterCount() == 1 }
        let taskC = Task { await service.thumbnail(for: root.appendingPathComponent("c.mp4"), maxPixelSize: 50) }
        await waitUntil("C が待ちに並ばない") { await service.pendingWaiterCount() == 2 }

        // B をキャンセル → B は起こされ、スロットを取らずに降りる。
        taskB.cancel()
        let cancelledResult = await taskB.value
        #expect(cancelledResult == nil)

        // 旧実装では B の幻のスロット解放が C を起こし、A と並んで
        // 2 本目のデコードが走っていた。C はまだ待っているのが正しい。
        await waitUntil("B の分の待ちが減らない") { await service.pendingWaiterCount() == 1 }
        #expect(loader.activeCount == 1)

        // A を終わらせると C が順番どおり動き、同時実行は常に 1 本のまま。
        loader.releaseOne()
        await waitUntil("C がローダーに入らない") {
            let waiting = await service.pendingWaiterCount()
            return loader.activeCount == 1 && waiting == 0
        }
        loader.releaseOne()
        _ = await taskA.value
        _ = await taskC.value
        #expect(loader.maxObservedConcurrency == 1)
    }

    // MARK: - AppAssociationStore: 旧形式の関連付けは一覧にも載る [監査 F-AC]

    @Test func legacyAssociationsAppearInTheExtensionList() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let storageURL = root.appendingPathComponent("appAssociations.json")
        // 拡張前（`[String: String]` 単体）の旧形式。mkv の関連付けを持つ。
        try Data(#"{"mkv": "com.example.player"}"#.utf8).write(to: storageURL)
        let store = AppAssociationStore(storageURL: storageURL)

        let extensions = await store.extensions()

        // 関連付けを持つ拡張子が一覧に載らないと、「ビューア」タブから
        // 確認も変更もできない迷子の設定になる。
        #expect(extensions.contains("mkv"))
        #expect(extensions.contains("zip")) // 既定の 8 形式も従来どおり合流する
    }

    // MARK: - nextAvailableName: リンク切れシンボリックリンクとの衝突 [監査 F-T]

    @Test func keepBothSkipsOverADanglingSymlinkOccupyingTheCandidateName() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceDir = root.appendingPathComponent("src", isDirectory: true)
        let destDir = root.appendingPathComponent("dest", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        try Data("new".utf8).write(to: sourceDir.appendingPathComponent("photo.txt"))
        try Data("old".utf8).write(to: destDir.appendingPathComponent("photo.txt"))
        // 候補名 "photo 2.txt" をリンク切れのシンボリックリンクが占めている。
        // `fileExists` はリンクを辿るため、以前は「空いている」と誤判定して
        // COPYFILE_EXCL が EEXIST で失敗していた。
        try FileManager.default.createSymbolicLink(
            at: destDir.appendingPathComponent("photo 2.txt"),
            withDestinationURL: destDir.appendingPathComponent("no-such-target.txt")
        )

        let receipts = try await FileOperationService().copy(
            [sourceDir.appendingPathComponent("photo.txt")],
            to: destDir,
            options: OpOptions(conflictPolicy: .keepBoth)
        )

        #expect(receipts.count == 1)
        #expect(receipts.first?.toURL.lastPathComponent == "photo 3.txt")
        #expect(FileManager.default.fileExists(atPath: destDir.appendingPathComponent("photo 3.txt").path))
    }

    // MARK: - restoreFromTrash: 部分成功の受領書 [監査 F-Q]

    @Test func restoreFromTrashCarriesReceiptsOfAlreadyRestoredItems() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let trashLike = root.appendingPathComponent("trash", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: trashLike, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try Data("1".utf8).write(to: trashLike.appendingPathComponent("one.txt"))
        try Data("2".utf8).write(to: trashLike.appendingPathComponent("two.txt"))
        // 2 件目の戻り先は既に別の項目が占めている → 途中で失敗する。
        try Data("occupied".utf8).write(to: home.appendingPathComponent("two.txt"))
        let receipts = [
            TrashReceipt(
                originalURL: home.appendingPathComponent("one.txt"),
                trashURL: trashLike.appendingPathComponent("one.txt"), identity: nil
            ),
            TrashReceipt(
                originalURL: home.appendingPathComponent("two.txt"),
                trashURL: trashLike.appendingPathComponent("two.txt"), identity: nil
            ),
        ]

        do {
            _ = try await FileOperationService().restoreFromTrash(receipts)
            Issue.record("失敗するはずの復元が成功した")
        } catch let partial as PartialTransferFailure {
            // 戻せた 1 件目の受領書は失敗の中に運ばれてくる（Undo・履歴用）。
            #expect(partial.receipts.count == 1)
            #expect(partial.receipts.first?.toURL.lastPathComponent == "one.txt")
        }
        #expect(FileManager.default.fileExists(atPath: home.appendingPathComponent("one.txt").path))
    }

    // MARK: - 同一ボリューム内の移動は空き容量を要求しない [監査 F-V]

    /// クローン非対応（exFAT）のボリュームで、空き容量より大きいファイルを
    /// **同じボリューム内で**移動できること。移動は `rename(2)` で 1 バイトも
    /// 書かないのに、以前は総量の走査結果と空きを比べて誤って断っていた。
    @Test func movingWithinAVolumeDoesNotRequireFreeSpace() async throws {
        // 作れない環境では飛ばす（`FreeSpacePreflightTests` と同じ方針）。
        // **黙って飛ばさず 1 行残す** — この検証が空振りしていないかを、
        // 実行環境ごとに確かめられるようにするため [§6.1]。
        guard let volume = TinyVolume.make(megabytes: 100, fileSystem: "ExFAT") else {
            FileHandle.standardError.write(
                Data("[Phase1AuditRegressionTests] TinyVolume を作れないため、同一ボリューム移動の検証を飛ばしました\n".utf8)
            )
            return
        }
        defer { volume.destroy() }
        let bigFile = volume.mountPoint.appendingPathComponent("big.bin")
        // ボリュームの空きの大半を使うファイル（残りの空きより大きい）。
        let payload = Data(count: 60 * 1024 * 1024)
        try payload.write(to: bigFile)
        let subfolder = volume.mountPoint.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: subfolder, withIntermediateDirectories: true)

        let receipts = try await FileOperationService().move([bigFile], to: subfolder)

        #expect(receipts.count == 1)
        #expect(FileManager.default.fileExists(atPath: subfolder.appendingPathComponent("big.bin").path))
    }
}
