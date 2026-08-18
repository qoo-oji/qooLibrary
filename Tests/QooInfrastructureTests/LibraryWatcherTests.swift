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
            WatchedLibrary(id: LibraryID(rawValue: 1), rootPath: "/lib", lastEventID: 0),
            WatchedLibrary(id: LibraryID(rawValue: 2), rootPath: "/lib/inner", lastEventID: 0),
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
            WatchedLibrary(id: LibraryID(rawValue: 1), rootPath: "/lib", lastEventID: 0)])
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
            WatchedLibrary(id: LibraryID(rawValue: 1), rootPath: "/lib", lastEventID: 0)])
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
            WatchedLibrary(id: LibraryID(rawValue: 1), rootPath: "/lib", lastEventID: 0)])
        var iterator = watcher.requests.makeAsyncIterator()
        watcher.handle([change("/lib/x", flags: kFSEventStreamEventFlagMustScanSubDirs)])
        let request = try #require(await iterator.next())
        #expect(request.needsFullScan)
        #expect(request.relativePaths.isEmpty)
    }

    @Test("ルート自身の変更もフルスキャンへ落とす")
    func rootChangedFallsBackToFullScan() async throws {
        let (watcher, _) = makeWatcher([
            WatchedLibrary(id: LibraryID(rawValue: 1), rootPath: "/lib", lastEventID: 0)])
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
            WatchedLibrary(id: id, rootPath: "/lib", lastEventID: 0)])
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
            WatchedLibrary(id: id, rootPath: "/lib", lastEventID: 0)])
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

    @Test("監視していないパスの変更は無視する")
    func unwatchedPathIsIgnored() async {
        let (watcher, _) = makeWatcher([
            WatchedLibrary(id: LibraryID(rawValue: 1), rootPath: "/lib", lastEventID: 0)])
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
