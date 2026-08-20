import Testing
import Foundation
@testable import QooKit

// MARK: - 畳んだ射影

@Suite("FoldedSubject — 照合用の射影")
struct FoldedSubjectTests {
    @Test("全角を半角へ畳む。文字数は変えない")
    func foldsWidthKeepingCount() {
        let s = FoldedSubject("Ｖｏｌ．１２")
        #expect(s.text == "Vol.12")
        #expect(s.count == 6)
        // `raw` は原文から取るので、ユーザーの表記は失われない。
        #expect(s.originalText(in: 0..<6) == "Ｖｏｌ．１２")
    }

    @Test("全角スペースも半角として扱う [WidthFolding]")
    func foldsIdeographicSpace() {
        #expect(FoldedSubject("a　b").text == "a b")
    }

    /// **実ファイル名の 75.5% は NFD。** ICU はコードポイント単位で比べるので、
    /// ここで NFC へ揃えておかないと NFC で書かれたパターンが一致しない。
    @Test("NFD の入力を NFC へ合成する")
    func composesToNFC() throws {
        let decomposed = "か\u{3099}"                     // NFD の「が」
        #expect(decomposed.unicodeScalars.count == 2)
        let s = FoldedSubject(decomposed)
        #expect(s.count == 1)                             // 書記素としては 1 文字
        let regex = try SafeRegex("が")                    // NFC で書いたパターン
        guard case .found(let m) = regex.match(anchoredAt: 0, in: s, budget: 1) else {
            Issue.record("NFD の入力に NFC のパターンが一致しなかった")
            return
        }
        #expect(m.range == 0..<1)
        #expect(s.originalText(in: m.range) == decomposed) // 原文は NFD のまま返る
    }

    /// 非 BMP 文字（絵文字）は UTF-16 で 2 単位を占める。**対応表が無いと
    /// 添字がずれる**——実ファイル名に絵文字は実在する。
    @Test("絵文字を含んでも文字添字が正しく写る")
    func mapsIndicesAcrossNonBMP() throws {
        let s = FoldedSubject("😀作品 第01巻")
        let regex = try SafeRegex(#"第([0-9]+)巻"#)
        guard case .found(let m) = regex.matchAtEnd(in: s, budget: 1) else {
            Issue.record("末尾一致しなかった")
            return
        }
        #expect(s.originalText(in: m.range) == "第01巻")
        // 絵文字を 1 文字として数えた位置に来ること。
        #expect(m.range.lowerBound == 4)
    }
}

// MARK: - ウォッチドッグ

@Suite("SafeRegex — 時間の上限")
struct SafeRegexBudgetTests {
    /// **この suite の要。** `(a+)+` は指数時間で、無制限なら a×30 で数十秒かかる。
    /// 打ち切りが効いていれば予算ぶんで返る。
    @Test("破滅的バックトラッキングを予算内で打ち切る")
    func abandonsCatastrophicPattern() throws {
        let regex = try SafeRegex("(a+)+")
        let subject = FoldedSubject(String(repeating: "a", count: 30) + "!")
        let started = Date()
        let result = regex.matchAtEnd(in: subject, budget: 0.05)
        let elapsed = Date().timeIntervalSince(started)

        #expect(result == .abandoned)
        // 打ち切りを外すと数十秒かかる。1 秒で切れば取り違えようがない。
        #expect(elapsed < 1.0, "打ち切りが効いていない（\(elapsed) 秒）")
    }

    @Test("位置アンカー照合でも打ち切れる")
    func abandonsWhenAnchored() throws {
        let regex = try SafeRegex("(a+)+$")
        let subject = FoldedSubject(String(repeating: "a", count: 30) + "!")
        #expect(regex.match(anchoredAt: 0, in: subject, budget: 0.05) == .abandoned)
    }

