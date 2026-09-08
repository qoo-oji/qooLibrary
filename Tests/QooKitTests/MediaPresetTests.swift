//
//  映像プリセットと表示名の組み立て [MF-11][MF-14][MF-21]。
//
//  ここが固定するのは**着手前の実測で決めた形**である（21章 §21.2）——
//  実蔵書の映像 79 件で `SxxEyy` は 0%、`第N話` が 8.9%（すべて「サブタイトル」
//  を伴う）、括弧も角括弧も持たないファイルが 56%。
//
import Testing
import Foundation
@testable import QooKit

@Suite("映像プリセット [MF-14]")
struct MediaPresetTests {

    private func snapshot(_ key: String) throws -> LibrarySettingsSnapshot {
        let sets = try BuiltInTemplates.volumeSets()
        let presets = try BuiltInTemplates.libraryTypes()
        let names = Array(Set(presets.map(\.libraryTypeName))).sorted()
        let preset = try #require(presets.first { $0.key == key })
        return try TemplateInstantiation.snapshot(
            from: preset, volumeSets: sets, libraryID: LibraryID(rawValue: 1),
            mediaTypeVocabulary: names)
    }

    private func parse(_ name: String, _ key: String) throws -> ParsedFileFields? {
        let s = try snapshot(key)
        guard let r = FilenameParser().parse(name, settings: s) else { return nil }
        return FieldPostProcessor.postProcess(r, settings: s)
    }

    @Test("実測にある形（第N話「サブタイトル」）が読める")
    func readsTheShapeFoundInTheCorpus() throws {
        let f = try #require(try parse("作品名 第01話「副題」 (1080p)", "builtin.video-series"))
        #expect(f.seriesName == "作品名")
        #expect(f.episode == 1)
        #expect(f.subtitle == "副題")
    }

    @Test("シリーズ名を持たない形は、話数だけを読んでシリーズを作らない")
    func aNameWithoutASeriesDoesNotInventOne() throws {
        // **`@episode` 系を `@series @episode` より先に並べてある理由**——
        // 逆にすると `@series` が `第` を、`@episode` が `01話` を取って
        // 「第」というシリーズができる（実装時に実測で踏んだ）。
        let f = try #require(try parse("第01話「副題」", "builtin.video-series"))
        #expect(f.seriesName == nil)
        #expect(f.episode == 1)
        #expect(f.subtitle == "副題")
    }

    @Test("SxxEyy はシーズンと話数を同時に読み、シーズンはラベルにもなる [MF-06]")
    func seasonAndEpisodeComeFromOneToken() throws {
        let f = try #require(try parse("Show S02E05", "builtin.video-series"))
        #expect(f.season == 2)
        #expect(f.episode == 5)
        // **束縛したフィールドに正規化した番号が入る**——`S02` という綴りを
        // そのままラベルにすると、`シーズン2` や `第2期` と書いた行が
        // 別のラベルへ割れて、フィールドを軸にした分類が成立しない。
        let sets = try BuiltInTemplates.volumeSets()
        let preset = try #require(try BuiltInTemplates.libraryTypes()
            .first { $0.key == "builtin.video-series" })
        let seasonField = try #require(preset.semanticKeywordBindings[.season])
        #expect(f.labelValues[seasonField] == ["2"])
        _ = sets
    }

    /// **MF-21 の実測。** 仕様は「素の数字も `@episode` の型条件に含める。
    /// ただし Jellyfin #3669 と同じ壊れ方をしないことを実装時に測る」と
    /// していた——測ったら起きたので、型条件から素の数字を外した。
    @Test("解像度を話数と読まない [MF-21]")
    func aResolutionIsNotReadAsAnEpisodeNumber() throws {
        #expect(try parse("作品名 1920x1080", "builtin.video-series") == nil)
        #expect(try parse("作品名 1080", "builtin.video-series") == nil)
    }

    @Test("フォールバック（@title 単独）は置かない［ユーザー判断 2026-09-08］")
    func thereIsNoBareTitleFallback() throws {
        // 構造を持たない名前は**未整理として残す**。コミック側の統合と
        // 同じ判断——「タイトルだけ取れた解決済み」にすると埋もれる。
        #expect(try parse("作品名だけ", "builtin.video-series") == nil)
        #expect(try parse("作品名だけ", "builtin.video-single") == nil)
        for preset in try BuiltInTemplates.libraryTypes() {
            #expect(!preset.filenameFormats.contains("@title"), "\(preset.key)")
        }
    }

    @Test("単発は出演者を読み、対象拡張子は映像用に差し替わる")
    func theSingleWorkPresetReadsTheActor() throws {
        let f = try #require(try parse("[出演者A] 作品名", "builtin.video-single"))
        #expect(f.title == "作品名")
        let preset = try #require(try BuiltInTemplates.libraryTypes()
            .first { $0.key == "builtin.video-single" })
        let actorField = try #require(preset.semanticKeywordBindings[.actor])
        #expect(f.labelValues[actorField] == ["出演者A"])

        let draft = TemplateInstantiation.draft(
            from: preset, volumeSets: try BuiltInTemplates.volumeSets(), displayName: "X")
        #expect(draft.targetExtensions.contains("mkv"))
        #expect(!draft.targetExtensions.contains("cbz"))
    }

    @Test("コミックのプリセットは既定の対象拡張子のまま")
    func comicPresetsKeepTheSharedExtensions() throws {
        let preset = try #require(try BuiltInTemplates.libraryTypes()
            .first { $0.key == "builtin.doujinshi" })
        let draft = TemplateInstantiation.draft(
            from: preset, volumeSets: try BuiltInTemplates.volumeSets(), displayName: "X")
        #expect(Set(draft.targetExtensions) == AppDefaults.Library.targetExtensions)
    }
}

