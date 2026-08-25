import Foundation
import QooKit
import Testing
@testable import QooApplication

//
//  カバー画像の解決順序 [IV-02][IV-03]。
//
//  読み手は右ペイン（`CoverEditorModel`）とライブラリ表示モードの一覧のセルの
//  2 つで、**どちらも同じこの関数を通る**。実体を触る判定なので、素の値では
//  なく実際に一時ディレクトリへ置いて確かめる。
//

@Suite("カバー画像の解決順序 [IV-02][IV-03]")
struct CoverResolutionTests {

    private struct Workspace: ~Copyable {
        let root: URL
        init() throws {
            root = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("qoo-cover-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
        func write(_ relative: String) throws -> URL {
            let url = root.appendingPathComponent(relative)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: url.path, contents: Data([0x89, 0x50]))
            return url
        }
        deinit { try? FileManager.default.removeItem(at: root) }
    }

    @Test("①ユーザー指定が最優先 [IV-03]")
    func userSpecifiedWins() throws {
        let w = try Workspace()
        let book = try w.write("作品.cbz")
        _ = try w.write("covers/作品.png")                    // ②も置いてある
        let user = try w.write("usercovers/abc.png")

        let r = CoverResolution.resolve(
            url: book, assignment: .userSpecified(ref: "abc"), userCoverURL: user)
        #expect(r.source == .userSpecified)
        #expect(r.imageURL == user)
    }

    /// **複製が消えていたら黙って②③へ落ちる。** 参照はあるが実体が無い状態で
    /// ①を返すと、`ThumbnailService` が生成に失敗して汎用アイコンになり、
    /// サイドカーがあるのに使われない。
    @Test("複製が失われていたら②へ落ちる [CV-08 の裏返し]")
    func missingUserCoverFallsBackToSidecar() throws {
        let w = try Workspace()
        let book = try w.write("作品.cbz")
        let sidecar = try w.write("covers/作品.png")
        let missing = w.root.appendingPathComponent("usercovers/消えた.png")

        let r = CoverResolution.resolve(
            url: book, assignment: .userSpecified(ref: "消えた"), userCoverURL: missing)
        #expect(r.source == .sidecar)
        // **URL 全体で比べない**——一時ディレクトリは `/var` と `/private/var` の
        // どちらでも表され、実装が返すのは列挙が返した綴りのほうになる
        // （CLAUDE.md に記録済みの罠。実装ではなくテストの比較が誤る）。
        #expect(r.imageURL?.lastPathComponent == sidecar.lastPathComponent)
        #expect(r.imageURL?.deletingLastPathComponent().lastPathComponent == "covers")
    }

    @Test("②サイドカーは自動のときに効く [IV-02②]")
    func sidecarIsUsedWhenAutomatic() throws {
        let w = try Workspace()
        let book = try w.write("作品.cbz")
        let sidecar = try w.write("covers/作品.jpg")

        let r = CoverResolution.resolve(url: book, assignment: .automatic, userCoverURL: nil)
        #expect(r.source == .sidecar)
        #expect(r.imageURL?.lastPathComponent == sidecar.lastPathComponent)
    }

    @Test("③どちらも無ければ自動抽出 [IV-02③]")
    func fallsBackToAutomatic() throws {
        let w = try Workspace()
        let book = try w.write("作品.cbz")

        let r = CoverResolution.resolve(url: book, assignment: .automatic, userCoverURL: nil)
        #expect(r.source == .auto)
        #expect(r.imageURL == nil)
        // 呼び出し側が分岐せずに済むよう、対象そのものを返す。
        #expect(r.previewURL(for: book) == book)
    }

    /// `.userSpecified` でない割り当てに参照が残っていても①にしない。
    /// 「自動へ戻したのに古い複製が出続ける」を防ぐ [CV-07]。
    @Test("自動へ戻した行は複製があっても①にしない [CV-07]")
    func automaticIgnoresALeftoverDuplicate() throws {
        let w = try Workspace()
        let book = try w.write("作品.cbz")
        let user = try w.write("usercovers/古い.png")

        let r = CoverResolution.resolve(
            url: book, assignment: CoverAssignment(source: .auto, ref: "古い"),
            userCoverURL: user)
        #expect(r.source == .auto)
        #expect(r.imageURL == nil)
    }
}
