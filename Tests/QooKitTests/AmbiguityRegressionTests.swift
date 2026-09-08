//
//  T-10 の掃引で洗い出した曖昧性の**決着を固定する** [16章 §16.5][17章 フェーズ2 DoD]。
//
//  掃引そのものは `AmbiguitySweep.swift`（`QOO_AMBIGUITY_SWEEP=1` のときだけ走る道具）。
//  ここは掃引が見つけた組を、**二度と黙って変わらないように**固定する側。
//
//  ## 掃引の結果（2026-09-07、観測 2,558 件）
//
//  | 分類 | 件数 | 内容 |
//  |---|---|---|
//  | D1 曖昧だが選択は正しい | 基準値 82/82 ほか | 巻数・空白・保護文字列の族は食い違いゼロ |
//  | D2 選択が誤り | **0 件** | |
//  | D3 真に曖昧（規則どおり） | 206 ＋ 16 | 値が括弧を含む／値が `@booktype` の語彙と一致 |
//  | D4 実は一意 | — | 群の内部の選び方は後続に影響しない（下記） |
//
import Testing
import Foundation
@testable import QooKit

@Suite("T-10 曖昧性の決着 [FF-13][FF-03][TY-01][PT-01]")
struct AmbiguityRegressionTests {

    // MARK: - 足場

    private func doujinshiA() throws -> (LibraryTypeTemplate, LibrarySettingsSnapshot) {
        let volumeSets = try BuiltInTemplates.volumeSets()
        let presets = try BuiltInTemplates.libraryTypes()
        let names = Array(Set(presets.map(\.libraryTypeName))).sorted()
        guard let preset = presets.first(where: { $0.displayName == "同人誌" }) else {
            throw TestSkip.missingPreset
        }
        let settings = try TemplateInstantiation.snapshot(
            from: preset, volumeSets: volumeSets, libraryID: LibraryID(rawValue: 1),
            bookTypeVocabulary: names)
        return (preset, settings)
    }

    enum TestSkip: Error { case missingPreset }

    private func context(vocabulary: [String] = []) -> FormatCompilationContext {
        FormatCompilationContext(delimiters: .default, maxFields: 10,
                                 bookTypeVocabulary: vocabulary, semanticBindings: [:])
    }

    // MARK: - 対照: 曖昧でない値なら全フォーマットが意図どおり

