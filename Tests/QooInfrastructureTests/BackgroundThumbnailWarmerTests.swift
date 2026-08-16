import CoreGraphics
import Foundation
import Testing

@testable import QooInfrastructure
@testable import QooKit

/// バックグラウンド動画サムネイル生成 [9.6 節、ユーザー要望] の掃引ロジック。
///
/// `UserDefaults(suiteName:)` を使うため直列実行に固定する
/// [`UserDefaultsKeyBindingStoreTests` と同じ理由: OS レベルの `CFPreferences`
/// ドメイン登録を伴い、並列実行で稀に干渉する]。
///
/// **拡張子は必ず `mp4`（macOS 標準搭載、`public.movie` 準拠が OS 自体に
/// 組み込まれている）を使うこと。`mkv` は使わない** [CI で発見した回帰:
/// `mkv` の `.movie` 準拠は対応アプリのインストール有無に依存する]。
@Suite(.serialized) @MainActor struct BackgroundThumbnailWarmerTests {
    // MARK: - ハーネス

    @MainActor
    private struct Harness {
        let warmer: BackgroundThumbnailWarmer
        let loader: CountingVideoLoader
        let cache: DefaultCoverImageCache
        let root: URL
        let base: URL

        /// `restart()` は待ち合わせゼロで即座に掃引を始める設定にしてある。
        func sweep() async {
            warmer.restart()
            await warmer.awaitCurrentSweep()
        }

        func cleanUp() {
            removeThrowawayDirectory(at: base)
        }
    }

    private func makeHarness(
        enabled: Bool = true,
        hidesThumbnails: Bool = false,
        isGloballyHidden: @escaping @Sendable () async -> Bool = { false },
        isRemote: @escaping @Sendable (URL) -> Bool = { _ in false },
        isDataless: @escaping @Sendable (URL) -> Bool = { _ in false },
        loaderResult: @escaping @Sendable (URL) -> CGImage? = { _ in
            TestImageFixture.makeCGImage(width: 8, height: 8)
        }
    ) throws -> Harness {
        let loader = CountingVideoLoader(result: loaderResult)
        return try makeHarness(
            enabled: enabled, hidesThumbnails: hidesThumbnails,
            isGloballyHidden: isGloballyHidden, isRemote: isRemote, isDataless: isDataless,
            countingLoader: loader, videoLoader: loader
        )
    }

    private func makeHarness(
        enabled: Bool = true,
        hidesThumbnails: Bool = false,
        isGloballyHidden: @escaping @Sendable () async -> Bool = { false },
        isRemote: @escaping @Sendable (URL) -> Bool = { _ in false },
        isDataless: @escaping @Sendable (URL) -> Bool = { _ in false },
        countingLoader: CountingVideoLoader,
        videoLoader: any VideoThumbnailLoading
    ) throws -> Harness {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("qoo-warmer-test-\(UUID().uuidString)")
        let root = base.appendingPathComponent("root", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let cache = DefaultCoverImageCache(baseDirectory: base.appendingPathComponent("covers"))
        let service = ThumbnailService(
            cache: cache,
            videoThumbnailLoader: videoLoader,
            isGloballyHidden: { false },
            isDataless: { _ in false }
        )
        let defaults = UserDefaults(suiteName: "qoo-warmer-test-\(UUID().uuidString)")!
        defaults.set(enabled, forKey: BackgroundThumbnailWarmer.enabledKey)
        let roots = [BackgroundThumbnailWarmer.SweepRoot(url: root, hidesThumbnails: hidesThumbnails)]
        let warmer = BackgroundThumbnailWarmer(
            thumbnailService: service,
            cache: cache,
            defaults: defaults,
            sweepRoots: { roots },
            isGloballyHidden: isGloballyHidden,
            isRemote: isRemote,
            isDataless: isDataless,
            restartDebounce: .zero
        )
        return Harness(warmer: warmer, loader: countingLoader, cache: cache, root: root, base: base)
    }

    /// 中身は動画である必要は無い（フェイクのローダーがデコードしない）。
    private func makeVideoFile(in folder: URL, name: String) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try Data("not real video bytes".utf8).write(to: url)
        return url
    }

    // MARK: - 生成と差分

