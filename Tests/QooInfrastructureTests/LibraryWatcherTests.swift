import Testing
import Foundation
import QooKit
@testable import QooInfrastructure

@Suite("LibraryWatcher [10.1][10.5][SY-01〜SY-08][FO-12][EV-01〜EV-04]")
@MainActor
struct LibraryWatcherTests {

    func makeWatcher(_ libraries: [WatchedLibrary]) -> (LibraryWatcher, ExpectedChangeLedger) {
        let ledger = ExpectedChangeLedger()
        let watcher = LibraryWatcher(ledger: ledger)
        watcher.setWatchedForTesting(libraries)
        return (watcher, ledger)
    }

    func change(_ path: String, flags: Int = 0) -> FileSystemChange {
        FileSystemChange(path: path, flags: FSEventStreamEventFlags(flags))
    }

    /// **辞書順で直前の要素だけを見る実装にしてはならない** [DW-03]。
    /// `/a`・`/a b`・`/a/b` はこの順に並ぶため、`/a/b` の直前が `/a b` になる。
    @Test("祖先に含まれるルートを剪定する [DW-03]")
    func prunesNestedRoots() {
        #expect(LibraryWatcher.prunedRoots(["/a", "/a b", "/a/b"]) == ["/a", "/a b"])
        #expect(LibraryWatcher.prunedRoots(["/a/b", "/a"]) == ["/a"])
        #expect(LibraryWatcher.prunedRoots(["/x", "/y"]) == ["/x", "/y"])
        #expect(LibraryWatcher.prunedRoots(["/a", "/a"]) == ["/a"])
        #expect(LibraryWatcher.prunedRoots([]).isEmpty)
        // 名前の前方一致だけでは剪定しない（`/ab` は `/a` の配下ではない）
        #expect(LibraryWatcher.prunedRoots(["/a", "/ab"]) == ["/a", "/ab"])
    }

    @Test("パスは最長一致でライブラリへ振り分ける")
    func longestMatchWins() {
        let (watcher, _) = makeWatcher([
            WatchedLibrary(id: LibraryID(rawValue: 1), rootPath: "/lib"),
            WatchedLibrary(id: LibraryID(rawValue: 2), rootPath: "/lib/inner"),
        ])
        #expect(watcher.library(containing: "/lib/inner/a.cbz")?.id == LibraryID(rawValue: 2))
        #expect(watcher.library(containing: "/lib/a.cbz")?.id == LibraryID(rawValue: 1))
        #expect(watcher.library(containing: "/other/a.cbz") == nil)
        // 根そのものも一致する
        #expect(watcher.library(containing: "/lib")?.id == LibraryID(rawValue: 1))
    }

    @Test("外部変更はスキャン要求になる")
    func externalChangeEmitsRequest() async throws {
        let (watcher, _) = makeWatcher([
            WatchedLibrary(id: LibraryID(rawValue: 1), rootPath: "/lib")])
        var iterator = watcher.requests.makeAsyncIterator()
        watcher.handle([change("/lib/フォルダ/作品.cbz")])
        let request = try #require(await iterator.next())
        #expect(request.libraryID == LibraryID(rawValue: 1))
        #expect(request.relativePaths == ["フォルダ/作品.cbz"])
        #expect(!request.needsFullScan)
    }

    /// **自己変更は台帳で落とす** [FO-12][EV-01]。
    @Test("台帳に一致する変更はスキャン要求にならない [FO-12]")
    func selfChangeIsFiltered() async throws {
        let (watcher, ledger) = makeWatcher([
            WatchedLibrary(id: LibraryID(rawValue: 1), rootPath: "/lib")])
        ledger.expect([URL(fileURLWithPath: "/lib/自分で作った.cbz")], kind: .createDirectory)

        var iterator = watcher.requests.makeAsyncIterator()
        watcher.handle([change("/lib/自分で作った.cbz"),
                        change("/lib/よそが作った.cbz")])
        let request = try #require(await iterator.next())
        #expect(request.relativePaths == ["よそが作った.cbz"], "自己変更が落ちていない")
    }

