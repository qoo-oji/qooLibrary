//
//  ライブラリを実体に追随させる調整役 [SY-01〜SY-08][VD-01〜VD-11][EV-01〜EV-04]。
//
//  `LibraryWatcher`（FSEvents）・`VolumeMonitor`（着脱）・`ScanEngine`（収束）を
//  結ぶ。**この 3 つは互いを知らない**——変更の検知と、走査と、DB の更新は
//  別々の関心事で、どれをどう繋ぐかという方針だけをここに置く。
//
//  `QooApplication` に置く理由は `LibraryServices` と同じで、`QooPersistence`
//  （リポジトリ）と `QooInfrastructure`（監視・走査）の**両方に依存してよい
//  唯一の層**だから [A-01][A-02]。
//
import Foundation
import QooInfrastructure
import QooKit

/// 起動から終了まで、ライブラリと実体のずれを埋め続ける。
@MainActor
public final class LibrarySyncCoordinator {

    public struct Dependencies {
        public let libraries: any LibraryRepository
        public let roots: any LibraryRootLocating
        /// 走査の実行。`ScanEngine` を包んで渡す（この型は `ScanEngine` の
        /// 組み立て方を知らなくてよい）。
        public let scan: @Sendable (ScanEngine.Mode, URL) async throws -> ScanSummary
        public let watcher: LibraryWatcher
        public let monitor: VolumeMonitor
        /// 起動時にフルスキャンし直すまでの間隔 [SY-05]。`nil` で無効。
        public let fullScanInterval: TimeInterval?

        /// `@MainActor` なのは、既定値の `LibraryWatcher.shared` を読むため。
        @MainActor
        public init(libraries: any LibraryRepository,
                    roots: any LibraryRootLocating = RegisteredFolderRootLocator(),
                    scan: @escaping @Sendable (ScanEngine.Mode, URL) async throws -> ScanSummary,
                    watcher: LibraryWatcher = .shared,
                    monitor: VolumeMonitor = VolumeMonitor(),
                    fullScanInterval: TimeInterval? = AppLimits.Watch.defaultFullScanInterval) {
            self.libraries = libraries
            self.roots = roots
            self.scan = scan
            self.watcher = watcher
            self.monitor = monitor
            self.fullScanInterval = fullScanInterval
        }
    }

    private let deps: Dependencies
    private var subscriptions: [Task<Void, Never>] = []
    private var isStarted = false

    /// 走査の待ち行列。ライブラリごとに畳んで、**1 本ずつ**実行する。
    private var pending: [LibraryID: PendingScan] = [:]
    /// いま走らせている最中のライブラリ。**`pending` から取り出した時点で
    /// ここへ移る**——取り出しただけで「未処理が無い」と見なすと、走査の
    /// 途中で終了したときに起点だけ進んで変更が失われる。
    private var inFlight: Set<LibraryID> = []
    private var pump: Task<Void, Never>?
    /// いま見えている根。走査と `resolvedPath` の更新に使う。
    private var locations: [LibraryID: URL] = [:]

    /// 走査が 1 本終わるたびに呼ばれる。**自動走査ではダイアログを出さない**
    /// ［設計判断］——利用者が Finder で自分で消したファイルに対して
    /// 「N 件が見つからなくなりました」と出るのは純粋な雑音で、
    /// 本当に見てほしい 1 枚まで読み飛ばされるようになる [ER-11 の精神]。
    /// 要約は診断ログに残り、どのファイルかは整理ウインドウ [OR-01〜05] で見る。
    public var onScanFinished: ((LibraryID, ScanSummary) -> Void)?

    public init(dependencies: Dependencies) {
        self.deps = dependencies
    }

    deinit {
        for task in subscriptions { task.cancel() }
        pump?.cancel()
    }

    // MARK: - 開始・停止

    /// 監視を始める。何度呼んでも 1 回しか効かない。
    public func start() async {
        guard !isStarted else { return }
        isStarted = true

        // **購読してから開始する。** 逆にすると、開始直後に届いた着脱を
        // 取りこぼす（`VolumeMonitor.events` は同期的に登録される）。
        let volumeEvents = await deps.monitor.events
        subscriptions.append(Task { [weak self] in
            for await event in volumeEvents {
                guard let self else { return }
                await self.handle(event)
            }
        })
        let requests = deps.watcher.requests
        subscriptions.append(Task { [weak self] in
            for await request in requests {
                guard let self else { return }
                self.enqueue(request)
            }
        })
        await deps.monitor.start()
        await resync(startup: true)
        Log.watch.info("実体への追随を開始: 監視 \(locations.count) ライブラリ")
    }

