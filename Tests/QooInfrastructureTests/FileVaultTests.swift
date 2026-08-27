//
//  保管庫への出し入れ（実ファイル）[FA-01〜FA-16]。
//
import Foundation
import Testing
import QooKit
@testable import QooInfrastructure

@Suite("保管庫への出し入れ [FA-01〜FA-16]")
struct FileVaultTests {
    let fileOps = FileOperationService()

    struct Workspace {
        let root: URL

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("qoo-vault-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }

        func write(_ relativePath: String, _ text: String = "x") throws {
            let url = root.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }

        func exists(_ relativePath: String) -> Bool {
            FileManager.default.fileExists(atPath: root.appendingPathComponent(relativePath).path)
        }

        func cleanup() { try? FileManager.default.removeItem(at: root) }
    }

    // MARK: - 運ぶ [FA-01][FA-02][FA-03][FA-09]

    @Test("保管庫へ運ぶと、階層をそのまま写した場所に着く [FA-02][FA-03]")
    func archivingMirrorsTheLibraryHierarchy() async throws {
        let w = try Workspace(); defer { w.cleanup() }
        try w.write("作者A/作品1.cbz")

        let result = try await FileVault.relocate(
            from: "作者A/作品1.cbz", to: VaultPath.archived("作者A/作品1.cbz"),
            root: w.root, fileOps: fileOps)

        #expect(result.to == ".qooarchive/作者A/作品1.cbz")
        #expect(w.exists(".qooarchive/作者A/作品1.cbz"))
        #expect(!w.exists("作者A/作品1.cbz"))
    }

    @Test("戻す先が消えていれば作って戻す [FA-09]")
    func restoringRecreatesTheMissingFolder() async throws {
        let w = try Workspace(); defer { w.cleanup() }
        try w.write(".qooarchive/作者A/作品1.cbz")

        let result = try await FileVault.relocate(
            from: ".qooarchive/作者A/作品1.cbz", to: "作者A/作品1.cbz",
            root: w.root, fileOps: fileOps)

        #expect(result.to == "作者A/作品1.cbz")
        #expect(w.exists("作者A/作品1.cbz"))
    }

    @Test("同名があれば連番を付けて両方残す [FA-13]")
    func collidingNamesAreNumbered() async throws {
        let w = try Workspace(); defer { w.cleanup() }
        try w.write("作者A/作品1.cbz", "新しい")
        try w.write(".qooarchive/作者A/作品1.cbz", "先にあった")

        let result = try await FileVault.relocate(
            from: "作者A/作品1.cbz", to: VaultPath.archived("作者A/作品1.cbz"),
            root: w.root, fileOps: fileOps)

        #expect(result.to != ".qooarchive/作者A/作品1.cbz")
        #expect(w.exists(".qooarchive/作者A/作品1.cbz"))
        #expect(w.exists(result.to))
        // 先にあったほうを壊していない。
        let kept = try String(contentsOf: w.root.appendingPathComponent(
            ".qooarchive/作者A/作品1.cbz"), encoding: .utf8)
        #expect(kept == "先にあった")
    }

    // MARK: - サイドカー [FA-14][FA-15][FA-17]

    @Test("サイドカーのカバー画像も連れて行く [FA-14]")
    func sidecarCoversTravelWithTheFile() async throws {
        let w = try Workspace(); defer { w.cleanup() }
        try w.write("作者A/作品1.cbz")
        try w.write("作者A/covers/作品1.png")

        _ = try await FileVault.relocate(
            from: "作者A/作品1.cbz", to: VaultPath.archived("作者A/作品1.cbz"),
            root: w.root, fileOps: fileOps)

        #expect(w.exists(".qooarchive/作者A/covers/作品1.png"))
        #expect(!w.exists("作者A/covers/作品1.png"))
    }

    @Test("運んだ先でも名前で突き合わせられる [FA-17]")
    func theSidecarKeepsMatchingAfterANumberedLanding() async throws {
        let w = try Workspace(); defer { w.cleanup() }
        try w.write("作者A/作品1.cbz")
        try w.write("作者A/covers/作品1.png")
        // 先客がいて、本体に連番が付く状況を作る [FA-13]。
        try w.write(".qooarchive/作者A/作品1.cbz", "先客")

        let result = try await FileVault.relocate(
            from: "作者A/作品1.cbz", to: VaultPath.archived("作者A/作品1.cbz"),
            root: w.root, fileOps: fileOps)

        // **着地した本体の名前に合わせて運ぶ。** 独立に採番されると
        // `SidecarCoverLocator` の名前の突き合わせから外れ、
        // 「保管庫へ入れた本だけ絵が消える」形になる。
        let landed = w.root.appendingPathComponent(result.to)
        #expect(SidecarCoverLocator.locate(for: landed) != nil)
    }