    @Test("MustScanSubDirs はフルスキャンへ落とす [SY-04][WA-04]")
    func mustScanSubDirsFallsBackToFullScan() async throws {
        let (watcher, _) = makeWatcher([
            WatchedLibrary(id: LibraryID(rawValue: 1), rootPath: "/lib")])
        var iterator = watcher.requests.makeAsyncIterator()
        watcher.handle([change("/lib/x", flags: kFSEventStreamEventFlagMustScanSubDirs)])
        let request = try #require(await iterator.next())
        #expect(request.needsFullScan)
        #expect(request.relativePaths.isEmpty)
    }

    @Test("ルート自身の変更もフルスキャンへ落とす")
    func rootChangedFallsBackToFullScan() async throws {
        let (watcher, _) = makeWatcher([
            WatchedLibrary(id: LibraryID(rawValue: 1), rootPath: "/lib")])
        var iterator = watcher.requests.makeAsyncIterator()
        watcher.handle([change("/lib", flags: kFSEventStreamEventFlagRootChanged)])
        #expect(try #require(await iterator.next()).needsFullScan)
    }

    /// 排他処理中はイベントを保留し、完了後に**差分照合を 1 回だけ**実行する
    /// [FO-14][LK-31][EV-02]。
    @Test("一括処理中は保留し、再開時にまとめて 1 回だけ要求する [FO-14][EV-02]")
    func suspendCoalescesIntoOneRequest() async throws {
        let id = LibraryID(rawValue: 1)
        let (watcher, _) = makeWatcher([
            WatchedLibrary(id: id, rootPath: "/lib")])
        var iterator = watcher.requests.makeAsyncIterator()

        watcher.suspend(id)
        watcher.handle([change("/lib/a.cbz")])
        watcher.handle([change("/lib/b.cbz")])
        watcher.handle([change("/lib/a.cbz")])       // 重複
        watcher.resume(id)

        let request = try #require(await iterator.next())
        #expect(request.relativePaths == ["a.cbz", "b.cbz"], "重複は畳んで 1 回にまとめる")
    }

    @Test("保留中に何も起きなければ再開しても要求は出ない")
    func resumeWithoutChangesEmitsNothing() async {
        let id = LibraryID(rawValue: 1)
        let (watcher, _) = makeWatcher([
            WatchedLibrary(id: id, rootPath: "/lib")])
        var emitted = 0
        let task = Task { @MainActor in
            for await _ in watcher.requests { emitted += 1 }
        }
        watcher.suspend(id)
        watcher.resume(id)
        try? await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()
        #expect(emitted == 0)
    }

    // MARK: - 自プロセスの変更 [FO-01][FO-10][FO-12]

    /// **FSEvents は自分の変更を落とす** [FO-10]し、台帳も落とす [FO-12]。
    /// 二重に落ちるので、アプリがライブラリへ入れたファイルは DB に載らない
    /// ——ファイルマネージャーからドラッグしたものが蔵書に現れない、という形。
    @Test("自プロセスの変更もスキャン要求になる [FO-01]")
    func localChangesAlsoProduceScanRequests() async throws {
        let (watcher, _) = makeWatcher([
            WatchedLibrary(id: LibraryID(rawValue: 1), rootPath: "/lib")])
        var iterator = watcher.requests.makeAsyncIterator()

        watcher.noteLocalChanges(at: [URL(fileURLWithPath: "/lib/フォルダ/自分で入れた.cbz")])
        let request = try #require(await iterator.next())
        #expect(request.libraryID == LibraryID(rawValue: 1))
        #expect(request.relativePaths == ["フォルダ/自分で入れた.cbz"])
        #expect(!request.needsFullScan)
    }

    /// **台帳は引かない。** 台帳の目的は自動リネームの無限ループを防ぐこと
    /// [R-13][FO-24] であって、収束型のスキャン [FO-20] にとっては
    /// 「自分の変更こそ DB に反映すべきもの」。
    @Test("台帳に載っていても、自プロセスの変更はスキャン要求になる")
    func theLedgerDoesNotSuppressTheLocalChannel() async throws {
        let (watcher, ledger) = makeWatcher([
            WatchedLibrary(id: LibraryID(rawValue: 1), rootPath: "/lib")])
        let url = URL(fileURLWithPath: "/lib/自分で作った.cbz")
        ledger.expect([url], kind: .createDirectory)

        var iterator = watcher.requests.makeAsyncIterator()
        watcher.noteLocalChanges(at: [url])
        #expect(try #require(await iterator.next()).relativePaths == ["自分で作った.cbz"])
    }

