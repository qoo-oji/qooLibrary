//
//  登録フォルダの監視 [10.1][10.5][SY-01〜SY-08][WA-01〜WA-07][FO-12][EV-01〜EV-04]。
//
//  10.0 の `DirectoryChangeHub`（「今画面に映っているものを実体に合わせる」）とは
//  別の関心事。こちらは「登録フォルダを DB と突き合わせて収束させる」ための入口で、
//  土台の `FileSystemEventStream` だけを共有する。
//
import Foundation
import QooKit

/// 1 回の差分の要求。
public struct ScanRequest: Sendable, Equatable {
    public let libraryID: LibraryID
    /// 変更のあった相対パス。空なら全体。
    public let relativePaths: [String]
    /// `MustScanSubDirs` 等でフルスキャンへ落とす必要がある [SY-04][WA-04]。
    public let needsFullScan: Bool
    /// このバッチで最後に見たイベント ID。保存して次回の `sinceWhen` にする [SY-02]。
    public let lastEventID: UInt64

    public init(libraryID: LibraryID, relativePaths: [String],
                needsFullScan: Bool, lastEventID: UInt64) {
        self.libraryID = libraryID
        self.relativePaths = relativePaths
        self.needsFullScan = needsFullScan
        self.lastEventID = lastEventID
    }
}

/// 監視対象のライブラリ。
public struct WatchedLibrary: Sendable, Equatable {
    public let id: LibraryID
    /// 解決済みの根（物理パス）。
    public let rootPath: String
    /// **使えると検証済みの**差分の起点 [SY-02][WA-11]。`nil` は
    /// 「履歴を要求してはいけない」——渡すと**黙って 0 件になる**（§10.1.0）。
    ///
    /// 検証は呼び出し側（調整役）が `FSEventsHistory.usableCheckpoint` で
    /// 済ませてから渡す。**ここで検証しないのは、検証が I/O を伴うため**
    /// （この型はメインアクタ上で組み立てられる）。
    public let usableCheckpoint: FSEventsCheckpoint?

    public init(id: LibraryID, rootPath: String, usableCheckpoint: FSEventsCheckpoint? = nil) {
        self.id = id
        self.rootPath = rootPath
        self.usableCheckpoint = usableCheckpoint
    }
}

/// `FileSystemEventStream` が `@MainActor` に閉じているため、こちらも
/// メインアクタに置く（`DirectoryChangeHub` と同じ）。ここでする仕事は
/// 台帳の照合（ロック 1 回）と振り分けだけで、I/O をしない。
@MainActor
public final class LibraryWatcher {
    /// アプリ全体で 1 つ [ST-01]。`FileOperationService` の 1 箇所から
    /// 自己変更を届けるための固定の宛先が要る（``noteLocalChanges(at:)`` 参照）。
    public static let shared = LibraryWatcher()

    private var stream: FileSystemEventStream?
    var watched: [WatchedLibrary] = []
    var continuations: [UUID: AsyncStream<ScanRequest>.Continuation] = [:]
    /// 一括処理中は保留する [FO-14][LK-31][EV-02]。
    private var suspendedLibraries: Set<LibraryID> = []
    private var pendingWhileSuspended: [LibraryID: Set<String>] = [:]
    private let ledger: ExpectedChangeLedger

    public init(ledger: ExpectedChangeLedger = .shared) {
        self.ledger = ledger
    }

    public var requests: AsyncStream<ScanRequest> {
        AsyncStream { continuation in
            let id = UUID()
            self.continuations[id] = continuation
            continuation.onTermination = { _ in
                Task { @MainActor in self.continuations.removeValue(forKey: id) }
            }
        }
    }

