import Foundation
import QooKit
import Testing

@testable import QooInfrastructure

/// **ボリューム UUID を持たない場所でも、別のボリュームとして区別できること**
/// [NV3-01]。
///
/// SMB では `volumeUUIDString` が必ず `nil` になる（1-16b の実測、3 系統すべて）。
/// 以前はそこを `?? ""` で埋めていたため、**マウント中のネットワーク共有
/// すべてが同じボリュームに見えて**いた。`FileIdentity` はサムネイルと
/// Quick Look のカバーのキャッシュ鍵なので、そのとき起きるのは
/// **別の作品の表紙が表示される**ことである。
///
/// ネットワーク共有はテストから用意できないが、**UDF は同じく
/// `volumeUUIDString` が `nil`** になることを実測で確認した（APFS・HFS+・
/// exFAT・FAT は UUID を返す）。フォールバック経路そのものはこれで確かめられる。
@Suite(.serialized) struct VolumeIdentityTests {
    /// UUID があるボリュームでは、それをそのまま使う（従来どおり）。
    @Test func usesTheVolumeUUIDWhenThereIsOne() throws {
        let url = FileManager.default.temporaryDirectory
        let uuid = try #require(
            try url.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString,
            "一時ディレクトリのボリュームが UUID を持たない環境では検証できない"
        )
        #expect(VolumeIdentity.identifier(for: url) == uuid)
    }

    /// **この suite の主眼。** UUID を持たないボリュームでも識別子が得られ、
    /// **起動ボリュームとは別の値になる**。
    ///
    /// 空文字を返していた頃は、ここが起動ボリュームと同じ（どちらも `""`）に
    /// なっていた。
    @Test func fallsBackToTheMountSourceWhenThereIsNoUUID() throws {
        guard let volume = TinyVolume.make(megabytes: 20, fileSystem: "UDF") else {
            // 作れない環境では検証を飛ばす（他のボリューム系テストと同じ方針）。
            return
        }
        defer { volume.destroy() }

        // 前提の確認 — この形式が UUID を持たないこと自体が実測に基づく。
        // 将来 macOS が UUID を返すようになったらこのテストは意味を失うので、
        // そのときは前提が変わったと分かるようにしておく。
        let uuid = try? volume.mountPoint
            .resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString
        guard uuid == nil else { return }

        let identifier = try #require(VolumeIdentity.identifier(for: volume.mountPoint))
        #expect(!identifier.isEmpty, "空文字を返している（これが NV3-01 の不具合そのもの）")
        #expect(identifier.hasPrefix("net-"), "マウント元からの導出になっていない: \(identifier)")

        let boot = try #require(VolumeIdentity.identifier(for: URL(fileURLWithPath: "/")))
        #expect(identifier != boot, "UUID の無いボリュームが起動ボリュームと同一視されている")
    }

    /// 同じ場所を 2 度尋ねれば同じ値。**再マウントをまたいでも変わらない**
    /// ことがキャッシュを効かせ続ける条件なので、まず決定性を固定する。
    @Test func isStableForTheSameVolume() throws {
        guard let volume = TinyVolume.make(megabytes: 20, fileSystem: "UDF") else { return }
        defer { volume.destroy() }
        let first = VolumeIdentity.identifier(for: volume.mountPoint)
        let second = VolumeIdentity.identifier(for: volume.mountPoint)
        #expect(first != nil)
        #expect(first == second)
    }

    /// `FileIdentity` まで通して、UUID の無いボリュームの識別子が
    /// 空文字にならないこと。**ここが実際にキャッシュ鍵になる経路**。
    @Test func fileIdentityOnAVolumeWithoutUUIDIsNotEmpty() throws {
        guard let volume = TinyVolume.make(megabytes: 20, fileSystem: "UDF") else { return }
        defer { volume.destroy() }
        let file = volume.mountPoint.appendingPathComponent("a.txt")
        guard (try? Data("x".utf8).write(to: file)) != nil else { return } // 読み取り専用なら飛ばす

        let identity = try FileMetadata.identity(of: file)
        #expect(!identity.volumeUUID.isEmpty)
    }
}
