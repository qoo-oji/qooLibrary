import Testing
import Foundation
import QooKit
@testable import QooInfrastructure
@testable import QooPersistence

//
//  メディア向けの 4 列が**実際の走査で**入るか [MF-03〜05][MF-19][MF-10]。
//
//  単体テスト（`MediaPatternSetTests`）は `applyParsedFields` を直に呼ぶので、
//  **走査がその値をそこまで運んでいるか**は 1 件も見ていなかった——実際
//  `FolderLabelResolver.ResolvedLabels` が 4 値を持っておらず、
//  「単体では列へ入るのに実際の走査では 1 件も入らない」状態だった
//  （引き継ぎの回に発見）。ここはその経路を端から端まで通す。
//

@Suite("走査がメディアの 4 列を書く [MF-10]", .serialized)
struct MediaFieldScanTests {

    @Test("映像プリセットの走査で、シーズン・話・サブタイトルが列に入る")
    func aScanFillsTheMediaColumns() async throws {
        let ws = try await ScanWorkspace(preset: "builtin.video-series",
                                         targetExtensions: ["mp4"])
        try ws.write("作品名/作品名 S02E05「副題」.mp4")
        _ = try await ws.scanFull()

        let row = try #require(try await ws.rows().first)
        #expect(row.seriesName == "作品名")
        #expect(row.season == 2)
        #expect(row.episode == 5)
        #expect(row.subtitle == "副題")
    }

    /// サブタイトルは検索対象 [SR-03]。列へ入っていても `searchKey` へ
    /// 畳まれていなければ、画面には出るのに検索で見つからない。
    @Test("サブタイトルで検索できる")
    func theSubtitleIsSearchable() async throws {
        let ws = try await ScanWorkspace(preset: "builtin.video-series",
                                         targetExtensions: ["mp4"])
        try ws.write("作品名/作品名 S01E01「探せる副題」.mp4")
        _ = try await ws.scanFull()

        let hit = try await ws.files.query(
            FileQuery(libraryID: ws.libraryID, searchText: "探せる副題", limit: 10))
        #expect(hit.rows.count == 1)
    }

    /// 公開日は ISO 8601 の部分形 [MF-19]。**素の 4 桁を巻数・話数として
    /// 読まない**ことも同時に見る [MF-21]。
    @Test("公開日が列に入り、話数として読まれない")
    func theReleaseDateLandsInItsOwnColumn() async throws {
        let ws = try await ScanWorkspace(preset: "builtin.video-single",
                                         targetExtensions: ["mp4"])
        // **映像プリセットは `@date` を使わない** [MF-19、ユーザー判断]——
        // 実蔵書で 4 桁の年号と解像度が見分けられなかったため。ここでは
        // 利用者が自分で足した場合を試すので、草案へ日付のパターンを入れる。
        var draft = try #require(try await ws.libraries.settingsDraft(libraryID: ws.libraryID))
        draft.filenameFormats = [FilenameFormatDraft(source: "@title (@date)", isEnabled: true)]
        draft.volumeFormats.append(VolumeFormatDraft(
            source: #"(?<year>(?:19|20)[0-9]{2})-(?<month>[0-9]{1,2})-(?<day>[0-9]{1,2})"#,
            isEnabled: true, role: .date))
        try await ws.libraries.updateSettings(draft, libraryID: ws.libraryID)

        try ws.write("作品名 (2024-01-15).mp4")
        _ = try await ws.scanFull()

        let row = try #require(try await ws.rows().first)
        #expect(row.title == "作品名")
        #expect(row.releaseDate == "2024-01-15")
        #expect(row.episode == nil)
        #expect(row.volume.number == nil)
    }
}
