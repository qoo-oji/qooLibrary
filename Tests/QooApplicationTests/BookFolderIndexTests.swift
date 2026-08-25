import Foundation
import QooKit
import Testing
@testable import QooApplication

//
//  フォルダ表示モードでのブックフォルダ [IF-17][IF-18]。
//
//  `ServicesWorkspace`（`LibraryServicesTests.swift`）を共有し、実際に DB を
//  開いて確かめる——印の出どころが走査の結果（`isBookFolder`）なので、
//  リポジトリを偽物に差し替えると肝心の部分が試せない。
//

@Suite("ブックフォルダの印と開き方 [IF-17][IF-18]", .serialized)
struct BookFolderIndexTests {

    /// **フォルダにしか印を出さない。** 同名のファイルとフォルダは同じ場所に
    /// 共存できるので、名前だけで照合するとファイルの側にも印が付く。
    @Test("印はフォルダにだけ出す [IF-17]")
    func onlyDirectoriesAreIndicated() {
        let names: Set<String> = ["作品A"]
        #expect(BookFolderIndex.indicatesBookFolder(name: "作品A", isDirectory: true, in: names))
        #expect(!BookFolderIndex.indicatesBookFolder(name: "作品A", isDirectory: false, in: names))
        #expect(!BookFolderIndex.indicatesBookFolder(name: "作品B", isDirectory: true, in: names))
    }

    @MainActor
    private func workspace() async throws -> (ServicesWorkspace, LibrarySummary) {
        let w = try ServicesWorkspace()
        await w.bootstrap()
        // 一般コミック(A) の形。ブックフォルダは配下に画像だけを持つフォルダ [IF-01]。
        try w.write("(一般コミック) [著者値A] 作品名A 第01巻.cbz")
        try w.write("(一般コミック) [著者値A] 作品名A 第02巻/001.jpg")
        try w.write("(一般コミック) [著者値A] 作品名A 第02巻/002.jpg")
        let id = try await w.enable("builtin.general-comic-a")
        _ = try await w.services.scan(libraryID: id, root: w.libraryRoot)
        let library = try #require(w.services.library(registrationUUID: w.registrationUUID))
        return (w, library)
    }

    @MainActor
    @Test("走査が 1 冊と見なしたフォルダの名前が返る [IF-17][IF-01]")
    func loadsBookFolderNames() async throws {
        let (w, library) = try await workspace()
        let index = BookFolderIndex()
        await index.load(library: library, relativePath: "", services: w.services)

        #expect(index.names == ["(一般コミック) [著者値A] 作品名A 第02巻"])
        // 既定は偽＝フォルダを開く [IF-18]。
        #expect(!index.opensWithApp)
    }

    /// **ボリューム経由では引かない** [LF-01 と同じ判断]。同じ実フォルダでも、
    /// ライブラリの入口から入ったときだけライブラリ由来の情報を見せる。
    @MainActor
    @Test("ライブラリが無ければ空にする [LF-01]")
    func clearsWithoutALibrary() async throws {
        let (w, library) = try await workspace()
        let index = BookFolderIndex()
        await index.load(library: library, relativePath: "", services: w.services)
        #expect(!index.names.isEmpty)

        await index.load(library: nil, relativePath: "", services: w.services)
        #expect(index.names.isEmpty)
        #expect(!index.opensWithApp)
    }

    @MainActor
    @Test("設定を変えると開き方が変わる [IF-18]")
    func reflectsTheLibrarySetting() async throws {
        let (w, library) = try await workspace()
        var draft = try #require(try await w.services.settingsDraft(libraryID: library.id))
        draft.opensBookFolderWithApp = true
        try await w.services.updateSettings(draft, libraryID: library.id)

        let index = BookFolderIndex()
        await index.load(library: library, relativePath: "", services: w.services)
        #expect(index.opensWithApp, "ライブラリ単位の設定がその場で効く")
    }

    @MainActor
    @Test("clear で空に戻る")
    func clearEmptiesEverything() async throws {
        let (w, library) = try await workspace()
        let index = BookFolderIndex()
        await index.load(library: library, relativePath: "", services: w.services)
        index.clear()
        #expect(index.names.isEmpty)
        #expect(!index.opensWithApp)
    }
}
