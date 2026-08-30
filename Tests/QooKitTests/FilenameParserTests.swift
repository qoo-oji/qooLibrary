import Testing
import Foundation
@testable import QooKit

// MARK: - 補助

/// 05章 §5.4 の VS-Full 相当（テストで使う最小限）。
func vsFull() -> [CompiledVolumePattern] {
    VolumePatternCompiler.compileAll([
        VolumePattern(source: #"第([0-9]+(?:\.[0-9]+)?)巻"#, priority: 0),
        VolumePattern(source: #"([0-9]+(?:\.[0-9]+)?)巻"#, priority: 1),
        VolumePattern(source: #"vol\.([0-9]+)"#, priority: 2),
        VolumePattern(source: #"vol\s+([0-9]+)"#, priority: 3),
        VolumePattern(source: #"v([0-9]+)"#, priority: 4),
        VolumePattern(source: "上巻", priority: 10, kind: .separator),
        VolumePattern(source: "中巻", priority: 11, kind: .separator),
        VolumePattern(source: "下巻", priority: 12, kind: .separator),
        VolumePattern(source: "最終巻", priority: 13, kind: .separator),
    ])
}

func vsDoujin() -> [CompiledVolumePattern] {
    VolumePatternCompiler.compileAll([
        VolumePattern(source: "総集編", priority: 0, kind: .separator),
        VolumePattern(source: "前編", priority: 1, kind: .separator),
        VolumePattern(source: "中編", priority: 2, kind: .separator),
        VolumePattern(source: "後編", priority: 3, kind: .separator),
        VolumePattern(source: "完結編", priority: 4, kind: .separator),
    ])
}

func settings(formats: [String],
              typeName: String = "一般コミック",
              types: [String] = ["一般コミック", "成年コミック", "同人誌", "同人CG"],
              volume: [CompiledVolumePattern] = [],
              protectedTokens: [ProtectedToken] = [],
              /// 既定は**旧 `@labelgroupN` と同じ番号**へ束縛する
              /// （`@circle`→1・`@genre`→2・`@event`→3・`@keyword`→4・`@author`→5）
              /// ——`@labelgroupN` の撤去 [v3 ステージ 5] で予約語へ書き換えた際、
              /// 番号を書いた既存の検査をそのまま生かすため。
              semantic: [SemanticKeyword: Int] = [.circle: 1, .genre: 2, .event: 3,
                                                  .keyword: 4, .author: 5],
              delimiters: DelimiterSet = .default) throws -> LibrarySettingsSnapshot {
    let ctxt = FormatCompilationContext(delimiters: delimiters,
                                        allLibraryTypeNames: types,
                                        semanticBindings: semantic)
    let compiled = try formats.enumerated().map { i, src in
        try FormatCompiler.compile(src, context: ctxt, priority: i)
    }
    return LibrarySettingsSnapshot(
        libraryID: LibraryID(rawValue: 1),
        libraryTypeName: typeName,
        allLibraryTypeNames: types,
        delimiters: delimiters,
        protectedTokens: ProtectedTokenCompiler.compileAll(protectedTokens),
        filenameFormats: compiled,
        volumeFormats: volume,
        semanticBindings: semantic)
}

// MARK: - プリセットテンプレート [11.4 節]

@Suite("プリセットテンプレートのフォーマットが検証を通る [LT-01]")
struct PresetTemplateTests {
    /// 要件定義書 11.4 節に列挙されたフォーマットをそのまま書き写したもの。
    /// **ここが落ちたら検証器の解釈が実際のテンプレートと食い違っている。**
    static let allPresetFormats: [(preset: String, formats: [String])] = [
        ("一般コミック(A)", ["(@booktype) [@circle] @title",
                          "[@circle] @title"]),
        ("一般コミック(B)", ["(@booktype) [@circle] @title",
                          "[@circle] @title",
                          "@title"]),
        ("成年コミック(A)", ["(@booktype) [@circle] @title",
                          "[@circle] @title"]),
        ("成年コミック(B)", ["(@booktype) [@circle] @title",
                          "[@circle] @title",
                          "@title"]),
        ("同人誌(A)", [
            "(@circle) [@genre (@event)] @title (@keyword) [@author]",
            "(@circle) [@genre (@event)] @title (@keyword)",
            "(@circle) [@genre (@event)] @title [@author]",
            "(@circle) [@genre (@event)] @title",
            "(@circle) [@genre] @title (@keyword) [@author]",
            "(@circle) [@genre] @title (@keyword)",
            "(@circle) [@genre] @title [@author]",
            "(@circle) [@genre] @title",
            "[@genre] @title (@keyword) [@author]",
            "[@genre] @title (@keyword)",
            "[@genre] @title [@author]",
            "[@genre] @title"]),
        ("同人CG(B)", [
            "(@booktype) [@circle (@genre)] @title (@event) [@keyword]",
            "(@booktype) [@circle (@genre)] @title (@event)",
            "(@booktype) [@circle (@genre)] @title [@keyword]",
            "(@booktype) [@circle (@genre)] @title",
            "(@booktype) [@circle] @title (@event) [@keyword]",
            "(@booktype) [@circle] @title (@event)",
            "(@booktype) [@circle] @title [@keyword]",
            "(@booktype) [@circle] @title",
            "[@circle (@genre)] @title (@event) [@keyword]",
            "[@circle (@genre)] @title (@event)",
            "[@circle (@genre)] @title [@keyword]",
            "[@circle (@genre)] @title",
            "[@circle] @title (@event) [@keyword]",
            "[@circle] @title (@event)",
            "[@circle] @title [@keyword]",
            "[@circle] @title"]),
    ]

    @Test("すべてのプリセットのファイル名フォーマットがコンパイルできる",
          arguments: allPresetFormats)
    func presetsCompile(_ preset: (preset: String, formats: [String])) throws {
        let ctxt = FormatCompilationContext(allLibraryTypeNames: ["一般コミック", "成年コミック", "同人CG"])
        for src in preset.formats {
            #expect(throws: Never.self, "\(preset.preset): \(src)") {
                try FormatCompiler.compile(src, context: ctxt)
            }
        }
    }

    @Test("フォルダ階層割り当てのフォーマットもコンパイルできる [AL-01][AL-02]")
    func folderLevelFormatsCompile() throws {
        // 一般コミック(B) 第1階層: `[@circle] @genre`
        // 括弧の境界があるので自由文字列の隣接にならない [VD-02]
        _ = try FormatCompiler.compile("[@circle] @genre", context: FormatCompilationContext())
        _ = try FormatCompiler.compile("@genre", context: FormatCompilationContext())
        _ = try FormatCompiler.compile("@circle", context: FormatCompilationContext())
    }
}

// MARK: - 実データ形状での照合

@Suite("FilenameParser — 実データの形")
struct FilenameParserRealShapeTests {
    let parser = FilenameParser()

    @Test("成年コミック: (成年コミック) [作者名] タイトル")
    func adultComic() throws {
        let s = try settings(formats: ["(@booktype) [@circle] @title",
                                       "[@circle] @title"],
                             typeName: "成年コミック")
        let r = try #require(parser.parse("(成年コミック) [98765架空社] タイトル名",
                                          settings: s, purpose: .libraryScan))
        #expect(r.fields[.circle]?.text == "98765架空社")
        #expect(r.fields[.title]?.text == "タイトル名")
        #expect(r.libraryTypeMismatch == false)
    }

    @Test("同人誌: (同人誌) [サークル (作家)] タイトル (原作) — 入れ子のペア型 [FF-11]")
    func doujinNested() throws {
        let s = try settings(formats: [
            "(@booktype) [@genre (@event)] @title (@keyword)",
            "(@booktype) [@genre] @title (@keyword)",
        ], typeName: "同人誌", volume: vsDoujin())
        let r = try #require(parser.parse("(同人誌) [サークル名 (作家名)] 作品タイトル (オリジナル)",
                                          settings: s, purpose: .libraryScan))
        #expect(r.fields[.genre]?.text == "サークル名")
        #expect(r.fields[.event]?.text == "作家名")
        #expect(r.fields[.title]?.text == "作品タイトル")
        #expect(r.fields[.keyword]?.text == "オリジナル")
    }

    @Test("サークル名のみ（作家名の併記が無い 12%）は 2 番目のフォーマットで拾う [FF-03]")
    func doujinWithoutArtist() throws {
        let s = try settings(formats: [
            "(@booktype) [@genre (@event)] @title (@keyword)",
            "(@booktype) [@genre] @title (@keyword)",
        ], typeName: "同人誌")
        let r = try #require(parser.parse("(同人誌) [サークル名] 作品タイトル (オリジナル)",
                                          settings: s, purpose: .libraryScan))
        #expect(r.fields[.genre]?.text == "サークル名")
        #expect(r.fields[.event] == nil)
        #expect(r.fields[.title]?.text == "作品タイトル")
    }

    @Test("一般コミック: [著者] タイトル 第01巻 — @title 末尾から巻数を抽出 [SE-02]")
    func generalComicVolume() throws {
        let s = try settings(formats: ["[@circle] @title"], volume: vsFull())
        let r = try #require(parser.parse("[佐藤秀峰] ブラックジャックによろしく 第01巻",
                                          settings: s, purpose: .libraryScan))
        let f = FieldPostProcessor.postProcess(r, settings: s)
        #expect(f.title == "ブラックジャックによろしく 第01巻")
        #expect(f.seriesName == "ブラックジャックによろしく")
        #expect(f.volume.kind == .numeric)
        #expect(f.volume.number == 1)
        #expect(f.volume.raw == "第01巻")
        #expect(f.labelValues[1] == ["佐藤秀峰"])
    }

    @Test("タイトル中に区切り文字があっても両端アンカーで正しく解釈できる [TY-04][MT2-03]")
    func delimitersInsideTitle() throws {
        let s = try settings(formats: ["[@circle] @title (@keyword)"])
        let r = try #require(parser.parse("[著者名] 作品 (副題) の話 (オリジナル)",
                                          settings: s, purpose: .libraryScan))
        #expect(r.fields[.title]?.text == "作品 (副題) の話")
        #expect(r.fields[.keyword]?.text == "オリジナル")
    }

    /// 実コーパスでは `(` 5,953 に対し `)` 5,950 で、**閉じ括弧が欠けたファイル名が実在する**。
    @Test("括弧が閉じていないファイル名で落ちない（照合失敗として扱う）")
    func unbalancedBracketsDoNotCrash() throws {
        let s = try settings(formats: ["[@circle] @title"])
        #expect(parser.parse("[著者名 タイトル", settings: s, purpose: .libraryScan) == nil)
        #expect(parser.parse("[[[[[[", settings: s, purpose: .libraryScan) == nil)
        #expect(parser.parse("]]]]]", settings: s, purpose: .libraryScan) == nil)
        #expect(parser.parse("", settings: s, purpose: .libraryScan) == nil)
    }

    @Test("全角の括弧・スペース・数字を含んでも一致する [N-02][WS-01]")
    func fullwidthInput() throws {
        let s = try settings(formats: ["[@circle] @title"], volume: vsFull())
        // 全角スペースが 2 つ、全角数字の巻数
        let r = try #require(parser.parse("[著者名]　　タイトル 第０１巻",
                                          settings: s, purpose: .libraryScan))
        let f = FieldPostProcessor.postProcess(r, settings: s)
        #expect(f.labelValues[1] == ["著者名"])
        #expect(f.volume.number == 1)
    }

    @Test("フォーマットは登録順に評価し最初にマッチしたものを採る [FF-03][FF-04]")
    func formatPriority() throws {
        let s = try settings(formats: ["[@circle] @title (@keyword)",
                                       "[@circle] @title"])
        let r = try #require(parser.parse("[著者] タイトル (タグ)", settings: s, purpose: .libraryScan))
        #expect(r.fields[.keyword]?.text == "タグ")   // 1 番目が勝つ
    }

    @Test("空白だけのフィールドは捕捉しない（意味のないラベルを作らない）[WS-05]")
    func whitespaceOnlyFieldRejected() throws {
        let s = try settings(formats: ["[@circle] @title"])
        #expect(parser.parse("[   ] タイトル", settings: s, purpose: .libraryScan) == nil)
        #expect(parser.parse("[著者]    ", settings: s, purpose: .libraryScan) == nil)
    }
}