    /// 監視対象を差し替える。**オフラインのライブラリには張らない** [SY-08][WA-06]。
    ///
    /// ストリームは 1 本で足りる。FSEvents のイベント ID はシステム全体で単調
    /// （SDK いわく「global, system-wide clock のように振る舞う」）なので、
    /// `sinceWhen` は**検証済みの起点の最小値**にしておけば取りこぼさない。
    /// 新しい起点を持つライブラリには余分なイベントが届くが、スキャンは冪等
    /// なので害が無い [FO-20]。
    ///
    /// **検証できなかったライブラリの起点は混ぜない** [WA-12]。混ぜても
    /// そのボリュームには履歴が無いので再生されず（§10.1.0 の実測）、
    /// 代わりに他のボリュームの履歴を無用に遡らせるだけになる。
    /// そういうライブラリは呼び出し側がフルスキャンへ落とす。
    public func setLibraries(_ libraries: [WatchedLibrary]) async {
        watched = libraries
        guard !libraries.isEmpty else {
            stream = nil
            return
        }
        if stream == nil {
            let box = WeakBox(self)
            stream = FileSystemEventStream(
                sinceWhen: Self.sinceWhen(for: libraries),
                // スキャンの入力なので、表示の追随より長くまとめる [SY-07]。
                latency: AppLimits.Watch.scanCoalescingLatency
            ) { changes in
                Task { @MainActor in box.value?.handle(changes) }
            }
        }
        await stream?.setRoots(Self.prunedRoots(libraries.map(\.rootPath)))
    }

    /// ストリームに渡す差分の起点を決める [SY-03][WA-11][WA-12]。
    ///
    /// **検証済みの起点だけを使い、その最小値を採る。** イベント ID は
    /// システム全体で単調（SDK いわく「global, system-wide clock のように
    /// 振る舞う」）なので、最小値なら取りこぼさない。余分に届く分は
    /// スキャンが冪等 [FO-20] なので害が無い。
    ///
    /// **検証できなかった起点は混ぜない** [WA-12]。混ぜてもそのボリュームには
    /// 履歴が無いので再生されず（§10.1.0 の実測）、他のボリュームの履歴を
    /// 無用に遡らせるだけになる。1 つも無ければ「今から」。
    static func sinceWhen(for libraries: [WatchedLibrary]) -> FSEventStreamEventId {
        guard let earliest = libraries.compactMap({ $0.usableCheckpoint?.eventID }).min() else {
            return FSEventStreamEventId(kFSEventStreamEventIdSinceNow)
        }
        return FSEventStreamEventId(earliest)
    }

    /// **自プロセスが加えた変更**を伝える [FO-01]。
    ///
    /// FSEvents は `kFSEventStreamCreateFlagIgnoreSelf` [FO-10] で自分の変更を
    /// 落とし、さらに期待変更台帳 [FO-12] も落とす。二重に落ちるので、
    /// **アプリがライブラリフォルダへ入れたファイルは DB に載らない**
    /// ——ファイルマネージャーからドラッグしたものが蔵書に現れない、という形。
    ///
    /// `DirectoryChangeHub.noteLocalChanges` と同じ考え方で、
    /// `FileOperationService` の 1 箇所から明示的に知らせる。ファイルシステムを
    /// 変更する経路はすべてそこを通ることが静的検査 [FO-02][B-10] で
    /// 強制されているので、**知らせ忘れが構造的に起こらない。**
    ///
    /// - Note: **台帳を引かない。** 台帳の目的は自動リネームの無限ループを
    ///   防ぐこと [R-13][FO-24] であって、収束型のスキャン [FO-20] にとっては
    ///   「自分の変更こそ DB に反映すべきもの」である。ここでの二重処理は
    ///   冪等なので無害。
    public nonisolated static func noteLocalChanges(at urls: [URL]) {
        guard !urls.isEmpty else { return }
        Task { @MainActor in shared.noteLocalChanges(at: urls) }
    }

    /// ``noteLocalChanges(at:)`` の実体。既にメインアクタ上の呼び出し元
    /// （テストを含む）はこちらを直接使える。
    public func noteLocalChanges(at urls: [URL]) {
        guard !watched.isEmpty else { return }          // ライブラリが無ければ何もしない
        var byLibrary: [LibraryID: Set<String>] = [:]
        for url in urls {
            let path = url.standardizedFileURL.path
            guard let library = library(containing: path) else { continue }
            byLibrary[library.id, default: []].insert(Self.relativePath(path, in: library))
        }
        for (id, paths) in byLibrary {
            if suspendedLibraries.contains(id) {
                pendingWhileSuspended[id, default: []].formUnion(paths)   // [FO-14][EV-02]
                continue
            }
            emit(ScanRequest(libraryID: id, relativePaths: paths.sorted(),
                             needsFullScan: false, lastEventID: latestEventID))
        }
    }

