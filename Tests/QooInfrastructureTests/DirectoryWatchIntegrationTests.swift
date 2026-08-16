import Foundation
import Testing

@testable import QooInfrastructure

/// 実際の FSEvents と、`FileOperationService` からの通知が、本当に画面まで
/// 届くかを確かめる統合テスト [10章 §10.0]。
///
/// **外部の変更は必ず別プロセス（`/bin/mkdir` など）に行わせる。**
/// `kFSEventStreamCreateFlagIgnoreSelf` は自プロセスの変更を落とすため、
/// テスト自身が `FileManager` で作ったファイルでは何も届かない
/// （その挙動自体はサンドボックス下の probe で実測済み）。
@MainActor
@Suite struct DirectoryWatchIntegrationTests {
    /// FSEvents はコアレス（`AppLimits.Watch.coalescingLatency`）してから
    /// 配送するため、待ち時間には余裕を持たせる。ポーリングなので通常は
    /// この上限よりずっと早く抜ける。
    private static let deadline: Duration = .seconds(10)

    private func makeDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("qoo-watch-integration-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        // **わざと素の URL のまま返す。** 一時ディレクトリは
        // `/var/folders/…`（実体は `/private/var/folders/…`）なので、
        // 「画面が扱っているパスと FSEvents が返すパスが食い違う」状況が
        // そのまま再現される。正規化は `DirectoryChangeHub` の仕事であり、
        // それが効いていることまで含めてこのテストで確かめたい。
        return url
    }

    /// 別プロセスに変更させる（`IgnoreSelf` を回避するため）。
    private func runExternally(_ executable: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
    }

    /// `generation` が増えるまで待つ。増えなければ `false`。
    private func waitForChange(_ watch: DirectoryObservation, from baseline: Int) async -> Bool {
        await waitForChange(watch, from: baseline, within: Self.deadline)
    }

