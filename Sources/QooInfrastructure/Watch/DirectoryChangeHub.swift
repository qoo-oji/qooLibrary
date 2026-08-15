import AppKit
import Foundation
import QooKit

/// 「そのフォルダの何を見張るか」。
public enum DirectoryWatchScope: Sendable, Hashable {
    /// 直下だけ。一覧表示・ツリーの 1 行など、**そのフォルダの中身が
    /// 見えている**場所が使う。孫以下の変更では反応しない。
    case shallow
    /// 配下すべて。再帰検索の結果や、再帰的な集計 [DT-05][DT-06] が使う。
    case deep
}

/// 表示中のフォルダに外部（Finder・他アプリ・他のマシン）から加えられた変更を
/// 検知し、**関心のある表示だけ**を更新させる中枢 [10章 §10.0]。
///
/// ## なぜ必要か
/// ファイルマネージャーとして、表示している内容が実体と食い違ったままなのは
/// 致命的である。1-16 まではアプリ自身の操作を `SessionState.reloadToken` で
/// 全ウインドウへ知らせるだけで、アプリの外で起きた変更には一切追随できなかった。
///
/// ## 3 つの入口を 1 つの出口へ束ねる
/// | 入口 | 何を拾うか | 遅延 |
/// |---|---|---|
/// | FSEvents（`FileSystemEventStream`）| ローカルボリュームで**他プロセス**が加えた変更 | `AppLimits.Watch.coalescingLatency` |
/// | ``noteLocalChanges(at:)`` | **自プロセス**が加えた変更。FSEvents は `IgnoreSelf` で自分の変更を落とすため、こちらで明示的に伝える | 即時 |
/// | ディレクトリ更新日時のポーリング | ネットワークボリューム上の変更。FSEvents は他のマシンが加えた変更を報告しない | `AppLimits.Watch.remotePollInterval` |
///
/// 出口はどれも同じ ``DirectoryObservation/generation`` の加算で、購読側から
/// 見れば区別が無い。**差分を適用するのではなく「読み直せ」とだけ伝える**
/// [設計判断] — スキャンエンジンの「実ファイルの状態と突き合わせて収束させる」
/// [FO-20][SY-12] と同じ考え方で、同じ変更を 2 回伝えても結果が変わらない。
///
/// ## 自分の変更をどう伝えるか
/// **`FileOperationService` の 1 箇所から通知する** [FO-01]。ファイルシステムを
/// 変更する経路はすべてそこを通ることが静的検査 [FO-02][B-10] で強制されている
/// ので、通知を書き忘れることが構造的に起こらない。`CommandStack.record()` が
/// 実行・取り消し・やり直しのログを 1 箇所に集めているのと同じ考え方。
///
/// ## `QooInfrastructure` に置く理由
/// OS（FSEvents・`NSWorkspace`）に face する部品であり、`FileOperationService`
/// からも UI からも届く必要がある。`ThumbnailVisibility` が同じ理由でこの層に
/// いるのと同じ位置づけ。
///
/// ## 2-2 との関係
/// 仕様 10.1 節の `FSEventsWatcher`（登録フォルダごとに 1 ストリームを張り、
/// `FSEventStreamEventId` を DB に保存して差分スキャンを駆動する）とは
/// **別の関心事**であり、置き換えるものではない。こちらは「今画面に映って
/// いるものを実体に合わせる」ためだけの、DB に依存しない部品。2-2 では
/// `FileSystemEventStream` を土台として再利用できる。
@MainActor
public final class DirectoryChangeHub {
    public static let shared = DirectoryChangeHub()

    /// アプリが前面にあるか。ネットワークボリュームのポーリングを前面時だけに
    /// 絞るために使う。テストからは差し替えられる（既定の実体を評価するのは
    /// 実際にポーリングが動くときだけなので、`NSApplication` を使わない
    /// テストがこれに触れることは無い）。
    private let isApplicationActive: @MainActor () -> Bool

    private var stream: FileSystemEventStream?
    private var registrations: [UUID: Registration] = [:]
    /// 「直下を見張っている関心」の索引（パス → 登録 ID）。イベント 1 件あたり
    /// 辞書 2 回の引き当てで済ませるためのもの。
    private var shallowIndex: [String: Set<UUID>] = [:]
    /// 「配下すべてを見張っている関心」。イベント 1 件ごとに全登録を走査すると
    /// 最悪ケース（4,000 件のイベント × 数十件の関心）で無駄が大きいため、
    /// 前方一致の照合が要る関心だけを分けて持つ（通常 0〜1 件）。
    private var deepTokens: Set<UUID> = []
    // 以下 3 つは `deinit`（`nonisolated`）から後始末するため
    // `nonisolated(unsafe)`。書き換えはすべてメインアクタ上のメソッドから
    // 行い、`deinit` の時点では他に参照が無いため競合しない。
    private nonisolated(unsafe) var rootRebuildTask: Task<Void, Never>?
    private nonisolated(unsafe) var remotePollTask: Task<Void, Never>?
    private nonisolated(unsafe) var activationObserver: (any NSObjectProtocol)?

