import Foundation
import Testing

@testable import QooInfrastructure

@Suite struct RegisteredFolderStoreTests {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("qoo-registeredfolder-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeStore(storageURL: URL) -> RegisteredFolderStore {
        RegisteredFolderStore(storageURL: storageURL)
    }

    @Test func registerAddsToFoldersOfThatKind() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("Library1", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let store = makeStore(storageURL: root.appendingPathComponent("state.json"))

        let registered = try await store.register(url: target, kind: .library, displayName: nil)

        #expect(registered.displayName == "Library1")
        let libraries = await store.folders(kind: .library)
        #expect(libraries.map(\.id) == [registered.id])
        let temporaries = await store.folders(kind: .temporary)
        #expect(temporaries.isEmpty)
    }

    @Test func registerUsesProvidedDisplayName() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("RawName", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let store = makeStore(storageURL: root.appendingPathComponent("state.json"))

        let registered = try await store.register(url: target, kind: .temporary, displayName: "取り込み用")

        #expect(registered.displayName == "取り込み用")
    }

    /// [RG-03][RG-04] 既存の登録フォルダの子孫を新たに登録しようとすると拒否される。
    @Test func registerRejectsDescendantOfExistingRegistration() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let parent = root.appendingPathComponent("Parent", isDirectory: true)
        let child = parent.appendingPathComponent("Child", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        let store = makeStore(storageURL: root.appendingPathComponent("state.json"))
        _ = try await store.register(url: parent, kind: .library, displayName: nil)

        await #expect(throws: RegisteredFolderError.nestedRegistration) {
            try await store.register(url: child, kind: .library, displayName: nil)
        }
    }

    /// [RG-03][RG-04] 既存の登録フォルダの祖先を新たに登録しようとしても拒否される
    /// （逆方向のネスト）。
    @Test func registerRejectsAncestorOfExistingRegistration() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let parent = root.appendingPathComponent("Parent", isDirectory: true)
        let child = parent.appendingPathComponent("Child", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        let store = makeStore(storageURL: root.appendingPathComponent("state.json"))
        _ = try await store.register(url: child, kind: .temporary, displayName: nil)

        await #expect(throws: RegisteredFolderError.nestedRegistration) {
            try await store.register(url: parent, kind: .library, displayName: nil)
        }
    }

    @Test func unregisterRemovesTheFolder() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("ToRemove", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let store = makeStore(storageURL: root.appendingPathComponent("state.json"))
        let registered = try await store.register(url: target, kind: .library, displayName: nil)

        try await store.unregister(registered.id)

        let libraries = await store.folders(kind: .library)
        #expect(libraries.isEmpty)
    }

    @Test func renameChangesDisplayNameOnly() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("Original", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let store = makeStore(storageURL: root.appendingPathComponent("state.json"))
        let registered = try await store.register(url: target, kind: .library, displayName: nil)

        try await store.rename(registered.id, to: "新しい名前")

        let libraries = await store.folders(kind: .library)
        #expect(libraries.first?.displayName == "新しい名前")
        #expect(libraries.first?.id == registered.id)
    }

    @Test func registrationPersistsAcrossStoreInstancesOverTheSameStorage() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("Persisted", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let storageURL = root.appendingPathComponent("state.json")
        let firstStore = makeStore(storageURL: storageURL)
        _ = try await firstStore.register(url: target, kind: .library, displayName: "永続化テスト")

        let secondStore = makeStore(storageURL: storageURL)
        await secondStore.loadAndActivateAll()

        let libraries = await secondStore.folders(kind: .library)
        #expect(libraries.map(\.displayName) == ["永続化テスト"])
    }

    /// [RG-08] ファイルシステムが永続的なファイル ID をサポートしない場合は
    /// 登録を拒否する。実際に非対応ボリュームを用意するのは困難なため、
    /// フェイクの `VolumeEligibilityChecking` で拒否を模擬する。
    @Test func registerRejectsUnsupportedFileSystem() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("Unsupported", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let store = RegisteredFolderStore(
            storageURL: root.appendingPathComponent("state.json"),
            volumeChecker: RejectingVolumeChecker()
        )

        await #expect(throws: RegisteredFolderError.self) {
            try await store.register(url: target, kind: .library, displayName: nil)
        }
    }
}

private struct RejectingVolumeChecker: VolumeEligibilityChecking {
    func capability(of url: URL) throws -> VolumeCapability {
        VolumeCapability(
            volumeUUID: "fake", fileSystemName: "exFAT", supportsPersistentIDs: false,
            isNetworkVolume: false, isReadOnly: false
        )
    }

    func evaluate(_ url: URL) async throws -> VolumeEligibility {
        .rejected(reason: .noPersistentFileID(fileSystem: "exFAT"))
    }
}
