import Foundation
import Testing

@testable import QooKit

/// 埋め込みメタデータとファイル名・フォルダ名の優先解決 [EM-03〜EM-05][EMM-01〜EMM-07]。
@Suite struct EmbeddedMetadataMergeTests {

    /// ファイル名から解決できた状態（メタデータを当てる前）。
    private func baseline(labels: [Int: [String]] = [3: ["ファイル名の著者"]])
        -> FolderLabelResolver.ResolvedLabels
    {
        FolderLabelResolver.ResolvedLabels(
            labels: labels,
            title: "ファイル名の題",
            seriesName: "ファイル名のシリーズ",
            volume: .numeric(9, raw: "第09巻"),
            authorName: "ファイル名の著者",
            matchedFormatID: UUID(),
            nearestFormat: nil,
            libraryTypeMismatch: false,
            folderProvidedGroups: [])
    }

    private func settings(authorGroup: Int? = 3, seriesGroup: Int? = nil)
        -> LibrarySettingsSnapshot
    {
        var bindings: [SemanticKeyword: Int] = [:]
        if let authorGroup { bindings[.author] = authorGroup }
        if let seriesGroup { bindings[.series] = seriesGroup }
        return LibrarySettingsSnapshot(libraryID: LibraryID(rawValue: 1),
                                       semanticBindings: bindings)
    }

    @Test func noMetadataChangesNothing() {
        let base = baseline()
        let out = EmbeddedMetadataMerge.apply(nil, to: base, settings: settings())
        #expect(out.title == base.title)
        #expect(out.seriesName == base.seriesName)
        #expect(out.volume == base.volume)
        #expect(out.authorName == base.authorName)
        #expect(out.labels == base.labels)
    }

    @Test func emptyMetadataChangesNothing() {
        let base = baseline()
        let out = EmbeddedMetadataMerge.apply(EmbeddedMetadata(source: .comicInfo),
                                              to: base, settings: settings())
        #expect(out.title == base.title)
        #expect(out.labels == base.labels)
    }

    /// [EMM-01] 優先はフィールドごと。`Series` しか持たない `ComicInfo.xml` は実在し、
    /// そこで巻数まで捨てるとファイル名から読めていたはずの巻数を失う。
    @Test func overridesOnlyTheFieldsTheMetadataHas() {
        let out = EmbeddedMetadataMerge.apply(
            EmbeddedMetadata(source: .comicInfo, series: "メタのシリーズ"),
            to: baseline(), settings: settings())
        #expect(out.seriesName == "メタのシリーズ")
        #expect(out.title == "ファイル名の題")          // 触らない
        #expect(out.volume == .numeric(9, raw: "第09巻"))  // 触らない
        #expect(out.authorName == "ファイル名の著者")     // 触らない
    }

    @Test func overridesTheVolumeWithItsOwnRawSpelling() {
        let out = EmbeddedMetadataMerge.apply(
            EmbeddedMetadata(source: .comicInfo, volume: 3, volumeRaw: "3"),
            to: baseline(), settings: settings())
        #expect(out.volume == .numeric(3, raw: "3"))
    }

    @Test func buildsARawSpellingWhenTheMetadataHasNone() {
        let out = EmbeddedMetadataMerge.apply(
            EmbeddedMetadata(source: .epub, volume: 4),
            to: baseline(), settings: settings())
        #expect(out.volume == .numeric(4, raw: "4"))
    }

    /// [EMM-07] 衝突していて未確定なら**巻数だけ**下の層の値を使う。
    @Test func anUndecidedVolumeLeavesTheFilenameValueInPlace() {
        let metadata = EmbeddedMetadata(
            source: .comicInfo, title: "メタの題", volume: nil,
            volumeConflict: .init(number: 12, numberRaw: "12", volume: 2, volumeRaw: "2"))
        let out = EmbeddedMetadataMerge.apply(metadata, to: baseline(), settings: settings())
        #expect(out.volume == .numeric(9, raw: "第09巻"))   // ファイル名由来のまま
        #expect(out.title == "メタの題")                     // 他のフィールドは上書きする
    }

