//
//  シリーズの提案タブの判定 [SS-01〜SS-08][19章 §19.5]（ステージ 10）。
//
//  一覧の出し分け・検索・既定のライブラリはすべて純粋関数なので、ここで
//  直に固定する（`FileVaultModel` のテストと同じ形）。
//
import Testing
import Foundation
import QooKit
@testable import QooApplication

@Suite("シリーズの提案タブ [SS-01〜SS-08]")
struct SeriesSuggestionModelTests {

    private static func suggestion(_ name: String, folder: String = "作者A",
                                   ids: [Int64], titles: [String]? = nil)
        -> SeriesSuggestion
    {
        let members = ids.enumerated().map { index, id in
            SeriesSuggestion.Member(id: FileID(rawValue: id),
                                    title: titles?[index] ?? "\(name)\(index + 1)",
                                    volume: .none)
        }
        return SeriesSuggestion(seriesName: name, folderPath: folder, members: members)
    }

    private static func group(_ name: String, folder: String = "作者A",
                              ids: [Int64], titles: [String]? = nil,
                              ignored: Bool = false) -> SeriesSuggestionModel.Group {
        SeriesSuggestionModel.Group(
            suggestion: suggestion(name, folder: folder, ids: ids, titles: titles),
            isIgnored: ignored)
    }

    // MARK: - 無視の出し分け [SS-05]

    @Test("無視した組は既定では出さない [SS-05]")
    func hidesIgnoredGroupsByDefault() {
        let groups = [Self.group("作品タイトル", ids: [1, 2]),
                      Self.group("別作品タイトル", ids: [3, 4], ignored: true)]
        let visible = SeriesSuggestionModel.visible(groups, showsIgnored: false, matching: "")
        #expect(visible.map(\.suggestion.seriesName) == ["作品タイトル"])
    }

    @Test("「無視したものも表示」で戻る")
    func showsIgnoredWhenAsked() {
        let groups = [Self.group("作品タイトル", ids: [1, 2]),
                      Self.group("別作品タイトル", ids: [3, 4], ignored: true)]
        #expect(SeriesSuggestionModel.visible(groups, showsIgnored: true, matching: "").count == 2)
    }

    @Test("全員に印が付いているときだけ無視とみなす [SS-05]")
    func aPartiallyMarkedGroupIsNotIgnored() {
        let s = Self.suggestion("作品タイトル", ids: [1, 2, 3])
        let all = SeriesSuggestionReport(suggestions: [s],
                                         ignoredFileIDs: [FileID(rawValue: 1),
                                                          FileID(rawValue: 2),
                                                          FileID(rawValue: 3)])
        let partial = SeriesSuggestionReport(suggestions: [s],
                                             ignoredFileIDs: [FileID(rawValue: 1)])
        #expect(all.isIgnored(s))
        // 一部だけ付いているのは「状況が変わった」しるしなので出す。
        #expect(!partial.isIgnored(s))
    }

    // MARK: - 検索

    @Test("シリーズ名で絞れる")
    func searchesBySeriesName() {
        let groups = [Self.group("作品タイトル", ids: [1, 2]),
                      Self.group("別作品", ids: [3, 4])]
        let visible = SeriesSuggestionModel.visible(groups, showsIgnored: false,
                                                    matching: "作品タイトル")
        #expect(visible.count == 1)
    }

    @Test("メンバーのタイトルとフォルダでも絞れる")
    func searchesByMemberTitleAndFolder() {
        let groups = [Self.group("作品", folder: "作者A", ids: [1, 2],
                                 titles: ["作品ABC", "作品XYZ"]),
                      Self.group("別作品", folder: "作者B", ids: [3, 4])]
        #expect(SeriesSuggestionModel.visible(groups, showsIgnored: false,
                                              matching: "XYZ").count == 1)
        #expect(SeriesSuggestionModel.visible(groups, showsIgnored: false,
                                              matching: "作者B").count == 1)
    }

    @Test("全角で打っても半角の綴りに当たる [LE-12 と同じ判定]")
    func searchIsWidthInsensitive() {
        let groups = [Self.group("STUDIO A", ids: [1, 2])]
        #expect(SeriesSuggestionModel.visible(groups, showsIgnored: false,
                                              matching: "ＳＴＵＤＩＯ").count == 1)
    }

    // MARK: - 既定で選ぶライブラリ

    @Test("指定されたライブラリを最優先で選ぶ")
    func prefersTheRequestedLibrary() {
        let libraries = [Self.library(1), Self.library(2)]
        #expect(SeriesSuggestionModel.defaultLibrary(from: libraries,
                                                     preferring: LibraryID(rawValue: 2))
                == LibraryID(rawValue: 2))
    }

    @Test("指定が無ければ先頭を選ぶ（件数では選び直さない）")
    func fallsBackToTheFirstLibrary() {
        // **件数で選ばない**——件数を知るには検出を走らせるしかないので、
        // 「中身のある最初のライブラリ」を選ぶために全ライブラリぶん
        // 走らせては本末転倒になる（`FileVaultModel` との違い）。
        let libraries = [Self.library(1), Self.library(2)]
        #expect(SeriesSuggestionModel.defaultLibrary(from: libraries, preferring: nil)
                == LibraryID(rawValue: 1))
        #expect(SeriesSuggestionModel.defaultLibrary(from: [], preferring: nil) == nil)
    }

    private static func library(_ id: Int64) -> LibrarySummary {
        LibrarySummary(id: LibraryID(rawValue: id), uuid: UUID(), displayName: "L\(id)",
                       resolvedPath: "/tmp/lib\(id)", volumeUUID: "V",
                       libraryTypeID: LibraryTypeID(rawValue: 0),
                       isOnline: true, isReadOnlyDueToFS: false, fileCount: 0,
                       settingsRevision: 0)
    }
}
