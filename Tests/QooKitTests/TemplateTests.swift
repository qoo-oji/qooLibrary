import Testing
import Foundation
@testable import QooKit

@Suite("組み込みテンプレート [11.3][11.4][LT-01][MT-02]")
struct BuiltInTemplateTests {
    @Test("巻数フォーマットセットを読める")
    func volumeSetsLoad() throws {
        let sets = try BuiltInTemplates.volumeSets()
        #expect(sets.sets["VS-Full"]?.isEmpty == false)
        #expect(sets.sets["VS-Doujin"]?.isEmpty == false)
        #expect(sets.sets["VS-None"]?.isEmpty == true)
    }

    @Test("プリセットを 8 種すべて読める [11.4]")
    func libraryTypesLoad() throws {
        let presets = try BuiltInTemplates.libraryTypes()
        #expect(presets.count == 8)
        #expect(Set(presets.map(\.key)).count == 8)          // key は一意
        #expect(presets.map(\.displayName).contains("同人誌(A)"))
    }

    /// **すべてのプリセットが実際に使える設定へ展開できること。**
    /// ここが落ちたら、テンプレート定義とパーサの解釈が食い違っている。
    @Test("すべてのプリセットが設定スナップショットへ展開できる [LT-03]")
    func allPresetsInstantiate() throws {
        let sets = try BuiltInTemplates.volumeSets()
        let presets = try BuiltInTemplates.libraryTypes()
        let typeNames = Array(Set(presets.map(\.libraryTypeName)))
        for preset in presets {
            let s = try TemplateInstantiation.snapshot(
                from: preset, volumeSets: sets, libraryID: LibraryID(rawValue: 1),
                allLibraryTypeNames: typeNames)
            #expect(!s.filenameFormats.isEmpty, "\(preset.displayName) にフォーマットが無い")
            #expect(s.libraryTypeName == preset.libraryTypeName)
            #expect(s.filenameFormats.map(\.priority) == Array(0..<preset.filenameFormats.count))
        }
    }

