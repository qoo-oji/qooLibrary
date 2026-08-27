import Testing
import Foundation
import GRDB
import QooKit
@testable import QooInfrastructure
@testable import QooPersistence

//
//  保管庫と走査の関係 [SY-10][FA2-12][FA-05][FA-12]。
//
//  **この suite の主目的は 1 件目。** 走査が `.qooarchive` へ降りないと、
//  保管庫へ移しただけでそのファイルが「見なかったもの」になり、
//  `markUnseenAsOrphaned`（`state = 'active'` を無条件に拾う）が孤立にする
//  ——**片付けたつもりが「見つからないファイル」一覧に現れる。**
//  2-11 の着手前はまさにその状態で、`LibraryEnumerator` のコメントだけが
//  「`.qooarchive` は対象に含める [SY-10]」と、存在しない保護を主張していた。
//

@Suite("保管庫と走査 [SY-10][FA2-12]", .serialized)
struct FileVaultScanTests {

    /// 保管庫へ移した形を作る（実ファイルの移動そのものは `FileVaultTests` が試す）。
    private func archiveOnDisk(_ w: ScanWorkspace, _ relativePath: String) throws {
        try w.move(relativePath, to: VaultPath.archived(relativePath))
    }

    @Test("保管庫へ移したファイルは孤立にならない [SY-10][ID-06]")
    func archivedFilesAreNotOrphaned() async throws {
        let w = try await ScanWorkspace()
        try w.write("作者A/(同人誌) [サークルA (作家A)] 作品1 (オリジナル).cbz")
        _ = try await w.scanFull()

        try archiveOnDisk(w, "作者A/(同人誌) [サークルA (作家A)] 作品1 (オリジナル).cbz")
        let summary = try await w.scanFull()

        #expect(summary.orphaned == 0, "保管庫へ移しただけで孤立にしてはならない")
        #expect(summary.added == 0, "同じ inode なので新しい行を作らない [ID-02]")
        let rows = try await w.allRows()
        #expect(rows.count == 1)
        #expect(rows[0].state == .active)
        #expect(VaultPath.isInside(rows[0].path))
    }

    @Test("保管庫のファイルには印が付く [FA-05][SY-10]")
    func filesInsideTheVaultAreMarkedArchived() async throws {
        let w = try await ScanWorkspace()
        try w.write(".qooarchive/作者A/(同人誌) [サークルA (作家A)] 作品1 (オリジナル).cbz")
        let summary = try await w.scanFull()

        #expect(summary.added == 1)
        let archived = try await w.files.archivedFiles(libraryID: w.libraryID)
        #expect(archived.count == 1)
    }

    @Test("保管庫のファイルは蔵書の一覧に出ない [FA-05][FA-12]")
    func archivedFilesLeaveTheLibraryListing() async throws {
        let w = try await ScanWorkspace()
        try w.write("作者A/(同人誌) [サークルA (作家A)] 作品1 (オリジナル).cbz")
        try w.write("作者B/(同人誌) [サークルB] 作品2 (原作B).cbz")
        _ = try await w.scanFull()
        #expect(try await w.rows().count == 2)

        try archiveOnDisk(w, "作者A/(同人誌) [サークルA (作家A)] 作品1 (オリジナル).cbz")
        _ = try await w.scanFull()

        // `FileQuery` の既定は `includeArchived: false`。
        let visible = try await w.rows()
        #expect(visible.count == 1)
        #expect(visible[0].relativePath.hasPrefix("作者B/"))
    }

    @Test("保管庫から戻せば蔵書の一覧に返る [FA-07]")
    func restoredFilesComeBackToTheListing() async throws {
        let w = try await ScanWorkspace()
        let path = "作者A/(同人誌) [サークルA (作家A)] 作品1 (オリジナル).cbz"
        try w.write(path)
        _ = try await w.scanFull()
        try archiveOnDisk(w, path)
        _ = try await w.scanFull()
        #expect(try await w.rows().isEmpty)

        try w.move(VaultPath.archived(path), to: path)
        let summary = try await w.scanFull()

        #expect(summary.orphaned == 0)
        #expect(try await w.rows().count == 1)
        #expect(try await w.files.archivedFiles(libraryID: w.libraryID).isEmpty)
    }

    // MARK: - 保管庫「だけ」を通す [FA-02]

    @Test("ほかの隠しフォルダは今までどおり取り込まない")
    func otherHiddenFoldersStayExcluded() async throws {
        let w = try await ScanWorkspace()
        try w.write(".Trashes/(同人誌) [サークルA (作家A)] 捨てた.cbz")
        try w.write(".qooarchive/(同人誌) [サークルB] しまった.cbz")

        _ = try await w.scanFull()
        let rows = try await w.allRows()
        #expect(rows.count == 1)
        #expect(rows[0].path.hasPrefix(".qooarchive/"))
    }

    @Test("深い場所の同名フォルダは保管庫ではない [FA-02]")
    func onlyTheVaultAtTheLibraryRootIsScanned() async throws {
        let w = try await ScanWorkspace()
        try w.write("作者A/.qooarchive/(同人誌) [サークルA (作家A)] 作品1 (オリジナル).cbz")

        _ = try await w.scanFull()
        #expect(try await w.allRows().isEmpty, "利用者が自分で置いた隠しフォルダを取り込まない")
    }

    @Test("保管庫の中でも covers は取り込まない [FA-14]")
    func coversStayExcludedInsideTheVault() async throws {
        let w = try await ScanWorkspace(targetExtensions: ["cbz", "png"])
        try w.write(".qooarchive/作者A/(同人誌) [サークルA (作家A)] 作品1 (オリジナル).cbz")
        try w.write(".qooarchive/作者A/covers/(同人誌) [サークルA (作家A)] 作品1 (オリジナル).png")

        _ = try await w.scanFull()
        let rows = try await w.allRows()
        #expect(rows.count == 1, "サイドカー画像そのものは蔵書ではない")
        #expect(rows[0].path.hasSuffix(".cbz"))
    }

    // MARK: - 差分走査でも同じ規則 [FA2-12]

    @Test("差分走査も保管庫へ降りる")
    func incrementalScanReachesTheVault() async throws {
        let w = try await ScanWorkspace()
        try w.write("作者A/(同人誌) [サークルA (作家A)] 作品1 (オリジナル).cbz")
        _ = try await w.scanFull()

        try archiveOnDisk(w, "作者A/(同人誌) [サークルA (作家A)] 作品1 (オリジナル).cbz")
        let summary = try await w.engine.scan(
            .incremental(libraryID: w.libraryID,
                         paths: ["作者A", ".qooarchive/作者A"]),
            root: w.root)

        #expect(summary.orphaned == 0)
        let rows = try await w.allRows()
        #expect(rows.count == 1)
        #expect(VaultPath.isInside(rows[0].path))
    }
}