    @Test("サイドカーが無ければ何もしない")
    func filesWithoutSidecarsAreFine() async throws {
        let w = try Workspace(); defer { w.cleanup() }
        try w.write("作者A/作品1.cbz")

        _ = try await FileVault.relocate(
            from: "作者A/作品1.cbz", to: VaultPath.archived("作者A/作品1.cbz"),
            root: w.root, fileOps: fileOps)

        #expect(!w.exists(".qooarchive/作者A/covers"))
    }

    // MARK: - 空フォルダの後始末 [FA-06][FA-08][FA-10][FA-16]

    @Test("空になったフォルダを片付ける [FA-06]")
    func emptiedFoldersAreRemoved() async throws {
        let w = try Workspace(); defer { w.cleanup() }
        try w.write("作者A/作品1.cbz")
        _ = try await FileVault.relocate(
            from: "作者A/作品1.cbz", to: VaultPath.archived("作者A/作品1.cbz"),
            root: w.root, fileOps: fileOps)

        await FileVault.pruneEmptyFolders(
            [w.root.appendingPathComponent("作者A"),
             w.root.appendingPathComponent("作者A/covers")],
            root: w.root, fileOps: fileOps)

        #expect(!w.exists("作者A"))
    }

    @Test("隠しファイルしか残っていなければ空とみなす [FA-10]")
    func foldersWithOnlyHiddenFilesCountAsEmpty() async throws {
        let w = try Workspace(); defer { w.cleanup() }
        try w.write("作者A/.DS_Store")

        await FileVault.pruneEmptyFolders(
            [w.root.appendingPathComponent("作者A")], root: w.root, fileOps: fileOps)

        #expect(!w.exists("作者A"))
    }

    /// **隠しフォルダは「空」に数えない**［レビューで発見］。`.git` や
    /// このアプリ自身の `.qoo-replace-backup-<uuid>` [NV-92] を抱えたフォルダを
    /// 空と判定すると、`deletePermanently` が**ゴミ箱を経由せずに木ごと消す**。
    @Test("隠しフォルダが残っていれば片付けない [FA-10]")
    func foldersHoldingHiddenSubfoldersAreKept() async throws {
        let w = try Workspace(); defer { w.cleanup() }
        try w.write("作者A/.qoo-replace-backup-1/中身.cbz")

        await FileVault.pruneEmptyFolders(
            [w.root.appendingPathComponent("作者A")], root: w.root, fileOps: fileOps)

        #expect(w.exists("作者A/.qoo-replace-backup-1/中身.cbz"))
    }

    @Test("ほかにファイルが残っていれば片付けない")
    func foldersThatStillHoldFilesAreKept() async throws {
        let w = try Workspace(); defer { w.cleanup() }
        try w.write("作者A/作品2.cbz")

        await FileVault.pruneEmptyFolders(
            [w.root.appendingPathComponent("作者A")], root: w.root, fileOps: fileOps)

        #expect(w.exists("作者A/作品2.cbz"))
    }

    @Test("空になった covers を片付けてから親も片付ける [FA-16]")
    func emptiedCoversFoldersAreRemovedBeforeTheirParent() async throws {
        let w = try Workspace(); defer { w.cleanup() }
        try w.write("作者A/作品1.cbz")
        try w.write("作者A/covers/作品1.png")
        _ = try await FileVault.relocate(
            from: "作者A/作品1.cbz", to: VaultPath.archived("作者A/作品1.cbz"),
            root: w.root, fileOps: fileOps)

        await FileVault.pruneEmptyFolders(
            [w.root.appendingPathComponent("作者A"),
             w.root.appendingPathComponent("作者A/covers")],
            root: w.root, fileOps: fileOps)

        // **深いほうから畳まないと親は空にならない。**
        #expect(!w.exists("作者A"))
    }

    @Test("ライブラリ根そのものは決して消さない")
    func theLibraryRootIsNeverRemoved() async throws {
        let w = try Workspace(); defer { w.cleanup() }

        await FileVault.pruneEmptyFolders([w.root], root: w.root, fileOps: fileOps)

        #expect(FileManager.default.fileExists(atPath: w.root.path))
    }

    @Test("根の外は片付けない")
    func nothingOutsideTheLibraryIsRemoved() async throws {
        let w = try Workspace(); defer { w.cleanup() }
        let outside = w.root.deletingLastPathComponent()
            .appendingPathComponent("qoo-vault-outside-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }

        await FileVault.pruneEmptyFolders([outside], root: w.root, fileOps: fileOps)

        #expect(FileManager.default.fileExists(atPath: outside.path))
    }
}