    /// いまストリームが処理した最新のイベント ID。監視していなければ
    /// **システム全体の現在値**を使う——`0` を保存すると「まだ無い」の意味に
    /// なり、次回に履歴を要求できなくなる。
    public var latestEventID: UInt64 {
        stream.map { UInt64($0.latestEventID) } ?? FSEventsHistory.currentEventID()
    }

    /// テスト用。実 FSEvents を張らずに振り分けだけを試す。
    func setWatchedForTesting(_ libraries: [WatchedLibrary]) { watched = libraries }

    /// 監視を止め、最後のイベント ID を返す [WA-02][SY-02]。
    public func stop() -> UInt64 {
        let id = stream.map { UInt64($0.latestEventID) } ?? 0
        stream = nil
        watched = []
        return id
    }

    /// 一括処理中の一時停止 [FO-14][LK-31]。完了後に差分照合を 1 回だけ実行する。
    public func suspend(_ libraryID: LibraryID) {
        suspendedLibraries.insert(libraryID)
    }

    public func resume(_ libraryID: LibraryID) {
        suspendedLibraries.remove(libraryID)
        guard let paths = pendingWhileSuspended.removeValue(forKey: libraryID), !paths.isEmpty
        else { return }
        emit(ScanRequest(libraryID: libraryID, relativePaths: Array(paths).sorted(),
                         needsFullScan: false, lastEventID: latestEventID))
    }

    // MARK: - イベントの処理 [10.5]

    func handle(_ changes: [FileSystemChange]) {
        var byLibrary: [LibraryID: Set<String>] = [:]
        var fullScan: Set<LibraryID> = []

        for change in changes {
            guard let library = library(containing: change.path) else { continue }
            if change.isRootChanged || change.mustScanSubDirectories {
                fullScan.insert(library.id)                        // [SY-04][WA-04]
                continue
            }
            // ① 台帳照合。自己変更はここで落とす [FO-12][EV-01]。
            if ledger.consume(path: change.path) != nil { continue }

            byLibrary[library.id, default: []]
                .insert(Self.relativePath(change.path, in: library))
        }

        let lastID = latestEventID
        for id in fullScan {
            guard !suspendedLibraries.contains(id) else { continue }   // [EV-02]
            emit(ScanRequest(libraryID: id, relativePaths: [],
                             needsFullScan: true, lastEventID: lastID))
        }
        for (id, paths) in byLibrary where !fullScan.contains(id) {
            if suspendedLibraries.contains(id) {
                pendingWhileSuspended[id, default: []].formUnion(paths)  // [FO-14][EV-02]
                continue
            }
            emit(ScanRequest(libraryID: id, relativePaths: paths.sorted(),
                             needsFullScan: false, lastEventID: lastID))
        }
    }

    func emit(_ request: ScanRequest) {
        for continuation in continuations.values { continuation.yield(request) }
    }

    /// 監視ルートからの相対パス。根そのものなら空文字。
    static func relativePath(_ path: String, in library: WatchedLibrary) -> String {
        if path == library.rootPath { return "" }
        guard path.hasPrefix(library.rootPath + "/") else { return path }
        return String(path.dropFirst(library.rootPath.count + 1))
    }

    func library(containing path: String) -> WatchedLibrary? {
        // 最長一致。`/` は他のすべての接頭辞なので、素の前方一致では誤る
        // （`MountTable` で同じ罠を踏んでいる）。
        watched
            .filter { path == $0.rootPath || path.hasPrefix($0.rootPath + "/") }
            .max { $0.rootPath.count < $1.rootPath.count }
    }

    /// 祖先に含まれるルートを剪定する [DW-03]。
    ///
    /// **辞書順で直前の要素だけを見る実装にしてはならない**——`/a`・`/a b`・`/a/b`
    /// の順に並ぶため、`/a/b` の直前が `/a b` になって剪定に失敗する。
    static func prunedRoots(_ paths: [String]) -> [String] {
        let unique = Array(Set(paths)).sorted { $0.count < $1.count }
        var kept: [String] = []
        for path in unique {
            if kept.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) { continue }
            kept.append(path)
        }
        return kept.sorted()
    }
}

/// `FileSystemEventStream` のコールバックから自分を強参照しないための箱。
@MainActor
private final class WeakBox {
    weak var value: LibraryWatcher?
    init(_ value: LibraryWatcher) { self.value = value }
}
