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

    /// [フェーズ1完了時のリソースリーク監査で追加] 同じ場所への許可を重複して
    /// 追加すると、取り消し時にどちらか一方の `stopAccessingSecurityScopedResource`
    /// が呼ばれないまま残ってしまうリークの温床になっていたため、重複を防ぐ。
    @Test func grantAccessToTheSamePathTwiceReturnsTheExistingGrant() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("Target", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let store = VolumeAccessStore(storageURL: root.appendingPathComponent("state.json"))

        let first = try await store.grantAccess(to: target, displayName: nil)
        let second = try await store.grantAccess(to: target, displayName: nil)

        #expect(first.id == second.id)
        let list = await store.grantedAccess()
        #expect(list.count == 1)
    }

    /// [フェーズ1完了時の監査で追加] JSON のデコードに失敗しても、次の
    /// `save()` が壊れた元ファイルを黙って上書きしないことを確認する
    /// （`RegisteredFolderStore` にも同じ対策がある）。
    @Test func corruptStorageFileIsPreservedAsABackupInsteadOfBeingOverwritten() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let storageURL = root.appendingPathComponent("state.json")
        try Data("not valid json".utf8).write(to: storageURL)
        let store = VolumeAccessStore(storageURL: storageURL)

        let list = await store.grantedAccess()
        #expect(list.isEmpty)

        let siblings = try FileManager.default.contentsOfDirectory(atPath: root.path)
        let backups = siblings.filter { $0.hasPrefix("state.json.corrupt-") }
        #expect(backups.count == 1)
        #expect(!FileManager.default.fileExists(atPath: storageURL.path))
    }

    // MARK: - hasGrant [1-16 移動メニューの Finder 準拠、標準の場所を開く判定]

    /// 祖先への許可で足りる場所（実ホーム・`/Users/Shared` 等）。
    @Test func ancestorGrantCoversADescendantWhenExactMatchIsNotRequired() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let child = root.appendingPathComponent("Child/Grandchild", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        let store = VolumeAccessStore(storageURL: root.appendingPathComponent("state.json"))
        try await store.grantAccess(to: root, displayName: nil)

        #expect(await store.hasGrant(covering: child, requiringExactMatch: false))
        #expect(await store.hasGrant(covering: root, requiringExactMatch: false))
    }

    /// TCC 保護フォルダ（書類・デスクトップ）。**祖先の許可では足りない** —
    /// `/` を許可してあってもサンドボックス層を通るだけで TCC は通らないため
    /// [1章 §1.4 B-25 の実測]。
    @Test func ancestorGrantDoesNotCountWhenExactMatchIsRequired() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let child = root.appendingPathComponent("Documents", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        let store = VolumeAccessStore(storageURL: root.appendingPathComponent("state.json"))
        try await store.grantAccess(to: root, displayName: nil)

        #expect(await store.hasGrant(covering: child, requiringExactMatch: true) == false)

        try await store.grantAccess(to: child, displayName: nil)
        #expect(await store.hasGrant(covering: child, requiringExactMatch: true))
    }

    /// **名前が前方一致するだけの別フォルダを覆っていると誤らない。**
    /// 素の `hasPrefix` で書くと `…/Doc` が `…/Documents` を覆う判定になる。
    @Test func aSiblingWhoseNameMerelySharesAPrefixIsNotCovered() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let granted = root.appendingPathComponent("Doc", isDirectory: true)
        let other = root.appendingPathComponent("Documents", isDirectory: true)
        for url in [granted, other] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        let store = VolumeAccessStore(storageURL: root.appendingPathComponent("state.json"))
        try await store.grantAccess(to: granted, displayName: nil)

        #expect(await store.hasGrant(covering: other, requiringExactMatch: false) == false)
        #expect(await store.hasGrant(covering: granted, requiringExactMatch: false))
    }

    @Test func nothingIsCoveredWhenThereAreNoGrants() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = VolumeAccessStore(storageURL: root.appendingPathComponent("state.json"))

        #expect(await store.hasGrant(covering: root, requiringExactMatch: false) == false)
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
