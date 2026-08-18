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
}

/// 監視対象のライブラリ。
public struct WatchedLibrary: Sendable, Equatable {
    public let id: LibraryID
    /// 解決済みの根（物理パス）。
    public let rootPath: String
    /// 前回保存したイベント ID [SY-02]。
    public let lastEventID: UInt64

    public init(id: LibraryID, rootPath: String, lastEventID: UInt64) {
        self.id = id
        self.rootPath = rootPath
        self.lastEventID = lastEventID
    }
}

/// `FileSystemEventStream` が `@MainActor` に閉じているため、こちらも
/// メインアクタに置く（`DirectoryChangeHub` と同じ）。ここでする仕事は
/// 台帳の照合（ロック 1 回）と振り分けだけで、I/O をしない。
@MainActor
public final class LibraryWatcher {
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
    /// ストリームは 1 本で足りる。FSEvents のイベント ID はシステム全体で単調なので、
    /// `sinceWhen` は**全ライブラリの最小値**にしておけば取りこぼさない。新しい ID を
    /// 持つライブラリには余分なイベントが届くが、スキャンは冪等なので害が無い [FO-20]。
    public func setLibraries(_ libraries: [WatchedLibrary]) async {
        watched = libraries
        guard !libraries.isEmpty else {
            stream = nil
            return
        }
        let sinceWhen = libraries.map(\.lastEventID).min() ?? 0
        if stream == nil {
            let box = WeakBox(self)
            stream = FileSystemEventStream(
                sinceWhen: sinceWhen == 0
                    ? FSEventStreamEventId(kFSEventStreamEventIdSinceNow)
                    : FSEventStreamEventId(sinceWhen)
            ) { changes in
                Task { @MainActor in box.value?.handle(changes) }
            }
        }
        await stream?.setRoots(Self.prunedRoots(libraries.map(\.rootPath)))
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
                         needsFullScan: false,
                         lastEventID: stream.map { UInt64($0.latestEventID) } ?? 0))
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

            var relative = change.path
            if relative.hasPrefix(library.rootPath + "/") {
                relative.removeFirst(library.rootPath.count + 1)
            } else if relative == library.rootPath {
                relative = ""
            }
            byLibrary[library.id, default: []].insert(relative)
        }

        let lastID = stream.map { UInt64($0.latestEventID) } ?? 0
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
