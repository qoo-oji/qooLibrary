import Foundation
import Testing

@testable import QooInfrastructure

/// ストア内のブックマーク解決が `FileIO` 経由・上限時間付きで行われること
/// [NV6-05]。解決がブロックしてもストアはハングせず、上限を超えた解決は
/// 「応答なし」（オフライン）として扱われる。
@Suite struct BookmarkResolutionDeadlineTests {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("qoo-bookmark-deadline-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 上限を超えた解決は `.offline(reason: .unresponsive)` になる。
    @Test func timedOutResolutionMapsToUnresponsiveOffline() async throws {
        let resolver = BlockingBookmarkResolver()
        defer { resolver.releaseAll() }

        let resolution = await resolver.resolve(Data("x".utf8), waitingAtMost: .milliseconds(200))

        #expect(resolution == .offline(reason: .unresponsive))
    }

    /// 解決がブロックしても `RegisteredFolderStore` はハングせず、その登録を
    /// オフラインとして扱い、他の操作（一覧など）は使える状態が保たれる。
    @Test func registeredFolderStoreTreatsTimedOutResolutionAsOffline() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let storageURL = root.appendingPathComponent("state.json")
        let record = RegisteredFolder(
            kind: .library, displayName: "無応答の共有", bookmarkData: Data("bookmark".utf8)
        )
        try JSONEncoder().encode([record]).write(to: storageURL)

        let resolver = BlockingBookmarkResolver()
        defer { resolver.releaseAll() }
        let store = RegisteredFolderStore(
            storageURL: storageURL, bookmarks: resolver, resolutionDeadline: .milliseconds(200)
        )

        // 初回読み込み（＝全登録の解決）が上限時間で戻ってくること。
        let libraries = await store.folders(kind: .library)
        #expect(libraries.map(\.id) == [record.id])

        // 上限を超えた解決はオフライン（`nil`）扱い [SB-05 と同じ見え方]。
        #expect(await store.resolvedURL(for: record) == nil)
        // スコープは 1 件も開始されていない。
        #expect(await store.activeAccessCount() == 0)
    }

    /// 解決がブロックしても `VolumeAccessStore` はハングしない（同上）。
    @Test func volumeAccessStoreTreatsTimedOutResolutionAsOffline() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let storageURL = root.appendingPathComponent("state.json")
        let record = GrantedVolumeAccess(displayName: "無応答の共有", bookmarkData: Data("bookmark".utf8))
        try JSONEncoder().encode([record]).write(to: storageURL)

        let resolver = BlockingBookmarkResolver()
        defer { resolver.releaseAll() }
        let store = VolumeAccessStore(
            storageURL: storageURL, bookmarks: resolver, resolutionDeadline: .milliseconds(200)
        )

        let grants = await store.grantedAccess()
        #expect(grants.map(\.id) == [record.id])
        #expect(await store.resolvedURL(for: record) == nil)
    }

    /// 初回読み込みは全登録を**並行に**解決する [NV6-05]。
    ///
    /// タイミングではなく状態で検証する（本 CLAUDE.md「時間で判定するテストの
    /// 罠」参照）: リゾルバは「全件が同時に到着したら成功を返し、到着し
    /// きらないまま待ちが尽きたら失敗を返す」バリアになっている。逐次実装なら
    /// 1 件目が独りで待ち続けて失敗するため、このテストが落ちる。
    @Test func initialLoadResolvesAllBookmarksInParallel() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let storageURL = root.appendingPathComponent("state.json")
        let records = (1...3).map { index in
            RegisteredFolder(
                kind: .library, displayName: "Library\(index)",
                bookmarkData: Data(root.appendingPathComponent("Library\(index)").path.utf8)
            )
        }
        try JSONEncoder().encode(records).write(to: storageURL)

        let resolver = BarrierBookmarkResolver(expected: records.count)
        let store = RegisteredFolderStore(storageURL: storageURL, bookmarks: resolver)

        await store.loadAndActivateAll()

        #expect(resolver.sawAllConcurrently, "全登録の解決が同時に走っていない（逐次に退行している）")
    }
}

/// 解決が永遠にブロックする状況の模擬（応答しないサーバ相当）。
/// テスト終了時は必ず `releaseAll()` で解放し、塞いだスレッドをテスト
/// プロセスに残さないこと。
private final class BlockingBookmarkResolver: BookmarkResolving, @unchecked Sendable {
    private let gate = DispatchSemaphore(value: 0)

    func releaseAll() {
        // 待ち手の数を正確に数える必要は無い。余分な signal は無害。
        for _ in 0..<64 { gate.signal() }
    }

    func makeBookmark(for url: URL) throws -> Data { Data(url.path.utf8) }

    func resolve(_ data: Data) -> BookmarkResolution {
        gate.wait()
        return .offline(reason: .volumeNotMounted)
    }

    func resolveAllowingMount(_ data: Data) -> BookmarkResolution { resolve(data) }

    func withAccess<T: Sendable>(_ data: Data, _ body: @Sendable (URL) async throws -> T) async throws -> T {
        throw BookmarkAccessError.offline(.volumeNotMounted)
    }
}

/// 「期待した件数が**同時に**解決中になったか」を観測するバリア。
///
/// 判定は累積の到着数ではなく**同時滞在数の最大値**で行う——累積で数えると、
/// 逐次実装でも最後の 1 件が「全件到着済み」を見てしまい、テストが空振りする
/// （書いてから変異検証で気づいて直した）。逐次実装では同時滞在は常に 1 なので、
/// 各呼び出しは猶予いっぱい待ったのち失敗を返し、テストが確定的に落ちる。
private final class BarrierBookmarkResolver: BookmarkResolving, @unchecked Sendable {
    private let expected: Int
    private let condition = NSCondition()
    private var inFlight = 0
    private var maxInFlight = 0

    init(expected: Int) {
        self.expected = expected
    }

    var sawAllConcurrently: Bool {
        condition.lock()
        defer { condition.unlock() }
        return maxInFlight >= expected
    }

    func makeBookmark(for url: URL) throws -> Data { Data(url.path.utf8) }

    func resolve(_ data: Data) -> BookmarkResolution {
        condition.lock()
        inFlight += 1
        maxInFlight = max(maxInFlight, inFlight)
        condition.broadcast()
        // 2 秒は「全員が揃うのを待つ」ための猶予で、成功時は即座に抜ける。
        // FileIO の既定の上限（5 秒）より短くしてあるため、逐次実装でも
        // タイムアウト側ではなくこちらの失敗として確定的に観測できる。
        let bail = Date().addingTimeInterval(2)
        while maxInFlight < expected {
            guard condition.wait(until: bail) else { break }
        }
        let sawAll = maxInFlight >= expected
        inFlight -= 1
        condition.unlock()
        guard sawAll else { return .offline(reason: .volumeNotMounted) }
        return .resolved(url: URL(fileURLWithPath: String(decoding: data, as: UTF8.self)), isStale: false)
    }

    func resolveAllowingMount(_ data: Data) -> BookmarkResolution { resolve(data) }

    func withAccess<T: Sendable>(_ data: Data, _ body: @Sendable (URL) async throws -> T) async throws -> T {
        throw BookmarkAccessError.offline(.volumeNotMounted)
    }
}
