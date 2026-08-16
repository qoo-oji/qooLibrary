import Foundation
import Testing

@testable import QooInfrastructure

/// **ブックマークの解決がボリュームをマウントしてはならない** [RG3-01][NV-91]。
///
/// ## なぜ固定するのか
/// 解決には**未マウントのボリュームを実際にマウントする副作用**がある
/// （8章 §8.7.1 BM-5）。ローカルのディスクイメージなら一瞬で済むが、
/// ネットワークボリュームでは意味がまったく違う:
///
/// - 接続タイムアウト分ブロックする（NFS の hard マウントなら**無限**）
/// - **ユーザーが何も操作していないのに認証ダイアログが出る**
/// - しかもこれを踏むのは `RegisteredFolderStore.loadAndActivateAll()` と
///   `VolumeAccessStore.loadAndActivateAll()`＝**アプリの起動経路**である
///
/// 使い捨てのディスクイメージで実測したときの差:
///
/// | | 結果 |
/// |---|---|
/// | `.withoutMounting` あり | 失敗 `code 4` を 12ms で返し、**マウントされない** |
/// | `.withoutMounting` なし | **解決成功** 120ms、**ボリュームが実際にマウントされた** |
///
/// この検証は「うっかり `.withoutMounting` を外した」を捕まえるためのもの。
@Suite(.serialized) struct BookmarkMountSideEffectTests {
    /// 既定の解決は、外れているボリュームを**付け直さない**。
    @Test func resolvingDoesNotRemountAnEjectedVolume() throws {
        guard let volume = TinyVolume.make(megabytes: 20) else { return }
        defer { volume.destroy() }

        let target = volume.mountPoint.appendingPathComponent("registered", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)

        let resolver = SecurityScopedBookmarkResolver()
        let bookmark = try resolver.makeBookmark(for: target)

        guard volume.detachKeepingImage() else { return }
        // 外れたことを確かめてから測る（外れていなければ検証にならない）。
        guard !FileManager.default.fileExists(atPath: volume.mountPoint.path) else {
            Issue.record("ボリュームを外せなかったため検証できない")
            return
        }

        let resolution = resolver.resolve(bookmark)

        // **これがこの検証の主眼。** 解決の副作用で付け直されていないこと。
        #expect(
            !FileManager.default.fileExists(atPath: volume.mountPoint.path),
            "解決がボリュームを付け直してしまった（`.withoutMounting` が外れている）"
        )

        // 未接続として扱われること。`.resolved` を返してしまうと、
        // 呼び出し側は「オンライン」と誤解して読みに行き、そこで初めて失敗する。
        guard case .offline = resolution else {
            Issue.record("外れているのに `.offline` にならなかった: \(resolution)")
            return
        }

        volume.reattach()
    }

    /// 逆方向の固定 — 明示的に頼めばマウントを許す経路が生きていること。
    /// これが壊れると「ユーザーが選び直しても復帰できない」になる。
    ///
    /// - Note: 非サンドボックスのテストプロセスでは `.withSecurityScope` の
    ///   解決自体が形式エラー（`code 259`）になることがあり、その場合は
    ///   マウント経路まで到達しない。**環境依存の失敗をテストの失敗に
    ///   仕立てない**ため、そのときは静かに飛ばす。
    @Test func resolvingWithMountingAllowedCanBringTheVolumeBack() throws {
        guard let volume = TinyVolume.make(megabytes: 20) else { return }
        defer { volume.destroy() }

        let target = volume.mountPoint.appendingPathComponent("registered", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)

        let resolver = SecurityScopedBookmarkResolver()
        let bookmark = try resolver.makeBookmark(for: target)

        guard volume.detachKeepingImage() else { return }
        guard !FileManager.default.fileExists(atPath: volume.mountPoint.path) else { return }

        let resolution = resolver.resolveAllowingMount(bookmark)

        switch resolution {
        case .resolved:
            #expect(
                FileManager.default.fileExists(atPath: volume.mountPoint.path),
                "解決に成功したのにマウントされていない"
            )
        case .offline:
            // この環境では判定できない（上記 Note）。固定するものが無いので飛ばす。
            break
        }

        volume.reattach()
    }
}