    @Test("普通のパターンは打ち切られない")
    func normalPatternIsNotAbandoned() throws {
        let regex = try SafeRegex(#"第([0-9]+)巻"#)
        let result = regex.matchAtEnd(in: FoldedSubject("作品 第01巻"), budget: 0.02)
        guard case .found(let m) = result else {
            Issue.record("一致するはずが \(result)")
            return
        }
        #expect(m.captureRange == 4..<6)
    }

    @Test("打ち切られたパターンはその設定の中で二度と試されない")
    func abandonedPatternIsSkipped() {
        let patterns = VolumePatternCompiler.compileAll([
            VolumePattern(source: "(a+)+", priority: 0),
        ])
        let subject = FoldedSubject(String(repeating: "a", count: 30) + "!")
        _ = VolumeMatcher.matchAtEnd(subject, patterns: patterns)
        #expect(patterns.first?.health.abandonedIDs.isEmpty == false)

        // 2 回目は照合そのものを試さないので、予算ぶんも待たない。
        let started = Date()
        _ = VolumeMatcher.matchAtEnd(subject, patterns: patterns)
        #expect(Date().timeIntervalSince(started) < 0.01)
    }

    @Test("名前付きグループがあればそちらから巻数を取る")
    func namedGroupWins() throws {
        let regex = try SafeRegex(#"(第)(?<volume>[0-9]+)巻"#)
        #expect(regex.hasNamedVolumeGroup)
        guard case .found(let m) = regex.matchAtEnd(in: FoldedSubject("作品 第07巻"), budget: 1) else {
            Issue.record("一致しなかった")
            return
        }
        #expect(m.captureRange.map { FoldedSubject("作品 第07巻").originalText(in: $0) } == "07")
    }
}

// MARK: - 安全性検査

@Suite("RegexSafety — 危険な正規表現の検出")
struct RegexSafetyTests {
    func kinds(_ source: String) -> [RegexSafetyFinding.Kind] {
        RegexSafety.staticFindings(source).map(\.kind)
    }

    @Test("量指定子の付いたグループが中にも量指定子を含む形を見つける")
    func detectsQuantifiedGroup() {
        #expect(kinds("(a+)+").contains(.quantifiedGroup))
        #expect(kinds("(a|a)*").contains(.quantifiedGroup))
        // **文字クラスやエスケープの直後の量指定子を読み飛ばすと、この 3 つを
        // 取りこぼす。** いちばん典型的な危険形なので必ず固定する。
        #expect(kinds("(?:[0-9]+)+").contains(.quantifiedGroup))
        #expect(kinds(#"(\d+)+"#).contains(.quantifiedGroup))
        #expect(kinds("([a-z]*)*").contains(.quantifiedGroup))
        #expect(kinds("(?:a{1,})+").contains(.quantifiedGroup))
        // 危険でない形は警告しない。
        #expect(!kinds("(?:abc)?").contains(.quantifiedGroup))
        #expect(!kinds("(a|b)").contains(.quantifiedGroup))
        #expect(!kinds("(?:a|b){2}").contains(.quantifiedGroup))
    }

    /// **既定のパターンが 1 つも警告されないこと。** 警告が出っぱなしになると、
    /// 本当に危ないものに気づけなくなる。
    @Test("既定として配るパターンは警告されない")
    func defaultPatternsAreClean() throws {
        let sets = try BuiltInTemplates.volumeSets()
        for name in ["VS-Full", "VS-Doujin"] {
            for pattern in try #require(sets.patterns(named: name)) {
                #expect(RegexSafety.staticFindings(pattern.source).isEmpty,
                        "\(name): \(pattern.source)")
            }
        }
    }

    @Test("読めない正規表現はエラーになる")
    func invalidSyntaxIsAnError() {
        let findings = RegexSafety.staticFindings("(")
        #expect(findings.count == 1)
        #expect(findings.first?.isError == true)
    }

    /// 照合は半角へ畳んだ後に行うので、全角の文字クラスは**決して一致しない**。
    @Test("全角の文字が書かれていたら知らせる")
    func warnsAboutFullWidth() {
        #expect(kinds("[０-９]+").contains { if case .fullWidthLiteral = $0 { true } else { false } })
        #expect(!kinds("[0-9]+").contains { if case .fullWidthLiteral = $0 { true } else { false } })
        // 漢字・かなは畳まれないので警告しない。
        #expect(!kinds("第([0-9]+)巻").contains { if case .fullWidthLiteral = $0 { true } else { false } })
    }

