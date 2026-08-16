import Foundation
import Testing

@testable import QooInfrastructure

/// 経路の照合と剪定 [10章 §10.0]。実際の FSEvents を使わず、
/// `noteLocalChanges(at:)`（自プロセスの変更を伝える入口）で振り分けを検証する。
@MainActor
@Suite struct DirectoryChangeHubTests {
    private func makeHub() -> DirectoryChangeHub {
        // ネットワークボリュームのポーリングは前面判定に依存するため、
        // テストからは常に前面として扱う（`NSApplication` に触れない）。
        DirectoryChangeHub(isApplicationActive: { true })
    }

    private func makeDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("qoo-watch-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - 振り分け

    @Test func shallowObservationSeesItsDirectChildren() {
        let hub = makeHub()
        let folder = makeDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let watch = DirectoryObservation(hub: hub)
        watch.watch(folder, scope: .shallow)

        hub.noteLocalChanges(at: [folder.appendingPathComponent("a.txt")])

        #expect(watch.generation == 1)
    }

    @Test func shallowObservationIgnoresChangesDeeperThanItsDirectChildren() {
        let hub = makeHub()
        let folder = makeDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let watch = DirectoryObservation(hub: hub)
        watch.watch(folder, scope: .shallow)

        hub.noteLocalChanges(at: [folder.appendingPathComponent("sub/deep/a.txt")])

        #expect(watch.generation == 0)
    }

    /// 表示中のフォルダ自身が消えた・改名されたときも読み直す必要がある
    /// （`WindowState.relocateIfFolderVanished()` が働けるように）。
    @Test func shallowObservationSeesChangesToTheWatchedDirectoryItself() {
        let hub = makeHub()
        let folder = makeDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let watch = DirectoryObservation(hub: hub)
        watch.watch(folder, scope: .shallow)

        hub.noteLocalChanges(at: [folder])

        #expect(watch.generation == 1)
    }

    @Test func deepObservationSeesChangesAnywhereBelow() {
        let hub = makeHub()
        let folder = makeDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let watch = DirectoryObservation(hub: hub)
        watch.watch(folder, scope: .deep)

        hub.noteLocalChanges(at: [folder.appendingPathComponent("sub/deep/a.txt")])

        #expect(watch.generation == 1)
    }

    @Test func observationsForOtherDirectoriesAreNotDisturbed() {
        let hub = makeHub()
        let watched = makeDirectory()
        let other = makeDirectory()
        defer {
            try? FileManager.default.removeItem(at: watched)
            try? FileManager.default.removeItem(at: other)
        }
        let watch = DirectoryObservation(hub: hub)
        watch.watch(watched, scope: .shallow)

        hub.noteLocalChanges(at: [other.appendingPathComponent("a.txt")])

        #expect(watch.generation == 0)
    }

    /// 名前が前方一致するだけの別フォルダを巻き込まない
    /// （`/x/Photos` の変更で `/x/Photos Backup` が読み直されない）。
    @Test func aSiblingWhoseNameIsAPrefixIsNotAffected() {
        let hub = makeHub()
        let parent = makeDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let backup = parent.appendingPathComponent("Photos Backup", isDirectory: true)
        let watch = DirectoryObservation(hub: hub)
        watch.watch(backup, scope: .deep)

        hub.noteLocalChanges(at: [parent.appendingPathComponent("Photos/a.jpg")])

        #expect(watch.generation == 0)
    }

    @Test func watchingNilStopsDelivery() {
        let hub = makeHub()
        let folder = makeDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let watch = DirectoryObservation(hub: hub)
        watch.watch(folder, scope: .shallow)
        watch.watch(nil)

        hub.noteLocalChanges(at: [folder.appendingPathComponent("a.txt")])

        #expect(watch.generation == 0)
    }

    @Test func severalObservationsOnTheSameDirectoryAreAllNotified() {
        let hub = makeHub()
        let folder = makeDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = DirectoryObservation(hub: hub)
        let second = DirectoryObservation(hub: hub)
        first.watch(folder, scope: .shallow)
        second.watch(folder, scope: .shallow)

        hub.noteLocalChanges(at: [folder.appendingPathComponent("a.txt")])

        #expect(first.generation == 1)
        #expect(second.generation == 1)
    }

    /// 1 回の呼び出しで同じ関心に当たるパスが複数あっても、読み直しは 1 回で足りる。
    @Test func oneBatchBumpsTheGenerationOnlyOnce() {
        let hub = makeHub()
        let folder = makeDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let watch = DirectoryObservation(hub: hub)
        watch.watch(folder, scope: .shallow)

        hub.noteLocalChanges(at: (1...20).map { folder.appendingPathComponent("f\($0).txt") })

        #expect(watch.generation == 1)
    }

    // MARK: - 監視ルートの剪定

    @Test func pruningDropsDescendantsOfAKeptRoot() {
        let roots = DirectoryChangeHub.pruneDescendants(["/a", "/a/b", "/a/b/c", "/d"])
        #expect(roots == ["/a", "/d"])
    }

    /// **辞書順で直前の要素だけを見る実装にすると落ちるケース。**
    /// 空白（0x20）は `/`（0x2F）より小さいため `/a` → `/a b` → `/a/b` と
    /// 並び、`/a/b` の直前は祖先ではない `/a b` になる。
    @Test func pruningHandlesASiblingThatSortsBetweenAnAncestorAndItsChild() {
        let roots = DirectoryChangeHub.pruneDescendants(["/a", "/a b", "/a/b"])
        #expect(roots == ["/a", "/a b"])
    }

    @Test func pruningCollapsesEverythingUnderTheFilesystemRoot() {
        let roots = DirectoryChangeHub.pruneDescendants(["/", "/Volumes/X", "/Users/someone"])
        #expect(roots == ["/"])
    }

    @Test func pruningKeepsUnrelatedRoots() {
        let roots = DirectoryChangeHub.pruneDescendants(["/Volumes/X", "/Volumes/Y"])
        #expect(roots == ["/Volumes/X", "/Volumes/Y"])
    }

    @Test func pathContainmentDoesNotMatchOnAPartialComponent() {
        #expect(DirectoryChangeHub.path("/a/b", isAtOrUnder: "/a"))
        #expect(DirectoryChangeHub.path("/a", isAtOrUnder: "/a"))
        #expect(!DirectoryChangeHub.path("/ab", isAtOrUnder: "/a"))
        #expect(DirectoryChangeHub.path("/anything", isAtOrUnder: "/"))
    }
}

/// FSEvents の C コンテキストまわりの寿命 [レビューで発見した二重 retain の
/// 回帰テスト]。ストリームは移動・ツリー展開のたびに作り直されるため、
/// 1 本あたり 1 つ漏れるだけでも積み上がる。
@MainActor
@Suite struct FileSystemEventStreamLifetimeTests {
    /// 解放されたかどうかを外から観測するための番人。
    private final class DeinitSpy: @unchecked Sendable {
        private let onDeinit: @Sendable () -> Void
        init(onDeinit: @escaping @Sendable () -> Void) { self.onDeinit = onDeinit }
        deinit { onDeinit() }
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.lock(); value = true; lock.unlock() }
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }

    @Test func theCallbackContextIsReleasedWhenTheStreamGoesAway() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("qoo-stream-lifetime-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let released = Flag()
        do {
            let spy = DeinitSpy { released.set() }
            let stream = FileSystemEventStream { _ in
                // クロージャに番人を捕まえさせる。これが解放されれば、
                // FSEvents に渡した箱も解放されたということ。
                _ = spy
            }
            await stream.setRoots([folder.path])
            try await Task.sleep(for: .milliseconds(300))
            await stream.setRoots([]) // ストリームを破棄する
        }

        // FSEvents は自分のキューで破棄するため、解放は非同期に起きる。
        let start = ContinuousClock.now
        while ContinuousClock.now - start < .seconds(5) {
            if released.isSet { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(released.isSet)
    }
}

/// **ネットワークボリューム用のポーリングを、必要なときだけ動かすこと**
/// [NV6-02、8章 §8.11.16]。
///
/// 判定そのものは `MountTable` に委ねているので、ここでは
/// **合成したマウント表**を渡して両方向を固定する——実際の共有を
/// 用意しなくても、ローカルだけの環境で回帰を捕まえられる。
@MainActor
@Suite struct RemotePollingDecisionTests {
    private func makeHub() -> DirectoryChangeHub {
        DirectoryChangeHub(isApplicationActive: { true })
    }

    private func makeDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("qoo-poll-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 起動ボリューム上だけを見ているなら、ポーリングは要らない。
    ///
    /// **一度ここを落とした。** 「`.shallow` の関心があれば動かす」と書いた
    /// ところ、`FolderTreePane` と `FolderContentView` が常に登録しているため
    /// **前面にいる間ずっと 2 秒ごとに空回りする**状態になっていた。
    @Test func localOnlyRegistrationsDoNotNeedPolling() {
        let hub = makeHub()
        let folder = makeDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let watch = DirectoryObservation(hub: hub)
        watch.watch(folder, scope: .shallow)

        // `#expect` にテーブルそのものを渡さない（落ちたときマウント 97 件が
        // 丸ごと出力され、肝心の 1 行が読めなくなる）。
        let needsPolling = hub.needsRemotePolling(using: MountTable.current())
        #expect(!needsPolling)
    }

    /// 同じ登録でも、その場所がリモートならポーリングが要る。
    /// **これが無いと「常に false」の実装でも上のテストが通ってしまう。**
    @Test func aRegistrationOnARemoteVolumeNeedsPolling() {
        let hub = makeHub()
        let folder = makeDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let watch = DirectoryObservation(hub: hub)
        watch.watch(folder, scope: .shallow)

        // 一時ディレクトリを載せている起動ボリュームを「リモート」に見立てる。
        let pretendRemote = MountTable(entries: [
            .init(mountPoint: "/", fileSystemType: "smbfs", isLocal: false)
        ])
        let needsPolling = hub.needsRemotePolling(using: pretendRemote)
        #expect(needsPolling)
    }

    /// 一覧として見ていない（`.deep`）関心はポーリングの対象外。
    /// ディレクトリ自身の更新日時では配下の変更を拾えないため。
    @Test func deepRegistrationsAreNotPolled() {
        let hub = makeHub()
        let folder = makeDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let watch = DirectoryObservation(hub: hub)
        watch.watch(folder, scope: .deep)

        let pretendRemote = MountTable(entries: [
            .init(mountPoint: "/", fileSystemType: "smbfs", isLocal: false)
        ])
        let needsPolling = hub.needsRemotePolling(using: pretendRemote)
        #expect(!needsPolling)
    }

    /// 関心が無ければ当然要らない。
    @Test func noRegistrationsMeansNoPolling() {
        let hub = makeHub()
        let pretendRemote = MountTable(entries: [
            .init(mountPoint: "/", fileSystemType: "smbfs", isLocal: false)
        ])
        let needsPolling = hub.needsRemotePolling(using: pretendRemote)
        #expect(!needsPolling)
    }
}
