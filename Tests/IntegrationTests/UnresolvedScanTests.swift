import Testing
import Foundation
import GRDB
import QooKit
@testable import QooInfrastructure
@testable import QooPersistence

//
//  未解決ファイルの記録と再マッチング [AL-30〜AL-34][UR-01〜UR-06]。
//
//  実ファイルを列挙して DB へ収束させる経路をそのまま試す
//  （`ScanIntegrationTests` の `ScanWorkspace` を共有）。
//

@Suite("未解決ファイルの記録と再マッチング [AL-31][AL-34]", .serialized)
struct UnresolvedScanTests {

    /// 走査後の未解決一覧。
    private func unresolved(_ w: ScanWorkspace) async throws -> [UnresolvedFile] {
        try await w.files.unresolvedFiles(libraryID: w.libraryID, includeIgnored: true)
    }

    @Test("どのフォーマットにも当たらないファイルが行として記録される [AL-31]")
    func scanRecordsUnresolved() async throws {
        let w = try await ScanWorkspace()
        try w.write("(同人誌) [サークルA (作家A)] 作品1 (オリジナル).cbz")
        try w.write("まったく別の形式.cbz")

        let summary = try await w.scanFull()
        #expect(summary.unresolvedNames == 1)

        let rows = try await unresolved(w)
        #expect(rows.map(\.row.filename) == ["まったく別の形式.cbz"])
        #expect(rows[0].isIgnored == false)
    }

    @Test("解決したファイルは記録されない（数えるだけの実装との違い）")
    func resolvedFilesAreNotRecorded() async throws {
        let w = try await ScanWorkspace()
        try w.write("(同人誌) [サークルA (作家A)] 作品1 (オリジナル).cbz")
        _ = try await w.scanFull()
        #expect(try await unresolved(w).isEmpty)
    }

    @Test("2 回走らせても行は増えない（収束型）[FO-20][SY-12]")
    func rescanIsIdempotent() async throws {
        let w = try await ScanWorkspace()
        try w.write("まったく別の形式.cbz")
        _ = try await w.scanFull()
        _ = try await w.scanFull()
        #expect(try await unresolved(w).count == 1)
    }

    @Test("フォーマットを足して再マッチングすると、一覧から消えてラベルが付く [AL-34][UR-04]")
    func rematchResolvesAfterAddingAFormat() async throws {
        let w = try await ScanWorkspace()
        try w.write("独自形式＿サークルZ＿作品Z.cbz")
        _ = try await w.scanFull()
        #expect(try await unresolved(w).count == 1)

        // 「サークル」はプリセット同人誌(A) の第 2 グループ [11.4 節]。
        var draft = try #require(try await w.libraries.settingsDraft(libraryID: w.libraryID))
        draft.filenameFormats.append(
            FilenameFormatDraft(source: "独自形式＿@labelgroup2＿@title"))
        try await w.libraries.updateSettings(draft, libraryID: w.libraryID)

        let outcome = try await w.engine.rematchUnresolved(libraryID: w.libraryID)
        #expect(outcome.attempted == 1)
        #expect(outcome.resolved == 1)
        #expect(try await unresolved(w).isEmpty)

        let row = try #require(try await w.rows().first)
        #expect(row.title == "作品Z")
        let groups = try await w.labels.groups(libraryID: w.libraryID)
        let circle = try #require(groups.first { $0.name == "サークル" })
        let labels = try await w.labels.labels(groupID: circle.id, includeArchived: true)
        #expect(labels.map(\.name).contains("サークルZ"))
    }

    @Test("再マッチングは実ファイルを 1 つも読まない [AL-34]")
    func rematchDoesNotTouchTheFileSystem() async throws {
        let w = try await ScanWorkspace()
        try w.write("独自形式＿サークルZ＿作品Z.cbz")
        _ = try await w.scanFull()

        // **実体を消してから**再マッチングする。実体を見る実装なら、ここで
        // 列挙に失敗するか 0 件になる——DB の行だけを見ていることの裏取り。
        try w.remove("独自形式＿サークルZ＿作品Z.cbz")

        var draft = try #require(try await w.libraries.settingsDraft(libraryID: w.libraryID))
        draft.filenameFormats.append(
            FilenameFormatDraft(source: "独自形式＿@labelgroup2＿@title"))
        try await w.libraries.updateSettings(draft, libraryID: w.libraryID)

        let outcome = try await w.engine.rematchUnresolved(libraryID: w.libraryID)
        #expect(outcome.resolved == 1)
    }