    @Test("後方参照と先読みを見つける")
    func detectsBackreferenceAndLookaround() {
        #expect(kinds(#"(a)\1"#).contains(.backreference))
        #expect(kinds("(?=a)b").contains(.lookaround))
        #expect(kinds("(?<=a)b").contains(.lookaround))
    }

    @Test("実測は危ないものだけを挙げる")
    func measuresOnlyDangerousPatterns() {
        #expect(!RegexSafety.measuredFindings("(a+)+$").isEmpty)
        #expect(RegexSafety.measuredFindings(#"第([0-9]+)巻"#).isEmpty)
    }
}

// MARK: - 旧記法からの変換

@Suite("LegacyVolumeNotation — 旧記法からの変換")
struct LegacyVolumeNotationTests {
    @Test("メタ記号が正規表現になる")
    func convertsMetaTokens() {
        #expect(LegacyVolumeNotation.regex(fromVolumeSource: "第??巻")
                == #"第([0-9]+(?:\.[0-9]+)?)巻"#)
        #expect(LegacyVolumeNotation.regex(fromVolumeSource: "vol<space>??")
                == #"vol\s+([0-9]+(?:\.[0-9]+)?)"#)
    }

    /// **リテラルのピリオドをエスケープし損ねると `vol.7` が `volX7` にも当たる。**
    @Test("リテラルのメタ文字はエスケープされる")
    func escapesLiterals() {
        let converted = LegacyVolumeNotation.regex(fromVolumeSource: "vol.??")
        #expect(converted.hasPrefix(#"vol\."#))
    }

    @Test("?? が 2 つ以上なら 2 つ目以降は非キャプチャにする")
    func onlyFirstDigitsCaptures() throws {
        let converted = LegacyVolumeNotation.regex(fromVolumeSource: "??-??")
        let regex = try SafeRegex(converted)
        #expect(regex.captureGroupCount == 1)
    }

    /// **変換の正しさは「同じ入力に同じように当たるか」で見る。** 綴りの一致だけを
    /// 見ると、変換表の 1 行が壊れても気づけないことがある。
    @Test("変換後のパターンが旧記法と同じ入力に当たる")
    func convertedPatternsMatchTheSameInputs() throws {
        let cases: [(legacy: String, matches: [String], rejects: [String])] = [
            ("第??巻", ["作品 第01巻", "作品 第３巻", "作品 第3.5巻"], ["作品 第巻"]),
            ("??巻",   ["作品 12巻"],                                  ["作品 巻"]),
            ("vol.??", ["作品 vol.7"],                                 ["作品 volX7"]),
            ("vol<space>??", ["作品 vol 12", "作品 vol　12"],           ["作品 vol12"]),
            ("v??",    ["作品 v3"],                                     ["作品 v"]),
        ]
        for c in cases {
            let patterns = VolumePatternCompiler.compileAll([
                VolumePattern(source: LegacyVolumeNotation.regex(fromVolumeSource: c.legacy)),
            ])
            for input in c.matches {
                #expect(VolumeMatcher.matchAtEnd(Array(input), patterns: patterns) != nil,
                        "\(c.legacy) が \(input) に当たらない")
            }
            for input in c.rejects {
                #expect(VolumeMatcher.matchAtEnd(Array(input), patterns: patterns) == nil,
                        "\(c.legacy) が \(input) に当たってしまう")
            }
        }
    }

    /// 旧実装は「キーの空白 1 個 = 入力の空白 1 個以上」という弾力的な照合をしていた
    /// [PT-04]。素直にエスケープするとこの性質が失われる。
    @Test("保護文字列の空白は弾力的なまま移る")
    func protectedLiteralKeepsElasticWhitespace() throws {
        let converted = LegacyVolumeNotation.regex(fromProtectedLiteral: "(完全 版)")
        #expect(converted == #"\(完全\s+版\)"#)
        let tokens = ProtectedTokenCompiler.compileAll([ProtectedToken(pattern: converted)])
        // 全角括弧・全角の連続空白でも当たる（畳んだ射影に対して照合するため）。
        let input = ProtectedTokenMasker.mask("A （完全　　版） B", tokens: tokens)
        #expect(input.maskedChars.count == 5)
    }
}

