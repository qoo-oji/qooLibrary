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
                bookTypeVocabulary: typeNames)
            #expect(!s.filenameFormats.isEmpty, "\(preset.displayName) にフォーマットが無い")
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
        guard case .singleLabelGroup(let field) = s.folderLevelAssignments[1] else {
            Issue.record("第1階層の割り当てが違う: \(String(describing: s.folderLevelAssignments[1]))")
            return
        }
        #expect(field == 2)      // サークル
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
        // 著者は `@author` で取り、意味束縛で著者フィールドへ流す [RW-13]
        // ——`authorName` 列にも入るようにするため（束縛が無いと、
        // `@author` で取った値はどのラベルフィールドにも付かない）。
        // 番号ではなく**意味予約語**で書く [RWI-02]——番号はフィールドの身元では
        // ないので、並べ替えや改名で意味が変わってしまう。
        #expect(f.usedFields == [.author, .series])
        #expect(s.semanticBindings[.series] == 6)          // @series → シリーズ [SE-06]
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
                                                     settings: s))
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
        // 巻数を取り出すもの。`raw` には**原文の表記**が残る。
        for (title, expectedSeries, expectedRaw) in [
            ("ブラックジャックによろしく 第01巻", "ブラックジャックによろしく", "第01巻"),
            ("作品名 12巻", "作品名", "12巻"),
            ("作品名 vol.7", "作品名", "vol.7"),
            ("作品名 Vol.7", "作品名", "Vol.7"),      // 大文字小文字を問わない
            ("作品名 VOLUME 7", "作品名", "VOLUME 7"),
        ] {
            let out = SeriesExtractor.extract(fromTitle: title, patterns: patterns)
            #expect(out.seriesName == expectedSeries, "\(title)")
            #expect(out.volume.raw == expectedRaw, "\(title)")
        }
        // 区切り専用のもの。**シリーズ名は切るが巻数は持たない** [2026-08 の仕様変更]。
        for (title, expectedSeries) in [
            ("作品名 上巻", "作品名"),
            ("作品名 最終巻", "作品名"),
        ] {
            let out = SeriesExtractor.extract(fromTitle: title, patterns: patterns)
            #expect(out.seriesName == expectedSeries, "\(title)")
            #expect(out.volume.kind == VolumeValue.Kind.none, "\(title)")
        }
    }

    @Test("VS-Doujin の区切り語が揃っている（実データで出現する形）")
    func doujinSeparators() throws {
        let sets = try BuiltInTemplates.volumeSets()
        let patterns = VolumePatternCompiler.compileAll(
            try #require(sets.patterns(named: "VS-Doujin")))
        // 実コーパスの同人誌に現れた: 総集編(81) 前編(13) 中編(4) 後編(11) 完結編(5)
        // これらは**シリーズ名を切るだけ**で巻数を持たない [2026-08 の仕様変更]。
        for word in ["総集編", "前編", "中編", "後編", "完結編", "上巻", "中巻", "下巻", "最終巻"] {
            let out = SeriesExtractor.extract(fromTitle: "作品名 \(word)", patterns: patterns)
            #expect(out.seriesName == "作品名", "\(word)")
            #expect(out.volume.kind == VolumeValue.Kind.none, "\(word)")
        }
        // `総集編2` のように数字が続く形もまとめて切る。
        let mixed = SeriesExtractor.extract(fromTitle: "作品名 総集編2", patterns: patterns)
        #expect(mixed.seriesName == "作品名")
        #expect(mixed.volume.kind == VolumeValue.Kind.none)
    }
}

@Suite("既定色パレット [CO-01〜CO-07][MT-13]")
struct LabelColorPaletteTests {
    @Test("フィールド数に応じて色相環を等分する [MT-13]", arguments: [1, 5, 10, 12, 20])
    func generatesForAnyCount(_ n: Int) {
        let palette = LabelColorPalette.palette(count: n)
        #expect(palette.count == n)
        #expect(Set(palette.map(\.hexLight)).count == n, "色が重複している")
    }

