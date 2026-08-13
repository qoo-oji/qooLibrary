import Foundation
import Testing

@testable import QooInfrastructure

@Suite struct AppAssociationStoreTests {
    /// macOS に常時同梱されているアプリの bundle ID。テスト環境でも確実に
    /// `NSWorkspace.urlForApplication(withBundleIdentifier:)` が解決できる、
    /// 数十年変わっていない安定した ID のため採用する。
    private let stableBundleID = "com.apple.TextEdit"

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("qoo-appassociation-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func primaryReturnsNilForUnsetExtension() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppAssociationStore(storageURL: root.appendingPathComponent("state.json"))

        let primary = await store.primary(for: "txt")

        #expect(primary == nil)
    }

    @Test func setPrimaryAndPrimaryRoundTrip() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppAssociationStore(storageURL: root.appendingPathComponent("state.json"))

        try await store.setPrimary(stableBundleID, for: "txt")
        let primary = await store.primary(for: "txt")

        #expect(primary?.bundleID == stableBundleID)
    }

    /// 拡張子は大文字小文字を区別しない。
    @Test func setPrimaryIsCaseInsensitiveForExtension() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppAssociationStore(storageURL: root.appendingPathComponent("state.json"))

        try await store.setPrimary(stableBundleID, for: "TXT")
        let primary = await store.primary(for: "txt")

        #expect(primary?.bundleID == stableBundleID)
    }

    /// [AS-01] `nil` を渡すと「システムの既定に従う」へ戻る。
    @Test func setPrimaryToNilClearsOverride() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppAssociationStore(storageURL: root.appendingPathComponent("state.json"))
        try await store.setPrimary(stableBundleID, for: "txt")

        try await store.setPrimary(nil, for: "txt")

        let primary = await store.primary(for: "txt")
        #expect(primary == nil)
    }

    /// [AS2-05] 設定済みのアプリが（アンインストール等で）もう存在しない場合、
    /// `primary(for:)` はシステムの関連付けへのフォールバックとして `nil` を返す。
    @Test func primaryReturnsNilWhenSavedAppNoLongerExists() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppAssociationStore(storageURL: root.appendingPathComponent("state.json"))

        try await store.setPrimary("com.example.nonexistent-app-qoolibrary-test", for: "cbz")
        let primary = await store.primary(for: "cbz")

        #expect(primary == nil)
    }

    @Test func settingPersistsAcrossStoreInstancesOverTheSameStorage() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let storageURL = root.appendingPathComponent("state.json")
        let firstStore = AppAssociationStore(storageURL: storageURL)
        try await firstStore.setPrimary(stableBundleID, for: "cbz")

        let secondStore = AppAssociationStore(storageURL: storageURL)
        let primary = await secondStore.primary(for: "cbz")

        #expect(primary?.bundleID == stableBundleID)
    }
}
