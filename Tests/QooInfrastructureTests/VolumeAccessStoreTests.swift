import Foundation
import Testing

@testable import QooInfrastructure

@Suite struct VolumeAccessStoreTests {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("qoo-volumeaccess-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func grantAccessAddsToTheList() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("Target", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let store = VolumeAccessStore(storageURL: root.appendingPathComponent("state.json"))

        let granted = try await store.grantAccess(to: target, displayName: nil)

        #expect(granted.displayName == "Target")
        let list = await store.grantedAccess()
        #expect(list.map(\.id) == [granted.id])
    }

    @Test func grantAccessUsesProvidedDisplayName() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("RawName", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let store = VolumeAccessStore(storageURL: root.appendingPathComponent("state.json"))

        let granted = try await store.grantAccess(to: target, displayName: "Custom Name")

        #expect(granted.displayName == "Custom Name")
    }

    @Test func resolvedURLReturnsTheGrantedPath() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("Target", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let store = VolumeAccessStore(storageURL: root.appendingPathComponent("state.json"))
        let granted = try await store.grantAccess(to: target, displayName: nil)

        let resolved = await store.resolvedURL(for: granted)

        #expect(resolved?.standardizedFileURL.path == target.resolvingSymlinksInPath().standardizedFileURL.path)
    }

    @Test func revokeAccessRemovesFromTheList() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("Target", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let store = VolumeAccessStore(storageURL: root.appendingPathComponent("state.json"))
        let granted = try await store.grantAccess(to: target, displayName: nil)

        try await store.revokeAccess(granted.id)

        let list = await store.grantedAccess()
        #expect(list.isEmpty)
    }

    @Test func grantedAccessIsSortedByDisplayName() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = VolumeAccessStore(storageURL: root.appendingPathComponent("state.json"))
        for name in ["Zebra", "Apple", "Mango"] {
            let target = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            try await store.grantAccess(to: target, displayName: name)
        }

        let list = await store.grantedAccess()

        #expect(list.map(\.displayName) == ["Apple", "Mango", "Zebra"])
    }

    @Test func grantsPersistAcrossStoreInstancesOverTheSameStorage() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("Target", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let storageURL = root.appendingPathComponent("state.json")
        let firstStore = VolumeAccessStore(storageURL: storageURL)
        try await firstStore.grantAccess(to: target, displayName: "Target")

        let secondStore = VolumeAccessStore(storageURL: storageURL)
        let list = await secondStore.grantedAccess()

        #expect(list.map(\.displayName) == ["Target"])
    }
}
