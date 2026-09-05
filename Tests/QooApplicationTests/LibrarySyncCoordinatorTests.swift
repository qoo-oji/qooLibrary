import Foundation
import QooInfrastructure
import QooKit
import Testing
@testable import QooApplication

//
//  実体への追随の調整役 [SY-01〜SY-08][VD-01〜VD-11][EV-01〜EV-04]。
//
//  **共有インスタンスを一切使わない。** 既定の依存は `RegisteredFolderStore.shared`
//  と `LibraryWatcher.shared`（どちらもアプリ全体で 1 つ）なので、そのまま使うと
//  開発機の実際の登録フォルダに FSEvents を張ってしまう。
//

// MARK: - フェイク

/// 監視状態だけを持つ最小のリポジトリ。書き戻しを記録して検証する。
final class FakeLibraryRepository: LibraryRepository, @unchecked Sendable {
    private let lock = NSLock()
    private var _states: [LibraryWatchState] = []
    private(set) var onlineWrites: [(LibraryID, Bool)] = []
    private(set) var checkpointWrites: [(LibraryID, FSEventsCheckpoint)] = []
    private(set) var fullScanWrites: [LibraryID] = []
    private(set) var pathWrites: [(LibraryID, String)] = []
    var displayNameWrites: [(LibraryID, String)] = []

    init(_ states: [LibraryWatchState]) { _states = states }

    // **`NSLock.lock()` は async 関数の本体から呼べない**（`noasync`）ので、
    // 同期ヘルパーへ退避する。このコードベースで繰り返し踏んでいる罠。
    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }; return body()
    }

    func watchStates() async throws -> [LibraryWatchState] { withLock { _states } }
    func setOnline(_ online: Bool, libraryID: LibraryID) async throws {
        withLock {
            onlineWrites.append((libraryID, online))
            // **書いた値を反映する。** 記録するだけだと `watchStates()` が古い
            // 値を返し続け、「同じ状態なら書かない・知らせない」という性質を
            // どのテストも検査できない（実 DB は当然反映する）。
            guard let i = _states.firstIndex(where: { $0.id == libraryID }) else { return }
            let old = _states[i]
            _states[i] = LibraryWatchState(
                id: old.id, uuid: old.uuid, displayName: old.displayName,
                resolvedPath: old.resolvedPath, volumeUUID: old.volumeUUID,
                isOnline: online, checkpoint: old.checkpoint,
                lastFullScanAt: old.lastFullScanAt)
        }
    }
    func setResolvedPath(_ path: String, libraryID: LibraryID) async throws {
        withLock { pathWrites.append((libraryID, path)) }
    }
    func registeredTemplate(libraryID: LibraryID) async throws -> LibraryTypeTemplate? { nil }
    func setRegisteredTemplate(_ template: LibraryTypeTemplate?,
                               libraryID: LibraryID) async throws {}

    func setDisplayName(_ name: String, libraryID: LibraryID) async throws {
        withLock {
            displayNameWrites.append((libraryID, name))
            // `setOnline` と同じ理由で書いた値を反映する——反映しないと
            // 「同じ名前なら書かない」を検査できない。
            guard let i = _states.firstIndex(where: { $0.id == libraryID }) else { return }
            let old = _states[i]
            _states[i] = LibraryWatchState(
                id: old.id, uuid: old.uuid, displayName: name,
                resolvedPath: old.resolvedPath, volumeUUID: old.volumeUUID,
                isOnline: old.isOnline, checkpoint: old.checkpoint,
                lastFullScanAt: old.lastFullScanAt)
        }
    }
    func setFSEventsCheckpoint(_ checkpoint: FSEventsCheckpoint,
                               libraryID: LibraryID) async throws {
        withLock { checkpointWrites.append((libraryID, checkpoint)) }
    }
    func setLastFullScanAt(_ date: Date, libraryID: LibraryID) async throws {
        withLock { fullScanWrites.append(libraryID) }
    }

    // 以下、この suite では呼ばれない。
    func libraries() async throws -> [LibrarySummary] { [] }
    func library(id: LibraryID) async throws -> LibrarySummary? { nil }
    func library(uuid: UUID) async throws -> LibrarySummary? { nil }
    func settingsSnapshot(libraryID: LibraryID) async throws -> LibrarySettingsSnapshot? { nil }
    func settingsDraft(libraryID: LibraryID) async throws -> LibrarySettingsDraft? { nil }
    func updateSettings(_ draft: LibrarySettingsDraft, libraryID: LibraryID) async throws {}
    func register(_ registration: LibraryRegistration,
                  template: LibraryTypeTemplate) async throws -> LibraryID { .init(rawValue: 0) }
    func register(_ registration: LibraryRegistration, draft: LibrarySettingsDraft,
                  template: LibraryTypeTemplate?) async throws -> LibraryID { .init(rawValue: 0) }
    func unregister(id: LibraryID, keepLabels: Bool) async throws {}
    func totalFileCount() async throws -> Int { 0 }
}