@Suite("表示名の組み立て [SE-33][MF-11]")
struct DisplayTitleTests {

    @Test("既定のフォーマットはシリーズ名と巻数を繋ぐ")
    func theDefaultFormatJoinsSeriesAndVolume() {
        let out = DisplayTitle.compose(format: "@series @volume",
                                       parts: .init(series: "作品名", volume: "第01巻"))
        #expect(out == "作品名 第01巻")
    }

    @Test("値の無い部品は、余った空白ごと落とす")
    func missingPartsLeaveNoGap() {
        #expect(DisplayTitle.compose(format: "@series @volume",
                                     parts: .init(series: "作品名")) == "作品名")
        #expect(DisplayTitle.compose(format: "@series @volume",
                                     parts: .init(volume: "第01巻")) == "第01巻")
    }

    /// **括弧の対は中身が空なら丸ごと落とす**——これが無いと、サブタイトルの
    /// 無い行に `「」` だけが残る。
    @Test("中身の無い括弧は残らない")
    func emptyBracketsAreDropped() {
        let f = "@series @episode「@subtitle」"
        #expect(DisplayTitle.compose(format: f,
                                     parts: .init(series: "作品名", episode: 1,
                                                  subtitle: "副題")) == "作品名 1「副題」")
        #expect(DisplayTitle.compose(format: f,
                                     parts: .init(series: "作品名", episode: 1)) == "作品名 1")
    }

    @Test("括弧はライブラリの区切り設定に依存しない")
    func bracketsDoNotDependOnTheLibrarysDelimiters() {
        // 既定の `DelimiterSet` は `「」` を**解析の**区切りとして持たない。
        // 組み立ては表示の都合なので、そこに依存すると設定次第で `「」` が残る。
        #expect(!DelimiterSet.default.pairs.contains { $0.open == "「" })
        #expect(DisplayTitle.compose(format: "「@subtitle」",
                                     parts: .init(series: "作品名")) == nil)
    }

    @Test("差し込めるものが 1 つも無ければ nil（呼び出し側がファイル名へ落とす）")
    func nothingToComposeYieldsNil() {
        #expect(DisplayTitle.compose(format: "@series @volume", parts: .init()) == nil)
    }

    @Test("整数は小数点を出さない")
    func integersHaveNoDecimalPoint() {
        #expect(DisplayTitle.compose(format: "@episode",
                                     parts: .init(episode: 12)) == "12")
        #expect(DisplayTitle.compose(format: "@episode",
                                     parts: .init(episode: 12.5)) == "12.5")
    }

    /// **既知の限界**——素のリテラルは落とさない。`S@seasonE@episode` は
    /// シーズンが無い行で `SE5` になる。既定のフォーマットが括弧か空白でしか
    /// 部品を繋がないのはこのため。
    @Test("素のリテラルは落とさない（既知の限界）")
    func plainLiteralsSurvive() {
        #expect(DisplayTitle.compose(format: "S@seasonE@episode",
                                     parts: .init(episode: 5)) == "SE5")
    }
}