    @Test("ライブラリの外の変更は無視する")
    func localChangesOutsideAnyLibraryAreIgnored() async {
        let (watcher, _) = makeWatcher([
            WatchedLibrary(id: LibraryID(rawValue: 1), rootPath: "/lib")])
        var emitted = 0
        let task = Task { @MainActor in
            for await _ in watcher.requests { emitted += 1 }
        }
        watcher.noteLocalChanges(at: [URL(fileURLWithPath: "/どこか/x.cbz")])
        try? await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()
        #expect(emitted == 0)
    }

    /// 一括処理中は保留する [FO-14][EV-02]。自己変更の経路も同じ扱い。
    @Test("一括処理中は自プロセスの変更も保留する [FO-14]")
    func localChangesAreHeldWhileSuspended() async throws {
        let id = LibraryID(rawValue: 1)
        let (watcher, _) = makeWatcher([WatchedLibrary(id: id, rootPath: "/lib")])
        var iterator = watcher.requests.makeAsyncIterator()

        watcher.suspend(id)
        watcher.noteLocalChanges(at: [URL(fileURLWithPath: "/lib/a.cbz")])
        watcher.noteLocalChanges(at: [URL(fileURLWithPath: "/lib/b.cbz")])
        watcher.resume(id)

        #expect(try #require(await iterator.next()).relativePaths == ["a.cbz", "b.cbz"])
    }

    // MARK: - 差分の起点をストリームへ渡す [SY-03][WA-11][WA-12]

