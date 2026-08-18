//
//  期待変更台帳 [5.4 節][FO-10〜FO-15][EV-01]。
//
//  自己変更識別の**主たる手段**。FSEvents の `IgnoreSelf` はイベントが
//  ディレクトリ単位で合体するため単独では確実でなく、一次フィルタに留まる [FO-10]。
//
//  ただしこれも完全ではない——長い操作の途中で FSEvents が届けば、事前登録が
//  間に合っても粒度の粗いイベントで取りこぼしうる。**最終防衛線は自動リネーム
//  ルールの冪等性** [FO-21〜FO-24] であって、この台帳ではない。
//
import Foundation
import QooKit

/// **`actor` にしない** [設計判断]。FO-11 は「操作の**実行前**に登録する」と定めて
/// いるが、`actor` にすると登録が `await` を挟む非同期になり、`FileOperationService`
/// の同期的な入口から「実行前」を保証できない（`Task` を起こすと順序が崩れる）。
/// 中身は小さなメモリ上の索引なので、ロックで直列化すれば十分速い。
public final class ExpectedChangeLedger: @unchecked Sendable {
    public static let shared = ExpectedChangeLedger()

    private let lock = NSLock()

    public struct Entry: Sendable, Hashable {
        public let volumeUUID: String?
        public let inode: UInt64?
        /// 物理パス（`realpath(3)` 済み）。FSEvents は実体のパスを返す [DW-05]。
        public let path: String
        public let kind: OperationKind
        public let expiresAt: Date
        /// 変換リネーム由来など、自動リネームを抑止したい変更 [CR-63][PW-15]。
        public let suppressAutoRename: Bool
    }

    /// パスで引く索引。1 パスに複数の操作が重なりうる（移動元と移動先など）。
    private var byPath: [String: [Entry]] = [:]
    private var byIdentity: [FileIdentity: Entry] = [:]

    public init() {}

    // MARK: - 登録 [FO-11]

    /// 操作の**実行前**に登録する [FO-11]。
    ///
    /// - Parameter lifetime: 既定 10 秒 [FO-13]。期限切れは破棄し、以後は外部変更として扱う。
    public func expect(_ urls: [URL], kind: OperationKind,
                       suppressAutoRename: Bool = false,
                       lifetime: TimeInterval = AppLimits.Watch.ledgerEntryLifetime,
                       now: Date = Date()) {
        guard !urls.isEmpty else { return }
        // 物理パスの解決はロックの外で済ませる（`realpath(3)` は I/O を伴う）。
        let resolved = urls.map { (Self.physicalPath($0),
                                   Self.physicalPath($0.deletingLastPathComponent())) }
        lock.lock(); defer { lock.unlock() }
        let expiry = now.addingTimeInterval(lifetime)
        for (path, parent) in resolved {
            // 実体のパスで覚える。FSEvents は `/private/var/…` の側を返す [DW-05]。
            byPath[path, default: []].append(
                Entry(volumeUUID: nil, inode: nil, path: path, kind: kind,
                      expiresAt: expiry, suppressAutoRename: suppressAutoRename))
            // 親フォルダも登録する——FSEvents はディレクトリ単位で合体するため、
            // 子の作成・削除が親のパスとして届くことがある [FO-10]。
            if parent != path {
                byPath[parent, default: []].append(
                    Entry(volumeUUID: nil, inode: nil, path: parent, kind: kind,
                          expiresAt: expiry, suppressAutoRename: suppressAutoRename))
            }
        }
        purgeExpiredLocked(now: now)
    }