    @Test func generatesThumbnailsForVideosIncludingSubfolders() async throws {
        let h = try makeHarness()
        defer { h.cleanUp() }
        let a = try makeVideoFile(in: h.root, name: "a.mp4")
        let sub = h.root.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        _ = try makeVideoFile(in: sub, name: "b.mp4")
        // 動画でないファイルは対象にならない。
        try Data("text".utf8).write(to: h.root.appendingPathComponent("note.txt"))

        await h.sweep()

        #expect(h.loader.callCount == 2)
        // 生成物は実際にキャッシュへ載る（UI のオンデマンド要求・次回の掃引は
        // ここで拾われる）。
        let stamp = try FileMetadata.stamp(of: a)
        #expect(FileManager.default.fileExists(atPath: h.cache.url(for: stamp).path))
    }

    @Test func alreadyCachedVideosAreNotRegenerated() async throws {
        let h = try makeHarness()
        defer { h.cleanUp() }
        _ = try makeVideoFile(in: h.root, name: "a.mp4")

        await h.sweep()
        #expect(h.loader.callCount == 1)
        // 2 回目の掃引は差分ゼロ — ローダーは呼ばれない。
        await h.sweep()
        #expect(h.loader.callCount == 1)
    }

    // MARK: - 有効/無効・対象外

    @Test func doesNothingWhenDisabledInPreferences() async throws {
        let h = try makeHarness(enabled: false)
        defer { h.cleanUp() }
        _ = try makeVideoFile(in: h.root, name: "a.mp4")

        await h.sweep()

        #expect(h.loader.callCount == 0)
    }

    /// [DS-04] 強制非表示の登録フォルダは生成もしない。
    @Test func skipsRootsWithThumbnailsAlwaysHidden() async throws {
        let h = try makeHarness(hidesThumbnails: true)
        defer { h.cleanUp() }
        _ = try makeVideoFile(in: h.root, name: "a.mp4")

        await h.sweep()

        #expect(h.loader.callCount == 0)
    }

    /// [DS-05] 全体トグル非表示中は掃引を始めない。
    @Test func doesNothingWhileThumbnailsAreGloballyHidden() async throws {
        let h = try makeHarness(isGloballyHidden: { true })
        defer { h.cleanUp() }
        _ = try makeVideoFile(in: h.root, name: "a.mp4")

        await h.sweep()

        #expect(h.loader.callCount == 0)
    }

    /// [NV-37] ネットワークボリューム上の登録フォルダは丸ごと対象外。
    @Test func skipsRootsOnRemoteVolumes() async throws {
        let h = try makeHarness(isRemote: { _ in true })
        defer { h.cleanUp() }
        _ = try makeVideoFile(in: h.root, name: "a.mp4")

        await h.sweep()

        #expect(h.loader.callCount == 0)
    }

    /// [NV-73] dataless なファイルは（生成失敗として数えることもなく）飛ばす。
    /// 形式スキップのしきい値（3 回）を超える数の dataless ファイルが並んでいても、
    /// 実体のあるファイルの生成は行われる。
    @Test func datalessFilesAreSkippedWithoutCountingAsFormatFailures() async throws {
        let h = try makeHarness(isDataless: { $0.lastPathComponent.hasPrefix("cloud") })
        defer { h.cleanUp() }
        for index in 1...4 {
            _ = try makeVideoFile(in: h.root, name: "cloud\(index).mp4")
        }
        _ = try makeVideoFile(in: h.root, name: "real.mp4")

        await h.sweep()

        // URL 全体では比較しない — 一時ディレクトリは列挙器が `/private/var`、
        // テスト側が `/var` と、シンボリックリンクの解決状態で表現が揺れる。
        #expect(h.loader.calledURLs.map(\.lastPathComponent) == ["real.mp4"])
    }

    // MARK: - 形式単位のスキップ

    /// 1 度も成功しないまま同じ拡張子でしきい値（3 回）失敗したら、その形式は
    /// このセッションでは以降試さない — 生成できない形式のファイルが何百件
    /// 並んでいても、タイムアウト分の時間を無駄にしない [ユーザー要望の核心]。
    @Test func stopsAttemptingAFormatAfterConsecutiveFailures() async throws {
        let h = try makeHarness(loaderResult: { _ in nil })
        defer { h.cleanUp() }
        for index in 1...5 {
            _ = try makeVideoFile(in: h.root, name: "clip\(index).mp4")
        }

        await h.sweep()

        #expect(h.loader.callCount == AppLimits.Thumbnail.warmerFormatFailureThreshold)
    }

