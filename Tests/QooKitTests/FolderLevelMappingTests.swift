import Testing
import Foundation
@testable import QooKit

private func folderSettings(
    fileFormats: [String],
    levels: [Int: FolderLevelMappingSpec.Assignment],
    volume: [CompiledVolumePattern] = []
) throws -> LibrarySettingsSnapshot {
    let ctxt = FormatCompilationContext()
    let compiled = try fileFormats.enumerated().map { i, src in
        try FormatCompiler.compile(src, context: ctxt, priority: i)
    }
    return LibrarySettingsSnapshot(libraryID: LibraryID(rawValue: 1),
                                   filenameFormats: compiled,
                                   folderLevelAssignments: levels,
                                   volumeFormats: volume)
}

private func format(_ src: String) throws -> FolderLevelMappingSpec.Assignment {
    .format(try FormatCompiler.compile(src, context: FormatCompilationContext()))
}

@Suite("フォルダ名フォーマット [8.3.1〜8.3.5][AL-01〜AL-03][AL-23]")
struct FolderLabelExtractionTests {
    @Test("フォルダ名全体を 1 ラベルにする [成年コミック(B) 第1階層]")
    func singleLabelGroup() throws {
        let s = try folderSettings(fileFormats: ["@title"],
                                   levels: [1: .singleLabelGroup(index: 1)])
        let labels = FolderLabelResolver.labelsFromPath("佐藤秀峰/作品.cbz", settings: s)
        #expect(labels[1] == ["佐藤秀峰"])
    }

    @Test("1 つのフォルダ名から複数のラベルを取り出す [AL-01][AL-02]")
    func formatAssignment() throws {
        // 一般コミック(B) 第1階層: `[@labelgroup1] @labelgroup2`
        let s = try folderSettings(fileFormats: ["@title"],
                                   levels: [1: try format("[@labelgroup1] @labelgroup2")])
        let labels = FolderLabelResolver.labelsFromPath("[佐藤秀峰] ブラックジャック/作品.cbz",
                                                        settings: s)
        #expect(labels[1] == ["佐藤秀峰"])
        #expect(labels[2] == ["ブラックジャック"])
    }

    @Test("割り当てのない階層は素通しする [AL-03]")
    func noneAssignment() throws {
        let s = try folderSettings(fileFormats: ["@title"],
                                   levels: [1: .none, 2: .singleLabelGroup(index: 2)])
        let labels = FolderLabelResolver.labelsFromPath("無視/シリーズ/作品.cbz", settings: s)
        #expect(labels[1] == nil)
        #expect(labels[2] == ["シリーズ"])
    }

    @Test("想定した階層にフォルダが無い配置ではエラーにしない [AL-23]")
    func missingLevelIsNotAnError() throws {
        let s = try folderSettings(fileFormats: ["@title"],
                                   levels: [1: try format("[@labelgroup1] @labelgroup2"),
                                            2: .singleLabelGroup(index: 3)])
        // 第1階層のフォルダ名がフォーマットに合わない → その階層だけ適用しない
        let labels = FolderLabelResolver.labelsFromPath("括弧なしのフォルダ/作品.cbz", settings: s)
        #expect(labels.isEmpty)
    }

    @Test("同じラベルグループを複数階層に割り当てると両方付与される [FF-17][LB-02][FL-03]")
    func sameGroupAcrossLevels() throws {
        // 一般コミック(B): 第1階層 `[@labelgroup1] @labelgroup2`、第2階層 `@labelgroup2`
        let s = try folderSettings(fileFormats: ["@title"],
                                   levels: [1: try format("[@labelgroup1] @labelgroup2"),
                                            2: try format("@labelgroup2")])
        let labels = FolderLabelResolver.labelsFromPath("[著者] シリーズ/サブシリーズ/作品.cbz",
                                                        settings: s)
        #expect(labels[1] == ["著者"])
        #expect(labels[2] == ["シリーズ", "サブシリーズ"])
    }

    @Test("ブックフォルダは階層として数えない [IF-13]")
    func bookFolderIsNotALevel() throws {
        let s = try folderSettings(fileFormats: ["@title"],
                                   levels: [1: .singleLabelGroup(index: 1),
                                            2: .singleLabelGroup(index: 2)])
        // `著者/作品名/`（作品名がブックフォルダ）→ 第2階層は割り当てない
        let labels = FolderLabelResolver.labelsFromPath("著者/作品名/001.jpg",
                                                        settings: s, endsWithBookFolder: true)
        #expect(labels[1] == ["著者"])
        #expect(labels[2] == nil)
    }

    @Test("ライブラリ直下のファイルは階層を持たない")
    func flatFile() throws {
        let s = try folderSettings(fileFormats: ["@title"],
                                   levels: [1: .singleLabelGroup(index: 1)])
        #expect(FolderLabelResolver.labelsFromPath("作品.cbz", settings: s).isEmpty)
    }
}

@Suite("フォルダ名とファイル名の優先解決 [AL-20〜AL-22][FL-01]")
struct FolderPriorityTests {
    @Test("フォルダ名から得たグループはファイル名側を捨てる [AL-21]")
    func folderWins() throws {
        let s = try folderSettings(fileFormats: ["[@labelgroup1] @title"],
                                   levels: [1: .singleLabelGroup(index: 1)])
        let r = FolderLabelResolver.resolve(relativePath: "フォルダ側著者/[ファイル側著者] 作品.cbz",
                                            nameWithoutExtension: "[ファイル側著者] 作品",
                                            settings: s)
        #expect(r.labels[1] == ["フォルダ側著者"])         // フォルダ名優先
    }