    @Test("解決しなかったものは記録に残り、無視も保たれる [AL-33]")
    func rematchKeepsWhatStillDoesNotMatch() async throws {
        let w = try await ScanWorkspace()
        try w.write("まったく別の形式.cbz")
        _ = try await w.scanFull()
        let id = try #require(try await unresolved(w).first?.row.id)
        try await w.files.setUnresolvedIgnored([id], true)

        let outcome = try await w.engine.rematchUnresolved(libraryID: w.libraryID)
        #expect(outcome.attempted == 1)
        #expect(outcome.resolved == 0)

        let rows = try await unresolved(w)
        #expect(rows.count == 1)
        // **無視は保たれる。** 名前は変わっていないので前提が消えていない。
        #expect(rows[0].isIgnored == true)
    }

    @Test("無視したものも再マッチングの対象にする [AL-34]")
    func rematchIncludesIgnored() async throws {
        let w = try await ScanWorkspace()
        try w.write("独自形式＿サークルZ＿作品Z.cbz")
        _ = try await w.scanFull()
        let id = try #require(try await unresolved(w).first?.row.id)
        try await w.files.setUnresolvedIgnored([id], true)

        var draft = try #require(try await w.libraries.settingsDraft(libraryID: w.libraryID))
        draft.filenameFormats.append(
            FilenameFormatDraft(source: "独自形式＿@labelgroup2＿@title"))
        try await w.libraries.updateSettings(draft, libraryID: w.libraryID)

        let outcome = try await w.engine.rematchUnresolved(libraryID: w.libraryID)
        #expect(outcome.resolved == 1)
        // 解決したら行ごと消える——無視の意味が無くなるため。
        #expect(try await unresolved(w).isEmpty)
    }

    @Test("フォーマットが当たるようになれば、通常の再スキャンでも記録が消える")
    func rescanRemovesRecordsThatNowResolve() async throws {
        let w = try await ScanWorkspace()
        try w.write("独自形式＿サークルZ＿作品Z.cbz")
        _ = try await w.scanFull()
        #expect(try await unresolved(w).count == 1)

        var draft = try #require(try await w.libraries.settingsDraft(libraryID: w.libraryID))
        draft.filenameFormats.append(
            FilenameFormatDraft(source: "独自形式＿@labelgroup2＿@title"))
        try await w.libraries.updateSettings(draft, libraryID: w.libraryID)

        _ = try await w.scanFull()
        #expect(try await unresolved(w).isEmpty)
    }

    @Test("名前を直して当たるようになったら一覧から消える")
    func renamingIntoAMatchingNameResolves() async throws {
        let w = try await ScanWorkspace()
        try w.write("まったく別の形式.cbz")
        _ = try await w.scanFull()
        #expect(try await unresolved(w).count == 1)

        try w.move("まったく別の形式.cbz",
                   to: "(同人誌) [サークルA (作家A)] 作品1 (オリジナル).cbz")
        _ = try await w.scanFull()
        #expect(try await unresolved(w).isEmpty)
    }

    @Test("埋め込みメタデータを持つファイルは未解決にならない [EM-03]")
    func filesWithEmbeddedMetadataAreNotUnresolved() async throws {
        let reader = StubMetadataReader(metadata: EmbeddedMetadata(source: .comicInfo, title: "埋め込みの題"))
        let w = try await ScanWorkspace(metadata: reader)
        try w.write("まったく別の形式.cbz")
        let summary = try await w.scanFull()
        #expect(summary.unresolvedNames == 0)
        #expect(try await unresolved(w).isEmpty)
    }
}

/// どのファイルにも同じメタデータを返す読み取り器。
private struct StubMetadataReader: EmbeddedMetadataReading {
    let metadata: EmbeddedMetadata?
    func read(_ url: URL, kind: PreviewableFileKind,
              volumeSource: ComicInfoVolumeSource) async -> EmbeddedMetadata? {
        metadata
    }
}
