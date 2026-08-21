import Foundation
import GRDB
@testable import QooApplication
@testable import QooInfrastructure
import QooKit
import Testing
@testable import QooPersistence

//
//  監視から DB までを通す [SY-01〜SY-05][VD-03][VD-05][FO-01][ID-06]。
//
//  **調整役の単体テストだけでは足りない。** あちらは走査の呼ばれ方を記録する
//  だけで、実際に DB が実体へ収束するかは見ていない。ここは実ディレクトリ・
//  実 DB・実スキャンエンジンを使い、`LibraryWatcher` の要求から
//  `managedFile` の行が変わるところまでを 1 本で確かめる。
//
//  **FSEvents は使わない**（配送そのものは `DirectoryWatchIntegrationTests`
//  が別途担保している）。ここで試したいのは「要求が届いたあと何が起きるか」。
//

/// この suite だけの根の申告。`QooApplicationTests` の同名の型とは別ターゲット。
private struct FakeRootLocator: LibraryRootLocating {
    let locations: [UUID: LibraryRootLocation]
    func libraryRootLocations() async -> [UUID: LibraryRootLocation] { locations }
}

@MainActor
@Suite("監視から DB までの追随 [SY-01〜SY-05][ID-06]", .serialized)
struct LibrarySyncIntegrationTests {

    @MainActor
    final class Workspace {
        let base: URL
        let root: URL
        let database: QooDatabase
        let libraries: SQLiteLibraryRepository
        let files: SQLiteManagedFileRepository
        let engine: ScanEngine
        let watcher = LibraryWatcher()          // **共有インスタンスは使わない**
        let registrationUUID = UUID()
        var libraryID = LibraryID(rawValue: 0)
        var coordinator: LibrarySyncCoordinator!

        init() async throws {
            base = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("qoo-sync-e2e-\(UUID().uuidString)")
            root = base.appendingPathComponent("library")
            cleanupPath = base.path
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

            database = try QooDatabase.inMemory()
            let sets = try BuiltInTemplates.volumeSets()
            let template = try #require(
                try BuiltInTemplates.libraryTypes().first { $0.key == "builtin.doujinshi-a" })
            libraries = SQLiteLibraryRepository(database: database, volumeSets: sets)
            files = SQLiteManagedFileRepository(database: database)
            let labels = SQLiteLabelRepository(database: database)
            libraryID = try await libraries.register(
                LibraryRegistration(
                    uuid: registrationUUID, displayName: "E2E", bookmarkData: Data(),
                    resolvedPath: root.path,
                    volumeUUID: VolumeIdentity.identifier(for: root) ?? "TESTVOL",
                    libraryTypeID: LibraryTypeID(rawValue: 0)),
                template: template)
            var draft = try #require(try await libraries.settingsDraft(libraryID: libraryID))
            draft.targetExtensions = ["cbz"]
            draft.imageExtensions = Array(BookFolderDetector.defaultImageExtensions)
            try await libraries.updateSettings(draft, libraryID: libraryID)

            engine = ScanEngine(dependencies: .init(
                libraries: libraries, files: files, labels: labels))
        }

        // `@MainActor` の型でも `deinit` は非分離なので、隔離された
        // プロパティに触れない。パスだけ写しておいて片付ける。
        private let cleanupPath: String
        deinit { try? FileManager.default.removeItem(atPath: cleanupPath) }

        func makeCoordinator(location: LibraryRootLocation? = nil) {
            let engine = self.engine
            coordinator = LibrarySyncCoordinator(dependencies: .init(
                libraries: libraries,
                roots: FakeRootLocator(
                    locations: [registrationUUID: location ?? .online(root)]),
                scan: { mode, url in try await engine.scan(mode, root: url) },
                watcher: watcher,
                monitor: VolumeMonitor(),
                fullScanInterval: nil))
        }

