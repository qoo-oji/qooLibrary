//
//  ボリューム着脱検知 [10.2][VD-01〜VD-11][VM3-01〜VM3-05]。
//
//  1-17 は着脱**検知**を持たず、ツリー更新時にマウント一覧と突き合わせる受動的な
//  判定に留めていた（8章 §8.7.1）。ここはその遷移を能動的に駆動する。
//  **状態モデルと判定順序そのものは変えない**——特に、未マウントと判定した時点で
//  ブックマークの解決を試みない規則 [RG3-01] は維持する（解決がマウントを誘発し、
//  ネットワークボリューム切断時に UI をブロックしうるため）。
//
import AppKit
import Foundation
import QooKit

public enum VolumeEvent: Sendable, Equatable {
    case mounted(volumeUUID: String, url: URL)
    case willUnmount(volumeUUID: String)
    case didUnmount(volumeUUID: String)
    case renamed(volumeUUID: String, oldURL: URL, newURL: URL)
}

/// `NSWorkspace` のボリューム通知を購読して `VolumeEvent` に翻訳する。
///
/// 検知手段の優先順位 [10.2]:
/// 1. `NSWorkspace` の通知（主たる検知手段）[VD-01]
/// 2. `mountedVolumeURLs` の起動時列挙（起動前の着脱）[VD-08]
/// 3. FSEvents の Mount / Unmount フラグ（取りこぼしへの備え）[VD-07]
public actor VolumeMonitor {
    public private(set) var isRunning = false
    /// マウントパス → ボリューム識別子。`willUnmount` の時点では
    /// **まだ識別子を引ける**が、`didUnmount` では引けないので控えておく。
    private var identifierByPath: [String: String] = [:]
    private var continuations: [UUID: AsyncStream<VolumeEvent>.Continuation] = [:]
    private var observers: [NSObjectProtocol] = []

    public init() {}

    public var events: AsyncStream<VolumeEvent> {
        AsyncStream { continuation in
            let id = UUID()
            Task { await self.register(id, continuation) }
            continuation.onTermination = { _ in Task { await self.unregister(id) } }
        }
    }

    func register(_ id: UUID, _ continuation: AsyncStream<VolumeEvent>.Continuation) {
        continuations[id] = continuation
    }

    func unregister(_ id: UUID) {
        continuations.removeValue(forKey: id)
    }

    func emit(_ event: VolumeEvent) {
        for continuation in continuations.values { continuation.yield(event) }
    }

    // MARK: - 開始・停止

    public func start() async {
        guard !isRunning else { return }
        isRunning = true
        await reconcileWithMountedVolumes()          // [VD-08]

        let center = NSWorkspace.shared.notificationCenter
        func observe(_ name: NSNotification.Name,
                     _ handler: @escaping @Sendable (VolumeMonitor, URL) async -> Void) {
            let token = center.addObserver(forName: name, object: nil, queue: nil) { note in
                guard let url = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL
                        ?? note.userInfo?["NSDevicePath"].flatMap({ ($0 as? String).map(URL.init(fileURLWithPath:)) })
                else { return }
                Task { await handler(self, url) }
            }
            observers.append(token)
        }

        observe(NSWorkspace.didMountNotification) { await $0.handleMounted($1) }         // [VD-01]
        observe(NSWorkspace.willUnmountNotification) { await $0.handleWillUnmount($1) }  // [VD-04]
        observe(NSWorkspace.didUnmountNotification) { await $0.handleDidUnmount($1) }    // [VD-05]

        // 改名は old/new の 2 つの URL が来る [VD-06]
        let renameToken = center.addObserver(
            forName: NSWorkspace.didRenameVolumeNotification, object: nil, queue: nil) { note in
            guard let newURL = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL,
                  let oldURL = note.userInfo?[NSWorkspace.oldVolumeURLUserInfoKey] as? URL
            else { return }
            Task { await self.handleRenamed(from: oldURL, to: newURL) }
        }
        observers.append(renameToken)
    }

    public func stop() {
        let center = NSWorkspace.shared.notificationCenter
        for token in observers { center.removeObserver(token) }
        observers.removeAll()
        isRunning = false
    }

    // MARK: - 起動時の突き合わせ [VD-08][VM3-05]

    /// 起動前の着脱はこの経路でしか検出できない [VD-08]。
    public func reconcileWithMountedVolumes() async {
        let urls = await FileIO.perform {
            FileManager.default.mountedVolumeURLs(
                includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]) ?? []
        }
        var seen: [String: String] = [:]
        for url in urls {
            guard let identifier = await FileIO.perform({ VolumeIdentity.identifier(for: url) })
            else { continue }
            seen[url.standardizedFileURL.path] = identifier
        }
        // 前回から増えた／減ったぶんを通知する
        for (path, identifier) in seen where identifierByPath[path] == nil {
            emit(.mounted(volumeUUID: identifier, url: URL(fileURLWithPath: path)))
        }
        for (path, identifier) in identifierByPath where seen[path] == nil {
            emit(.didUnmount(volumeUUID: identifier))
        }
        identifierByPath = seen
    }

    /// 手動コマンド「ボリュームを再検証」[VD-09][MX 一覧]。
    public func revalidateAll() async {
        await reconcileWithMountedVolumes()
    }

    /// 現在マウント中の識別子。
    public var mountedIdentifiers: Set<String> { Set(identifierByPath.values) }

    // MARK: - 通知の処理

    func handleMounted(_ url: URL) async {
        guard let identifier = await FileIO.perform({ VolumeIdentity.identifier(for: url) })
        else { return }
        identifierByPath[url.standardizedFileURL.path] = identifier
        Log.watch.info("ボリュームがマウントされた: \(Log.path(url))")
        emit(.mounted(volumeUUID: identifier, url: url))          // [VD-03]
    }

    /// **アンマウントを妨げない** [VD-04][VM3-02]。ここでは処理の中断と
    /// ストリーム停止を素早く行うだけで、I/O をしない。
    func handleWillUnmount(_ url: URL) async {
        guard let identifier = identifierByPath[url.standardizedFileURL.path] else { return }
        emit(.willUnmount(volumeUUID: identifier))
    }

    func handleDidUnmount(_ url: URL) async {
        let path = url.standardizedFileURL.path
        // `didUnmount` の時点では識別子をもう引けない。控えておいたものを使う。
        guard let identifier = identifierByPath.removeValue(forKey: path) else { return }
        Log.watch.info("ボリュームが取り外された: \(Log.path(url))")
        emit(.didUnmount(volumeUUID: identifier))                 // [VD-05]
    }

    /// **`volumeUUID` は不変なので紐づけは維持される** [VD-06]。パスだけ更新する。
    func handleRenamed(from oldURL: URL, to newURL: URL) async {
        let oldPath = oldURL.standardizedFileURL.path
        var identifier = identifierByPath.removeValue(forKey: oldPath)
        if identifier == nil {
            identifier = await FileIO.perform { VolumeIdentity.identifier(for: newURL) }
        }
        guard let identifier else { return }
        identifierByPath[newURL.standardizedFileURL.path] = identifier
        emit(.renamed(volumeUUID: identifier, oldURL: oldURL, newURL: newURL))
    }
}