    // MARK: - 著者とラベル [EMM-03][EMM-04]

    @Test func joinsMultipleAuthorsForTheDisplayColumn() {
        let out = EmbeddedMetadataMerge.apply(
            EmbeddedMetadata(source: .comicInfo, authors: ["著者値A", "著者値B"]),
            to: baseline(), settings: settings())
        #expect(out.authorName == "著者値A, 著者値B")
    }

    /// ラベルは 1 人ずつ別に付ける——ラベルフィルタで著者を 1 人だけ選べる必要がある。
    @Test func addsOneLabelPerAuthor() {
        let out = EmbeddedMetadataMerge.apply(
            EmbeddedMetadata(source: .comicInfo, authors: ["著者値A", "著者値B"]),
            to: baseline(), settings: settings(authorGroup: 3))
        #expect(out.labels[3] == ["著者値A", "著者値B"])
    }

    /// [EMM-03] グループごと置き換える。フォルダ名由来の値を残すと、
    /// 同じ意味の値の出どころが 2 つある状態になる。
    @Test func replacesTheWholeGroupRatherThanAppending() {
        let base = baseline(labels: [3: ["フォルダ名の著者", "ファイル名の著者"]])
        let out = EmbeddedMetadataMerge.apply(
            EmbeddedMetadata(source: .comicInfo, authors: ["メタの著者"]),
            to: base, settings: settings(authorGroup: 3))
        #expect(out.labels[3] == ["メタの著者"])
    }

    @Test func leavesOtherFieldsAlone() {
        let base = baseline(labels: [1: ["ジャンル値A"], 3: ["ファイル名の著者"]])
        let out = EmbeddedMetadataMerge.apply(
            EmbeddedMetadata(source: .comicInfo, authors: ["メタの著者"]),
            to: base, settings: settings(authorGroup: 3))
        #expect(out.labels[1] == ["ジャンル値A"])
        #expect(out.labels[3] == ["メタの著者"])
    }

    /// 意味束縛が無ければラベルには触らない——流す先が無いのに勝手に付けない。
    @Test func doesNotTouchLabelsWithoutASemanticBinding() {
        let base = baseline(labels: [3: ["ファイル名の著者"]])
        let out = EmbeddedMetadataMerge.apply(
            EmbeddedMetadata(source: .comicInfo, authors: ["メタの著者"]),
            to: base, settings: settings(authorGroup: nil))
        #expect(out.labels[3] == ["ファイル名の著者"])
        #expect(out.authorName == "メタの著者")     // 列のほうは更新する
    }

    @Test func replacesTheSeriesLabelToo() {
        let base = baseline(labels: [5: ["ファイル名のシリーズ"]])
        let out = EmbeddedMetadataMerge.apply(
            EmbeddedMetadata(source: .epub, series: "メタのシリーズ"),
            to: base, settings: settings(authorGroup: nil, seriesGroup: 5))
        #expect(out.labels[5] == ["メタのシリーズ"])
    }

    // MARK: - 未解決の判定 [AL-31]

    @Test func aFileWithMetadataIsNotUnresolved() {
        let unmatched = FolderLabelResolver.ResolvedLabels(
            labels: [:], title: nil, seriesName: nil, volume: .none, authorName: nil,
            matchedFormatID: nil, nearestFormat: nil, libraryTypeMismatch: false,
            folderProvidedGroups: [])
        // メタデータから題が取れているなら「埋もれる」状態ではない。
        #expect(!EmbeddedMetadataMerge.isUnresolved(
            unmatched, metadata: EmbeddedMetadata(source: .comicInfo, title: "作品名A")))
        #expect(EmbeddedMetadataMerge.isUnresolved(unmatched, metadata: nil))
        #expect(EmbeddedMetadataMerge.isUnresolved(
            unmatched, metadata: EmbeddedMetadata(source: .comicInfo)))
    }

    @Test func aFileThatMatchedAFormatIsNeverUnresolved() {
        #expect(!EmbeddedMetadataMerge.isUnresolved(baseline(), metadata: nil))
    }
}