/// 走査を任意の時点まで保持する門。**時間ではなく状態で待つ**ため。
actor ScanGate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}

struct FakeRootLocator: LibraryRootLocating {
    let locations: [UUID: LibraryRootLocation]
    func libraryRootLocations() async -> [UUID: LibraryRootLocation] { locations }
}

/// 走査の呼ばれ方だけを記録する。
final class ScanRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [ScanEngine.Mode] = []
    var calls: [ScanEngine.Mode] { lock.lock(); defer { lock.unlock() }; return _calls }
    /// `@Sendable` な非 async クロージャから呼ばれるので、ここは `noasync` に
    /// 触れない（`scan` クロージャは async だが、記録は同期で済ませている）。
    func record(_ mode: ScanEngine.Mode) {
        lock.lock(); _calls.append(mode); lock.unlock()
    }
    var fullScanCount: Int {
        calls.count { if case .full = $0 { return true }; return false }
    }
    var incrementalPaths: [[String]] {
        calls.compactMap { if case .incremental(_, let p) = $0 { return p }; return nil }
    }
}

/// 呼ばれた回数を数えるだけの入れ物（`@Sendable` なクロージャから触る）。
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

@MainActor
@Suite("実体への追随 [SY-01〜SY-08][VD-01〜VD-11]", .serialized)
struct LibrarySyncCoordinatorTests {

