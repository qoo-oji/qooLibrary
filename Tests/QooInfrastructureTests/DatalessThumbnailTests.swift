import CoreGraphics
import Foundation
import QooKit
import Testing

@testable import QooInfrastructure

/// **クラウドにしか実体が無いファイルのために、勝手にダウンロードしない。**
///
/// ## なぜこの形に落ち着いたか（実測）
/// 当初は「協調読み取り（`NSFileCoordinator`）をしていないので、iCloud に
/// 追い出されたファイルは読めない・固まる」と疑っていた。実際に iCloud Drive
/// 上のファイルを `evictUbiquitousItem` で追い出して測ったところ:
///
/// | 読み方 | 結果 |
/// |---|---|
/// | 素の `Data(contentsOf:)`（協調なし・アプリの現状） | 成功。約 1 秒 |
/// | `FileHandle` で先頭だけ | 成功。約 1 秒 |
/// | `NSFileCoordinator` 経由 | 成功。**協調なしと差が無い** |
///
/// **読めなくなるわけでも固まるわけでもなかった**ので、`NSFileCoordinator`
/// の導入は見送った。本当の問題は「1 件あたり約 1 秒かけて実際に
/// ダウンロードが走る」こと。サムネイルは一覧を開いただけで何百件も自動生成
/// されるため、クラウドに預けたライブラリを開くと蔵書全体のダウンロードが
/// 始まってしまう。Finder も追い出されたファイルのサムネイルは作らない。
///
/// dataless なファイルは iCloud 上でしか作れないため、判定だけを差し替えて
/// 検証する（ユーザーのクラウドへ毎回書き込むわけにはいかない）。
@Suite struct DatalessThumbnailTests {
    private func sandbox() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("qoo-dataless-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func doesNotGenerateAThumbnailForACloudOnlyFile() async throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let image = root.appendingPathComponent("cover.png")
        try TestImageFixture.makePNGData(width: 40, height: 60).write(to: image)

        let service = ThumbnailService(
            cache: DefaultCoverImageCache(baseDirectory: root.appendingPathComponent("cache")),
            isGloballyHidden: { false },
            isDataless: { _ in true }
        )
        let result = await service.thumbnail(for: image, maxPixelSize: 128)
        #expect(result == nil, "クラウド上のファイルをダウンロードしてサムネイルを作ってしまった")
    }

    /// 逆方向の固定 — ローカルにあるファイルはこれまでどおり作ること。
    /// ここが壊れると、サムネイルが一切出なくなる。
    @Test func stillGeneratesAThumbnailForALocalFile() async throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let image = root.appendingPathComponent("cover.png")
        try TestImageFixture.makePNGData(width: 40, height: 60).write(to: image)

        let service = ThumbnailService(
            cache: DefaultCoverImageCache(baseDirectory: root.appendingPathComponent("cache")),
            isGloballyHidden: { false },
            isDataless: { _ in false }
        )
        let result = await service.thumbnail(for: image, maxPixelSize: 128)
        #expect(result != nil)
    }

    /// フォルダのカバー（子を最大 3 枚重ねる表示）でも、クラウド上の子は
    /// 数に入れないこと。ここを塞がないと、フォルダを 1 つ表示しただけで
    /// 子のダウンロードが始まる。
    @Test func folderCoversSkipCloudOnlyChildren() async throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("book", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for index in 1...3 {
            try TestImageFixture.makePNGData(width: 40, height: 60)
                .write(to: folder.appendingPathComponent("page\(index).png"))
        }

        let service = ThumbnailService(
            cache: DefaultCoverImageCache(baseDirectory: root.appendingPathComponent("cache")),
            isGloballyHidden: { false },
            isDataless: { _ in true }
        )
        let covers = await service.folderCoverThumbnails(for: folder, maxPixelSize: 128)
        #expect(covers.isEmpty)
    }

    /// 判定そのもの。ふつうのローカルファイルを dataless と誤判定しないこと
    /// （誤判定するとサムネイルが全く出なくなる）。
    @Test func localFilesAreNeverConsideredDataless() throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("local.bin")
        try Data("x".utf8).write(to: file)
        #expect(!CloudMaterialization.isDataless(file))
        // 存在しないパスでも落ちず、`false`（ふつうのファイル扱い）になること。
        #expect(!CloudMaterialization.isDataless(root.appendingPathComponent("missing")))
    }
}