    @Test("同人誌(B) のフォルダ階層割り当てが展開される [AL-01]")
    func folderLevelsInstantiate() throws {
        let sets = try BuiltInTemplates.volumeSets()
        let preset = try #require(try BuiltInTemplates.libraryTypes()
            .first { $0.key == "builtin.doujinshi-b" })
        let s = try TemplateInstantiation.snapshot(from: preset, volumeSets: sets,
                                                    libraryID: LibraryID(rawValue: 1))
        guard case .singleLabelGroup(let group) = s.folderLevelAssignments[1] else {
            Issue.record("第1階層の割り当てが違う: \(String(describing: s.folderLevelAssignments[1]))")
            return
        }
        #expect(group == 2)      // サークル
    }

    @Test("一般コミック(B) は第1階層にフォーマット割り当てを持つ [AL-02]")
    func generalComicBFolderFormat() throws {
        let sets = try BuiltInTemplates.volumeSets()
        let preset = try #require(try BuiltInTemplates.libraryTypes()
            .first { $0.key == "builtin.general-comic-b" })
        let s = try TemplateInstantiation.snapshot(from: preset, volumeSets: sets,
                                                    libraryID: LibraryID(rawValue: 1))
        guard case .format(let f) = s.folderLevelAssignments[1] else {
            Issue.record("第1階層がフォーマット割り当てでない"); return
        }
        // 著者は `@author` で取り、意味束縛で著者グループへ流す [RW-13]
        // ——`authorName` 列にも入るようにするため（束縛が無いと、
        // `@author` で取った値はどのラベルグループにも付かない）。
        #expect(f.usedFields == [.author, .labelGroup(2)])
        #expect(s.semanticBindings[.series] == 2)          // @series → シリーズ [SE-06]
        #expect(s.semanticBindings[.author] == 1)          // @author → 著者 [RW-13]
    }

    @Test("VS-None のライブラリでは巻数を抽出しない [成年コミック]")
    func volumeSetNone() throws {
        let sets = try BuiltInTemplates.volumeSets()
        let preset = try #require(try BuiltInTemplates.libraryTypes()
            .first { $0.key == "builtin.adult-comic-a" })
        let s = try TemplateInstantiation.snapshot(from: preset, volumeSets: sets,
                                                    libraryID: LibraryID(rawValue: 1))
        #expect(s.volumeFormats.isEmpty)
        let r = try #require(FilenameParser().parse("[著者] 作品名 第01巻",
                                                     settings: s, purpose: .libraryScan))
        let f = FieldPostProcessor.postProcess(r, settings: s)
        #expect(f.volume.kind == .none)
        #expect(f.title == "作品名 第01巻")               // 巻数を切り離さない
        #expect(f.seriesName == nil)
    }

    @Test("既定の巻数セットは登録順に関係なく正しく読む")
    func defaultVolumeSetReadsCorrectly() throws {
        let sets = try BuiltInTemplates.volumeSets()
        let patterns = VolumePatternCompiler.compileAll(
            try #require(sets.patterns(named: "VS-Full")))
        for (title, expectedSeries, expectedRaw) in [
            ("ブラックジャックによろしく 第01巻", "ブラックジャックによろしく", "第01巻"),
            ("作品名 12巻", "作品名", "12巻"),
            ("作品名 vol.7", "作品名", "vol.7"),
            ("作品名 上巻", "作品名", "上巻"),
            ("作品名 最終巻", "作品名", "最終巻"),
        ] {
            let out = SeriesExtractor.extract(fromTitle: title, patterns: patterns)
            #expect(out.seriesName == expectedSeries, "\(title)")
            #expect(out.volume.raw == expectedRaw, "\(title)")
        }
    }

    @Test("VS-Doujin の序列語が揃っている（実データで出現する形）")
    func doujinOrdinals() throws {
        let sets = try BuiltInTemplates.volumeSets()
        let patterns = VolumePatternCompiler.compileAll(
            try #require(sets.patterns(named: "VS-Doujin")))
        // 実コーパスの同人誌に現れた: 総集編(81) 前編(13) 中編(4) 後編(11) 完結編(5)
        for word in ["総集編", "前編", "中編", "後編", "完結編"] {
            let out = SeriesExtractor.extract(fromTitle: "作品名 \(word)", patterns: patterns)
            #expect(out.volume.kind == .ordinal, "\(word)")
            #expect(out.seriesName == "作品名", "\(word)")
        }
        // `総集編2` のような混在も序列として扱う [VM2-03]
        let mixed = SeriesExtractor.extract(fromTitle: "作品名 総集編2", patterns: patterns)
        #expect(mixed.volume.kind == .ordinal)
        #expect(mixed.volume.raw == "総集編2")
    }
}

@Suite("既定色パレット [CO-01〜CO-07][MT-13]")
struct LabelColorPaletteTests {
    @Test("グループ数に応じて色相環を等分する [MT-13]", arguments: [1, 5, 10, 12, 20])
    func generatesForAnyCount(_ n: Int) {
        let palette = LabelColorPalette.palette(count: n)
        #expect(palette.count == n)
        #expect(Set(palette.map(\.hexLight)).count == n, "色が重複している")
    }

    @Test("ライトモードの既定色は黒フォントで 4.5:1 以上 [CO-03]", arguments: [10, 12, 20])
    func lightModeContrast(_ n: Int) {
        for (i, c) in LabelColorPalette.palette(count: n).enumerated() {
            let ratio = LabelColorPalette.contrastRatio(c.hexLight, "#000000") ?? 0
            #expect(ratio >= 4.5, "グループ\(i + 1) の \(c.hexLight) が \(ratio)")
            #expect(LabelColorPalette.readableForeground(on: c.hexLight) == "#000000")
        }
    }

    @Test("ダークモードの既定色は白フォントで 4.5:1 以上 [CO-07]", arguments: [10, 12, 20])
    func darkModeContrast(_ n: Int) {
        for (i, c) in LabelColorPalette.palette(count: n).enumerated() {
            let ratio = LabelColorPalette.contrastRatio(c.hexDark, "#FFFFFF") ?? 0
            #expect(ratio >= 4.5, "グループ\(i + 1) の \(c.hexDark) が \(ratio)")
            #expect(LabelColorPalette.readableForeground(on: c.hexDark) == "#FFFFFF")
        }
    }

    @Test("原色のような高彩度は使わない [CO-02]")
    func lowSaturation() {
        #expect(LabelColorPalette.lightSaturation >= 0.15)
        #expect(LabelColorPalette.lightSaturation <= 0.25)
        #expect(LabelColorPalette.lightValue >= 0.85)
        #expect(LabelColorPalette.lightValue <= 0.92)
    }

    @Test("相対輝度とコントラスト比が WCAG の定義どおり [CO-03][CO-05]")
    func wcagMath() throws {
        #expect(abs(try #require(LabelColorPalette.relativeLuminance(hex: "#FFFFFF")) - 1.0) < 0.001)
        #expect(abs(try #require(LabelColorPalette.relativeLuminance(hex: "#000000"))) < 0.001)
        // 黒と白のコントラスト比は 21:1
        #expect(abs(try #require(LabelColorPalette.contrastRatio("#000000", "#FFFFFF")) - 21) < 0.01)
    }

    @Test("不正な色指定では nil を返す")
    func invalidHex() {
        #expect(LabelColorPalette.relativeLuminance(hex: "xyz") == nil)
        #expect(LabelColorPalette.contrastRatio("#FFF", "#000000") == nil)
        #expect(LabelColorPalette.color(forGroupIndex: 0, of: 10) == nil)
        #expect(LabelColorPalette.color(forGroupIndex: 11, of: 10) == nil)
        #expect(LabelColorPalette.palette(count: 0).isEmpty)
    }
}
