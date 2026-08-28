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
    @Test func registrationReportsWarningsToTheCaller() async throws {
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

    // MARK: - 縮退状態 [1-17、8章 §8.7.1]
    //
    // 分類そのものの網羅は `RegisteredFolderStatusTests`（純粋関数へ直接
    // ぶつける）が担当する。ここでは**実ストアを通した配線**——解決・
    // 最終解決パスの追従・場所の選び直し——だけを確かめる。

    @Test func statesReportsOnlineForALiveRegistration() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("Library1", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let store = makeStore(storageURL: root.appendingPathComponent("state.json"))
        _ = try await store.register(url: target, kind: .library, displayName: nil)

        let states = await store.states()

        #expect(states.count == 1)
        #expect(states[0].status.allowsNavigation)
        #expect(states[0].status.allowsWriting)
        #expect(!states[0].isNested)
    }

    /// 登録した時点で場所を控える。以後オフラインになっても「どこにあったか」
    /// を言えるのはこの値があるから。
    @Test func registerRecordsTheResolvedPath() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("Library1", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let store = makeStore(storageURL: root.appendingPathComponent("state.json"))

        let registered = try await store.register(url: target, kind: .library, displayName: nil).folder

        #expect(registered.lastKnownPath == target.resolvingSymlinksInPath().standardizedFileURL.path)
    }

    /// フォルダを消すと `.missing`（一時ディレクトリは常にマウントされているので
    /// `.offline` にはならない）。**登録レコードは自動削除しない** [RG3-04]。
    @Test func statesReportsMissingAfterTheFolderIsDeletedAndKeepsTheRegistration() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("Library1", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let store = makeStore(storageURL: root.appendingPathComponent("state.json"))
        _ = try await store.register(url: target, kind: .library, displayName: nil)
        try FileManager.default.removeItem(at: target)

        let states = await store.states()

        #expect(states.count == 1) // 消えていない [RG3-04][SB-05]
        guard case .missing(let path) = states[0].status else {
            Issue.record("期待は .missing だが \(states[0].status)")
            return
        }
        #expect(path == target.resolvingSymlinksInPath().standardizedFileURL.path)
        #expect(!states[0].status.allowsNavigation)
    }

    /// ゴミ箱の中にある登録は `.inTrash` になり、書き込みも移動も許さない [BM-2]。
    /// 実際にゴミ箱へ移すとユーザーのゴミ箱を汚すので、実測で確認した
    /// **パスの形**（成分に `.Trash` を含む）を一時ディレクトリ内に再現する。
    @Test func statesReportsInTrashForAFolderInsideATrashDirectory() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent(".Trash/Library1", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let store = makeStore(storageURL: root.appendingPathComponent("state.json"))
        _ = try await store.register(url: target, kind: .library, displayName: nil)

        let states = await store.states()

        #expect(states[0].status.resolvedURL != nil) // 解決自体は成功する
        guard case .inTrash = states[0].status else {
            Issue.record("期待は .inTrash だが \(states[0].status)")
            return
        }
        #expect(!states[0].status.allowsWriting)
        #expect(!states[0].status.allowsNavigation)
    }

    /// **ゴミ箱の中の場所は「最後に分かっている場所」として覚えない**
    /// ［実機検証で気づいた］。覚えてしまうと、そのまま完全削除されたときの
    /// `.missing` 表示と「場所を選び直す…」パネルの開始位置が、ゴミ箱の中の
    /// パスになる（実機ではパネルが起点を開けず、無関係なホームから開いた）。
    /// 覚えておきたいのは健全だったときの場所である。
    @Test func doesNotRememberLocationsInsideTheTrash() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let healthy = root.appendingPathComponent("Library1", isDirectory: true)
        try FileManager.default.createDirectory(at: healthy, withIntermediateDirectories: true)
        let store = makeStore(storageURL: root.appendingPathComponent("state.json"))
        _ = try await store.register(url: healthy, kind: .library, displayName: nil)
        _ = await store.states() // 健全な場所を覚える
        let healthyPath = await store.folders(kind: .library)[0].lastKnownPath

        // ゴミ箱へ移した、に相当する（実測したパスの形を再現する）。
        let trashDir = root.appendingPathComponent(".Trash", isDirectory: true)
        try FileManager.default.createDirectory(at: trashDir, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: healthy, to: trashDir.appendingPathComponent("Library1"))
        let states = await store.states()

        guard case .inTrash = states[0].status else {
            Issue.record("期待は .inTrash だが \(states[0].status)")
            return
        }
        // 覚えている場所は**移動前のまま**。
        #expect(states[0].folder.lastKnownPath == healthyPath)
        #expect(states[0].folder.lastKnownPath?.contains(".Trash") == false)
    }

    /// 外部でフォルダを移動するとブックマークが追従する（BM-1）ので、
    /// 控えている場所もそれに合わせて更新される。
    @Test func statesRefreshesTheKnownPathAfterAnExternalMove() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("Before", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let store = makeStore(storageURL: root.appendingPathComponent("state.json"))
        _ = try await store.register(url: target, kind: .library, displayName: nil)

        let moved = root.appendingPathComponent("After", isDirectory: true)
        try FileManager.default.moveItem(at: target, to: moved)
        let states = await store.states()

        // **リテラルのパスと比べない。** ブックマークが返すのは実体のパス
        // （`/private/var/…`）で、テスト側の `resolvingSymlinksInPath()` は
        // 先頭の `/private` を取り除く特別扱いを持つため一致しない
        // ——本プロジェクトが `DirectoryChangeHub` で一度踏んだ罠と同じ。
        // 確かめたいのは「移動先に追従したか」なので、そこだけを見る。
        let resolved = try #require(states[0].status.resolvedURL)
        #expect(resolved.lastPathComponent == "After")
        #expect(states[0].folder.lastKnownPath == resolved.standardizedFileURL.path)
    }

    /// [RG3-05] 登録時には弾いた入れ子が、外部での移動によって事後に成立する。
    /// **警告するだけで自動解除はしない** [RG3-04]。
    @Test func statesFlagsNestingCreatedByAnExternalMove() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let outer = root.appendingPathComponent("Outer", isDirectory: true)
        let inner = root.appendingPathComponent("Inner", isDirectory: true)
        try FileManager.default.createDirectory(at: outer, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        let store = makeStore(storageURL: root.appendingPathComponent("state.json"))
        _ = try await store.register(url: outer, kind: .library, displayName: nil)
        _ = try await store.register(url: inner, kind: .temporary, displayName: nil)

        // Finder で Inner を Outer の中へ移した、に相当する。
        try FileManager.default.moveItem(at: inner, to: outer.appendingPathComponent("Inner"))
        let states = await store.states()

        #expect(states.count == 2) // 自動解除しない
        #expect(states.filter(\.isNested).count == 2) // 両方に警告を出す
    }

    // MARK: 場所を選び直す

    @Test func relocateKeepsTheRegistrationIDAndItsSettings() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("Original", isDirectory: true)
        let replacement = root.appendingPathComponent("Replacement", isDirectory: true)
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: replacement, withIntermediateDirectories: true)
        let store = makeStore(storageURL: root.appendingPathComponent("state.json"))
        let registered = try await store.register(url: original, kind: .library, displayName: "蔵書").folder
        try await store.setThumbnailsAlwaysHidden(true, for: registered.id)
        try FileManager.default.removeItem(at: original)

        let relocated = try await store.relocate(registered.id, to: replacement).folder

        // **ID が変わらないのが要点。** これに紐づくもの（フェーズ2ではラベル・
        // 評価・カバー画像）がそのまま生き残る。
        #expect(relocated.id == registered.id)
        #expect(relocated.displayName == "蔵書")
        #expect(relocated.hidesThumbnails)
        let states = await store.states()
        #expect(states.count == 1)
        #expect(states[0].status.allowsWriting)
    }

    /// 移し先が別の登録の中なら拒む（新規登録と同じ検査）。
    @Test func relocateRejectsADestinationNestedInAnotherRegistration() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let other = root.appendingPathComponent("Other", isDirectory: true)
        let inside = other.appendingPathComponent("Inside", isDirectory: true)
        let subject = root.appendingPathComponent("Subject", isDirectory: true)
        try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: subject, withIntermediateDirectories: true)
        let store = makeStore(storageURL: root.appendingPathComponent("state.json"))
        _ = try await store.register(url: other, kind: .library, displayName: nil)
        let registered = try await store.register(url: subject, kind: .temporary, displayName: nil).folder

        await #expect(throws: RegisteredFolderError.nestedRegistration) {
            try await store.relocate(registered.id, to: inside)
        }
    }

    /// **自分自身との入れ子は除く。** 外さないと、同じ場所を選び直しただけで
    /// 「入れ子です」と拒まれてしまう。
    @Test func relocateAcceptsTheSameFolderAgain() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("Library1", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let store = makeStore(storageURL: root.appendingPathComponent("state.json"))
        let registered = try await store.register(url: target, kind: .library, displayName: nil).folder

        let relocated = try await store.relocate(registered.id, to: target).folder

        #expect(relocated.id == registered.id)
    }

    @Test func relocateRejectsAnUnknownRegistration() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("Library1", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let store = makeStore(storageURL: root.appendingPathComponent("state.json"))

        await #expect(throws: RegisteredFolderError.notRegistered) {
            try await store.relocate(UUID(), to: target)
        }
    }

    /// **後方互換。** `lastKnownPath` が導入される前に書かれた JSON も読める
    /// こと——読めないと `load()` が退避して空で続行するため、**登録が全部
    /// 消えたように見える**［`thumbnailsAlwaysHidden` を足したときと同じ罠］。
    @Test func decodesStorageWrittenBeforeTheLastKnownPathFieldExisted() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("Library1", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let storageURL = root.appendingPathComponent("state.json")

        // 旧形式（`lastKnownPath` も `thumbnailsAlwaysHidden` も無い）を手で書く。
        let bookmark = try target.bookmarkData(
            options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil
        )
        let legacy: [[String: Any]] = [[
            "id": UUID().uuidString,
            "kind": "library",
            "displayName": "旧形式の蔵書",
            "bookmarkData": bookmark.base64EncodedString(),
        ]]
        try JSONSerialization.data(withJSONObject: legacy).write(to: storageURL)

        let store = makeStore(storageURL: storageURL)
        let folders = await store.folders(kind: .library)

        #expect(folders.count == 1)
        #expect(folders[0].displayName == "旧形式の蔵書")
        #expect(folders[0].lastKnownPath == nil) // 未移行を表す

        // 一度状態を解決すれば場所を覚える。
        _ = await store.states()
        let refreshed = await store.folders(kind: .library)
        #expect(refreshed[0].lastKnownPath == target.resolvingSymlinksInPath().standardizedFileURL.path)
    }

    // MARK: - 並べ替え [RG3-33]

    /// 並びは保存順＝利用者が決めた順。並べ替えは永続化され、別インスタンス
    /// （＝次の起動）でも保たれる。
    @Test func reorderPersistsAcrossInstances() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        var ids: [UUID] = []
        let storageURL = root.appendingPathComponent("state.json")
        let store = makeStore(storageURL: storageURL)
        for name in ["A", "B", "C"] {
            let target = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            ids.append(try await store.register(url: target, kind: .library, displayName: nil).folder.id)
        }

        await store.reorder(ids: [ids[2], ids[0], ids[1]], kind: .library)

        let after = await store.folders(kind: .library).map(\.id)
        #expect(after == [ids[2], ids[0], ids[1]])
        let reopened = makeStore(storageURL: storageURL)
        let persisted = await reopened.folders(kind: .library).map(\.id)
        #expect(persisted == [ids[2], ids[0], ids[1]])
    }

    /// 渡されなかった登録は末尾へ寄せるだけで落とさない——順序の更新で
    /// レコードが消える経路を作らない。
    @Test func reorderDoesNotDropUnlistedRegistrations() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        var ids: [UUID] = []
        let store = makeStore(storageURL: root.appendingPathComponent("state.json"))
        for name in ["A", "B", "C"] {
            let target = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            ids.append(try await store.register(url: target, kind: .library, displayName: nil).folder.id)
        }

        await store.reorder(ids: [ids[1]], kind: .library)

        let after = await store.folders(kind: .library).map(\.id)
        #expect(after.count == 3)
        #expect(after.first == ids[1])
        #expect(Set(after) == Set(ids))
    }

    /// 並べ替えは種別の中で閉じる——ライブラリを並べ替えてもテンポラリの
    /// 並びは動かない。
    @Test func reorderKeepsTheOtherKindUntouched() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(storageURL: root.appendingPathComponent("state.json"))
        var libraryIDs: [UUID] = []
        var temporaryIDs: [UUID] = []
        for name in ["L1", "T1", "L2", "T2"] {
            let target = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            let kind: RegisteredFolderKind = name.hasPrefix("L") ? .library : .temporary
            let id = try await store.register(url: target, kind: kind, displayName: nil).folder.id
            if kind == .library { libraryIDs.append(id) } else { temporaryIDs.append(id) }
        }

        await store.reorder(ids: [libraryIDs[1], libraryIDs[0]], kind: .library)

        let libraries = await store.folders(kind: .library).map(\.id)
        #expect(libraries == [libraryIDs[1], libraryIDs[0]])
        let temporaries = await store.folders(kind: .temporary).map(\.id)
        #expect(temporaries == temporaryIDs)
    }

    // MARK: - フォルダ名＝表示名 [RG3-31]

    /// ライブラリの表示名は、実フォルダがリネームされたら解決時に追随する。
    /// 追随した名前は永続化される（次の起動で古い名前へ戻らない）。
    @Test func libraryDisplayNameFollowsAFolderRename() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("旧名", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let storageURL = root.appendingPathComponent("state.json")
        let store = makeStore(storageURL: storageURL)
        let folder = try await store.register(url: target, kind: .library, displayName: nil).folder
        #expect(folder.displayName == "旧名")

        let renamed = root.appendingPathComponent("新名", isDirectory: true)
        try FileManager.default.moveItem(at: target, to: renamed)

        let resolved = await store.resolvedURL(for: folder)
        #expect(resolved?.lastPathComponent == "新名")
        let after = await store.folders(kind: .library)
        #expect(after.first?.displayName == "新名")
        let reopened = makeStore(storageURL: storageURL)
        let persisted = await reopened.folders(kind: .library)
        #expect(persisted.first?.displayName == "新名")
    }

    /// テンポラリの表示名 [RG-05] は利用者が付けた名前なので、リネームに
    /// 追随しない（ライブラリの「フォルダ名＝表示名」とは別の規則）。
    @Test func temporaryDisplayNameDoesNotFollowARename() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("取り込み元", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let store = makeStore(storageURL: root.appendingPathComponent("state.json"))
        let folder = try await store.register(url: target, kind: .temporary, displayName: "取り込み用").folder

        let renamed = root.appendingPathComponent("別の名前", isDirectory: true)
        try FileManager.default.moveItem(at: target, to: renamed)

        _ = await store.resolvedURL(for: folder)
        let after = await store.folders(kind: .temporary)
        #expect(after.first?.displayName == "取り込み用")
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