    /// 操作の**完了後**に、実際に確定した同一性で登録し直す。
    ///
    /// 事前登録はパスしか分からない（新規作成の inode は操作後にしか決まらない）。
    /// 完了後にここを通すことで、`(volumeUUID, inode)` での照合もできるようになる。
    public func recordActual(_ identities: [FileIdentity], at urls: [URL],
                             kind: OperationKind, suppressAutoRename: Bool = false,
                             lifetime: TimeInterval = AppLimits.Watch.ledgerEntryLifetime,
                             now: Date = Date()) {
        guard !identities.isEmpty else { return }
        let paths = urls.map(Self.physicalPath)
        lock.lock(); defer { lock.unlock() }
        let expiry = now.addingTimeInterval(lifetime)
        for (offset, identity) in identities.enumerated() {
            let entry = Entry(volumeUUID: identity.volumeUUID, inode: identity.inode,
                              path: offset < paths.count ? paths[offset] : "", kind: kind,
                              expiresAt: expiry, suppressAutoRename: suppressAutoRename)
            byIdentity[identity] = entry
        }
        purgeExpiredLocked(now: now)
    }

    // MARK: - 照合 [FO-12]

    /// 一致したエントリを**消費して**返す [FO-12]。返ったイベントは処理をスキップする。
    ///
    /// 消費するのは 1 回きり。同じパスに 2 回変更があれば、2 回目は外部変更として扱う。
    @discardableResult
    public func consume(path: String, identity: FileIdentity? = nil,
                        now: Date = Date()) -> Entry? {
        let key = Self.physicalPath(URL(fileURLWithPath: path))
        lock.lock(); defer { lock.unlock() }
        purgeExpiredLocked(now: now)
        if let identity, let entry = byIdentity.removeValue(forKey: identity) {
            return entry
        }
        guard var entries = byPath[key], !entries.isEmpty else { return nil }
        let entry = entries.removeFirst()
        if entries.isEmpty { byPath.removeValue(forKey: key) } else { byPath[key] = entries }
        return entry
    }

    /// 期限切れを捨てる [FO-13]。
    public func purgeExpired(now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        purgeExpiredLocked(now: now)
    }

    private func purgeExpiredLocked(now: Date) {
        for (path, entries) in byPath {
            let alive = entries.filter { $0.expiresAt > now }
            if alive.isEmpty { byPath.removeValue(forKey: path) }
            else if alive.count != entries.count { byPath[path] = alive }
        }
        byIdentity = byIdentity.filter { $0.value.expiresAt > now }
    }

    public func removeAll() {
        lock.lock(); defer { lock.unlock() }
        byPath.removeAll()
        byIdentity.removeAll()
    }

    /// テスト・診断用。
    public var pendingCount: Int {
        lock.lock(); defer { lock.unlock() }
        return byPath.values.reduce(0) { $0 + $1.count } + byIdentity.count
    }

    // MARK: - 内部

    /// `realpath(3)` で実体のパスへ。
    ///
    /// **`resolvingSymlinksInPath()` は使わない**——`/private` を取り除く特別扱いが
    /// あり、FSEvents が返す `/private/var/…` と食い違う [8章 §8.11 の記録]。
    ///
    /// **まだ存在しないパスも安定して解決する。**台帳は操作の**前**に登録する
    /// [FO-11] ので、対象がまだ無いことがふつうにある。素の `realpath` は
    /// そのとき失敗して `/var/…` を返し、操作後の照合（実体があるので
    /// `/private/var/…`）と食い違う——**実際にこれで取りこぼした**。
    /// 存在する最深の祖先まで解決し、残りを継ぎ足す。
    nonisolated static func physicalPath(_ url: URL) -> String {
        let standardized = url.standardizedFileURL
        var components = standardized.pathComponents
        var suffix: [String] = []
        // `deletingLastPathComponent()` の繰り返しは使わない——ルートで `/..` を
        // 返しうる Apple の既知挙動があり、本プロジェクトで 3 度無限ループを踏んでいる。
        while components.count > 1 {
            if let resolved = resolveExisting(NSString.path(withComponents: components)) {
                return ([resolved] + suffix).reduce(into: "") { acc, part in
                    acc = acc.isEmpty ? part : (acc as NSString).appendingPathComponent(part)
                }
            }
            suffix.insert(components.removeLast(), at: 0)
        }
        return standardized.path
    }

    nonisolated static func resolveExisting(_ path: String) -> String? {
        path.withCString { cString in
            guard let resolved = realpath(cString, nil) else { return nil }
            defer { free(resolved) }
            return String(cString: resolved)
        }
    }
}
