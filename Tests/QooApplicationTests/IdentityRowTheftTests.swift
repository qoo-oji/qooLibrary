import Foundation
import QooKit
import Testing
@testable import QooApplication

//
//  **生きている行を横取りしないこと** [ID3-08][ID-05][ID-13]。
//
//  同じファイル名は複数のフォルダにふつうに存在する（`第01巻.cbz` 等）。
//  既定の設定 [ID-13] は「名前が同じなら確認しない」なので、そこに
//  「実体を失った行だけを引き継ぐ」という歯止めが無いと、片方を触っただけで
//  **もう片方の行が評価・手動ラベル・手動タイトルごと消える**。
//
//  A は走査の途中（`reconcile`）、B は走査の末尾の後始末（⑤）の経路。
//  **同じ思い違いが 2 か所にあった**ので、両方を固定する。
//
@Suite("生きている行を横取りしない [ID3-08]", .serialized)
struct IdentityRowTheftTests {
    private static let name = "(同人誌) [サークル値1 (著者値1)] 作品タイトル1 (ジャンル値1).cbz"

    private func put(_ w: ServicesWorkspace, _ rel: String, bytes: Int) throws {
        let url = w.libraryRoot.appendingPathComponent(rel)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: url)
        try Data(repeating: 0x41, count: bytes).write(to: url)
    }

    private func rating(_ w: ServicesWorkspace, _ id: LibraryID, _ rel: String) async throws -> Int? {
        let lib = try #require(try await w.services.libraries.first { $0.id == id })
        return try await w.services.fileRow(
            at: w.libraryRoot.appendingPathComponent(rel), in: lib)?.rating
    }

    /// ② 走査の途中（`reconcile`）で横取りされる。
    @Test("A: 別フォルダの同名ファイルを作り直しても、生きている行を横取りしない")
    @MainActor
    func recreating() async throws {
        let w = try ServicesWorkspace()
        await w.bootstrap()
        try put(w, "旧/\(Self.name)", bytes: 16)
        try put(w, "新/\(Self.name)", bytes: 32)
        let id = try await w.enable("builtin.doujinshi-a")
        _ = try await w.services.scan(libraryID: id, root: w.libraryRoot)

        let before = try await w.services.filesUnder(libraryID: id, folderRelativePath: "")
        let oldID = try #require(before.first { $0.value.hasPrefix("旧/") }).key
        try await w.services.setRating(4, ids: [oldID])

        // 新側だけを作り直す。**大きさは旧側と同じ**——これで旧の行が
        // `.nameAndSize`、新の行が `.pathOnly` になり、確度の順で旧が先に来る。
        try put(w, "新/\(Self.name)", bytes: 16)
        _ = try await w.services.scan(libraryID: id, root: w.libraryRoot)

        #expect(try await rating(w, id, "旧/\(Self.name)") == 4, "A: 旧側の★4が残るはず")
        #expect(try await rating(w, id, "新/\(Self.name)") == 0, "A: 新側は無印のはず")
    }

    /// 同じ走査で **inode で引けている行**を、パスの一致で横取りしないこと。
    /// 移動と新規作成が同時に起きるとこの形になる。
    @Test("C: 移動した先で inode 一致している行を、元の場所の新しいファイルに渡さない")
    @MainActor
    func movedRowKeepsItsIdentity() async throws {
        let w = try ServicesWorkspace()
        await w.bootstrap()
        try put(w, "旧/\(Self.name)", bytes: 16)
        let id = try await w.enable("builtin.doujinshi-a")
        _ = try await w.services.scan(libraryID: id, root: w.libraryRoot)

        let before = try await w.services.filesUnder(libraryID: id, folderRelativePath: "")
        try await w.services.setRating(4, ids: [try #require(before.first).key])

        // 旧 → 新 へ移動（inode はそのまま）し、旧に別の新しいファイルを作る。
        let from = w.libraryRoot.appendingPathComponent("旧/\(Self.name)")
        let to = w.libraryRoot.appendingPathComponent("新/\(Self.name)")
        try FileManager.default.createDirectory(at: to.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: from, to: to)
        try put(w, "旧/\(Self.name)", bytes: 32)

        _ = try await w.services.scan(libraryID: id, root: w.libraryRoot)
        // ★4 は**移動したファイル**に付いたままであるはず。
        #expect(try await rating(w, id, "新/\(Self.name)") == 4, "C: 移動先が★4を保つはず")
        #expect(try await rating(w, id, "旧/\(Self.name)") == 0, "C: 新しいファイルは無印のはず")
    }

    /// ⑤ 走査の末尾の後始末で横取りされる。
    @Test("B: 同名ファイルが消えても、別フォルダの生きている行を横取りしない")
    @MainActor
    func deleting() async throws {
        let w = try ServicesWorkspace()
        await w.bootstrap()
        try put(w, "旧/\(Self.name)", bytes: 16)
        try put(w, "新/\(Self.name)", bytes: 16)
        let id = try await w.enable("builtin.doujinshi-a")
        _ = try await w.services.scan(libraryID: id, root: w.libraryRoot)

        let before = try await w.services.filesUnder(libraryID: id, folderRelativePath: "")
        let oldID = try #require(before.first { $0.value.hasPrefix("旧/") }).key
        try await w.services.setRating(4, ids: [oldID])

        // 新側を**消すだけ**。旧側には一切触れていない。
        try FileManager.default.removeItem(
            at: w.libraryRoot.appendingPathComponent("新/\(Self.name)"))
        _ = try await w.services.scan(libraryID: id, root: w.libraryRoot)

        #expect(try await rating(w, id, "旧/\(Self.name)") == 4, "B: 旧側の★4が残るはず")
    }
}
