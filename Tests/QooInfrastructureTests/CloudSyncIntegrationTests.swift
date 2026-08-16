import Foundation
import QooKit
import Testing

@testable import QooInfrastructure

/// **クラウド同期（File Provider）の配下で、実際に期待どおり振る舞うか**
/// [NV8-01][NV8-02][NV8-04、8章 §8.11.8]。
///
/// ## なぜ環境変数で opt-in にするのか
/// `CloudSyncLocationTests` は「クラウドではない」と答える側と、パスからの
/// 提供元の読み取りを合成データで固定している。**残っていたのは
/// 「クラウドである」と答える側**で、これは実際にプロバイダの配下へ
/// フォルダを作らないと確かめられない。
///
/// かといって `~/Library/Mobile Documents/…` を勝手に使うと、**開発機の
/// iCloud アカウントへ黙って書き込む**ことになる。使い捨てにしてよい場所を
/// 明示してもらったときだけ走らせる。
///
/// ```
/// QOO_CLOUD_TEST_FOLDER=~/Library/Mobile\ Documents/com~apple~CloudDocs \
///   swift test --filter CloudSync
/// ```
///
/// ## 何が確かめられて、何が残るか
/// | | |
/// |---|---|
/// | iCloud Drive での検出・警告・脱水判定 | **このスイートで確かめられる** |
/// | 第三者プロバイダ（OneDrive/Dropbox/Box/Google Drive） | **未検証**。同じ File Provider 機構に乗るため同じはずだが [文献]、この開発機には 1 つも無い |
@Suite(.serialized) struct CloudSyncIntegrationTests {

    /// クラウド配下の使い捨てフォルダ。**既存のデータには一切触れない。**
    private struct Workspace: ~Copyable {
        let root: URL
        init?() {
            guard let base = ProcessInfo.processInfo.environment["QOO_CLOUD_TEST_FOLDER"],
                  !base.isEmpty
            else { return nil }
            let root = URL(fileURLWithPath: (base as NSString).expandingTildeInPath)
                .appendingPathComponent("qoo-probe-\(UUID().uuidString)")
            guard (try? FileManager.default.createDirectory(
                at: root, withIntermediateDirectories: true)) != nil
            else { return nil }
            self.root = root
        }
        /// **後片付けも試し直す。** 同期中のフォルダは削除が一過性に失敗し得る。
        deinit {
            // ``removeThrowawayDirectory(at:)`` の説明を参照 — `fileExists` で
            // 成否を判定すると、キャッシュ越しの古い答えを信じて
            // 「消した」ことにしてしまう。
            if let error = removeThrowawayDirectory(at: root) {
                FileHandle.standardError.write(Data(
                    "[CloudSyncIntegrationTests] 使い捨てフォルダを消せませんでした: \(root.path) — \(error)\n".utf8))
            }
        }
    }

    /// `brctl evict` で実体を追い出す。成功したら `true`。
    private static func evict(_ url: URL) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/brctl")
        process.arguments = ["evict", url.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        Thread.sleep(forTimeInterval: 1.5)
        return CloudMaterialization.isDataless(url)
    }

    // MARK: - NV8-04「クラウドである」と答える側

