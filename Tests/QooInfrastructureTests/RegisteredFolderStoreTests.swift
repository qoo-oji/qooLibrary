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

        let registered = try await store.register(url: target, kind: .library, displayName: nil).folder

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

        let registered = try await store.register(url: target, kind: .temporary, displayName: "取り込み用").folder

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
        let registered = try await store.register(url: target, kind: .library, displayName: nil).folder

        try await store.unregister(registered.id)

        let libraries = await store.folders(kind: .library)
        #expect(libraries.isEmpty)
    }

    // MARK: - サムネイルを常に非表示 [DS-04]

    @Test func thumbnailsAreNotAlwaysHiddenByDefault() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("Library1", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let store = makeStore(storageURL: root.appendingPathComponent("state.json"))

        let registered = try await store.register(url: target, kind: .library, displayName: nil).folder

        #expect(registered.hidesThumbnails == false)
    }

    @Test func thumbnailsAlwaysHiddenRoundTripsAndPersists() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("Library1", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let storageURL = root.appendingPathComponent("state.json")
        let store = makeStore(storageURL: storageURL)
        let registered = try await store.register(url: target, kind: .library, displayName: nil).folder

        try await store.setThumbnailsAlwaysHidden(true, for: registered.id)
        #expect(await store.folders(kind: .library).first?.hidesThumbnails == true)

        // 別インスタンス＝アプリを再起動した状態。
        let reopened = makeStore(storageURL: storageURL)
        #expect(await reopened.folders(kind: .library).first?.hidesThumbnails == true)

        try await reopened.setThumbnailsAlwaysHidden(false, for: registered.id)
        #expect(await reopened.folders(kind: .library).first?.hidesThumbnails == false)
    }

    /// **この属性を足す前に書かれた `registeredFolders.json` を読めること。**
    ///
    /// Swift の合成された `Decodable` はプロパティの既定値を使わず、キーが
    /// 無いと `keyNotFound` で失敗する。もし非 Optional で足していたら、
    /// 既存ユーザーのファイルは丸ごとデコードに失敗し——`load()` は失敗を
    /// バックアップへ退避して**空**で続行するため——登録済みのライブラリ／
    /// テンポラリがすべて消えたように見えるところだった。
    @Test func decodesStorageWrittenBeforeTheThumbnailAttributeExisted() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("Library1", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let storageURL = root.appendingPathComponent("state.json")

        // 旧形式をそのまま組み立てる（`thumbnailsAlwaysHidden` のキーが無い）。
        let bookmark = try target.bookmarkData(options: .withSecurityScope)
        let legacy: [[String: Any]] = [[
            "id": UUID().uuidString,
            "kind": "library",
            "displayName": "Library1",
            "bookmarkData": bookmark.base64EncodedString(),
        ]]
        try JSONSerialization.data(withJSONObject: legacy).write(to: storageURL)

        let store = makeStore(storageURL: storageURL)
        let libraries = await store.folders(kind: .library)

        #expect(libraries.count == 1)
        #expect(libraries.first?.displayName == "Library1")
        #expect(libraries.first?.hidesThumbnails == false)
    }

    @Test func renameChangesDisplayNameOnly() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("Original", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let store = makeStore(storageURL: root.appendingPathComponent("state.json"))
        let registered = try await store.register(url: target, kind: .library, displayName: nil).folder

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

    /// [フェーズ1完了時のリソースリーク・ファイル安全性監査で追加] JSON の
    /// デコードに失敗しても、次の `save()` が壊れた元ファイルを黙って
    /// 上書きしないことを確認する（`VolumeAccessStore` にも同じ対策がある）。
    /// これが無いと、たまたま1回デコードに失敗しただけで以前登録していた
    /// ライブラリ／テンポラリフォルダの記録が全て消え去ってしまう。
    @Test func corruptStorageFileIsPreservedAsABackupInsteadOfBeingOverwritten() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let storageURL = root.appendingPathComponent("state.json")
        try Data("not valid json".utf8).write(to: storageURL)
        let store = makeStore(storageURL: storageURL)

        let libraries = await store.folders(kind: .library)
        #expect(libraries.isEmpty)

        let siblings = try FileManager.default.contentsOfDirectory(atPath: root.path)
        let backups = siblings.filter { $0.hasPrefix("state.json.corrupt-") }
        #expect(backups.count == 1)
        #expect(!FileManager.default.fileExists(atPath: storageURL.path))
    }
    // MARK: - 完全削除に伴う強制解除 [FM-14、ユーザー要望]

    /// 登録フォルダ**そのもの**を完全削除する場合。
    @Test func registrationsInvalidatedFindsTheRegisteredFolderItself() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("Lib", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let store = makeStore(storageURL: root.appendingPathComponent("state.json"))
        let registered = try await store.register(url: target, kind: .library, displayName: nil).folder

        let doomed = await store.registrationsInvalidated(byDeleting: [target])

        #expect(doomed.map(\.folder.id) == [registered.id])
    }

    /// 登録フォルダの**祖先**を削除する場合（配下ごと消えるため登録も無効）。
    @Test func registrationsInvalidatedFindsRegistrationsUnderADeletedAncestor() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let parent = root.appendingPathComponent("parent", isDirectory: true)
        let nested = parent.appendingPathComponent("Lib", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let store = makeStore(storageURL: root.appendingPathComponent("state.json"))
        let registered = try await store.register(url: nested, kind: .library, displayName: nil).folder

        let doomed = await store.registrationsInvalidated(byDeleting: [parent])

        #expect(doomed.map(\.folder.id) == [registered.id])
    }

    /// 名前が前方一致するだけの別フォルダを巻き込まない
    /// （"Lib" を消しても "Library2" の登録は無効にならない）。
    @Test func registrationsInvalidatedIgnoresSiblingsWithACommonNamePrefix() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let lib = root.appendingPathComponent("Lib", isDirectory: true)
        let other = root.appendingPathComponent("Library2", isDirectory: true)
        try FileManager.default.createDirectory(at: lib, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let store = makeStore(storageURL: root.appendingPathComponent("state.json"))
        _ = try await store.register(url: other, kind: .library, displayName: nil)

        let doomed = await store.registrationsInvalidated(byDeleting: [lib])

        #expect(doomed.isEmpty)
    }

    @Test func unregisterAllRemovesTheGivenRegistrations() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("A", isDirectory: true)
        let b = root.appendingPathComponent("B", isDirectory: true)
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
        let store = makeStore(storageURL: root.appendingPathComponent("state.json"))
        let first = try await store.register(url: a, kind: .library, displayName: nil).folder
        let second = try await store.register(url: b, kind: .library, displayName: nil).folder

        await store.unregisterAll(ids: [first.id])

        let remaining = await store.folders(kind: .library)
        #expect(remaining.map(\.id) == [second.id])
    }

    /// **登録は通るが知らせるべきこと**を、呼び出し側へ渡すこと [NV-87][FS-06]。
    ///
    /// `VolumeEligibilityChecker` はネットワークボリュームに対して
    /// `.networkVolumeFSEventsUnreliable` を生成していたのに、`register` が
    /// `case .eligible: break` で捨てており、**UI へ届く口がそもそも無かった**
    /// （コメントには「提示は呼び出し側の責務」と書いてあった）。
    @Test func registrationReportsVolumeWarningsToTheCaller() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("共有", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)

        let store = RegisteredFolderStore(
            storageURL: root.appendingPathComponent("store.json"),
            volumeChecker: WarningVolumeChecker()
        )
        let result = try await store.register(url: target, kind: .library, displayName: nil)

        #expect(result.warnings == [.networkVolumeFSEventsUnreliable], "警告が捨てられている")
        // 警告があっても登録自体は通る（拒否ではない）。
        #expect(await store.folders(kind: .library).count == 1)
    }
}

/// 登録は通すが警告を返すフェイク（ネットワークボリュームの模擬）。
private struct WarningVolumeChecker: VolumeEligibilityChecking {
    func capability(of url: URL) throws -> VolumeCapability {
        VolumeCapability(
            volumeUUID: "fake", fileSystemName: "smbfs", supportsPersistentIDs: true,
            isNetworkVolume: true, isReadOnly: false
        )
    }

    func evaluate(_ url: URL) async throws -> VolumeEligibility {
        .eligible(warnings: [.networkVolumeFSEventsUnreliable])
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