    /// 監視を止め、差分の起点を保存する [WA-02][SY-02]。
    public func stop() async {
        for task in subscriptions { task.cancel() }
        subscriptions.removeAll()
        pump?.cancel()
        pump = nil
        await deps.monitor.stop()
        await saveCheckpoints(eventID: deps.watcher.latestEventID)
        _ = deps.watcher.stop()
        isStarted = false
        Log.watch.info("実体への追随を停止し、差分の起点を保存した")
    }

    // MARK: - 突き合わせ [VD-03][VD-05][VD-06][VD-08]

    /// 登録の状態と DB を突き合わせ、監視対象を組み直す。
    ///
    /// 起動時・着脱時・ライブラリの増減時・スリープ復帰時に呼ぶ。**冪等**で、
    /// 何度呼んでも同じ状態へ収束する（`ScanEngine` と同じ考え方 [FO-20]）。
    public func resync(startup: Bool = false) async {
        let states: [LibraryWatchState]
        do { states = try await deps.libraries.watchStates() } catch {
            Log.watch.error("ライブラリの監視状態を読めない: \(String(describing: error))")
            return
        }
        guard !states.isEmpty else {
            locations = [:]
            await deps.watcher.setLibraries([])
            return
        }
        let found = await deps.roots.libraryRootLocations()

        var watched: [WatchedLibrary] = []
        var nextLocations: [LibraryID: URL] = [:]
        for state in states {
            let location = found[state.uuid] ?? .unavailable("登録が見つからない")
            await applyOnlineTransition(state, location: location)
            guard let url = location.url else { continue }
            nextLocations[state.id] = url

            // **起点が使えるかは、根の実体に対してその場で確かめる** [WA-11]。
            // 保存した UUID と食い違えば履歴は別物で、渡しても 0 件になる。
            let usable = await FileIO.perform {
                FSEventsHistory.usableCheckpoint(state.checkpoint, rootURL: url)
            }
            watched.append(WatchedLibrary(id: state.id, rootPath: url.path,
                                          usableCheckpoint: usable))
            if startup {
                scheduleStartupScan(state, url: url, historyIsUsable: usable != nil)
            }
        }
        locations = nextLocations
        await deps.watcher.setLibraries(watched)
        startPumpIfNeeded()
    }

    /// オンライン／オフラインの遷移と、根の移動を DB へ書き戻す。
    private func applyOnlineTransition(_ state: LibraryWatchState,
                                       location: LibraryRootLocation) async {
        do {
            if state.isOnline != location.isOnline {
                try await deps.libraries.setOnline(location.isOnline, libraryID: state.id)
                // [VD-10] 状態遷移を記録する。専用の履歴ウインドウはまだ無いので
                // 診断ログに残す（`OperationLogRecord` はフェーズ 2 後半）。
                Log.watch.info(location.isOnline
                    ? "ライブラリがオンラインになった: \(Log.redactable(state.displayName))"
                    : """
                      ライブラリがオフラインになった: \(Log.redactable(state.displayName)) \
                      — \(location.unavailableReason ?? "理由不明")
                      """)
            }
            // ボリュームの改名などで根が動いたら書き直す [VD-06]。
            // **`volumeUUID` は不変なのでファイルの紐づけは維持される。**
            if let url = location.url, url.path != state.resolvedPath {
                try await deps.libraries.setResolvedPath(url.path, libraryID: state.id)
                Log.watch.info("ライブラリの根が移動した: \(Log.redactable(state.displayName)) → \(Log.path(url))")
            }
        } catch {
            Log.watch.error("ライブラリの状態を書き戻せない: \(String(describing: error))")
        }
    }