    /// 既定色は黒か白のどちらかで必ず読める [CO-03][CO-05][CO-07]。
    ///
    /// **文字色は色ごとに計算する**造り [CO-05] なので「全部黒」は主張しない
    /// ——利用者がラベル固有色を選べば当然崩れる。ここで固定するのは
    /// 「**既定色は必ずどちらかで 4.5:1 を満たす**」という不変条件のほう。
    @Test("既定色は計算した文字色で 4.5:1 以上 [CO-03][CO-05][CO-07]",
          arguments: [1, 5, 6, 10, 12, 20])
    func defaultColorsAreReadable(_ n: Int) throws {
        for (i, c) in LabelColorPalette.palette(count: n).enumerated() {
            for hex in [c.hexLight, c.hexDark] {
                let fg = try #require(LabelColorPalette.readableForeground(on: hex),
                                      "フィールド\(i + 1) の \(hex) は黒でも白でも読めない")
                let ratio = try #require(LabelColorPalette.contrastRatio(hex, fg))
                #expect(ratio >= 4.5, "フィールド\(i + 1) の \(hex) が \(ratio)")
            }
        }
    }

    /// **明るい帯なので、どの色でも黒文字で読める** [CO-03]。
    ///
    /// ライトもダークも同じ色を使う［ユーザー指定「なるべく明るい色で」］。
    /// これが崩れたら明度か色空間の変更を疑う。
    @Test("ライト・ダークとも全色が黒文字になる [CO-03]",
          arguments: [1, 5, 6, 10, 12, 20])
    func foregroundIsUniformWithinAMode(_ n: Int) {
        for c in LabelColorPalette.palette(count: n) {
            #expect(LabelColorPalette.readableForeground(on: c.hexLight) == "#000000", "\(c.hexLight)")
            #expect(c.hexDark == c.hexLight, "モードで色を変えていない")
        }
    }

    /// **原色じみた色を出さない** [CO-02]［ユーザー指定「原色はダメ」］。
    ///
    /// HSV で彩度・明度を固定すると、緑と黄だけが飛び抜けて明るく鮮やかになり
    /// （`#8AFF1A` のような蛍光色）、色相環の一部だけが「警告」に見えた。
    /// OKLCH は知覚的に均等なので、**どの色も同じ明るさに見える**。
    @Test("色相によらず明るさが揃い、原色じみた色が出ない [CO-02]",
          arguments: [5, 6, 8, 10, 12])
    func noGaringColors(_ n: Int) throws {
        var lights: [Double] = []
        for c in LabelColorPalette.palette(count: n) {
            lights.append(try #require(LabelColorPalette.relativeLuminance(hex: c.hexLight)))
        }
        let spread = (lights.max() ?? 0) - (lights.min() ?? 0)
        // HSV(S=0.85,V=0.97) では 0.30 を超えていた[実測]。
        #expect(spread < 0.12, "明るさのばらつきが \(spread)")
        for c in LabelColorPalette.palette(count: n) {
            let (r, g, b) = try #require(LabelColorPalette.components(hex: c.hexLight))
            #expect(!(max(r, g, b) > 0.98 && min(r, g, b) < 0.02), "\(c.hexLight) が原色")
        }
    }

    /// **青から赤へのグラデーション**［ユーザー指定、2026-08-30］。
    ///
    /// 「一番上のラベルが青、一番下が赤」なので、**件数によらず端が固定**される
    /// ——色相環を一周させる実装に戻すと末尾が青へ帰ってきて落ちる。
    @Test("先頭は青、末尾は赤で、その間を単調に降りる",
          arguments: [2, 4, 6, 10, 12])
    func rampGoesFromBlueToRed(_ n: Int) throws {
        let colors = LabelColorPalette.palette(count: n)
        let (fr, fg_, fb) = try #require(LabelColorPalette.components(hex: colors.first!.hexLight))
        #expect(fb > fr && fb > fg_, "先頭 \(colors.first!.hexLight) が青くない")
        let (lr, lg, lb) = try #require(LabelColorPalette.components(hex: colors.last!.hexLight))
        #expect(lr > lg && lr > lb, "末尾 \(colors.last!.hexLight) が赤くない")
        // 色相が始点から終点へ**単調に降りる**（色相環を一周させない）。
        // RGB の成分では確かめられない——緑は R=0、赤の端は B>0 になるため。
        let hues = LabelColorPalette.hues(count: n)
        #expect(hues.first == LabelColorPalette.hueStart)
        #expect(hues.last == LabelColorPalette.hueEnd)
        #expect(hues == hues.sorted(by: >), "色相が単調に降りていない: \(hues)")
    }

    /// **色相の始点はアプリアイコンの青**［ユーザー指定］。512px の画素を走査し、
    /// 有彩色 156,252 画素が集まった `#1F9CF8` の OKLCH 色相（247.4 度）。
    ///
    /// 明度は後の指定（「なるべく明るい色で」）で上げたので、**RGB は一致しない**
    /// ——同じ色相の明るい版になる。
    @Test("先頭の色はアプリアイコンと同じ系統の青")
    func firstColorMatchesTheAppIcon() throws {
        #expect(abs(LabelColorPalette.hueStart - 247.4) < 0.1)
        let first = try #require(LabelColorPalette.palette(count: 10).first)
        let (r, g, b) = try #require(LabelColorPalette.components(hex: first.hexLight))
        let (ir, ig, ib) = try #require(LabelColorPalette.components(hex: "#1F9CF8"))
        // 明るい版なので各チャンネルは上がるが、青が最大・赤が最小という並びは同じ
        #expect(b > g && g > r, "\(first.hexLight)")
        #expect(ib > ig && ig > ir)
        #expect(r >= ir && g >= ig && b >= ib, "アイコンより暗い: \(first.hexLight)")
    }

    /// **sRGB の外へ出る色相では彩度を落として収める**（gamut mapping）。
    ///
    /// 成分を 0...1 へ切り詰めるだけでは色相がずれる（緑が黄緑に転ぶ）——しかも
    /// 丸めた後で「収まっているか」を見ても必ず真になるので気づけない。**丸める
    /// 前の彩度で判定する**ことを固定する。
    @Test("どの色相でも、丸める前から sRGB に収まっている")
    func staysInSRGB() {
        for degrees in stride(from: 0.0, to: 360.0, by: 5.0) {
            let c = LabelColorPalette.gamutMappedChroma(
                lightness: LabelColorPalette.lightness, chroma: LabelColorPalette.chroma, hue: degrees)
            #expect(LabelColorPalette.isInSRGB(lightness: LabelColorPalette.lightness,
                                               chroma: c, hue: degrees),
                    "色相 \(degrees) で C=\(c) が sRGB の外")
            // 落としすぎない（探索が 0 へ潰れていないこと）
            #expect(c > LabelColorPalette.chroma * 0.4, "色相 \(degrees) で彩度が \(c) まで落ちた")
        }
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