// MARK: - @booktype の扱い [RW-01]

@Suite("@booktype の不一致 [RW-01][MV-14b]")
struct LibraryTypeMismatchTests {
    let parser = FilenameParser()

    @Test("スキャン時は警告のみでマッチする")
    func scanWarnsOnly() throws {
        let s = try settings(formats: ["(@booktype) [@circle] @title"],
                             typeName: "一般コミック")
        let r = try #require(parser.parse("(成年コミック) [著者] タイトル",
                                          settings: s, purpose: .libraryScan))
        #expect(r.libraryTypeMismatch == true)
    }

    @Test("移動時はマッチ失敗として次のフォーマットへ進む")
    func moveRejects() throws {
        let s = try settings(formats: ["(@booktype) [@circle] @title"],
                             typeName: "一般コミック")
        #expect(parser.parse("(成年コミック) [著者] タイトル",
                             settings: s, purpose: .moveToLibrary) == nil)
    }

    @Test("一致していれば警告は立たない")
    func matchingTypeIsClean() throws {
        let s = try settings(formats: ["(@booktype) [@circle] @title"],
                             typeName: "一般コミック")
        let r = try #require(parser.parse("(一般コミック) [著者] タイトル",
                                          settings: s, purpose: .moveToLibrary))
        #expect(r.libraryTypeMismatch == false)
    }
}