    /// 起動時に何を走らせるか [SY-03][SY-04][SY-05]。
    private func scheduleStartupScan(_ state: LibraryWatchState, url: URL,
                                     historyIsUsable: Bool) {
        // 履歴が使えないなら、非起動中の変更を知る手段が他に無い [SY-04]。
        // **ネットワークボリュームでは常にこちらへ来る**（§10.1.0 の実測）。
        if !historyIsUsable {
            request(.full, for: state.id, reason: "差分の起点が使えない")
            return
        }
        // 取りこぼしの最終安全網 [SY-05]。履歴が使えていても定期的に均す。
        if let interval = deps.fullScanInterval,
           state.needsPeriodicFullScan(interval: interval) {
            request(.full, for: state.id, reason: "前回のフルスキャンから間隔を超えた")
        }
        // 履歴が使えるなら、非起動中の変更は FSEvents の再生が
        // `ScanRequest` として運んでくる [SY-03]。ここでは何もしない。
    }

    // MARK: - 着脱 [VD-01〜VD-06]

    func handle(_ event: VolumeEvent) async {
        switch event {
        case .mounted, .renamed:
            await resync()                                   // [VD-03][VD-06]
        case .willUnmount(let volumeUUID):
            // **アンマウントを妨げない** [VD-04][VM3-02]。走っている走査を
            // 止めて、起点を保存するだけ。I/O はしない。
            cancelPending(volumeUUID: volumeUUID)
            await saveCheckpoints(eventID: deps.watcher.latestEventID)
        case .didUnmount:
            await resync()                                   // [VD-05]
        }
    }

    /// 手動の「ボリュームを再検証」[VD-09]。
    public func revalidateVolumes() async {
        await deps.monitor.revalidateAll()
        await resync()
    }

    /// 一括処理中は保留する [FO-14][LK-31][EV-02]。
    public func suspend(_ libraryID: LibraryID) { deps.watcher.suspend(libraryID) }
    public func resume(_ libraryID: LibraryID) { deps.watcher.resume(libraryID) }

    // MARK: - 走査の待ち行列

    struct PendingScan {
        var needsFullScan = false
        var paths: Set<String> = []
        var lastEventID: UInt64 = 0
        var reason: String = ""
    }

    enum ScanKind { case full, incremental }

    func enqueue(_ request: ScanRequest) {
        var entry = pending[request.libraryID] ?? PendingScan()
        entry.needsFullScan = entry.needsFullScan || request.needsFullScan
        entry.paths.formUnion(request.relativePaths)
        entry.lastEventID = max(entry.lastEventID, request.lastEventID)
        if entry.reason.isEmpty { entry.reason = "変更を検知" }
        pending[request.libraryID] = entry
        startPumpIfNeeded()
    }

    private func request(_ kind: ScanKind, for id: LibraryID, reason: String) {
        var entry = pending[id] ?? PendingScan()
        if kind == .full { entry.needsFullScan = true }
        entry.reason = reason
        // **起点は「走査を始める前」の値にする。** 走っている間に起きた変更は
        // 次回に再生されるほうが、取りこぼすより安い（スキャンは冪等 [FO-20]）。
        entry.lastEventID = max(entry.lastEventID, FSEventsHistory.currentEventID())
        pending[id] = entry
        startPumpIfNeeded()
    }

    /// テストと診断のための現在地。
    var pendingLibraryIDs: Set<LibraryID> { Set(pending.keys).union(inFlight) }

    private func cancelPending(volumeUUID: String) {
        // 走査は次の `resync` でオフラインと判定されて見送られる [SB-05]ので、
        // ここでは待ち行列から外すだけでよい。実行中のものは根の同一性検査で止まる。
        pending.removeAll()
    }

    /// 待ち行列を**1 本ずつ**流す。
    ///
    /// 並行に走らせない理由は 2 つ。①同じライブラリの重なりは `ScanEngine` が
    /// 弾くので待つだけ無駄 ②別のライブラリでも、走査は I/O を独占するので
    /// 同時に走らせると全部が遅くなる（特にネットワーク）。
    /// テスト用。待ち行列を流さずに積んだ状態を作る。
    var holdForTesting = false

    private func startPumpIfNeeded() {
        guard !holdForTesting else { return }
        guard pump == nil, !pending.isEmpty else { return }
        pump = Task { [weak self] in
            while let self, !Task.isCancelled {
                guard let next = self.takeNext() else { break }
                await self.run(next.id, next.scan)
            }
            self?.pump = nil
        }
    }