    private func waitForChange(
        _ watch: DirectoryObservation, from baseline: Int, within limit: Duration
    ) async -> Bool {
        let start = ContinuousClock.now
        while ContinuousClock.now - start < limit {
            if watch.generation != baseline { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    /// ストリームが**実際に生きている**ことを確かめてから戻る。
    ///
    /// **固定時間の sleep では足りない**［既存のフレークを直したもの］。
    /// 以前はここが `500ms` の `Task.sleep` で、「これだけ待てば
    /// `AppLimits.Watch.rootRebuildDebounce` と FSEvents の登録が終わって
    /// いるだろう」という当て推量だった。並列実行で間に合わないと、
    /// 直後の変更を**取りこぼしてから 10 秒待って落ちる**——
    /// Release で 4 回に 1 回ほど落ちていた原因がこれ。
    ///
    /// 代わりに、外部プロセスでプローブを作り、**それが観測できて初めて**
    /// 「登録は済んだ」と判断する。時間ではなく状態で待つので、
    /// 遅い環境でも速い環境でも正しい。
    ///
    /// - Note: 片付けと、通知が静まるところまで見てから戻る。プローブの
    ///   通知が呼び出し側の `baseline` より後ろに届くと、**本題と関係の
    ///   ない変更で成功と誤判定する**ため。
    private func waitUntilObserving(
        _ watch: DirectoryObservation, probeIn folder: URL
    ) async throws {
        let probe = folder.appendingPathComponent("qoo-startup-probe")
        let start = ContinuousClock.now
        var live = false
        while ContinuousClock.now - start < Self.deadline {
            let beforeCreate = watch.generation
            try runExternally("/usr/bin/touch", [probe.path])
            if await waitForChange(watch, from: beforeCreate, within: .milliseconds(500)) {
                live = true
                break
            }
            // まだ登録が終わっていない。片付けて次の周回へ。
            try? runExternally("/bin/rm", ["-f", probe.path])
        }
        guard live else {
            Issue.record("FSEvents の登録が \(Self.deadline) 以内に終わらなかった")
            return
        }

        try runExternally("/bin/rm", ["-f", probe.path])
        // プローブぶんの通知が静まるまで待つ（`generation` が動かなくなるまで）。
        var last = watch.generation
        while ContinuousClock.now - start < Self.deadline {
            try? await Task.sleep(for: .milliseconds(200))
            if watch.generation == last { return }
            last = watch.generation
        }
    }

    @Test func externalCreationReachesTheObservation() async throws {
        let folder = makeDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let hub = DirectoryChangeHub(isApplicationActive: { true })
        let watch = DirectoryObservation(hub: hub)
        watch.watch(folder, scope: .shallow)
        try await waitUntilObserving(watch, probeIn: folder)

        let baseline = watch.generation
        try runExternally("/bin/mkdir", [folder.appendingPathComponent("created").path])

        #expect(await waitForChange(watch, from: baseline))
    }

    @Test func externalRenameReachesTheObservation() async throws {
        let folder = makeDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        try runExternally("/bin/mkdir", [folder.appendingPathComponent("before").path])
        let hub = DirectoryChangeHub(isApplicationActive: { true })
        let watch = DirectoryObservation(hub: hub)
        watch.watch(folder, scope: .shallow)
        try await waitUntilObserving(watch, probeIn: folder)

        let baseline = watch.generation
        try runExternally("/bin/mv", [
            folder.appendingPathComponent("before").path,
            folder.appendingPathComponent("after").path,
        ])

        #expect(await waitForChange(watch, from: baseline))
    }

    /// 表示中のフォルダ自身が外部で消された場合 — FSEvents は `RootChanged`
    /// として知らせる（実測で確認済み）。これが届かないと、消えたフォルダの
    /// 内容を映したままの行き止まりになる。
    @Test func externalRemovalOfTheWatchedDirectoryReachesTheObservation() async throws {
        let parent = makeDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let folder = parent.appendingPathComponent("watched", isDirectory: true)
        try runExternally("/bin/mkdir", [folder.path])
        let hub = DirectoryChangeHub(isApplicationActive: { true })
        let watch = DirectoryObservation(hub: hub)
        watch.watch(folder, scope: .shallow)
        try await waitUntilObserving(watch, probeIn: folder)

        let baseline = watch.generation
        try runExternally("/bin/rmdir", [folder.path])

        #expect(await waitForChange(watch, from: baseline))
    }

    @Test func deepObservationSeesAnExternalChangeSeveralLevelsDown() async throws {
        let folder = makeDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let nested = folder.appendingPathComponent("a/b/c", isDirectory: true)
        try runExternally("/bin/mkdir", ["-p", nested.path])
        let hub = DirectoryChangeHub(isApplicationActive: { true })
        let watch = DirectoryObservation(hub: hub)
        watch.watch(folder, scope: .deep)
        try await waitUntilObserving(watch, probeIn: folder)

        let baseline = watch.generation
        try runExternally("/bin/mkdir", [nested.appendingPathComponent("created").path])

        #expect(await waitForChange(watch, from: baseline))
    }

    /// **アプリ自身の変更も届くこと。** FSEvents は `IgnoreSelf` で自分の変更を
    /// 落とすため、`FileOperationService` からの通知 [FO-01 の choke point] が
    /// 無ければここは届かない。この経路が切れると「Finder での変更は反映
    /// されるのに、自分で作ったフォルダが出てこない」という壊れ方をする。
    @Test func ownChangesReachTheObservationThroughFileOperationService() async throws {
        let folder = makeDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        // `FileOperationService` は共有インスタンスの `DirectoryChangeHub` へ
        // 伝えるため、こちらも共有ハブを使う（既定）。
        let watch = DirectoryObservation()
        watch.watch(folder, scope: .shallow)

        let baseline = watch.generation
        _ = try await FileOperationService().createDirectory(at: folder.appendingPathComponent("made"))

        #expect(await waitForChange(watch, from: baseline))
    }
}