    @Test("区切りを含まない値なら、全プリセットの全フォーマットが生成元のとおりに読める")
    func benignValuesRoundTripThroughEveryPresetFormat() throws {
        // 掃引の対照群。ここが崩れたら、曖昧性以前に優先順位か照合が壊れている。
        let observations = try AmbiguitySweep.run().filter {
            $0.adversary == .baseline && $0.preset != "合成"
        }
        #expect(observations.count == 40, "プリセットのフォーマット本数が変わった")
        for o in observations {
            #expect(o.chosenFormat == o.formatIndex,
                    "\(o.preset) #\(o.formatIndex) が別のフォーマット #\(o.chosenFormat.map(String.init) ?? "なし") で読まれた: \(o.input)")
            for (key, want) in o.intended {
                #expect(o.chosenFields[key] == want,
                        "\(o.preset) #\(o.formatIndex) の \(key): 意図「\(want)」 実際「\(o.chosenFields[key] ?? "（なし）")」")
            }
        }
    }

    // MARK: - D3: 値が括弧の対を含むと、優先順位の高い形が勝つ

    @Test("サークル名が括弧の対を含むと、著者付きの形が勝って著者として読まれる [FF-03]")
    func balancedParenthesesInsideAValueAreReadAsTheNextField() throws {
        let (_, settings) = try doujinshiA()
        let result = FilenameParser().parse("(同人誌) [集団 (仮)] 題名 (分野) [鍵語]",
                                            settings: settings)
        // `[サークル (作者)]` は同人誌の命名規約そのもの——人にも区別できない。
        // 優先順位の高い「著者付き」の形が勝つのが決着 [FF-03]。
        #expect(result?.fields[.circle]?.text == "集団")
        #expect(result?.fields[.author]?.text == "仮")
    }

    @Test("保護文字列に当たる括弧は守られ、サークル名の一部として残る [PT-01][PT-03]")
    func protectedTokensResolveTheParenthesisAmbiguity() throws {
        let (_, settings) = try doujinshiA()
        // `(完全版)` は既定の保護文字列 [AppDefaults.Library.protectedTokenPatterns]。
        // **これが曖昧性の逃げ道であることの実証**——上のテストと 1 文字しか違わない。
        let result = FilenameParser().parse("(同人誌) [集団 (完全版)] 題名 (分野) [鍵語]",
                                            settings: settings)
        #expect(result?.fields[.circle]?.text == "集団 (完全版)")
        #expect(result?.fields[.author] == nil)
    }

    @Test("値が不均衡な括弧を含むと、その形では表現できず別の形へ落ちる")
    func unbalancedBracketsFallThroughToAnotherFormat() throws {
        let (_, settings) = try doujinshiA()
        let result = FilenameParser().parse("(同人誌) [集団 (著者) 続き)] 題名 (分野) [鍵語]",
                                            settings: settings)
        // `[@circle (@author)]` は成立しない（閉じ括弧が余る）ので
        // `[@circle]` の形へ落ちる。値は丸ごとサークル名になる。
        #expect(result?.fields[.circle]?.text == "集団 (著者) 続き)")
        #expect(result?.fields[.author] == nil)
    }

    // MARK: - D3: 値が `@booktype` の語彙と一致すると、種別の形が勝つ

    @Test("イベント名が本の種別の語彙と一致すると、種別として読まれる [TY-01][FF-03]") 
    func eventNameThatCollidesWithTheBookTypeVocabularyIsReadAsBookType() throws {
        let (_, settings) = try doujinshiA()
        // `(@booktype) …` と `(@event) …` は**先頭以外まったく同じ形**なので、
        // 優先順位でしか決まらない [2026-09-04 の決定]。語彙に入る語を
        // イベント名に使うと、イベントとしては取れない。
        //
        // **これは限界として受け入れている**［ユーザー判断、2026-09-07、AM-07］——
        // 種別とイベントの使い分けは**テンプレートタイプを分けて**行う想定なので、
        // 1 つのライブラリで両方の語彙が衝突する状況をそもそも作らない。
        // 未決の穴ではないので、衝突を検知して知らせる仕掛けは作らない。
        let result = FilenameParser().parse("(同人誌) [集団 (著者)] 題名 (分野) [鍵語]",
                                            settings: settings)
        #expect(result?.fields[.bookType]?.text == "同人誌")
        #expect(result?.fields[.event] == nil)
        // 語彙に無い語ならイベントとして取れる（対照）。
        let event = FilenameParser().parse("(C99) [集団 (著者)] 題名 (分野) [鍵語]",
                                           settings: settings)
        #expect(event?.fields[.event]?.text == "C99")
        #expect(event?.fields[.bookType] == nil)
    }

    // MARK: - D1/D3: 分岐点ごとの決着

    @Test("自由文字列は非貪欲——区切りが複数あれば最初の 1 つで切る [FF-13]")
    func freeFieldsAreNonGreedy() throws {
        let format = try FormatCompiler.compile("@series - @title", context: context())
        let input = ParseInput("叢書 - 続編 - 題名")
        // 解は 2 通り。非貪欲なので短い方を採る。
        #expect(ParseEnumerator.enumerate(format, input: input, volumePatterns: []).solutions.count == 2)
        let result = FormatMatcher.match(format, input: input, volumePatterns: []).result
        #expect(result?.fields[.series]?.text == "叢書")
        #expect(result?.fields[.title]?.text == "続編 - 題名")
    }

    @Test("巻数は最長一致——非貪欲な自由文字列と組んでも数字を分け合わない [SE-24]")
    func volumeTakesTheLongestCandidate() throws {
        let sets = try BuiltInTemplates.volumeSets()
        let richest = sets.sets.max { $0.value.count < $1.value.count }?.key
        let patterns = VolumePatternCompiler.compileAll(richest.flatMap { sets.patterns(named: $0) } ?? [])
        // **末尾で終わる形は判定に使えない**——後ろに何も無ければ、短い巻数を
        // 採っても残りが余って失敗し、結局最長が選ばれる。順序の規則を試すには
        // **短い巻数でも全体が成立する形**が要る［変異 M2 が空振りして判明］。
        // **同じ位置で複数の巻数パターンが一致する入力**でなければ順序を試せない。
        // `01巻` は `([0-9]+)巻` と素の数字表記の両方に当たる [SE-24]
        //［変異 M2 が 2 度空振りして判明——数字だけの入力では候補が 1 つしか出ない］。
        let format = try FormatCompiler.compile("@series @volume @title", context: context())
        let input = ParseInput("叢書 01巻 題名")
        #expect(ParseEnumerator.enumerate(format, input: input,
                                          volumePatterns: patterns).solutions.count >= 2)
        let result = FormatMatcher.match(format, input: input, volumePatterns: patterns).result
        #expect(result?.fields[.series]?.text == "叢書")
        #expect(result?.fields[.volume]?.text == "01巻")
        #expect(result?.fields[.volume]?.volume?.number == 1)
        #expect(result?.fields[.title]?.text == "題名")

        // 末尾が巻数で終わる形では、どの順序でも同じ答えになる（対照）。
        let anchored = try FormatCompiler.compile("@series @volume", context: context())
        let tail = FormatMatcher.match(anchored, input: ParseInput("叢書 01"),
                                       volumePatterns: patterns).result
        #expect(tail?.fields[.volume]?.volume?.number == 1)
    }

    @Test("列挙値は長い順に試す——互いが接頭辞でも長い方が勝つ [TY-01]")
    func enumeratedValuesPreferTheLongestMatch() throws {
        // プリセットの語彙（一般コミック・成年コミック・同人誌・同人CG）は
        // 互いに接頭辞にならないので、この規則は**実データでは一度も通らない**。
        // 利用者が「本の種別」ラベルを足せば通りうるため、ここで固定する。
        // **括弧で囲むと判定に使えない**——群は [開き, 閉じ] の固定範囲を占め、
        // 内部は完全一致を要求されるので、短い候補は必ず余りを出して失敗する。
        // つまり**プリセットの `(@booktype)` はこの規則を一度も通らない**
        // ［変異 M3 が空振りして判明］。囲みの無い形で固定する。
        let bare = try FormatCompiler.compile("@booktype @title",
                                              context: context(vocabulary: ["同人", "同人誌"]))
        let result = FormatMatcher.match(bare, input: ParseInput("同人誌 題名"),
                                         volumePatterns: []).result
        #expect(result?.fields[.bookType]?.text == "同人誌")
        #expect(result?.fields[.title]?.text == "題名")

        // 群の中では順序に関わらず完全一致しか通らない（対照）。
        let grouped = try FormatCompiler.compile("(@booktype) @title",
                                                 context: context(vocabulary: ["同人", "同人誌"]))
        let inside = FormatMatcher.match(grouped, input: ParseInput("(同人誌) 題名"),
                                         volumePatterns: []).result
        #expect(inside?.fields[.bookType]?.text == "同人誌")
    }

    @Test("群の内部の選び方は後続に影響しない——閉じ括弧が一意に決まるため")
    func theInteriorOfAGroupNeverChangesWhatFollows() throws {
        // 本番は群の内部について**最初の解しか試さない**（後続が失敗しても選び直さない）。
        // それでも取りこぼしが起きないのは、群が [開き, 閉じ] の**固定範囲**を占め、
        // 閉じ括弧がネスト計数で一意に決まるから——内部の割り当ては後続と独立している。
        // 掃引 2,558 件で乖離 0 件だったことがこの論証の裏づけ。
        let format = try FormatCompiler.compile("[@circle (@author)] @title", context: context())
        for text in ["[集団 (著者)] 題名", "[集団 (著者) 余り] 題名",
                     "[集団 (著) (者)] 題名", "[集団 (著者)] 題名 (続き)"] {
            let input = ParseInput(text)
            let production = FormatMatcher.match(format, input: input, volumePatterns: []).result
            let enumerated = ParseEnumerator.enumerate(format, input: input,
                                                       volumePatterns: []).solutions
            #expect(AmbiguitySweep.compare(production: production,
                                           enumerated: enumerated.first) == nil,
                    "\(text) で本番と列挙器が食い違った")
        }
    }
}