    /// **検証できていない起点を渡してはならない** [WA-12]。渡しても
    /// そのボリュームには履歴が無いので再生されず（§10.1.0 の実測）、
    /// 他のボリュームの履歴を無用に遡らせるだけになる。
    @Test("検証済みの起点が 1 つも無ければ「今から」にする [WA-12]")
    func withoutAnyUsableCheckpointTheStreamStartsFromNow() {
        let libraries = [
            WatchedLibrary(id: LibraryID(rawValue: 1), rootPath: "/a"),
            WatchedLibrary(id: LibraryID(rawValue: 2), rootPath: "/b", usableCheckpoint: nil),
        ]
        #expect(LibraryWatcher.sinceWhen(for: libraries)
            == FSEventStreamEventId(kFSEventStreamEventIdSinceNow))
    }

    /// イベント ID はシステム全体で単調なので、最小値なら取りこぼさない。
    /// 余分に届く分はスキャンが冪等 [FO-20] なので害が無い。
    @Test("検証済みの起点の最小値を使う [SY-03]")
    func theStreamStartsFromTheEarliestUsableCheckpoint() {
        let libraries = [
            WatchedLibrary(id: LibraryID(rawValue: 1), rootPath: "/a",
                           usableCheckpoint: FSEventsCheckpoint(eventID: 900, deviceUUID: "A")),
            WatchedLibrary(id: LibraryID(rawValue: 2), rootPath: "/b",
                           usableCheckpoint: FSEventsCheckpoint(eventID: 100, deviceUUID: "B")),
            WatchedLibrary(id: LibraryID(rawValue: 3), rootPath: "/c"),   // 検証できていない
        ]
        #expect(LibraryWatcher.sinceWhen(for: libraries) == FSEventStreamEventId(100))
    }

    // MARK: - 起点の検証そのもの [SY-04][WA-11]

    @Test("起点は保存した UUID が現在のものと一致するときだけ使える [WA-11]")
    func aCheckpointIsUsableOnlyWhenTheDeviceUUIDMatches() {
        let checkpoint = FSEventsCheckpoint(eventID: 42, deviceUUID: "SAME")
        #expect(checkpoint.isUsable(currentDeviceUUID: "SAME"))
        #expect(!checkpoint.isUsable(currentDeviceUUID: "OTHER"), "履歴が別物に差し替わった")
        #expect(!checkpoint.isUsable(currentDeviceUUID: nil), "履歴を持たないボリューム")
    }

    @Test("まだ一度も保存していない起点は使えない")
    func anUnsavedCheckpointIsNeverUsable() {
        #expect(!FSEventsCheckpoint.unusable.isUsable(currentDeviceUUID: "ANY"))
        #expect(!FSEventsCheckpoint(eventID: 0, deviceUUID: "ANY").isUsable(currentDeviceUUID: "ANY"))
    }

    /// **「今から」の番兵を実在の ID と取り違えてはならない** [実機検証で発見]。
    ///
    /// ストリームが 1 件もイベントを処理していないと
    /// `FSEventStreamGetLatestEventId` は `kFSEventStreamEventIdSinceNow`
    /// （`UInt64.max`）を返す。それを起点として保存すると、次回は
    /// **「使える起点」と判定されたうえで「今から」が渡り、非起動中の変更が
    /// 黙って落ちる**——実機で `lastFSEventID = -1` として現れた。
    @Test("「今から」の番兵は起点として使えない")
    func theSinceNowSentinelIsNeverUsable() {
        #expect(FSEventsCheckpoint.sinceNowSentinel == UInt64(bitPattern: -1))
        let sentinel = FSEventsCheckpoint(eventID: FSEventsCheckpoint.sinceNowSentinel,
                                          deviceUUID: "SAME")
        #expect(!sentinel.isUsable(currentDeviceUUID: "SAME"))
    }

    /// 監視していない・まだ 1 件も処理していないときに保存する値。
    @Test("保存する起点は、番兵でも 0 でもない実在の ID になる [SY-02]")
    func theSavedEventIDIsAlwaysAReadableIdentifier() {
        let (watcher, _) = makeWatcher([])
        let id = watcher.latestEventID
        #expect(id != 0)
        #expect(id != FSEventsCheckpoint.sinceNowSentinel)
        // 保存してすぐ読み戻したときに「使える」と判定できること。
        #expect(FSEventsCheckpoint(eventID: id, deviceUUID: "V").isUsable(currentDeviceUUID: "V"))
    }

    // MARK: - 差分の起点 [SY-02][WA-10]

    /// **保存する起点は「まだ無い」を表す 0 にしない。** 0 で保存すると次回に
    /// 履歴を要求できず、非起動中の変更を丸ごと取りこぼす。
    @Test("監視していなくてもシステム全体の現在値を返す [SY-02]")
    func theLatestEventIDIsNeverZero() {
        let (watcher, _) = makeWatcher([])
        #expect(watcher.latestEventID > 0)
    }

    @Test("監視していないパスの変更は無視する")
    func unwatchedPathIsIgnored() async {
        let (watcher, _) = makeWatcher([
            WatchedLibrary(id: LibraryID(rawValue: 1), rootPath: "/lib")])
        var emitted = 0
        let task = Task { @MainActor in
            for await _ in watcher.requests { emitted += 1 }
        }
        watcher.handle([change("/どこか別の場所/x.cbz")])
        try? await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()
        #expect(emitted == 0)
    }
}

@Suite("VolumeMonitor [10.2][VD-01〜VD-11]")
struct VolumeMonitorTests {
    @Test("起動時にマウント中のボリュームを列挙する [VD-08][VM3-05]")
    func reconcileFindsMountedVolumes() async {
        let monitor = VolumeMonitor()
        await monitor.reconcileWithMountedVolumes()
        let identifiers = await monitor.mountedIdentifiers
        // 起動ボリュームは必ずある
        #expect(!identifiers.isEmpty)
    }

    @Test("2 回突き合わせても状態が変わらない（冪等）")
    func reconcileIsIdempotent() async {
        let monitor = VolumeMonitor()
        await monitor.reconcileWithMountedVolumes()
        let first = await monitor.mountedIdentifiers
        await monitor.reconcileWithMountedVolumes()
        #expect(await monitor.mountedIdentifiers == first)
    }

    @Test("ボリューム識別にはマウントパスではなく識別子を使う [VD-02][VM3-01]")
    func usesIdentifierNotPath() async {
        let monitor = VolumeMonitor()
        await monitor.reconcileWithMountedVolumes()
        // 改名しても識別子は変わらない、という設計をパス→識別子の表で表現している。
        // ここでは表が識別子を持っていることだけを固定する。
        #expect(await monitor.mountedIdentifiers.allSatisfy { !$0.isEmpty })
    }

