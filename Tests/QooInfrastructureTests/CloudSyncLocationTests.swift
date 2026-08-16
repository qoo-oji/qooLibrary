import Foundation
import Testing

@testable import QooInfrastructure

/// **クラウド同期の配下かどうかの判定** [NV8-04]。
///
/// ## この開発機で確かめられること・られないこと
/// `~/Library/CloudStorage` は空、iCloud Drive も 0 件——**クラウドストレージが
/// 1 つも無い**ため、「クラウドである」と答える側は end-to-end に確かめられない。
/// そこで:
///
/// | | 確かめ方 |
/// |---|---|
/// | 「クラウドではない」と答える側 | **実測**（ローカル・一時ディレクトリで確認）|
/// | 提供元の名前をパスから読む部分 | **純粋な文字列処理として確認**（実体は不要）|
/// | 「クラウドである」と答える側 | **未検証**。プロバイダを入れられる環境が要る |
@Suite struct CloudSyncLocationTests {

    // MARK: - パスからの提供元の読み取り

    /// `~/Library/CloudStorage/<Provider>-<Account>` から提供元を取り出す。
    /// **ドメイン識別子は iCloud では素の UUID** なので、ユーザーに見せられる
    /// 名前はこちらからしか得られない。
    @Test(arguments: [
        ("/Users/someone/Library/CloudStorage/OneDrive-Contoso/Comics", "OneDrive"),
        ("/Users/someone/Library/CloudStorage/Dropbox/Comics", "Dropbox"),
        ("/Users/someone/Library/CloudStorage/GoogleDrive-me@example.com", "GoogleDrive"),
        ("/Users/someone/Library/CloudStorage/Box-Box", "Box"),
        // 末尾がちょうど提供元のディレクトリでも取れること。
        ("/Users/someone/Library/CloudStorage/OneDrive-Personal", "OneDrive"),
    ])
    func readsTheProviderNameFromTheCloudStoragePath(path: String, expected: String) {
        #expect(CloudSyncLocation.providerNameFromPath(URL(fileURLWithPath: path)) == expected)
    }

    /// **紛らわしい場所を提供元と誤認しないこと。**
    @Test(arguments: [
        "/Users/someone/Comics",
        // `Library` の直下でなければ違う。
        "/Users/someone/CloudStorage/OneDrive-Contoso",
        // `CloudStorage` そのものには提供元が無い。
        "/Users/someone/Library/CloudStorage",
        // 名前が似ているだけの別物。
        "/Users/someone/Library/CloudStorageBackup/OneDrive",
        "/Volumes/Private/Comics",
    ])
    func doesNotMistakeOtherPlacesForCloudStorage(path: String) {
        #expect(CloudSyncLocation.providerNameFromPath(URL(fileURLWithPath: path)) == nil)
    }

    // MARK: - 実際の判定

    /// **ふつうのローカルの場所を「クラウド」と言わないこと。**
    ///
    /// 誤検出は、根拠の無い警告をユーザーに見せることを意味する。
    @Test func aPlainLocalFolderIsNotReportedAsCloudSynced() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("qoo-cloud-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(await CloudSyncLocation.detect(at: root) == nil)
    }

    // **所要時間そのものはテストしない。**
    // 最初は「6 秒以内に返ること」を書いたが、テスト全体を並行で回すと
    // 6.4 秒かかって落ちた（単体では数ミリ秒）。CLAUDE.md に既に
    // 「経過時間で判定するテストは並行実行で落ちる」という教訓が
    // 記録されている（`PauseTokenTests` で一度踏んだ）ので、それに従う。
    //
    // 守りたいのは「無限に待たない」ことであり、それは
    // `CloudSyncLocation` が `FileIO.withDeadline` を通していることで
    // 担保されている。上の 2 つのテストが**返ってくること**自体は
    // 確かめている（返らなければテストが終わらない）。
}
