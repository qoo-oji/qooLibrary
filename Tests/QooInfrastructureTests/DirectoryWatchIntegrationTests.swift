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
        let start = ContinuousClock.now
        while ContinuousClock.now - start < Self.deadline {
            if watch.generation != baseline { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    /// ストリームの立ち上げ（`AppLimits.Watch.rootRebuildDebounce` の待ち合わせ
    /// と FSEvents の登録）が終わるのを待つ。
    private func waitForStreamStartup() async {
        try? await Task.sleep(for: .milliseconds(500))
    }

    @Test func externalCreationReachesTheObservation() async throws {
        let folder = makeDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let hub = DirectoryChangeHub(isApplicationActive: { true })
        let watch = DirectoryObservation(hub: hub)
        watch.watch(folder, scope: .shallow)
        await waitForStreamStartup()

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
        await waitForStreamStartup()

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
        await waitForStreamStartup()

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
        await waitForStreamStartup()

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