    /// 実際のマウント／アンマウントは `hdiutil` を要し、この開発機では
    /// `swift test` 配下から EPERM で失敗する（CLAUDE.md の記録）。
    /// 着脱そのものの検証は 1-16 のイジェクトと同じく実機で行う。
    @Test("開始・停止が繰り返せる")
    func startStopIsRepeatable() async {
        let monitor = VolumeMonitor()
        await monitor.start()
        #expect(await monitor.isRunning)
        await monitor.stop()
        #expect(await monitor.isRunning == false)
        await monitor.start()
        await monitor.stop()
    }
}

//
//  `FileOperationService` からライブラリ監視へ届く経路 [FO-01]。
//
//  **上の suite だけでは足りない。** あちらは `LibraryWatcher` の振る舞いを
//  直に試すので、`announce` が `LibraryWatcher.noteLocalChanges` を呼ぶことを
//  誰も確かめていなかった——実際、その 1 行を消す変異が空振りした。
//
@Suite("自プロセスの変更がライブラリ監視へ届く [FO-01]", .serialized)
@MainActor
struct LibraryWatcherLocalChannelTests {

    /// **共有インスタンスを使う。** `FileOperationService` の通知先は
    /// `LibraryWatcher.shared` 固定なので、ここだけは共有で試すしかない。
    /// `setWatchedForTesting` は FSEvents のストリームを張らないので、
    /// 開発機の実フォルダを監視してしまうことはない。
    @Test func localChangesReachTheSharedWatcherThroughFileOperationService() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("qoo-local-channel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let watcher = LibraryWatcher.shared
        let id = LibraryID(rawValue: 4242)
        // FSEvents はシンボリックリンクを解決した実体のパスを返すので、
        // 監視ルートも同じ正規化を経ておく（`/tmp` は `/private/tmp`）。
        let rootPath = root.resolvingSymlinksInPath().path
        watcher.setWatchedForTesting([WatchedLibrary(id: id, rootPath: rootPath)])
        defer { watcher.setWatchedForTesting([]) }

        // **上限時間つきで待つ。** 素の `await iterator.next()` は、経路が
        // 切れているとき**失敗せずハングする**——変異を当てて実際にそうなった。
        // 壊れているときに落ちないテストは、何も守っていない。
        let received = Received()
        let collector = Task { @MainActor in
            for await request in watcher.requests { received.append(request); return }
        }
        defer { collector.cancel() }

        _ = try await FileOperationService()
            .createDirectory(at: root.appendingPathComponent("作者A"))

        let deadline = Date().addingTimeInterval(3)
        while received.value == nil, Date() < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        let request = try #require(received.value, "自プロセスの変更が届かなかった")
        #expect(request.libraryID == id)
        #expect(request.relativePaths == ["作者A"])
    }
}

/// 到着した要求を 1 件だけ控える箱。
@MainActor
final class Received {
    private(set) var value: ScanRequest?
    func append(_ request: ScanRequest) { if value == nil { value = request } }
}

//
//  ストリームを実際に張ったときの差分の起点 [SY-02][実機検証で発見]。
//
//  **ストリームを持たない経路だけでは足りない。** `FSEventStreamGetLatestEventId`
//  は、1 件もイベントを処理していないと `kFSEventStreamEventIdSinceNow`
//  （`UInt64.max`）を返す——それを保存すると、次回「使える起点」と判定された
//  うえで「今から」が渡り、非起動中の変更が黙って落ちる。
//
@Suite("実ストリームを張ったときの差分の起点 [SY-02]", .serialized)
@MainActor
struct LibraryWatcherCheckpointTests {

    @Test func aFreshStreamNeverReportsTheSinceNowSentinel() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("qoo-watcher-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let watcher = LibraryWatcher()
        defer { _ = watcher.stop() }
        // 検証済みの起点が無いので、ストリームは「今から」で作られる。
        await watcher.setLibraries([
            WatchedLibrary(id: LibraryID(rawValue: 1),
                           rootPath: root.resolvingSymlinksInPath().path)])

        let id = watcher.latestEventID
        #expect(id != FSEventsCheckpoint.sinceNowSentinel, "番兵をそのまま返している")
        #expect(id != 0)
        #expect(FSEventsCheckpoint(eventID: id, deviceUUID: "V").isUsable(currentDeviceUUID: "V"))
    }
}