    /// 使い捨ての根。`FSEventsHistory` が実体を引くので実ディレクトリが要る。
    final class Roots {
        let base: URL
        init() throws {
            base = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("qoo-sync-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        }
        deinit { try? FileManager.default.removeItem(at: base) }
        func make(_ name: String) throws -> URL {
            let url = base.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
    }

    func state(id: Int, uuid: UUID, path: String, isOnline: Bool = true,
               checkpoint: FSEventsCheckpoint = .unusable,
               lastFullScanAt: Date? = Date()) -> LibraryWatchState {
        LibraryWatchState(id: LibraryID(rawValue: Int64(id)), uuid: uuid,
                          displayName: "ライブラリ\(id)", resolvedPath: path,
                          volumeUUID: "VOL", isOnline: isOnline, checkpoint: checkpoint,
                          lastFullScanAt: lastFullScanAt)
    }

    func makeCoordinator(states: [LibraryWatchState],
                         locations: [UUID: LibraryRootLocation],
                         recorder: ScanRecorder,
                         repository: FakeLibraryRepository? = nil,
                         fullScanInterval: TimeInterval? = nil)
        -> (LibrarySyncCoordinator, FakeLibraryRepository, LibraryWatcher)
    {
        let repo = repository ?? FakeLibraryRepository(states)
        // **専用の `LibraryWatcher` を作る**（`.shared` は実登録フォルダを見る）。
        let watcher = LibraryWatcher()
        let coordinator = LibrarySyncCoordinator(dependencies: .init(
            libraries: repo,
            roots: FakeRootLocator(locations: locations),
            scan: { mode, _ in recorder.record(mode); return ScanSummary() },
            watcher: watcher,
            monitor: VolumeMonitor(),
            fullScanInterval: fullScanInterval))
        return (coordinator, repo, watcher)
    }

    // MARK: - オンライン／オフラインの駆動 [VD-03][VD-05]

    /// **`isOnline` を更新する経路がこれまで存在しなかった**（常に真）。
    /// R-01（外部ボリューム未接続でラベル一括喪失）に対する砦が 1 枚死んでいた。
    @Test("接続されていないライブラリをオフラインにする [VD-05][SB-05]")
    func marksADisconnectedLibraryOffline() async throws {
        let uuid = UUID()
        let recorder = ScanRecorder()
        let (coordinator, repo, _) = makeCoordinator(
            states: [state(id: 1, uuid: uuid, path: "/どこか", isOnline: true)],
            locations: [uuid: .unavailable("ボリュームが接続されていない")],
            recorder: recorder)

        await coordinator.resync()
        #expect(repo.onlineWrites.count == 1)
        #expect(repo.onlineWrites.first?.1 == false)
        #expect(recorder.calls.isEmpty, "オフラインのライブラリは走査しない [SY-08]")
    }

    /// **DB を書き換えるだけでは上位に届かない**（実機検証で発見）。
    ///
    /// `LibraryServices.libraries` は問い合わせた時点の写しなので、着脱を
    /// 知らせないと開いたままの画面が古い `isOnline` を見続ける——「見つから
    /// ないファイル」の整理ウインドウが取り出しに追随せず、**見えなくなった
    /// ボリュームの記録を削除できてしまった**（OR2-06 が防ごうとしている
    /// 事故そのもの、15章 §15.7）。
    @Test("オンライン／オフラインの遷移を上位へ知らせる [VD-03][VD-05]")
    func notifiesUpstreamWhenOnlineStateChanges() async throws {
        let uuid = UUID()
        let recorder = ScanRecorder()
        let (coordinator, _, _) = makeCoordinator(
            states: [state(id: 1, uuid: uuid, path: "/どこか", isOnline: true)],
            locations: [uuid: .unavailable("ボリュームが接続されていない")],
            recorder: recorder)
        let notifications = Counter()
        coordinator.onOnlineStateChanged = { notifications.increment() }

        await coordinator.resync()
        #expect(notifications.value == 1)

        // **変化が無ければ知らせない**——`libraries` の読み直しは DB への
        // 往復を伴うので、突き合わせのたびに走らせない。
        await coordinator.resync()
        #expect(notifications.value == 1, "同じ状態のままなら通知しない")
    }

    @Test("接続されたライブラリをオンラインに戻す [VD-03]")
    func marksAReconnectedLibraryOnline() async throws {
        let roots = try Roots()
        let url = try roots.make("lib")
        let uuid = UUID()
        let recorder = ScanRecorder()
        let (coordinator, repo, _) = makeCoordinator(
            states: [state(id: 1, uuid: uuid, path: url.path, isOnline: false)],
            locations: [uuid: .online(url)], recorder: recorder)

        await coordinator.resync()
        #expect(repo.onlineWrites.map(\.1) == [true])
    }

    @Test("状態が変わっていなければ書き戻さない（冪等）")
    func doesNotWriteWhenNothingChanged() async throws {
        let roots = try Roots()
        let url = try roots.make("lib")
        let uuid = UUID()
        let recorder = ScanRecorder()
        let (coordinator, repo, _) = makeCoordinator(
            states: [state(id: 1, uuid: uuid, path: url.path, isOnline: true)],
            locations: [uuid: .online(url)], recorder: recorder)

        await coordinator.resync()
        await coordinator.resync()
        #expect(repo.onlineWrites.isEmpty)
        #expect(repo.pathWrites.isEmpty)
    }

    /// ボリュームの改名で根が動く [VD-06]。**`volumeUUID` は不変なので
    /// ファイルの紐づけは維持される。**
    @Test("根が移動したら resolvedPath を書き直す [VD-06]")
    func rewritesTheResolvedPathWhenTheRootMoves() async throws {
        let roots = try Roots()
        let url = try roots.make("新しい名前")
        let uuid = UUID()
        let recorder = ScanRecorder()
        let (coordinator, repo, _) = makeCoordinator(
            states: [state(id: 1, uuid: uuid, path: "/Volumes/古い名前/lib")],
            locations: [uuid: .online(url)], recorder: recorder)

        await coordinator.resync()
        #expect(repo.pathWrites.map(\.1) == [url.path])
    }

    /// **フォルダ名＝表示名** [RG3-31]。根の移動（リネームを含む）で表示名も
    /// 追随する。`settingsRevision` の更新はリポジトリの実装が担う。
    @Test("根が移動したら表示名もフォルダ名へ追随する [RG3-31]")
    func rewritesTheDisplayNameWhenTheRootMoves() async throws {
        let roots = try Roots()
        let url = try roots.make("新しい名前")
        let uuid = UUID()
        let recorder = ScanRecorder()
        let (coordinator, repo, _) = makeCoordinator(
            states: [state(id: 1, uuid: uuid, path: "/Volumes/古い名前/lib")],
            locations: [uuid: .online(url)], recorder: recorder)

        await coordinator.resync()
        #expect(repo.displayNameWrites.map(\.1) == [url.lastPathComponent])
        // 名前が既に一致していれば書かない（冪等）。
        await coordinator.resync()
        #expect(repo.displayNameWrites.count == 1)
    }

    /// ゴミ箱の中・実体消失・ファイルシステム非対応も「走査しない」に畳む。
    @Test("走査してはいけない状態はすべてオフライン扱いにする")
    func everyDegradedStateStopsScanning() {
        #expect(!RegisteredFolderRootLocator
            .location(for: .offline(lastKnownPath: nil)).isOnline)
        #expect(!RegisteredFolderRootLocator
            .location(for: .inTrash(url: URL(fileURLWithPath: "/x"))).isOnline)
        #expect(!RegisteredFolderRootLocator
            .location(for: .missing(lastKnownPath: nil)).isOnline)
        #expect(!RegisteredFolderRootLocator
            .location(for: .unsupportedFileSystem(url: URL(fileURLWithPath: "/x"),
                                                  fileSystemName: "exfat")).isOnline)
        #expect(RegisteredFolderRootLocator
            .location(for: .online(url: URL(fileURLWithPath: "/x"))).isOnline)
    }

    // MARK: - 起動時に何を走らせるか [SY-03][SY-04][SY-05]

    /// **差分の起点が検証できないならフルスキャン** [SY-04]。ネットワーク
    /// ボリュームでは常にこちらへ来る（§10.1.0 の実測）。
    @Test("起点が使えないライブラリは起動時にフルスキャンする [SY-04]")
    func aLibraryWithoutAUsableCheckpointIsFullyScannedAtStartup() async throws {
        let roots = try Roots()
        let url = try roots.make("lib")
        let uuid = UUID()
        let recorder = ScanRecorder()
        let (coordinator, _, _) = makeCoordinator(
            states: [state(id: 1, uuid: uuid, path: url.path, checkpoint: .unusable)],
            locations: [uuid: .online(url)], recorder: recorder)

        await coordinator.resync(startup: true)
        try await settle(coordinator)
        #expect(recorder.fullScanCount == 1)
    }

    /// 起点が使えるなら、非起動中の変更は FSEvents の再生が運んでくる [SY-03]。
    @Test("起点が使えるライブラリは起動時に走査しない [SY-03]")
    func aLibraryWithAUsableCheckpointIsNotScannedAtStartup() async throws {
        let roots = try Roots()
        let url = try roots.make("lib")
        let uuid = UUID()
        let deviceUUID = try #require(FSEventsHistory.deviceUUID(for: url))
        let recorder = ScanRecorder()
        let (coordinator, _, _) = makeCoordinator(
            states: [state(id: 1, uuid: uuid, path: url.path,
                           checkpoint: FSEventsCheckpoint(eventID: 42, deviceUUID: deviceUUID))],
            locations: [uuid: .online(url)], recorder: recorder)

        await coordinator.resync(startup: true)
        try await settle(coordinator)
        #expect(recorder.calls.isEmpty)
    }

    /// 取りこぼしの最終安全網 [SY-05]。
    @Test("前回のフルスキャンから間隔を超えていれば走らせる [SY-05]")
    func aStaleLibraryIsFullyScannedAtStartup() async throws {
        let roots = try Roots()
        let url = try roots.make("lib")
        let uuid = UUID()
        let deviceUUID = try #require(FSEventsHistory.deviceUUID(for: url))
        let recorder = ScanRecorder()
        let (coordinator, _, _) = makeCoordinator(
            states: [state(id: 1, uuid: uuid, path: url.path,
                           checkpoint: FSEventsCheckpoint(eventID: 42, deviceUUID: deviceUUID),
                           lastFullScanAt: Date(timeIntervalSinceNow: -100))],
            locations: [uuid: .online(url)], recorder: recorder,
            fullScanInterval: 10)

        await coordinator.resync(startup: true)
        try await settle(coordinator)
        #expect(recorder.fullScanCount == 1)
    }

    @Test("間隔を無効にしていれば定期フルスキャンは走らない [SY-05]")
    func aDisabledIntervalNeverTriggersAPeriodicFullScan() async throws {
        let roots = try Roots()
        let url = try roots.make("lib")
        let uuid = UUID()
        let deviceUUID = try #require(FSEventsHistory.deviceUUID(for: url))
        let recorder = ScanRecorder()
        let (coordinator, _, _) = makeCoordinator(
            states: [state(id: 1, uuid: uuid, path: url.path,
                           checkpoint: FSEventsCheckpoint(eventID: 42, deviceUUID: deviceUUID),
                           lastFullScanAt: Date(timeIntervalSinceNow: -10_000_000))],
            locations: [uuid: .online(url)], recorder: recorder,
            fullScanInterval: nil)

        await coordinator.resync(startup: true)
        try await settle(coordinator)
        #expect(recorder.calls.isEmpty)
    }

    // MARK: - 変更の受け取り

    @Test("変更の要求は差分スキャンになる [SY-03]")
    func aChangeRequestBecomesAnIncrementalScan() async throws {
        let roots = try Roots()
        let url = try roots.make("lib")
        let uuid = UUID()
        let recorder = ScanRecorder()
        let (coordinator, _, _) = makeCoordinator(
            states: [state(id: 1, uuid: uuid, path: url.path)],
            locations: [uuid: .online(url)], recorder: recorder)
        await coordinator.resync()

        coordinator.enqueue(ScanRequest(libraryID: LibraryID(rawValue: 1),
                                        relativePaths: ["作者A/作品.cbz"],
                                        needsFullScan: false, lastEventID: 7))
        try await settle(coordinator)
        #expect(recorder.incrementalPaths == [["作者A/作品.cbz"]])
    }

    /// **短時間に届いた変更は畳んで 1 回にまとめる** [SY-07]。
    @Test("同じライブラリへの要求は畳んで 1 回にする")
    func requestsForTheSameLibraryAreCoalesced() async throws {
        let roots = try Roots()
        let url = try roots.make("lib")
        let uuid = UUID()
        let recorder = ScanRecorder()
        let (coordinator, _, _) = makeCoordinator(
            states: [state(id: 1, uuid: uuid, path: url.path)],
            locations: [uuid: .online(url)], recorder: recorder)
        await coordinator.resync()

        for path in ["a.cbz", "b.cbz", "a.cbz"] {
            coordinator.enqueue(ScanRequest(libraryID: LibraryID(rawValue: 1),
                                            relativePaths: [path],
                                            needsFullScan: false, lastEventID: 1))
        }
        try await settle(coordinator)
        #expect(recorder.calls.count == 1)
        #expect(recorder.incrementalPaths == [["a.cbz", "b.cbz"]], "重複は畳む")
    }

    @Test("フルスキャンの要求が混ざったらフルスキャンにする [SY-04]")
    func aFullScanRequestWins() async throws {
        let roots = try Roots()
        let url = try roots.make("lib")
        let uuid = UUID()
        let recorder = ScanRecorder()
        let (coordinator, _, _) = makeCoordinator(
            states: [state(id: 1, uuid: uuid, path: url.path)],
            locations: [uuid: .online(url)], recorder: recorder)
        await coordinator.resync()

        coordinator.enqueue(ScanRequest(libraryID: LibraryID(rawValue: 1),
                                        relativePaths: ["a.cbz"],
                                        needsFullScan: false, lastEventID: 1))
        coordinator.enqueue(ScanRequest(libraryID: LibraryID(rawValue: 1),
                                        relativePaths: [], needsFullScan: true, lastEventID: 2))
        try await settle(coordinator)
        #expect(recorder.fullScanCount == 1)
        #expect(recorder.incrementalPaths.isEmpty)
    }

    /// 監視していないライブラリの要求は捨てる（オフラインになった直後など）。
    @Test("根が分からないライブラリの要求は走らせない")
    func aRequestForAnUnknownLibraryIsDropped() async throws {
        let recorder = ScanRecorder()
        let (coordinator, _, _) = makeCoordinator(
            states: [], locations: [:], recorder: recorder)
        await coordinator.resync()

        coordinator.enqueue(ScanRequest(libraryID: LibraryID(rawValue: 99),
                                        relativePaths: ["x.cbz"],
                                        needsFullScan: false, lastEventID: 1))
        try await settle(coordinator)
        #expect(recorder.calls.isEmpty)
    }

    // MARK: - 差分の起点の保存 [SY-02][WA-10]

    /// **イベント ID は UUID とセットで保存する。** 単独で保存すると、次に
    /// 読むとき同じ FSEvents データベースのものか確かめられない。
    @Test("走査が終わったら起点を UUID とセットで保存する [SY-02][WA-10]")
    func savesTheCheckpointWithItsDeviceUUID() async throws {
        let roots = try Roots()
        let url = try roots.make("lib")
        let uuid = UUID()
        let recorder = ScanRecorder()
        let (coordinator, repo, _) = makeCoordinator(
            states: [state(id: 1, uuid: uuid, path: url.path)],
            locations: [uuid: .online(url)], recorder: recorder)
        await coordinator.resync()

        coordinator.enqueue(ScanRequest(libraryID: LibraryID(rawValue: 1),
                                        relativePaths: ["a.cbz"],
                                        needsFullScan: false, lastEventID: 1234))
        try await settle(coordinator)
        let saved = try #require(repo.checkpointWrites.last?.1)
        #expect(saved.eventID == 1234)
        #expect(saved.deviceUUID == FSEventsHistory.deviceUUID(for: url))
    }

    @Test("フルスキャンのときだけ最終フルスキャン日時を記録する [SY-05]")
    func recordsTheFullScanTimestampOnlyForFullScans() async throws {
        let roots = try Roots()
        let url = try roots.make("lib")
        let uuid = UUID()
        let recorder = ScanRecorder()
        let (coordinator, repo, _) = makeCoordinator(
            states: [state(id: 1, uuid: uuid, path: url.path)],
            locations: [uuid: .online(url)], recorder: recorder)
        await coordinator.resync()

        coordinator.enqueue(ScanRequest(libraryID: LibraryID(rawValue: 1),
                                        relativePaths: ["a.cbz"],
                                        needsFullScan: false, lastEventID: 1))
        try await settle(coordinator)
        #expect(repo.fullScanWrites.isEmpty)

        coordinator.enqueue(ScanRequest(libraryID: LibraryID(rawValue: 1),
                                        relativePaths: [], needsFullScan: true, lastEventID: 2))
        try await settle(coordinator)
        #expect(repo.fullScanWrites == [LibraryID(rawValue: 1)])
    }

    /// **起点の意味は「この ID まで DB へ反映済み」であって「受け取った」では
    /// ない。** 未処理の要求を抱えたまま進めると、走査せずに終了したときに
    /// その変更が黙って失われる（次のフルスキャンまで最長 7 日）。
    @Test("未処理の要求が残っているライブラリの起点は進めない [SY-02]")
    func doesNotAdvanceTheCheckpointWhileWorkIsStillQueued() async throws {
        let roots = try Roots()
        let url = try roots.make("lib")
        let uuid = UUID()
        let recorder = ScanRecorder()
        // **走らないライブラリ**を作るため、走査を止めた状態で要求だけ積む。
        let (coordinator, repo, _) = makeCoordinator(
            states: [state(id: 1, uuid: uuid, path: url.path)],
            locations: [uuid: .online(url)], recorder: recorder)
        await coordinator.resync()

        coordinator.holdForTesting = true          // pump を動かさない
        coordinator.enqueue(ScanRequest(libraryID: LibraryID(rawValue: 1),
                                        relativePaths: ["a.cbz"],
                                        needsFullScan: false, lastEventID: 5))
        #expect(coordinator.pendingLibraryIDs.contains(LibraryID(rawValue: 1)))

        await coordinator.stop()
        #expect(repo.checkpointWrites.isEmpty, "未処理があるのに起点を進めてはならない")
    }

    /// **取り出しただけで「未処理が無い」と見なしてはならない。** 走査の
    /// 途中で終了したときに、起点だけ進んで変更が失われる。
    @Test("走査の最中に終了しても起点を進めない [SY-02]")
    func doesNotAdvanceTheCheckpointWhileAScanIsInFlight() async throws {
        let roots = try Roots()
        let url = try roots.make("lib")
        let uuid = UUID()
        let gate = ScanGate()
        let recorder = ScanRecorder()
        let repo = FakeLibraryRepository([state(id: 1, uuid: uuid, path: url.path)])
        let watcher = LibraryWatcher()
        let coordinator = LibrarySyncCoordinator(dependencies: .init(
            libraries: repo,
            roots: FakeRootLocator(locations: [uuid: .online(url)]),
            // 走査を止めたまま保持する。
            scan: { mode, _ in recorder.record(mode); await gate.wait(); return ScanSummary() },
            watcher: watcher, monitor: VolumeMonitor(), fullScanInterval: nil))
        await coordinator.resync()

        coordinator.enqueue(ScanRequest(libraryID: LibraryID(rawValue: 1),
                                        relativePaths: ["a.cbz"],
                                        needsFullScan: false, lastEventID: 5))
        // 走査が始まる（＝待ち行列から取り出される）まで待つ。
        let deadline = Date().addingTimeInterval(3)
        while recorder.calls.isEmpty, Date() < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(!recorder.calls.isEmpty, "走査が始まらなかった")
        #expect(coordinator.pendingLibraryIDs.contains(LibraryID(rawValue: 1)),
                "実行中も未処理として数える")

        await coordinator.stop()
        #expect(repo.checkpointWrites.isEmpty, "走査の最中に起点を進めてはならない")
        await gate.open()
    }

    @Test("未処理が無ければ終了時に起点を進める [SY-02]")
    func advancesTheCheckpointOnStopWhenNothingIsQueued() async throws {
        let roots = try Roots()
        let url = try roots.make("lib")
        let uuid = UUID()
        let recorder = ScanRecorder()
        let (coordinator, repo, _) = makeCoordinator(
            states: [state(id: 1, uuid: uuid, path: url.path)],
            locations: [uuid: .online(url)], recorder: recorder)
        await coordinator.resync()

        await coordinator.stop()
        let saved = try #require(repo.checkpointWrites.last?.1)
        #expect(saved.eventID > 0)
        #expect(saved.deviceUUID == FSEventsHistory.deviceUUID(for: url))
    }

    // MARK: - 待ち行列が空になるのを待つ

    /// 走査は待ち行列を非同期に流すので、観測する前に落ち着かせる。
    ///
    /// **固定の `sleep` にしない。** 速い環境では観測前に終わって空振りし、
    /// 遅い環境では落ちる。待ち行列が空で pump も止まった、という**状態**で
    /// 判定する。
    func settle(_ coordinator: LibrarySyncCoordinator,
                within seconds: Double = 5) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if coordinator.isIdle { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("待ち行列が \(seconds) 秒で空にならなかった")
    }
}
