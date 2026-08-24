import Foundation
import Testing
@testable import QooInfrastructure
@testable import QooKit

//
//  サイドカーのカバー画像 [IV-02②][IV-03][CL-04]。
//

@Suite("サイドカーのカバー [IV-02②]")
struct SidecarCoverLocatorTests {

    private final class Workspace {
        let root: URL
        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("qoo-sidecar-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
        deinit { try? FileManager.default.removeItem(at: root) }

        @discardableResult
        func write(_ relativePath: String, image: Bool = false) throws -> URL {
            let url = root.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = image
                ? TestImageFixture.makePNGData(width: 4, height: 4)
                : Data(repeating: 0x41, count: 4)
            try data.write(to: url)
            return url
        }
    }

    /// - Note: **URL 全体で比べない。** 一時ディレクトリの列挙結果は
    ///   `/private/var/…`、こちらが組み立てた URL は `/var/…` になる
    ///   （macOS の既知のシンボリックリンク差。CLAUDE.md に既記録）。
    @Test("covers フォルダの同名画像を見つける [IV-02②]")
    func findsSidecar() throws {
        let w = try Workspace()
        let book = try w.write("作品名A 第01巻.cbz")
        try w.write("covers/作品名A 第01巻.jpg", image: true)
        #expect(SidecarCoverLocator.locate(for: book)?.lastPathComponent == "作品名A 第01巻.jpg")
    }

    @Test("covers フォルダが無ければ nil")
    func noCoversDirectory() throws {
        let w = try Workspace()
        #expect(SidecarCoverLocator.locate(for: try w.write("作品名A 第01巻.cbz")) == nil)
    }

    @Test("名前が違えば拾わない")
    func differentStemIsIgnored() throws {
        let w = try Workspace()
        let book = try w.write("作品名A 第01巻.cbz")
        try w.write("covers/作品名A 第02巻.jpg", image: true)
        #expect(SidecarCoverLocator.locate(for: book) == nil)
    }

    /// **画像だけを対象にする。** `covers/` にテキストを置いている人が居ても、
    /// それをカバーとして返すと復号に失敗して既定へ落ちるだけになる。
    @Test("画像でないファイルは拾わない")
    func nonImageIsIgnored() throws {
        let w = try Workspace()
        let book = try w.write("作品名A 第01巻.cbz")
        try w.write("covers/作品名A 第01巻.txt")
        #expect(SidecarCoverLocator.locate(for: book) == nil)
    }

    /// 大小文字はファイルシステムの都合で揺れる。**見つからないより
    /// 見つけすぎるほうが害が小さい**（「既定に戻す」で外せる）。
    @Test("大小文字が違っても拾う")
    func caseInsensitiveFallback() throws {
        let w = try Workspace()
        let book = try w.write("Comic Vol01.cbz")
        try w.write("covers/COMIC VOL01.png", image: true)
        #expect(SidecarCoverLocator.locate(for: book)?.lastPathComponent == "COMIC VOL01.png")
    }

    /// **完全一致を優先する。** 大小文字だけ違うものが同時にあるとき、
    /// 実行のたびに違うほうが選ばれると「たまに絵が変わる」ことになる。
    ///
    /// - Note: **大小文字違いのほうが自然順で先に来る標本にすること。**
    ///   逆にすると、完全一致の分岐を外しても大小文字無視の探索が同じものを
    ///   返してしまい、この検査は何も守らない（変異検証で空振りして判明）。
    @Test("完全一致を優先する")
    func prefersExactMatch() throws {
        let w = try Workspace()
        let book = try w.write("Comic Vol01.cbz")
        try w.write("covers/COMIC VOL01.jpg", image: true)   // 自然順では先
        try w.write("covers/Comic Vol01.png", image: true)   // 完全一致
        #expect(SidecarCoverLocator.locate(for: book)?.lastPathComponent == "Comic Vol01.png")
    }
}