    public init(isApplicationActive: @escaping @MainActor () -> Bool = { NSApplication.shared.isActive }) {
        self.isApplicationActive = isApplicationActive
        // アプリが前面に戻ったときの取りこぼし対策 [MX-10 と同じ考え方]。
        // FSEvents が何らかの理由で届かなかった変更、スリープ中の変更、
        // ネットワークボリューム上の変更のいずれもここで拾い直せる。
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.notifyAll(reason: "アプリが前面に戻った") }
        }
    }

    deinit {
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
        rootRebuildTask?.cancel()
        remotePollTask?.cancel()
    }

    // MARK: - 関心の登録

    /// `observation` が `url` を見張るようにする。既に同じ対象を見張って
    /// いれば何もしない。`url` が `nil` なら見張りを解く。
    ///
    /// 登録は**弱参照**で保持するので、`observation` が解放されればこの
    /// 登録も自然に効かなくなる（`DirectoryObservation.deinit` が
    /// ``unregister(_:)`` も呼ぶ）。
    func register(_ observation: DirectoryObservation, token: UUID, url: URL?, scope: DirectoryWatchScope) {
        guard let url else {
            unregister(token)
            return
        }
        let keys = Self.indexKeys(for: url)
        if let existing = registrations[token], existing.keys == keys, existing.scope == scope {
            return
        }
        removeFromIndex(token)
        registrations[token] = Registration(
            keys: keys,
            watchRoot: keys.last ?? url.path,
            scope: scope,
            observation: observation,
            isRemote: Self.isOnRemoteVolume(url)
        )
        addToIndex(token)
        scheduleRootRebuild()
        updateRemotePolling()
    }

    func unregister(_ token: UUID) {
        guard registrations[token] != nil else { return }
        removeFromIndex(token)
        registrations[token] = nil
        scheduleRootRebuild()
        updateRemotePolling()
    }

    // MARK: - 自分が加えた変更 [FO-01 の choke point から呼ばれる]

    /// アプリ自身が変更した項目を伝える。`FileOperationService` の各操作から
    /// 呼ばれる唯一の入口。
    ///
    /// **`nonisolated`** — `FileOperationService` は `actor` で、その中から
    /// 待たずに呼べる必要があるため。順序は問わない（世代番号を増やすだけで、
    /// 実際の中身は購読側が読み直して確かめる）。
    public nonisolated static func noteLocalChanges(at urls: [URL]) {
        guard !urls.isEmpty else { return }
        Task { @MainActor in shared.noteLocalChanges(at: urls) }
    }

    /// ``noteLocalChanges(at:)`` の実体。既にメインアクタ上にいる呼び出し元
    /// （テストを含む）はこちらを直接使える。
    public func noteLocalChanges(at urls: [URL]) {
        guard !urls.isEmpty else { return }
        apply(changedPaths: urls.map { $0.standardizedFileURL.path })
    }

    // MARK: - イベントの振り分け

    /// 変更のあったパスから、影響を受ける関心を割り出して知らせる。
    ///
    /// - `parent(P)` を直下に持つ関心 … 一覧の項目が増減・改名・変化した
    /// - `P` 自身を見張っている関心 … そのフォルダ自体が消えた・改名された
    /// - `P` を含む配下を見張っている関心 … 再帰検索・再帰集計
    private func apply(changedPaths: [String], rescanRoots: [String] = []) {
        guard !registrations.isEmpty else { return }
        var affected: Set<UUID> = []

        for path in changedPaths {
            if let ids = shallowIndex[(path as NSString).deletingLastPathComponent] { affected.formUnion(ids) }
            if let ids = shallowIndex[path] { affected.formUnion(ids) }
            for token in deepTokens where registrations[token]?.contains(path) == true {
                affected.insert(token)
            }
        }

        // [SY-04] イベントが多すぎて個別に列挙できなかった範囲。その配下に
        // ある関心はすべて疑う。
        for root in rescanRoots {
            for (token, registration) in registrations where registration.isAtOrUnder(root) {
                affected.insert(token)
            }
        }

        // 「なぜ画面が更新されないのか」は実機で必ず問われる種類の問いなので、
        // 経路が働いていること自体を追えるようにしておく。既定のレベル
        // （`info`）では出さない — 変更のたびに 1 行出るため。
        // **パスは書かない** — 件数だけで診断には足り、匿名化の対象を
        // 増やさずに済む。
        if !affected.isEmpty {
            Log.watch.debug("変更を検知: パス \(changedPaths.count) 件 → 表示 \(affected.count) 件を読み直し")
        }
        notify(affected)
    }

    private func notify(_ tokens: Set<UUID>) {
        var stale: [UUID] = []
        for token in tokens {
            guard let registration = registrations[token] else { continue }
            if let observation = registration.observation {
                observation.markChanged()
            } else {
                stale.append(token)
            }
        }
        for token in stale { unregister(token) }
    }

    private func notifyAll(reason: String) {
        guard !registrations.isEmpty else { return }
        Log.watch.debug("表示中のフォルダを再同期: \(reason)（関心 \(registrations.count) 件）")
        notify(Set(registrations.keys))
    }

    // MARK: - 監視ルート集合

    /// 関心が増減するたびにストリームを作り直すのではなく、短く待ち合わせて
    /// 1 回にまとめる（フォルダツリーを一気に展開すると関心が数十件まとめて
    /// 増えるため）。
    private func scheduleRootRebuild() {
        rootRebuildTask?.cancel()
        rootRebuildTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(AppLimits.Watch.rootRebuildDebounce))
            guard !Task.isCancelled, let self else { return }
            self.rebuildRoots()
        }
    }

    private func rebuildRoots() {
        let roots = Self.pruneDescendants(Set(registrations.values.map(\.watchRoot)))
        guard !roots.isEmpty else {
            stream?.setRoots([])
            return
        }
        if stream == nil {
            // 配送は専用キューから来るので、`@MainActor` へ渡し直す
            // （`FileSystemEventStream` のスレッドに関する説明を参照）。
            stream = FileSystemEventStream { [weak self] changes in
                Task { @MainActor in self?.handle(changes) }
            }
        }
        stream?.setRoots(roots)
    }

    private func handle(_ changes: [FileSystemChange]) {
        var paths: [String] = []
        var rescanRoots: [String] = []
        paths.reserveCapacity(changes.count)
        for change in changes {
            paths.append(change.path)
            if change.mustScanSubDirectories { rescanRoots.append(change.path) }
        }
        apply(changedPaths: paths, rescanRoots: rescanRoots)
    }

    /// FSEvents は監視ルート配下を**再帰的に**見るので、祖先が含まれている
    /// パスは渡すだけ無駄になる。
    ///
    /// 辞書順の直前の要素だけを見る実装にしてはいけない — `/a`・`/a b`・`/a/b`
    /// の順に並ぶため（空白 0x20 は `/` 0x2F より小さい）、`/a/b` の直前は
    /// 祖先ではない `/a b` になる。採用済みの全件と突き合わせる。件数は
    /// たかだか表示中のフォルダ数なので素直に書いて問題ない。
    nonisolated static func pruneDescendants(_ paths: Set<String>) -> [String] {
        var kept: [String] = []
        for path in paths.sorted() {
            let hasAncestor = kept.contains { Self.path(path, isAtOrUnder: $0) }
            if !hasAncestor { kept.append(path) }
        }
        return kept
    }

    nonisolated static func path(_ path: String, isAtOrUnder ancestor: String) -> Bool {
        if path == ancestor { return true }
        if ancestor == "/" { return path.hasPrefix("/") }
        return path.hasPrefix(ancestor + "/")
    }

    // MARK: - ネットワークボリューム

    /// リモートボリューム上の関心が 1 つでもあればポーリングを動かし、
    /// 無くなれば止める。
    private func updateRemotePolling() {
        let needsPolling = registrations.values.contains { $0.isRemote && $0.scope == .shallow }
        if needsPolling {
            guard remotePollTask == nil else { return }
            remotePollTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(AppLimits.Watch.remotePollInterval))
                    guard !Task.isCancelled, let self else { return }
                    self.pollRemoteDirectories()
                }
            }
        } else {
            remotePollTask?.cancel()
            remotePollTask = nil
        }
    }

    /// リモートボリューム上のフォルダについて、ディレクトリ自身の更新日時が
    /// 変わっていれば読み直させる。
    ///
    /// **子ファイルの中身だけが変わった場合は検知できない**（ディレクトリの
    /// 更新日時は項目の増減・改名でしか動かない）。それでも一覧の見た目に
    /// 効くのは主に項目の増減なので、`stat` 1 回で済むこの方法を採る
    /// [設計判断]。完全な追随はアプリが前面に戻ったときの再同期に委ねる。
    private func pollRemoteDirectories() {
        guard isApplicationActive() else { return }
        var affected: Set<UUID> = []
        for (token, registration) in registrations where registration.isRemote && registration.scope == .shallow {
            let previous = registration.lastRemoteStamp
            let current = Self.directoryStamp(registration.watchRoot)
            guard previous != current else { continue }
            registrations[token]?.lastRemoteStamp = current
            // 初回は基準を取るだけで、変化したとは見なさない。
            if previous != nil { affected.insert(token) }
        }
        notify(affected)
    }

    private static func directoryStamp(_ path: String) -> DirectoryStamp {
        var info = stat()
        guard stat(path, &info) == 0 else { return DirectoryStamp(exists: false, seconds: 0, nanoseconds: 0) }
        return DirectoryStamp(
            exists: true,
            seconds: Int64(info.st_mtimespec.tv_sec),
            nanoseconds: Int64(info.st_mtimespec.tv_nsec)
        )
    }

    private static func isOnRemoteVolume(_ url: URL) -> Bool {
        // 取得できなければローカル扱い（ポーリングしない）。存在しないパスや
        // 権限の無い場所で毎回失敗しても実害が無い側に倒す。
        (try? url.resourceValues(forKeys: [.volumeIsLocalKey]))?.volumeIsLocal == false
    }

    // MARK: - 索引

    private func addToIndex(_ token: UUID) {
        guard let registration = registrations[token] else { return }
        switch registration.scope {
        case .shallow:
            for key in registration.keys { shallowIndex[key, default: []].insert(token) }
        case .deep:
            deepTokens.insert(token)
        }
    }

    private func removeFromIndex(_ token: UUID) {
        guard let registration = registrations[token] else { return }
        deepTokens.remove(token)
        for key in registration.keys {
            shallowIndex[key]?.remove(token)
            if shallowIndex[key]?.isEmpty == true { shallowIndex[key] = nil }
        }
    }

    /// 照合に使うパスの表記。
    ///
    /// FSEvents は**シンボリックリンクや firmlink を解決した実体のパス**を
    /// 返す（`/tmp/x` ではなく `/private/tmp/x`）一方、`noteLocalChanges` へ
    /// 渡ってくるのは画面が扱っているままの URL である。どちらでも引き当て
    /// られるよう両方を索引に載せる。解決は登録時に一度だけで、イベント 1 件
    /// ごとの経路にはファイルシステムへの問い合わせを持ち込まない。
    nonisolated static func indexKeys(for url: URL) -> [String] {
        let standardized = url.standardizedFileURL.path
        let physical = physicalPath(standardized)
        return standardized == physical ? [standardized] : [standardized, physical]
    }

    /// `path` の物理パス。
    ///
    /// **`URL.resolvingSymlinksInPath()` を使ってはいけない** [実装中に発見]。
    /// あれは「先頭が `/private` なら `/private` を取り除く」という特別扱いを
    /// 持つ（Foundation のドキュメントに明記されている）ため、`/private/var/…`
    /// を `/var/…` へ**逆向きに**畳んでしまう。FSEvents が返すのは
    /// `/private/var/…` の側なので、これで正規化すると一時ディレクトリ配下を
    /// 見張ったときにイベントが 1 件も引き当たらない（統合テストが 4 件とも
    /// 落ちて発覚した）。`realpath(3)` にはこの特別扱いが無い。
    ///
    /// まだ存在しないパス（ボリュームが未接続の登録フォルダ、これから作られる
    /// フォルダ）に対しては `realpath` が失敗するため、実在する最も深い祖先
    /// まで遡って解決し、残りの成分を継ぎ足す。
    private nonisolated static func physicalPath(_ path: String) -> String {
        if let resolved = realpath(path, nil) {
            defer { free(resolved) }
            return String(cString: resolved)
        }
        let parent = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        // ルートまで遡ったら打ち切る（`deletingLastPathComponent` は `/` に
        // 対して `/` を返す）。本プロジェクトで 2 度踏んでいる、パス走査の
        // 無限ループを持ち込まないための番人。
        guard !parent.isEmpty, parent != path, !name.isEmpty else { return path }
        return (physicalPath(parent) as NSString).appendingPathComponent(name)
    }

    private struct Registration {
        /// 照合用のパス表記（1〜2 件、``indexKeys(for:)`` 参照）。
        let keys: [String]
        /// FSEvents に渡すパス。実体のパス（`keys` の末尾）を使う。
        let watchRoot: String
        let scope: DirectoryWatchScope
        weak var observation: DirectoryObservation?
        let isRemote: Bool
        var lastRemoteStamp: DirectoryStamp?

        func contains(_ path: String) -> Bool {
            keys.contains { DirectoryChangeHub.path(path, isAtOrUnder: $0) }
        }

        func isAtOrUnder(_ ancestor: String) -> Bool {
            keys.contains { DirectoryChangeHub.path($0, isAtOrUnder: ancestor) }
        }
    }

    private struct DirectoryStamp: Equatable {
        let exists: Bool
        let seconds: Int64
        let nanoseconds: Int64
    }
}