// MARK: - 保護文字列 [9.2.3]

@Suite("保護文字列 [PT-01〜PT-11]")
struct ProtectedTokenTests {
    let parser = FilenameParser()

    /// 仕様書 §4.7.3 の検証例をそのまま固定する。
    @Test("§4.7.3 の例: 事件記者コナン (仮) (01) - 著者")
    func specExample() throws {
        let token = ProtectedToken(pattern: #"\(仮\)"#)
        let s = try settings(formats: ["@series (@volume) - @circle"],
                             volume: vsFull(), protectedTokens: [token])
        let r = try #require(parser.parse("事件記者コナン (仮) (01) - 著者",
                                          settings: s, purpose: .libraryScan))
        #expect(r.fields[.circle]?.text == "著者")
        #expect(r.fields[.volume]?.volume?.number == 1)
        // 復元されて原文が返る [PT-03]
        #expect(r.fields[.series]?.text == "事件記者コナン (仮)")
    }

    @Test("保護文字列の位置指定 [PT-05]")
    func positionConstraint() throws {
        let suffixOnly = ProtectedToken(pattern: #"\(完全版\)"#, position: .suffix)
        let s = try settings(formats: ["[@circle] @title"], protectedTokens: [suffixOnly])
        // 末尾にあるのでマスクされ、@title に吸収される
        let r = try #require(parser.parse("[著者] タイトル (完全版)", settings: s, purpose: .libraryScan))
        #expect(r.fields[.title]?.text == "タイトル (完全版)")
    }

    @Test("最長一致・左優先でマスクする [PT-06]")
    func longestMatchWins() {
        let short = ProtectedToken(pattern: #"\(完全\)"#)
        let long = ProtectedToken(pattern: #"\(完全版\)"#)
        let input = ProtectedTokenMasker.mask("A (完全版) B", tokens: ProtectedTokenCompiler.compileAll([short, long]))
        #expect(input.maskedChars.count == 5)     // A, 空白, PUA, 空白, B
        #expect(ProtectedTokenMasker.isPlaceholder(input.maskedChars[2]))
        #expect(input.originalText(of: 2..<3) == "(完全版)")
    }

    @Test("全角半角・空白の揺れを吸収する [PT-04]")
    func normalizationInMatching() {
        let token = ProtectedToken(pattern: #"\(完全\s+版\)"#)
        // 全角括弧 + 全角スペース 2 つ
        let input = ProtectedTokenMasker.mask("A （完全　　版） B", tokens: ProtectedTokenCompiler.compileAll([token]))
        #expect(input.maskedChars.contains { ProtectedTokenMasker.isPlaceholder($0) })
    }

    @Test("保護文字列が無ければマスクせず素通しする")
    func noTokensFastPath() {
        let input = ProtectedTokenMasker.mask("[著者] タイトル", tokens: [])
        #expect(input.maskedChars == input.originalChars)
        #expect(input.maskTruncated == false)
    }

    @Test("無効なトークンはマスクしない")
    func disabledTokenIgnored() {
        let token = ProtectedToken(pattern: #"\(仮\)"#, isEnabled: false)
        let input = ProtectedTokenMasker.mask("A (仮) B", tokens: ProtectedTokenCompiler.compileAll([token]))
        #expect(!input.maskedChars.contains { ProtectedTokenMasker.isPlaceholder($0) })
    }

    /// PUA は 256 個しかない [PTI-05]。超過分はマスクせず、印を立てる。
    @Test("PUA の上限を超えたら打ち切って知らせる [PTI-05]")
    func placeholderCapacity() {
        let token = ProtectedToken(pattern: #"\(x\)"#)
        let text = String(repeating: "(x)", count: 300)
        let input = ProtectedTokenMasker.mask(text, tokens: ProtectedTokenCompiler.compileAll([token]))
        #expect(input.maskTruncated == true)
        let placeholders = input.maskedChars.filter { ProtectedTokenMasker.isPlaceholder($0) }
        #expect(placeholders.count == AppLimits.Format.maskPlaceholderCapacity)
    }
}