    /// 1 度でも成功した形式はスキップしない — 失敗はファイル個別の問題
    /// （壊れたファイル等）と分かるため、残りのファイルを見捨てない。
    @Test func aSingleSuccessKeepsTheFormatEnabled() async throws {
        let h = try makeHarness(loaderResult: { url in
            url.lastPathComponent.contains("ok")
                ? TestImageFixture.makeCGImage(width: 8, height: 8)
                : nil
        })
        defer { h.cleanUp() }
        // 自然順で 2 番目に成功が来る。以降 3 件が失敗し続けても（累計 4 失敗、
        // しきい値 3 超）、成功済みの形式なので全件試される。
        _ = try makeVideoFile(in: h.root, name: "a.mp4")
        _ = try makeVideoFile(in: h.root, name: "b-ok.mp4")
        _ = try makeVideoFile(in: h.root, name: "c.mp4")
        _ = try makeVideoFile(in: h.root, name: "d.mp4")
        _ = try makeVideoFile(in: h.root, name: "e.mp4")

        await h.sweep()

        #expect(h.loader.callCount == 5)
    }

    // MARK: - 停止

    /// `stop()` した掃引は残りのファイルへ進まない。ゲート付きローダーで
    /// 「1 件目の生成中」という状態を確実に作ってから止める（時間ではなく
    /// 状態で判定する [本プロジェクトのテスト方針]）。
    @Test func stoppingMidSweepAbandonsRemainingFiles() async throws {
        let counting = CountingVideoLoader(result: { _ in nil })
        let gate = GatedVideoLoader(wrapping: counting)
        let h = try makeHarness(countingLoader: counting, videoLoader: gate)
        defer { h.cleanUp() }
        _ = try makeVideoFile(in: h.root, name: "a.mp4")
        _ = try makeVideoFile(in: h.root, name: "b.mp4")

        h.warmer.restart()
        await gate.waitUntilFirstCall()
        h.warmer.stop()
        gate.releaseAll()
        await h.warmer.awaitCurrentSweep()

        #expect(h.loader.callCount == 1)
    }
}

// MARK: - フェイク

/// 呼び出しを記録するフェイクの動画サムネイルローダー。
private final class CountingVideoLoader: VideoThumbnailLoading, @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []
    private let result: @Sendable (URL) -> CGImage?

    init(result: @escaping @Sendable (URL) -> CGImage?) {
        self.result = result
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return urls.count
    }

    var calledURLs: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return urls
    }

    func makeThumbnail(for url: URL, maxPixelSize: Int) async -> CGImage? {
        record(url)
        return result(url)
    }

    // `NSLock.lock()` は async 関数本体からは呼べない（noasync）ため、
    // 同期ヘルパーに閉じ込める。
    private func record(_ url: URL) {
        lock.lock()
        urls.append(url)
        lock.unlock()
    }
}

/// 呼び出しを（テストが `releaseAll()` するまで）待たせるゲート。
/// 「生成の最中」という状態を決定的に作るためのもの。
private final class GatedVideoLoader: VideoThumbnailLoading, @unchecked Sendable {
    private let lock = NSLock()
    private let wrapped: any VideoThumbnailLoading
    private var released = false
    private var hasBeenCalled = false
    private var gateWaiters: [CheckedContinuation<Void, Never>] = []
    private var firstCallWaiters: [CheckedContinuation<Void, Never>] = []

    init(wrapping wrapped: any VideoThumbnailLoading) {
        self.wrapped = wrapped
    }

    func makeThumbnail(for url: URL, maxPixelSize: Int) async -> CGImage? {
        markCalled()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waitAtGate(continuation)
        }
        return await wrapped.makeThumbnail(for: url, maxPixelSize: maxPixelSize)
    }

    func waitUntilFirstCall() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            notifyOnFirstCall(continuation)
        }
    }

    // `NSLock.lock()` は async 関数本体からは呼べない（noasync）ため、
    // ロックを触る処理はすべて同期ヘルパーに閉じ込める。

    private func markCalled() {
        lock.lock()
        hasBeenCalled = true
        let announce = firstCallWaiters
        firstCallWaiters = []
        lock.unlock()
        announce.forEach { $0.resume() }
    }

    private func waitAtGate(_ continuation: CheckedContinuation<Void, Never>) {
        lock.lock()
        if released {
            lock.unlock()
            continuation.resume()
            return
        }
        gateWaiters.append(continuation)
        lock.unlock()
    }

    private func notifyOnFirstCall(_ continuation: CheckedContinuation<Void, Never>) {
        lock.lock()
        if hasBeenCalled {
            lock.unlock()
            continuation.resume()
            return
        }
        firstCallWaiters.append(continuation)
        lock.unlock()
    }

    func releaseAll() {
        lock.lock()
        released = true
        let waiters = gateWaiters
        gateWaiters = []
        lock.unlock()
        waiters.forEach { $0.resume() }
    }
}