// MARK: - 保護文字列

@Suite("保護文字列の正規表現化 [PT-01〜PT-11]")
struct ProtectedTokenRegexTests {
    func mask(_ text: String, _ patterns: [String],
              position: ProtectedToken.Position = .anywhere) -> ParseInput {
        ProtectedTokenMasker.mask(text, tokens: ProtectedTokenCompiler.compileAll(
            patterns.map { ProtectedToken(pattern: $0, position: position) }))
    }

    /// これが正規表現化のいちばんの目的——`(1999)`〜`(2024)` を 1 本で書ける。
    @Test("括弧の中の年号をまとめて保護できる")
    func yearInParenthesesIsOneToken() {
        for year in ["(1999)", "(2019)", "(2024)"] {
            let input = mask("作品名 \(year)", [#"\((19|20)[0-9]{2}\)"#])
            #expect(input.maskedChars.count == 5, "\(year)")   // 作品名(3) + 空白 + PUA
            #expect(ProtectedTokenMasker.isPlaceholder(input.maskedChars[4]), "\(year)")
        }
        // 年号でない 4 桁は保護しない。
        let other = mask("作品名 (1234)", [#"\((19|20)[0-9]{2}\)"#])
        #expect(other.maskedChars.count == "作品名 (1234)".count)
    }

    @Test("大文字小文字を無視する [PT-04]")
    func caseInsensitive() {
        let input = mask("A (Complete) B", [#"\(complete\)"#])
        #expect(ProtectedTokenMasker.isPlaceholder(input.maskedChars[2]))
    }

    @Test("位置指定が効く [PT-05]")
    func positionConstraint() {
        let atEnd = mask("(完) 作品", [#"\(完\)"#], position: .suffix)
        #expect(atEnd.maskedChars.count == "(完) 作品".count)   // 先頭なのでマスクされない
        let ok = mask("作品 (完)", [#"\(完\)"#], position: .suffix)
        #expect(ok.maskedChars.count == 4)
    }

    @Test("重なる候補は左端優先・同じ左端なら長い方 [PT-06]")
    func leftmostLongestWins() {
        let input = mask("A (完全版) B", [#"\(完全\)"#, #"\(完全版\)"#])
        #expect(input.maskedChars.count == 5)
        #expect(input.originalText(of: 2..<3) == "(完全版)")
    }

    /// 長さ 0 の一致を採ると、マスクが際限なく増えて PUA を食い潰す。
    @Test("空に一致するパターンでマスクが暴走しない")
    func zeroLengthMatchesAreIgnored() {
        let input = mask("作品名", ["x*"])
        #expect(input.maskedChars.count == 3)
    }
}

// MARK: - JSON バックアップの後方互換

@Suite("版 1 のバックアップを読めること [IE-14][JS-09]")
struct LegacyBackupDecodingTests {
    /// **以前書き出した文書を読めなくしないこと。** 版 1 は巻数フォーマットが
    /// `??` / `<space>` の独自記法で、序列を `ordinalRank` で表していた。
    @Test("版 1 の巻数フォーマットが正規表現と種別へ変換される")
    func decodesLegacyVolumeFormat() throws {
        let json = """
        [
          {"source": "第??巻", "priority": 0, "isEnabled": true},
          {"source": "上巻", "priority": 1, "isEnabled": true, "ordinalRank": 1}
        ]
        """
        let decoded = try JSONDecoder().decode([VolumeFormatBackup].self, from: Data(json.utf8))
        #expect(decoded[0].source == #"第([0-9]+(?:\.[0-9]+)?)巻"#)
        #expect(decoded[0].kind == VolumePatternKind.volume.rawValue)
        // 序列巻数だったものは「区切り専用」になる。
        #expect(decoded[1].kind == VolumePatternKind.separator.rawValue)
    }

    @Test("版 2 の文書はそのまま読む")
    func decodesCurrentVolumeFormat() throws {
        let json = """
        [{"source": "第([0-9]+)巻", "priority": 0, "isEnabled": true, "kind": "separator"}]
        """
        let decoded = try JSONDecoder().decode([VolumeFormatBackup].self, from: Data(json.utf8))
        #expect(decoded[0].source == "第([0-9]+)巻")       // 二重変換されない
        #expect(decoded[0].kind == "separator")
    }

    @Test("版 1 の保護文字列がエスケープされた正規表現になる")
    func decodesLegacyProtectedToken() throws {
        let json = """
        [{"text": "(完全 版)", "position": "suffix", "isEnabled": true}]
        """
        let decoded = try JSONDecoder().decode([ProtectedTokenBackup].self, from: Data(json.utf8))
        #expect(decoded[0].pattern == #"\(完全\s+版\)"#)
    }

    @Test("書き出しは新しいキーだけを使う")
    func encodesNewKeysOnly() throws {
        let data = try JSONEncoder().encode(
            VolumeFormatBackup(source: "x", priority: 0, isEnabled: true, kind: "volume"))
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"kind\""))
        #expect(!text.contains("ordinalRank"))
    }

    @Test("往復して同じになる")
    func roundTrips() throws {
        let original = ProtectedTokenBackup(pattern: #"\((19|20)[0-9]{2}\)"#,
                                            position: "anywhere", isEnabled: true)
        let decoded = try JSONDecoder().decode(
            ProtectedTokenBackup.self, from: try JSONEncoder().encode(original))
        #expect(decoded == original)
    }
}

// MARK: - 保存時の検証

@Suite("巻数フォーマットの検証 [LibrarySettingsDraft.validate]")
struct VolumeFormatValidationTests {
    /// 検証したいのは巻数フォーマットだけなので、他が原因のエラーを混ぜない。
    func draft(_ patterns: [VolumeFormatDraft]) -> LibrarySettingsDraft {
        LibrarySettingsDraft(displayName: "L", libraryTypeName: "T",
                             targetExtensions: ["cbz"], volumeFormats: patterns)
    }

    func volumeIssues(_ source: String, kind: VolumePatternKind = .volume) -> [LibrarySettingsIssue] {
        draft([VolumeFormatDraft(source: source, kind: kind)])
            .validate().filter { $0.section == .volumeFormats }
    }

    @Test("正しいパターンは何も言われない")
    func validPatternIsClean() {
        #expect(volumeIssues(#"第([0-9]+)巻"#).isEmpty)
        #expect(volumeIssues(#"(?<volume>[0-9]+)巻"#).isEmpty)
    }

    /// **巻数の値をどこから取るかが決まらない。** 巻数 0 と誤って扱うより、
    /// 保存の時点で知らせるほうがよい。
    @Test("キャプチャグループが無い巻数パターンはエラー")
    func missingCaptureGroupIsAnError() {
        let issues = volumeIssues("第[0-9]+巻")
        #expect(issues.contains { $0.severity == .error })
    }

    @Test("キャプチャが複数あって名前が無ければエラー")
    func ambiguousCaptureGroupIsAnError() {
        let issues = volumeIssues("(第)([0-9]+)巻")
        #expect(issues.contains { $0.severity == .error })
    }

    @Test("名前付きグループがあれば複数キャプチャでもよい")
    func namedGroupResolvesAmbiguity() {
        #expect(volumeIssues(#"(第)(?<volume>[0-9]+)巻"#).isEmpty)
    }

    /// 区切り専用は値を取らないので、キャプチャの有無を問わない。
    @Test("区切り専用はキャプチャが無くてもよい")
    func separatorNeedsNoCapture() {
        #expect(volumeIssues("上巻", kind: .separator).isEmpty)
        #expect(volumeIssues("(上巻|下巻)", kind: .separator).isEmpty)
    }

    @Test("読めない正規表現はエラー")
    func invalidRegexIsAnError() {
        #expect(volumeIssues("第([0-9]+巻").contains { $0.severity == .error })
    }

    /// **実行時は `SafeRegex` のウォッチドッグが必ず打ち切る**ので、危ないという
    /// だけで保存を止める理由が無い [三層防御の ①]。
    @Test("危ない形は警告にとどめる（保存はできる）")
    func dangerousPatternIsOnlyAWarning() {
        // キャプチャは 1 つ（中は非キャプチャ）なので、警告の理由は「量指定子の
        // 付いたグループ」だけになる。
        let issues = volumeIssues(#"((?:[0-9]+)+)巻"#)
        #expect(issues.contains { $0.severity == .warning })
        #expect(!issues.contains { $0.severity == .error })
    }

    @Test("保護文字列も同じ検証を受ける")
    func protectedTokensAreValidated() {
        let d = LibrarySettingsDraft(displayName: "L", libraryTypeName: "T",
                                     targetExtensions: ["cbz"],
                                     protectedTokens: [ProtectedToken(pattern: "(")])
        #expect(d.validate().contains { $0.section == .protectedTokens && $0.severity == .error })
    }

    /// 実測は `validate()` ではなく `measuredIssues()` の担当。**入力のたびに
    /// 走らせると、危険な正規表現を直している最中に画面が重くなる。**
    @Test("実測は validate には含まれず measuredIssues が担う")
    func measurementIsSeparate() {
        let d = draft([VolumeFormatDraft(source: #"((?:[0-9]+)+)巻"#)])
        let slowMarker = "時間の上限に達しました"
        #expect(!d.validate().contains { $0.message.contains(slowMarker) })
        #expect(d.measuredIssues().contains { $0.message.contains(slowMarker) })
    }
}

// MARK: - 既定の保護文字列

@Suite("既定の保護文字列 [PT-01、2026-08 のユーザー要望]")
struct DefaultProtectedTokenTests {
    /// **既定値の出どころが 1 つであること。** テンプレートからの草案と、
    /// テンプレートから直に作るスナップショットで食い違うと、設定画面で見た
    /// 挙動と実際に登録されたライブラリの挙動がずれる。
    @Test("テンプレート由来の草案に既定が入る")
    func draftCarriesDefaults() throws {
        let templates = try BuiltInTemplates.libraryTypes()
        let sets = try BuiltInTemplates.volumeSets()
        let preset = try #require(templates.first)
        let draft = try TemplateInstantiation.draft(from: preset, volumeSets: sets,
                                                    displayName: "L")
        #expect(draft.protectedTokens.map(\.pattern)
                == AppDefaults.Library.protectedTokenPatterns)
    }

    @Test("白紙の草案にも同じ既定が入る")
    func blankDraftCarriesDefaults() throws {
        let sets = try BuiltInTemplates.volumeSets()
        let draft = TemplateInstantiation.blankDraft(
            volumeSets: sets, displayName: "L", defaultLabelGroupName: "G")
        #expect(draft.protectedTokens.map(\.pattern)
                == AppDefaults.Library.protectedTokenPatterns)
    }

    @Test("既定は正規表現として正しく、警告も出ない")
    func defaultsAreClean() {
        for pattern in AppDefaults.Library.protectedTokenPatterns {
            #expect(RegexSafety.staticFindings(pattern).isEmpty, "\(pattern)")
        }
    }

    /// 既定を入れた狙いはこれ——`(2019)` が巻数と誤読されたり、括弧が
    /// フィールドの境界と見なされたりしないようにする。
    @Test("括弧の中の年号と完結の印が 1 かたまりになる")
    func defaultsProtectYearsAndCompletionMarks() {
        let tokens = ProtectedTokenCompiler.compileAll(
            AppDefaults.Library.protectedTokenPatterns.map { ProtectedToken(pattern: $0) })
        for mark in ["(1999)", "(2024)", "(完結)", "(完全版)", "(終)"] {
            let input = ProtectedTokenMasker.mask("作品名 \(mark)", tokens: tokens)
            #expect(input.maskedChars.count == 5, "\(mark)")
            #expect(ProtectedTokenMasker.isPlaceholder(input.maskedChars[4]), "\(mark)")
        }
        // 年号でない 4 桁や、無関係な語は保護しない。
        for other in ["(1234)", "(未完)"] {
            let input = ProtectedTokenMasker.mask("作品名 \(other)", tokens: tokens)
            #expect(input.maskedChars.count == "作品名 \(other)".count, "\(other)")
        }
    }
}
