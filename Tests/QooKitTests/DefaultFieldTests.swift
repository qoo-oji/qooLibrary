//
//  既定フィールド 5 種の保証と、意味予約語での参照 [§19.2][§19.10 ステージ 5][RWI-02]。
//
import Testing
import Foundation
@testable import QooKit

@Suite("既定フィールドと意味予約語 [§19.2][RWI-02]")
struct DefaultFieldTests {

    // MARK: - 保証 [§19.2]

    /// **全プリセットが既定 5 種を持ち、意味予約語で束縛されている。**
    ///
    /// これが「全ライブラリに保証」の実体である［ユーザー判断: 保証は新規登録に
    /// のみ及ぼす。既存ライブラリの設定は黙って書き換えない］——プリセットから
    /// 登録すればこの 5 種が入り、白紙から登録しても入る（下の検査）。
    @Test("すべてのプリセットが既定フィールド 5 種を持つ")
    func everyPresetCarriesTheDefaultFields() throws {
        let presets = try BuiltInTemplates.libraryTypes()
        #expect(!presets.isEmpty)
        for preset in presets {
            let bindings = preset.semanticKeywordBindings
            for keyword in SemanticKeyword.defaultFields {
                let index = try #require(bindings[keyword],
                                         "\(preset.key): \(keyword.rawValue) の束縛が無い")
                #expect(preset.fields.contains { $0.index == index },
                        "\(preset.key): \(keyword.rawValue) の束縛先 \(index) が実在しない")
            }
            // 既定 6 種の束縛先は互いに重ならず、実在するフィールドを指す。
            // **番号は固定しない**——プリセットは 1〜5 と 7、白紙は 1〜6 で、
            // 番号はフィールドの身元ではない [§19.2]。
            let defaults = SemanticKeyword.defaultFields.compactMap { bindings[$0] }
            #expect(Set(defaults).count == SemanticKeyword.defaultFields.count,
                    "\(preset.key): 既定フィールドの束縛先が重複している")
        }
    }

    /// **1 つのフィールドに 2 つの予約語を束縛しない** [RW-14]。
    @Test("予約語とフィールドは 1 対 1 [RW-14]")
    func bindingsAreOneToOne() throws {
        for preset in try BuiltInTemplates.libraryTypes() {
            let indices = preset.semanticKeywordBindings.values
            #expect(Set(indices).count == indices.count, "\(preset.key)")
        }
    }

    /// プリセットのフォーマットは**撤去した予約語を含まない**。
    ///
    /// `@labelgroupN`（番号はフィールドの身元ではない）と `@libraryname`
    /// （表示名がフォルダ名へ追随するので照合値が改名で変わる [RG3-31]）は
    /// v3 ステージ 5 で撤去した——**綴りが残っていると「不明な予約語」になり、
    /// そのフォーマットは 1 件も照合しなくなる。**
    @Test("プリセットに撤去した予約語が残っていない [RWI-02]")
    func presetsReferToFieldsBySemanticKeyword() throws {
        let withdrawn = ["@labelgroup", "@libraryname", "@librarytype"]
        for preset in try BuiltInTemplates.libraryTypes() {
            for source in preset.filenameFormats {
                for word in withdrawn {
                    #expect(!source.contains(word), "\(preset.key): \(source)")
                }
            }
            for (level, spec) in preset.folderLevels {
                guard let format = spec.format else { continue }
                for word in withdrawn {
                    #expect(!format.contains(word), "\(preset.key) 階層 \(level): \(format)")
                }
            }
        }
    }

    /// 白紙から始めても既定 6 種は揃う [§19.2]。
    @Test("白紙の草案も既定フィールド 6 種を持つ")
    func blankDraftCarriesTheDefaultFields() throws {
        let sets = try BuiltInTemplates.volumeSets()
        let draft = TemplateInstantiation.blankDraft(
            volumeSets: sets, displayName: "白紙",
            defaultFieldNames: ["著者", "サークル", "ジャンル", "イベント", "キーワード", "本の種別"])
        #expect(draft.fields.map(\.name)
                == ["著者", "サークル", "ジャンル", "イベント", "キーワード", "本の種別"])
        for (offset, keyword) in SemanticKeyword.defaultFields.enumerated() {
            #expect(draft.semanticBindings[keyword] == offset + 1)
        }
        // 訳語が足りなくても壊れない——予約語の綴りで埋める。
        let sparse = TemplateInstantiation.blankDraft(
            volumeSets: sets, displayName: "白紙", defaultFieldNames: ["著者"])
        #expect(sparse.fields.count == 6)
        #expect(sparse.fields[1].name == "circle")
    }

    /// 予約語の綴りが全フィールドで引けること。
    ///
    /// `FormatCompileError.label` は網羅的な `switch` をやめて対応表の検索に
    /// したので（綴りを 2 箇所に書かないため）、**コンパイラは新しい
    /// `FieldRef` の case を教えてくれない**。ここで代わりに固定する。
    @Test("すべてのフィールドが予約語の綴りを持つ")
    func everyFieldHasASpelling() {
        let cases: [FieldRef] = [.title, .series, .author, .circle, .event, .genre,
                                 .keyword, .volume, .bookType]
        for field in cases {
            let word = FormatCompileError.label(field)
            #expect(word.hasPrefix("@") && word != "@?", "\(field)")
        }
        #expect(FormatCompileError.label(.ignore(3)) == "@ignore")
    }

    // MARK: - 束縛の無い予約語を弾く [RW-16][RWI-02]

    /// **フィールドを消してもフォーマットが残る**経路を弾く。
    /// `@labelgroupN` の実在検査と揃っていないと、片方だけ通ってしまう。
    @Test("束縛の無い予約語を参照する草案は保存できない [RW-16]")
    func draftWithUnboundKeywordIsRejected() throws {
        let sets = try BuiltInTemplates.volumeSets()
        var draft = TemplateInstantiation.blankDraft(
            volumeSets: sets, displayName: "L",
            defaultFieldNames: ["著者", "サークル", "ジャンル", "イベント", "キーワード", "本の種別"])
        draft.filenameFormats = [FilenameFormatDraft(source: "[@circle] @title")]
        #expect(draft.validationErrors.isEmpty)             // 束縛があるうちは通る

        // キーワードのフィールドを消す＝束縛が外れる。
        let keywordIndex = try #require(draft.semanticBindings[.keyword])
        draft.fields.removeAll { $0.index == keywordIndex }
        draft.semanticBindings[.keyword] = nil
        draft.filenameFormats = [FilenameFormatDraft(source: "[@circle] @title [@keyword]")]
        #expect(!draft.validationErrors.isEmpty)

        // 構造化列を持つ `@series` / `@author` は束縛が無くても通る [RW-16]
        // ——照合だけの用途が正当（旧プリセットの `[@author] @genre`）。
        draft.semanticBindings[.author] = nil
        draft.filenameFormats = [FilenameFormatDraft(source: "[@author] @title")]
        #expect(draft.validationErrors.isEmpty)
    }

    // MARK: - 撤去した予約語 [v3 ステージ 5]

    /// **撤去した綴りは「不明な予約語」として弾かれる。**
    ///
    /// 表に残っていても普段のテストは通ってしまう（誰も「読めないこと」を
    /// 主張していないため）——変異検証で 2 件空振りして分かった。ここで固定する。
    @Test("@labelgroupN と @libraryname は予約語として読めない")
    func withdrawnReservedWordsAreUnknown() {
        for source in ["[@labelgroup1] @title", "[@labelgroup12] @title",
                       "(@libraryname) @title"] {
            #expect(throws: FormatCompileError.self, "\(source) が通ってしまう") {
                _ = try FormatCompiler.compile(source, context: FormatCompilationContext(),
                                               priority: 0)
            }
        }
        // 対応表にも載っていない（パレットにも出ない）。
        let words = Set(ReservedWordTable.entries.map(\.word))
        #expect(!words.contains("@libraryname"))
        #expect(!words.contains("@librarytype"))     // → @booktype へ改名
        #expect(words.contains("@booktype"))
        #expect(!words.contains { $0.hasPrefix("@labelgroup") })
    }

    // MARK: - 照合 [RWI-02]

    private func snapshot(_ source: String,
                          bindings: [SemanticKeyword: Int]) throws -> LibrarySettingsSnapshot {
        let context = FormatCompilationContext(semanticBindings: bindings)
        return LibrarySettingsSnapshot(
            libraryID: LibraryID(rawValue: 1),
            filenameFormats: [try FormatCompiler.compile(source, context: context, priority: 0)],
            semanticBindings: bindings)
    }

    /// 新しい予約語で切り出した値が、束縛先のフィールドへラベルとして流れる。
    @Test("@circle・@event・@genre・@keyword がラベルになる [RWI-02]")
    func newKeywordsFlowIntoLabels() throws {
        let bindings: [SemanticKeyword: Int] = [.author: 1, .circle: 2, .genre: 3,
                                                .event: 4, .keyword: 5]
        let settings = try snapshot(
            "(@event) [@circle (@author)] @title (@genre) [@keyword]", bindings: bindings)
        let outcome = FilenameParser().parse(
            "(C99) [サークルA (著者A)] 作品X (ジャンルA) [キーワードA]",
            settings: settings)
        let result = try #require(outcome)
        let parsed = FieldPostProcessor.postProcess(result, settings: settings)

        #expect(parsed.labelValues[1] == ["著者A"])
        #expect(parsed.labelValues[2] == ["サークルA"])
        #expect(parsed.labelValues[3] == ["ジャンルA"])
        #expect(parsed.labelValues[4] == ["C99"])
        #expect(parsed.labelValues[5] == ["キーワードA"])
        // `@author` だけは構造化列にも入る [RW-16]——他の 4 種は列を持たない。
        #expect(parsed.authorName == "著者A")
    }

    /// **束縛が無ければラベルにしない** [RW-16]。切り出しはできるが、
    /// どのフィールドへ入れるかが決まっていないので落とす。
    @Test("束縛の無い予約語はラベルにならない [RW-16]")
    func unboundKeywordsProduceNoLabels() throws {
        let settings = try snapshot("[@circle] @title", bindings: [:])
        let result = try #require(FilenameParser().parse("[サークルA] 作品X", settings: settings))
        let parsed = FieldPostProcessor.postProcess(result, settings: settings)
        #expect(parsed.labelValues.isEmpty)
        #expect(parsed.title == "作品X")
    }

    /// **フォルダ名フォーマットでは構造化列も助けにならない** [code-review の指摘]。
    ///
    /// `FolderLabelResolver` が返すのはラベルだけで、タイトル・シリーズ・著者は
    /// ファイル名側から決まる [AL-22]。だから束縛の無い `@author` / `@series` を
    /// フォルダ名フォーマットに書くと**値がどこにも残らない**——ファイル名側では
    /// 正当な「照合だけの用途」が、ここでは静かな取りこぼしになる。
    @Test("フォルダ名フォーマットでは束縛の無い @author も弾く [RW-16]")
    func folderFormatsRejectUnboundStructuredKeywords() throws {
        let sets = try BuiltInTemplates.volumeSets()
        var draft = TemplateInstantiation.blankDraft(
            volumeSets: sets, displayName: "L",
            defaultFieldNames: ["著者", "サークル", "ジャンル", "イベント", "キーワード", "本の種別"])
        draft.filenameFormats = [FilenameFormatDraft(source: "@title")]

        // 束縛があるうちは通る
        draft.folderLevels = [FolderLevelDraft(level: 1, assignment: .format(source: "[@author] @circle"))]
        #expect(draft.validationErrors.isEmpty)

        // ファイル名では通る書き方（構造化列があるので照合専用が正当）
        draft.semanticBindings[.author] = nil
        draft.filenameFormats = [FilenameFormatDraft(source: "[@author] @title")]
        draft.folderLevels = []
        #expect(draft.validationErrors.isEmpty)

        // 同じ書き方をフォルダ名でやると弾かれる
        draft.folderLevels = [FolderLevelDraft(level: 1, assignment: .format(source: "[@author] @circle"))]
        #expect(!draft.validationErrors.isEmpty)
    }

    /// フォルダ名フォーマットでも予約語がラベルになる [RW-17]。
    ///
    /// **ファイル名側と揃っていること**が要点——揃っていないと、同じ `@circle`
    /// がファイル名では効いてフォルダ名では黙って捨てられる。
    @Test("フォルダ名フォーマットの予約語もラベルになる [RW-17]")
    func folderFormatsAlsoProduceSemanticLabels() throws {
        let bindings: [SemanticKeyword: Int] = [.author: 1, .series: 6]
        let context = FormatCompilationContext(semanticBindings: bindings)
        let settings = LibrarySettingsSnapshot(
            libraryID: LibraryID(rawValue: 1),
            folderLevelAssignments: [
                1: .format(try FormatCompiler.compile("[@author] @series", context: context))
            ],
            semanticBindings: bindings)
        let labels = FolderLabelResolver.labelsFromPath("[著者A] 作品X/第01巻.cbz",
                                                       settings: settings)
        #expect(labels[1] == ["著者A"])
        #expect(labels[6] == ["作品X"])
    }
}