    @Test("優先の単位はラベルグループごと。フォーマット全体ではない [AL-21][FL-01]")
    func perGroupPriority() throws {
        let s = try folderSettings(fileFormats: ["[@labelgroup1] @title (@labelgroup4)"],
                                   levels: [1: .singleLabelGroup(index: 1)])
        let r = FolderLabelResolver.resolve(
            relativePath: "フォルダ側著者/[ファイル側著者] 作品 (タグ).cbz",
            nameWithoutExtension: "[ファイル側著者] 作品 (タグ)",
            settings: s)
        #expect(r.labels[1] == ["フォルダ側著者"])         // フォルダから得たので捨てる
        #expect(r.labels[4] == ["タグ"])                   // フォルダから得ていないので採る
    }

    @Test("@title は常にファイル名から [AL-22]")
    func titleAlwaysFromFilename() throws {
        let s = try folderSettings(fileFormats: ["[@labelgroup1] @title"],
                                   levels: [1: .singleLabelGroup(index: 1)])
        let r = FolderLabelResolver.resolve(relativePath: "著者/[別著者] 作品名.cbz",
                                            nameWithoutExtension: "[別著者] 作品名",
                                            settings: s)
        #expect(r.title == "作品名")
    }

    @Test("ファイル名がどのフォーマットにも一致しなくてもフォルダ側は生きる [AL-31]")
    func folderLabelsSurviveUnmatchedFilename() throws {
        let s = try folderSettings(fileFormats: ["[@labelgroup1] @title"],
                                   levels: [1: .singleLabelGroup(index: 1)])
        let r = FolderLabelResolver.resolve(relativePath: "著者/括弧のない名前.cbz",
                                            nameWithoutExtension: "括弧のない名前",
                                            settings: s)
        #expect(r.labels[1] == ["著者"])
        #expect(r.matchedFormatID == nil)
        #expect(r.title == nil)
    }

    @Test("シリーズ・巻数はファイル名から導かれる [SE-02]")
    func seriesFromFilename() throws {
        let s = try folderSettings(fileFormats: ["[@labelgroup1] @title"],
                                   levels: [1: .singleLabelGroup(index: 1)],
                                   volume: vsFull())
        let r = FolderLabelResolver.resolve(
            relativePath: "佐藤秀峰/[佐藤秀峰] ブラックジャックによろしく 第03巻.cbz",
            nameWithoutExtension: "[佐藤秀峰] ブラックジャックによろしく 第03巻",
            settings: s)
        #expect(r.seriesName == "ブラックジャックによろしく")
        #expect(r.volume.number == 3)
    }
}

@Suite("巻数の出力書式 [5.5][CR-20〜CR-25]")
struct VolumeFormatterTests {
    /// 要件 10.3 節の表と一致すること。
    @Test("仕様書 §5.5 の変換例")
    func specExamples() {
        let style = VolumeOutputStyle()             // 第{n}巻 / 2 桁 / {s} / ""
        #expect(VolumeFormatter.render(.numeric(1, raw: "(01)"), style: style) == "第01巻")
        #expect(VolumeFormatter.render(.numeric(3, raw: "(3)"), style: style) == "第03巻")
        #expect(VolumeFormatter.render(.numeric(12, raw: "(vol.12)"), style: style) == "第12巻")
        // `上巻` `前編` のような表記は巻数ではなく**区切り**になったので、巻数としては
        // `.none` になり `noneOutput` が使われる [2026-08 の仕様変更]。
        #expect(VolumeFormatter.render(.none, style: style) == "")
    }

    @Test("ゼロ埋めは整数部にのみ適用する")
    func zeroPadIntegerPartOnly() {
        var style = VolumeOutputStyle()
        style.digits = 3
        #expect(VolumeFormatter.render(.numeric(3.5, raw: "3.5"), style: style) == "第003.5巻")
        style.digits = 0
        #expect(VolumeFormatter.render(.numeric(3, raw: "3"), style: style) == "第3巻")
    }

    @Test("全角数字で出力できる [CR-22]")
    func fullwidthOutput() {
        var style = VolumeOutputStyle()
        style.numeralWidth = .fullwidth
        #expect(VolumeFormatter.render(.numeric(12, raw: "12"), style: style) == "第１２巻")
    }

    /// **`第上巻巻` のような出力は構造的に起こらない。** 以前は序列専用の
    /// テンプレートを分けることで防いでいたが、序列巻数そのものを廃止したので
    /// 巻数の書式に当てはまるのは数値だけになった [VO-01 の趣旨は保たれる]。
    @Test("数値テンプレートに当たるのは数値巻数だけ [CR-23][VO-01]")
    func numericTemplateOnlyAppliesToNumbers() {
        var style = VolumeOutputStyle()
        style.numericTemplate = "第{n}巻"
        style.noneOutput = ""
        #expect(VolumeFormatter.render(.none, style: style) == "")
    }

    @Test("none の出力を差し替えられる")
    func customNoneOutput() {
        var style = VolumeOutputStyle()
        style.noneOutput = "（単巻）"
        #expect(VolumeFormatter.render(.none, style: style) == "（単巻）")
    }

    @Test("数値テンプレートに装飾を足せる [CR-22]")
    func decoratedNumeric() {
        var style = VolumeOutputStyle()
        style.numericTemplate = "（{n}）"
        #expect(VolumeFormatter.render(.numeric(2, raw: "02"), style: style) == "（02）")
    }
}
