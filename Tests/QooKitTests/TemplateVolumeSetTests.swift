import Foundation
import Testing

@testable import QooKit

/// テンプレートが役割ごとの正規表現セットを引くこと [MF-09][MF-14]。
///
/// **`volumeSet` だけを見ていた頃の経路が残ると、映像プリセットを登録しても
/// 話数・シーズン・日付の正規表現が 1 本も入らない**——フォーマットは
/// `@episode` を含むのに候補が無いので、全ファイルが未整理になる。
@Suite("テンプレートの正規表現セット [MF-09]")
struct TemplateVolumeSetTests {

    private static let sets = VolumeSetDefinition(sets: [
        "VS": [.init(source: #"第([0-9]+)巻"#, kind: nil)],
        "ES": [.init(source: #"第([0-9]+)話"#, kind: nil)],
        "SS": [.init(source: #"第([0-9]+)期"#, kind: nil)],
        "DS": [.init(source: #"\(([0-9]{4})\)"#, kind: nil)],
    ])

    private func template(episode: String? = nil, season: String? = nil,
                          date: String? = nil) -> LibraryTypeTemplate {
        LibraryTypeTemplate(
            key: "builtin.sample", displayName: "見本", libraryTypeName: "見本",
            version: 1,
            labelGroups: [.init(index: 1, name: "著者", autoAssign: true)],
            semanticBindings: ["@author": 1], folderLevels: [:],
            filenameFormats: ["[@author] @title"], volumeSet: "VS",
            episodeSet: episode, seasonSet: season, dateSet: date)
    }

    @Test("volumeSet だけのテンプレートは巻数の役割しか持たない")
    func comicTemplateHasVolumesOnly() {
        let (p, missing) = TemplateInstantiation.volumePatterns(
            for: template(), volumeSets: Self.sets)
        #expect(missing.isEmpty)
        #expect(p.map(\.role) == [.volume])
    }

    @Test("episodeSet / seasonSet / dateSet がそれぞれの役割で入る")
    func mediaTemplateGathersEveryRole() {
        let (p, missing) = TemplateInstantiation.volumePatterns(
            for: template(episode: "ES", season: "SS", date: "DS"), volumeSets: Self.sets)
        #expect(missing.isEmpty)
        #expect(Set(p.map(\.role)) == [.volume, .episode, .season, .date])
        #expect(p.first { $0.role == .episode }?.source == #"第([0-9]+)話"#)
        #expect(p.first { $0.role == .date }?.source == #"\(([0-9]{4})\)"#)
    }

    /// **綴り誤りは黙って飛ばさない** [MF-09]。飛ばすと、話数を取るはずの
    /// ライブラリが 1 件も一致しないまま登録される。
    @Test("知らない集合名は snapshot が拒む")
    func unknownSetNamesAreRejected() {
        #expect(throws: TemplateInstantiation.Error.unknownVolumeSet("ES-Typo")) {
            _ = try TemplateInstantiation.snapshot(
                from: template(episode: "ES-Typo"), volumeSets: Self.sets,
                libraryID: LibraryID(rawValue: 1))
        }
    }

    /// 草案は登録される内容そのもの [LT-03]。**役割まで写らないと、
    /// 設定画面が話数のパターンを巻数の区画に並べる。**
    @Test("草案にも役割ごとに入る")
    func theDraftCarriesTheRoles() {
        let draft = TemplateInstantiation.draft(
            from: template(episode: "ES", season: "SS", date: "DS"),
            volumeSets: Self.sets, displayName: "見本")
        #expect(Set(draft.volumeFormats.map(\.role)) == [.volume, .episode, .season, .date])
        #expect(draft.volumeFormats.first { $0.role == .season }?.source == #"第([0-9]+)期"#)
    }

    /// **優先順は集合ごとに 0 から振り直される。** 照合は役割で絞ってから行う
    /// ので、役割をまたいだ番号の重なりは同長のときの決着 [SE-21] に影響しない。
    @Test("優先順は集合ごとに 0 から振り直す")
    func prioritiesRestartPerSet() {
        let (p, _) = TemplateInstantiation.volumePatterns(
            for: template(episode: "ES"), volumeSets: Self.sets)
        #expect(p.filter { $0.role == .volume }.map(\.priority) == [0])
        #expect(p.filter { $0.role == .episode }.map(\.priority) == [0])
    }
}