        func write(_ relativePath: String) throws {
            let url = root.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: url.path,
                                           contents: Data(repeating: 0x41, count: 16))
        }

        func rows() async throws -> [(path: String, state: FileState)] {
            try await database.writer.read { db in
                try Row.fetchAll(db, sql: "SELECT relativePath, state FROM managedFile").map {
                    ($0["relativePath"] as String,
                     FileState(rawValue: $0["state"] as String) ?? .active)
                }
            }
        }

        func settle(within seconds: Double = 10) async throws {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline {
                if coordinator.isIdle { return }
                try await Task.sleep(for: .milliseconds(5))
            }
            Issue.record("走査が \(seconds) 秒で終わらなかった")
        }
    }

    /// **起点が使えない（＝新規ライブラリ）なら起動時にフルスキャン** [SY-04]。
    @Test("起動時のフルスキャンが実ファイルを DB へ取り込む [SY-04]")
    func aStartupFullScanImportsRealFiles() async throws {
        let w = try await Workspace()
        try w.write("(同人誌) [サークルA (作家A)] 作品1 (オリジナル).cbz")
        try w.write("読み飛ばす.txt")
        w.makeCoordinator()

        await w.coordinator.resync(startup: true)
        try await w.settle()

        let rows = try await w.rows()
        #expect(rows.count == 1, "対象拡張子だけを取り込む")
        #expect(rows.first?.state == .active)
    }

    /// **差分の要求が実際に DB を動かす。** 調整役の単体テストは走査の
    /// 呼ばれ方しか見ないので、ここで実体への収束まで確かめる。
    @Test("差分の要求で追加されたファイルが DB へ載る [SY-03]")
    func anIncrementalRequestImportsANewFile() async throws {
        let w = try await Workspace()
        try w.write("作者A/[サークルA] 既存.cbz")
        w.makeCoordinator()
        await w.coordinator.resync(startup: true)
        try await w.settle()

        try w.write("作者A/[サークルB] 追加.cbz")
        w.coordinator.enqueue(ScanRequest(
            libraryID: w.libraryID, relativePaths: ["作者A/[サークルB] 追加.cbz"],
            needsFullScan: false, lastEventID: 10))
        try await w.settle()

        let rows = try await w.rows()
        #expect(rows.count == 2)
        #expect(rows.allSatisfy { $0.state == .active })
    }

    /// **自プロセスの変更も届く** [FO-01]。FSEvents は自分の変更を落とすので、
    /// この経路が無いとアプリがライブラリへ入れたファイルが DB に載らない。
    @Test("自プロセスの変更が DB へ載る [FO-01]")
    func aLocalChangeReachesTheDatabase() async throws {
        let w = try await Workspace()
        w.makeCoordinator()
        await w.coordinator.resync(startup: true)
        try await w.settle()
        #expect(try await w.rows().isEmpty)

        try w.write("作者A/[サークルA] 自分で入れた.cbz")
        w.watcher.setWatchedForTesting([
            WatchedLibrary(id: w.libraryID, rootPath: w.root.path)])
        w.watcher.noteLocalChanges(at: [
            w.root.appendingPathComponent("作者A/[サークルA] 自分で入れた.cbz")])
        // 要求は `requests` を購読している調整役へ届く。
        w.coordinator.enqueue(ScanRequest(
            libraryID: w.libraryID, relativePaths: ["作者A/[サークルA] 自分で入れた.cbz"],
            needsFullScan: false, lastEventID: 1))
        try await w.settle()

        #expect(try await w.rows().count == 1)
    }

    /// 外部で削除されたファイルが孤立になる [ID-06]。
    @Test("差分の要求で削除されたファイルが孤立になる [ID-06]")
    func anIncrementalRequestOrphansADeletedFile() async throws {
        let w = try await Workspace()
        try w.write("作者A/[サークルA] 消える.cbz")
        try w.write("作者A/[サークルB] 残る.cbz")
        w.makeCoordinator()
        await w.coordinator.resync(startup: true)
        try await w.settle()

        let changed = "作者A/" + (try FileManager.default.contentsOfDirectory(
            at: w.root.appendingPathComponent("作者A"), includingPropertiesForKeys: nil)
            .first { $0.lastPathComponent.contains("消える") }?.lastPathComponent ?? "")
        try FileManager.default.removeItem(at: w.root.appendingPathComponent(changed))
        w.coordinator.enqueue(ScanRequest(
            libraryID: w.libraryID, relativePaths: [changed],
            needsFullScan: false, lastEventID: 2))
        try await w.settle()

        let rows = try await w.rows()
        #expect(rows.first { $0.path.contains("消える") }?.state == .orphaned)
        #expect(rows.first { $0.path.contains("残る") }?.state == .active)
    }

    /// **オフラインになったら走査しない** [SB-05][ID-08][R-01]。ここを誤ると
    /// 外付けを抜いただけでラベル紐づけを一括で失う。
    @Test("オフラインのライブラリは走査せず、DB もオフラインになる [VD-05][SB-05]")
    func anOfflineLibraryIsNeitherScannedNorOrphaned() async throws {
        let w = try await Workspace()
        try w.write("作者A/[サークルA] 1.cbz")
        w.makeCoordinator()
        await w.coordinator.resync(startup: true)
        try await w.settle()
        #expect(try await w.rows().count == 1)

        // ボリュームが外れた。**実体はまだあるが、見えない状態を模す。**
        w.makeCoordinator(location: .unavailable("ボリュームが接続されていない"))
        await w.coordinator.resync(startup: true)
        try await w.settle()

        let summary = try #require(try await w.libraries.library(id: w.libraryID))
        #expect(!summary.isOnline)
        #expect(try await w.rows().allSatisfy { $0.state == .active }, "孤立にしてはならない")
    }

    /// 差分の起点が DB に残り、次回の判断に使える [SY-02][WA-10]。
    @Test("走査のあと差分の起点が保存される [SY-02][WA-10]")
    func theCheckpointIsPersisted() async throws {
        let w = try await Workspace()
        try w.write("作者A/[サークルA] 1.cbz")
        w.makeCoordinator()
        await w.coordinator.resync(startup: true)
        try await w.settle()

        let state = try #require(try await w.libraries.watchStates().first)
        #expect(state.checkpoint.eventID > 0)
        #expect(state.checkpoint.deviceUUID == FSEventsHistory.deviceUUID(for: w.root))
        #expect(state.lastFullScanAt != nil, "フルスキャンの時刻が記録される [SY-05]")
    }
}