    /// **これが 8章 §8.11.13 に「未検証」として残っていた項目そのもの。**
    @Test func aFolderInsideACloudProviderIsDetected() async throws {
        guard let workspace = Workspace() else { return }
        let detection = await CloudSyncLocation.detect(at: workspace.root)
        let found = try #require(detection, "クラウド配下なのに検出できていない")
        // ドメイン識別子か提供元の名前のどちらかは得られるはず。iCloud Drive は
        // `~/Library/CloudStorage` に居ないので、名前ではなくドメインで当たる。
        #expect(
            found.domainIdentifier != nil || found.providerName != nil,
            "検出はしたが手掛かりが何も無い: \(found)"
        )
    }

    /// 逆向きの固定。**これが無いと「常に検出したと答える」実装でも
    /// 上のテストが通ってしまう。**
    @Test func aLocalFolderIsNotDetectedAsCloud() async throws {
        guard Workspace() != nil else { return } // 環境が無いときは両方飛ばす
        let local = FileManager.default.temporaryDirectory
            .appendingPathComponent("qoo-local-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: local) }

        let detection = await CloudSyncLocation.detect(at: local)
        #expect(detection == nil, "ローカルの一時ディレクトリをクラウドと誤認した")
    }

    /// **登録すると実際に警告が返ること** [NV8-04]。検出できても
    /// `RegisteredFolderStore` が捨てていれば意味が無い——`isReadOnly` が
    /// 「計算されていたのに誰も読んでいなかった」のと同じ抜けを防ぐ。
    @Test func registeringACloudFolderReportsTheWarning() async throws {
        guard let workspace = Workspace() else { return }
        let storage = FileManager.default.temporaryDirectory
            .appendingPathComponent("qoo-cloud-store-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: storage) }

        let store = RegisteredFolderStore(storageURL: storage)
        let result = try await store.register(
            url: workspace.root, kind: .library, displayName: "cloud probe"
        )
        let hasCloudWarning = result.warnings.contains {
            if case .cloudSyncedLocation = $0 { return true }
            return false
        }
        #expect(hasCloudWarning, "クラウド配下の登録なのに警告が付いていない: \(result.warnings)")
    }

    // MARK: - NV8-01/02 脱水したファイルの扱い

    /// `SF_DATALESS` が実際に立ち、``CloudMaterialization`` が拾えること。
    ///
    /// これが読めないと、一覧を開いただけで**頼んでもいない蔵書全体の
    /// ダウンロードが始まる**（サムネイル生成が 1 件ずつ実体化させるため）。
    @Test func anEvictedFileIsSeenAsDataless() async throws {
        guard let workspace = Workspace() else { return }
        let file = workspace.root.appendingPathComponent("evictable.bin")
        try Data(repeating: 0x51, count: 2 * 1024 * 1024).write(to: file)

        #expect(!CloudMaterialization.isDataless(file), "書いた直後は実体があるはず")
        guard Self.evict(file) else { return } // 追い出せない環境では飛ばす
        #expect(CloudMaterialization.isDataless(file), "追い出したのに脱水と判定できていない")

        // 読めば実体化する（＝ユーザーが明示的に頼んだ操作は従来どおり通る [NV8-02]）。
        let read = try Data(contentsOf: file)
        #expect(read.count == 2 * 1024 * 1024)
        #expect(!CloudMaterialization.isDataless(file), "読んだのに脱水のまま")
    }

    /// **サムネイルを作らないこと** [NV8-02]。ここが効かないと、
    /// アイコン表示でフォルダを開いた瞬間に全件のダウンロードが始まる。
    @Test func noThumbnailIsGeneratedForADatalessFile() async throws {
        guard let workspace = Workspace() else { return }
        let image = workspace.root.appendingPathComponent("cover.png")
        try TestImageFixture.makePNGData(width: 64, height: 64).write(to: image)

        // **対照をまず取る。** これが無いと、サムネイルが別の理由（画像が
        // 壊れている・サービスが常に失敗する）で `nil` でも下の検証が通り、
        // **何も検査していないテスト**になる。本プロジェクトは実際に
        // 空振りのテストを書いて後から気づいている。
        let service = ThumbnailService()
        let whileMaterialized = await service.thumbnail(for: image, maxPixelSize: 128)
        #expect(whileMaterialized != nil, "実体があるうちはサムネイルが作れるはず（対照が成立していない）")

        guard Self.evict(image) else { return }
        // 実体があったときのサムネイルがキャッシュに残っていると、脱水後も
        // それが返って検証にならない。キャッシュを別の場所にしてやり直す。
        let isolated = ThumbnailService(
            cache: DefaultCoverImageCache(
                baseDirectory: FileManager.default.temporaryDirectory
                    .appendingPathComponent("qoo-cloud-cache-\(UUID().uuidString)", isDirectory: true)
            )
        )
        let whileDataless = await isolated.thumbnail(for: image, maxPixelSize: 128)
        #expect(whileDataless == nil, "脱水したファイルからサムネイルを作ってしまった（＝実体化させた）")
        #expect(CloudMaterialization.isDataless(image), "サムネイル生成が実体化を引き起こした")
    }
}
