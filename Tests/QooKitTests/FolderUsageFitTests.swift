import Testing
import Foundation
@testable import QooKit

private let bindings: [SemanticKeyword: Int] = [
    .author: 1, .studio: 2, .genre: 3, .event: 4, .keyword: 5, .series: 6, .mediaType: 7,
]

private func settings(_ formats: [String],
                      level1: FolderLevelMappingSpec.Assignment?) throws
    -> LibrarySettingsSnapshot
{
    let ctxt = FormatCompilationContext(mediaTypeVocabulary: ["同人誌"],
                                        semanticBindings: bindings)
    let compiled = try formats.enumerated().map { i, s in
        try FormatCompiler.compile(s, context: ctxt, priority: i)
    }
    return LibrarySettingsSnapshot(
        libraryID: LibraryID(rawValue: 1),
        filenameFormats: compiled,
        folderLevelAssignments: level1.map { [1: $0] } ?? [:],
        volumeFormats: [],
        semanticBindings: bindings)
}

private let doujin = [
    "(@mediatype) [@studio (@author)] @title (@genre)",
    "(@mediatype) [@studio (@author)] @title",
    "[@studio] @title",
]

@Suite("フォルダ名がラベルとして妥当かの実測 [RG3-24]")
struct FolderUsageFitTests {

    @Test("サークルで分けた蔵書は ON を勧める")
    func circleFoldersSuggestOn() throws {
        let s = try settings(doujin, level1: .singleLabelGroup(index: 2))
        let samples = (1...10).map { i in
            (folder: "サークル値\(i)",
             filename: "(同人誌) [サークル値\(i) (著者値\(i))] 作品\(i) (ジャンル値1)")
        }
        let r = FolderUsageFit.measure(samples: samples, settings: s)
        #expect(r.matched == 10)
        #expect(r.total == 10)
        #expect(r.suggestsOn)
    }

    @Test("作品名で分けた蔵書は OFF を勧める [この推定が要る理由]")
    func titleFoldersSuggestOff() throws {
        let s = try settings(doujin, level1: .singleLabelGroup(index: 2))
        let samples = (1...10).map { i in
            (folder: "作品\(i)",
             filename: "(同人誌) [サークル値\(i) (著者値\(i))] 作品\(i) (ジャンル値1)")
        }
        let r = FolderUsageFit.measure(samples: samples, settings: s)
        #expect(r.matched == 0)
        #expect(!r.suggestsOn)
    }

    @Test("ファイル名からその値が取れないサンプルは分母から外す")
    func unjudgeableSamplesAreExcluded() throws {
        let s = try settings(doujin, level1: .singleLabelGroup(index: 2))
        let samples = [
            (folder: "サークル値A", filename: "(同人誌) [サークル値A (著者値1)] 作品1"),
            // どのフォーマットにも当たらない＝判断材料が無い
            (folder: "サークル値A", filename: "括弧のない名前"),
            (folder: "サークル値A", filename: "もう一つの括弧なし"),
        ]
        let r = FolderUsageFit.measure(samples: samples, settings: s)
        #expect(r.total == 1)      // 判断できたのは 1 件だけ
        #expect(r.matched == 1)
        #expect(r.suggestsOn)
    }

    @Test("format 型は一致率をそのまま使う")
    func formatAssignmentUsesMatchRate() throws {
        let ctxt = FormatCompilationContext(mediaTypeVocabulary: [], semanticBindings: bindings)
        let folderFormat = FolderLevelMappingSpec.Assignment.format(
            try FormatCompiler.compile("[@author] @series", context: ctxt))
        let s = try settings(["[@author] @title"], level1: folderFormat)
        let samples = [
            (folder: "[著者値A] 作品名A", filename: "[著者値A] 第01巻"),
            (folder: "[著者値B] 作品名B", filename: "[著者値B] 第01巻"),
            (folder: "未整理", filename: "[著者値C] 第01巻"),
        ]
        let r = FolderUsageFit.measure(samples: samples, settings: s)
        #expect(r.matched == 2)
        #expect(r.total == 3)
        #expect(r.suggestsOn)
    }

    @Test("1 階層目の割り当てが無ければ測らない")
    func noAssignmentMeansNoMeasurement() throws {
        let s = try settings(doujin, level1: nil)
        let r = FolderUsageFit.measure(
            samples: [(folder: "サークル値A", filename: "[サークル値A] 作品1")], settings: s)
        #expect(r.total == 0)
        #expect(!r.suggestsOn)
    }

    @Test("全角と半角の違いは同じ値として扱う [NM-01 と揃える]")
    func widthIsNormalized() throws {
        let s = try settings(["[@studio] @title"], level1: .singleLabelGroup(index: 2))
        let r = FolderUsageFit.measure(
            samples: [(folder: "ＳＴＵＤＩＯ", filename: "[STUDIO] 作品1")], settings: s)
        #expect(r.matched == 1)
        #expect(r.suggestsOn)
    }
}
