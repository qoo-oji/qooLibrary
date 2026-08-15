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

    /// [Finder 対比監査] コンテキストメニューの「常にこのアプリケーションで
    /// 開く」（「このアプリケーションで開く」の ⌥ 代替）は、一覧に無い拡張子
    /// に対しても実行できる。関連付けだけ保存して一覧に載せないと、環境設定
    /// 「ビューア」タブ（`extensions()` しか表示しない）に現れず、後から確認も
    /// 変更もできない迷子の設定になってしまうため、ストア側で一覧にも加える。
    @Test func setPrimaryAddsTheExtensionToTheManagedList() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppAssociationStore(storageURL: root.appendingPathComponent("state.json"))
        let before = await store.extensions()
        #expect(!before.contains("qoo-test-ext"))

        try await store.setPrimary(stableBundleID, for: "QOO-TEST-EXT") // 大文字でも小文字で登録される

        let after = await store.extensions()
        #expect(after.contains("qoo-test-ext"))
    }

    /// 逆に「システムの既定に従う」へ戻しただけでは一覧から外さない
    /// （管理対象から降ろすのは `removeExtension(_:)` の役割）。
    @Test func setPrimaryToNilKeepsTheExtensionInTheManagedList() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppAssociationStore(storageURL: root.appendingPathComponent("state.json"))
        try await store.setPrimary(stableBundleID, for: "qoo-test-ext")

        try await store.setPrimary(nil, for: "qoo-test-ext")

        let extensions = await store.extensions()
        #expect(extensions.contains("qoo-test-ext"))
        let primary = await store.primary(for: "qoo-test-ext")
        #expect(primary == nil)
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

    /// [ユーザー要望] 初回起動時は、qooLibrary が実際に読める形式（zip/cbz・
    /// 7z/cb7・rar/cbr）と qooViewer が対応する形式（pdf・epub）が既定で
    /// この一覧に入っている。**[統合] 以前は「組み込み」として別管理して
    /// いたが、「既定拡張子とカスタム拡張子を分離する意味はない」という
    /// ユーザー指摘を受けて単一の一覧に統合した——以後は他の追加項目と
    /// 全く同じ扱い（削除・追加が自由にできる）。**
    @Test func freshStoreSeedsWithDefaultExtensions() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppAssociationStore(storageURL: root.appendingPathComponent("state.json"))

        let extensions = await store.extensions()

        #expect(extensions == ["7z", "cb7", "cbr", "cbz", "epub", "pdf", "rar", "zip"])
    }

    /// [ユーザー要望] 動画ライブラリとしても使えるよう、任意の拡張子を
    /// ビューアタブの管理対象に追加できる。
    @Test func addExtensionAddsToTheList() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppAssociationStore(storageURL: root.appendingPathComponent("state.json"))

        try await store.addExtension("MP4")

        let extensions = await store.extensions()
        #expect(extensions.contains("mp4")) // 大文字小文字を区別せず小文字化して保持
    }

    @Test func extensionsAreSortedAndDeduplicated() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppAssociationStore(storageURL: root.appendingPathComponent("state.json"))

        try await store.addExtension("mkv")
        try await store.addExtension("avi")
        try await store.addExtension("mkv") // 重複追加

        let extensions = await store.extensions()
        #expect(extensions == extensions.sorted())
        #expect(extensions.filter { $0 == "mkv" }.count == 1)
        #expect(extensions.contains("avi"))
    }

    @Test func removeExtensionRemovesFromListAndClearsItsPrimary() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppAssociationStore(storageURL: root.appendingPathComponent("state.json"))
        try await store.addExtension("mp4")
        try await store.setPrimary(stableBundleID, for: "mp4")

        try await store.removeExtension("mp4")

        let extensions = await store.extensions()
        #expect(!extensions.contains("mp4"))
        let primary = await store.primary(for: "mp4")
        #expect(primary == nil)
    }

    /// [統合の核心] 既定で入っている拡張子（例: zip）も、ユーザーが追加した
    /// 拡張子と全く同じように削除できる。削除後に別インスタンスで読み直しても
    /// 復活しない（既定値の投入は初回起動時の1回きりで、以後は永続化された
    /// 内容がそのまま尊重される——将来のバージョンで既定拡張子が増えても、
    /// 既にこのファイルを持つユーザーの一覧を上書き・マージすることはない）。
    @Test func removingADefaultExtensionRemovesItPermanently() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let storageURL = root.appendingPathComponent("state.json")
        let store = AppAssociationStore(storageURL: storageURL)
        let before = await store.extensions()
        #expect(before.contains("zip"))

        try await store.removeExtension("zip")

        let after = await store.extensions()
        #expect(!after.contains("zip"))

        let reopened = AppAssociationStore(storageURL: storageURL)
        let reloaded = await reopened.extensions()
        #expect(!reloaded.contains("zip"))
    }

    @Test func extensionsPersistAcrossStoreInstances() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let storageURL = root.appendingPathComponent("state.json")
        let firstStore = AppAssociationStore(storageURL: storageURL)
        try await firstStore.addExtension("mov")

        let secondStore = AppAssociationStore(storageURL: storageURL)
        let extensions = await secondStore.extensions()

        #expect(extensions.contains("mov"))
    }

    /// 拡張子リストを導入する前の `[String: String]` 単体の JSON 形式
    /// （既存ユーザーの永続化ファイル）も引き続き読み込める。この形式には
    /// 拡張子一覧という概念自体が無かったため、初回起動と同じく既定値で
    /// 埋める。
    @Test func loadsLegacyPlainDictionaryFormat() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let storageURL = root.appendingPathComponent("state.json")
        let legacyJSON = try JSONEncoder().encode(["cbz": stableBundleID])
        try legacyJSON.write(to: storageURL)
        let store = AppAssociationStore(storageURL: storageURL)

        let primary = await store.primary(for: "cbz")
        let extensions = await store.extensions()

        #expect(primary?.bundleID == stableBundleID)
        #expect(extensions.contains("cbz"))
    }

    /// [ユーザー要望・重要な移行ケース] 「組み込み／カスタム」を分離して
    /// 管理していた頃に保存されたファイル（組み込み形式が一度も
    /// `customExtensions` に含まれていない——このセッション中に実機で
    /// mp4/mkv の関連付けをテストした際に実際に作られたファイルと同じ形）
    /// を読み込んでも、組み込みだった形式が一覧から消えたままにならない。
    @Test func migratesPreUnificationFileByUnioningInDefaultExtensions() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let storageURL = root.appendingPathComponent("state.json")
        let preUnificationJSON = """
        {"associations":{"cbr":"com.example.viewer"},"customExtensions":["mkv","mp4"]}
        """
        try Data(preUnificationJSON.utf8).write(to: storageURL)
        let store = AppAssociationStore(storageURL: storageURL)

        let extensions = await store.extensions()

        #expect(extensions.contains("mkv"))
        #expect(extensions.contains("mp4"))
        #expect(extensions.contains("zip")) // 組み込みだった形式も消えない
        #expect(extensions.contains("pdf"))

        // 移行は1回きり: zip を削除して読み直しても復活しない。
        try await store.removeExtension("zip")
        let reopened = AppAssociationStore(storageURL: storageURL)
        let reloaded = await reopened.extensions()
        #expect(!reloaded.contains("zip"))
        #expect(reloaded.contains("mkv")) // 他の項目は保持される
    }
}