//
//  手動の走査も「どこまで反映したか」を記録する [SY-02][SY-05][WA-10]。
//
//  **有効化直後の初回スキャンと、ユーザーによる再スキャンはここを通る。**
//  記録しないと、次の起動で毎回「起点が使えない」と判定されてフルスキャンから
//  やり直すことになる——ネットワーク上のライブラリでは特に高くつく。
//
@MainActor
@Suite("手動の走査が差分の起点を残す [SY-02]", .serialized)
struct ManualScanCheckpointTests {

    @Test func aManualScanThroughLibraryServicesPersistsTheCheckpoint() async throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("qoo-manual-\(UUID().uuidString)")
        let root = base.appendingPathComponent("library")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        FileManager.default.createFile(
            atPath: root.appendingPathComponent("(同人誌) [サークルA] 作品.cbz").path,
            contents: Data(repeating: 0x41, count: 16))

        let services = LibraryServices()
        let storeURL = base.appendingPathComponent("store/qooLibrary.sqlite")
        await services.bootstrap(storeURL: storeURL)
        let template = try #require(services.presetTemplates.first { $0.key == "builtin.doujinshi-a" })
        let id = try await services.enable(
            registrationUUID: UUID(), displayName: "手動", url: root,
            bookmarkData: Data(), template: template)

        let summary = try await services.scan(libraryID: id, root: root)
        #expect(summary.added == 1)

        // ストアを直接読む（`LibraryServices` は内部状態を公開しない）。
        let database = try QooDatabase.open(at: storeURL)
        let repository = SQLiteLibraryRepository(
            database: database, volumeSets: try BuiltInTemplates.volumeSets())
        let state = try #require(try await repository.watchStates().first)
        #expect(state.checkpoint.eventID > 0, "起点が記録されていない")
        #expect(state.checkpoint.deviceUUID == FSEventsHistory.deviceUUID(for: root),
                "デバイス UUID とセットで記録されていない")
        #expect(state.lastFullScanAt != nil, "フルスキャンの時刻が記録されていない [SY-05]")
        // 記録した起点が、次の起動で実際に「使える」と判定されること。
        #expect(state.checkpoint.isUsable(
            currentDeviceUUID: FSEventsHistory.deviceUUID(for: root)))
    }
}