    /// 待ち行列が空で、流している途中でもない。**テストの同期点。**
    ///
    /// 固定の `sleep` で待つと、速い環境では観測前に終わり、遅い環境では
    /// 落ちる——時間ではなく状態で待つ（このコードベースで繰り返している作法）。
    var isIdle: Bool { pending.isEmpty && inFlight.isEmpty && pump == nil }

    private func takeNext() -> (id: LibraryID, scan: PendingScan)? {
        guard let id = pending.keys.sorted(by: { $0.rawValue < $1.rawValue }).first,
              let entry = pending.removeValue(forKey: id) else { return nil }
        inFlight.insert(id)
        return (id, entry)
    }

    private func run(_ id: LibraryID, _ entry: PendingScan) async {
        defer { inFlight.remove(id) }
        guard let url = locations[id] else { return }
        let mode: ScanEngine.Mode = entry.needsFullScan || entry.paths.isEmpty
            ? .full(libraryID: id)
            : .incremental(libraryID: id, paths: entry.paths.sorted())
        // 起点は走査の**前**に控える（`request` と同じ理由）。
        let eventID = entry.lastEventID == 0 ? FSEventsHistory.currentEventID() : entry.lastEventID
        do {
            let summary = try await deps.scan(mode, url)
            guard !summary.cancelled, !summary.skipped else { return }
            await saveCheckpoint(libraryID: id, url: url, eventID: eventID,
                                 didFullScan: entry.needsFullScan || entry.paths.isEmpty)
            Log.scan.debug("""
                自動走査 \(entry.reason): 追加 \(summary.added) / 更新 \(summary.updated) \
                / 孤立 \(summary.orphaned) / 場所 \(summary.scannedUnits)
                """)
            onScanFinished?(id, summary)
        } catch is CancellationError {
            // 利用者が止めた／アンマウントで畳んだ。次の突き合わせで拾い直す。
        } catch {
            Log.scan.warning("自動走査に失敗: \(String(describing: error))")
        }
    }

    // MARK: - 差分の起点の保存 [SY-02][WA-10]

    private func saveCheckpoint(libraryID: LibraryID, url: URL,
                                eventID: UInt64, didFullScan: Bool) async {
        // **UUID とセットで保存する。** 単独で保存できる API を持たせて
        // いないのは、次に読むとき検証できない起点を作らないため。
        // **番兵を保存しない**（多層防御）。上流で落としているが、ここは
        // すべての保存経路が通る 1 箇所なので、最後にもう一度確かめる。
        guard eventID != 0, eventID != FSEventsCheckpoint.sinceNowSentinel else {
            Log.watch.debug("起点が実在の ID でないので保存しない")
            return
        }
        let deviceUUID = await FileIO.perform { FSEventsHistory.deviceUUID(for: url) }
        do {
            try await deps.libraries.setFSEventsCheckpoint(
                FSEventsCheckpoint(eventID: eventID, deviceUUID: deviceUUID),
                libraryID: libraryID)
            if didFullScan {
                try await deps.libraries.setLastFullScanAt(Date(), libraryID: libraryID)
            }
        } catch {
            Log.watch.warning("差分の起点を保存できない: \(String(describing: error))")
        }
    }

    /// 監視中のライブラリの起点をまとめて保存する（終了時・アンマウント時）。
    ///
    /// **未処理の要求が残っているライブラリは進めない。** 起点の意味は
    /// 「この ID までは DB へ反映済み」であって「この ID まで受け取った」では
    /// ない——受け取っただけで進めると、走査せずに終了したときに**その変更が
    /// 黙って失われる**（次のフルスキャン [SY-05] まで、最長 7 日）。
    ///
    /// 待ち行列が空なら、届いたものはすべて反映済みなので進めてよい。
    /// まだ配送されていないイベントは `FSEventStreamGetLatestEventId` より
    /// 大きい ID を持つので、これを起点にしても飛ばさない。
    private func saveCheckpoints(eventID: UInt64) async {
        for (id, url) in locations where pending[id] == nil && !inFlight.contains(id) {
            await saveCheckpoint(libraryID: id, url: url, eventID: eventID, didFullScan: false)
        }
    }
}
