import Testing
import Foundation
@testable import QooKit

// MARK: - 03章 §3.1 の例（仕様書の表をそのまま固定する）

@Suite("TextNormalizer — 仕様書 03章 §3.1 の例")
struct TextNormalizerSpecExamples {
    @Test("NFD の漢字は NFC になる")
    func nfdBecomesNFC() {
        let nfd = "佐藤秀峰".decomposedStringWithCanonicalMapping
        let out = TextNormalizer.normalize(nfd)
        #expect(out == "佐藤秀峰")
        #expect(out.unicodeScalars.count == "佐藤秀峰".precomposedStringWithCanonicalMapping.unicodeScalars.count)
    }

    @Test("全角英数と全角スペースが半角になり小文字化される")
    func fullwidthBecomesHalfwidth() {
        #expect(TextNormalizer.normalize("ＡＢＣ　１２３") == "abc 123")
    }

    @Test("連続する空白は 1 個に畳まれ前後がトリムされる")
    func whitespaceCollapses() {
        #expect(TextNormalizer.normalize("  ブラック  ジャック  ") == "ブラック ジャック")
    }

    @Test("全角数字を含む巻数表記")
    func volumeLikeInput() {
        #expect(TextNormalizer.normalize("Vol.１２") == "vol.12")
    }
}

// MARK: - 不変条件

@Suite("TextNormalizer — 不変条件")
struct TextNormalizerInvariants {
    /// 実データに現れる形を標本にする。**きれいな例だけを標本にすると、
    /// その分野で最も普通の入力を取りこぼす**（CLAUDE.md の記録）。
    static let samples: [String] = [
        "(同人誌) [サークル名 (作家名)] タイトル 総集編 (オリジナル)",
        "(成年コミック) [作者名] タイトル～サブタイトル～",
        "【C99】作品名 → 続編、その2「完全版」 (1:2)",
        "著者名 タイトル 第01巻",
        "ＡＢＣ　１２３",
        "  前後に空白  ",
        "ば　び\tぶ\u{00A0}べ ぼ",
        "ロングーバケーション",          // 長音。CFStringTransform だと壊れる
        "ｶﾞｷﾞｸﾞ",                        // 半角カナ。変換してはならない
        "",
        " ",
        "　",
        "パピプペポ".decomposedStringWithCanonicalMapping,
        "İstanbul",
        "🍣寿司🍣",
    ]

    @Test("normalize は冪等である", arguments: samples)
    func idempotent(_ s: String) {
        let once = TextNormalizer.normalize(s)
        #expect(TextNormalizer.normalize(once) == once)
    }

    @Test("normalize の出力は NFC である", arguments: samples)
    func outputIsNFC(_ s: String) {
        let out = TextNormalizer.normalize(s)
        #expect(out == out.precomposedStringWithCanonicalMapping)
    }

    @Test("同じ入力は常に同じ出力（純粋関数）[NM-04]", arguments: samples)
    func deterministic(_ s: String) {
        #expect(TextNormalizer.normalize(s) == TextNormalizer.normalize(s))
    }

    @Test("NFD と NFC の入力は同じ結果になる [N-01][R-03]", arguments: samples)
    func nfdAndNFCAgree(_ s: String) {
        #expect(TextNormalizer.normalize(s.decomposedStringWithCanonicalMapping)
                == TextNormalizer.normalize(s.precomposedStringWithCanonicalMapping))
    }

    @Test("display は原文をそのまま返す [N-02][N-03]")
    func displayIsIdentity() {
        for s in Self.samples { #expect(TextNormalizer.display(s) == s) }
    }

    @Test("大文字・小文字は常に同一視する（小文字へ畳む）［N-04 撤回］")
    func caseIsAlwaysFolded() {
        #expect(TextNormalizer.normalize("AbC") == "abc")
    }
}

// MARK: - NM-01 / NM-02: 壊してはならないもの

@Suite("TextNormalizer — 変換してはならないもの [NM-01][NM-02]")
struct TextNormalizerPreservation {
    @Test("長音「ー」を変換しない。CFStringTransform はこれを壊す")
    func longVowelMarkSurvives() {
        // 実コーパス 2,953 件のうち 26.3%（778 件）が長音を含む。
        #expect(TextNormalizer.normalize("ロングーバケーション") == "ロングーバケーション")
        #expect(TextNormalizer.normalize("ー") == "ー")
    }

    @Test("半角カナを変換しない [NM-02]")
    func halfwidthKanaSurvives() {
        #expect(TextNormalizer.normalize("ｶﾞｷﾞｸﾞ") == "ｶﾞｷﾞｸﾞ".precomposedStringWithCanonicalMapping)
    }

    @Test("全角カナを半角にしない")
    func fullwidthKanaSurvives() {
        #expect(TextNormalizer.normalize("パピプペポ") == "パピプペポ")
    }

    @Test("波ダッシュ・ハイフン類はそのまま（実データの 7.9% に現れる）")
    func dashesSurvive() {
        #expect(TextNormalizer.normalize("〜") == "〜")
        #expect(TextNormalizer.normalize("‐–—") == "‐–—")
        // 全角ハイフンマイナス U+FF0D は U+FF01〜FF5E の範囲なので半角へ畳む
        #expect(TextNormalizer.normalize("－") == "-")
    }

    @Test("BMP 外の文字（絵文字）を壊さない")
    func astralPlaneSurvives() {
        #expect(TextNormalizer.normalize("🍣寿司🍣") == "🍣寿司🍣")
    }
}

// MARK: - WidthFolding

@Suite("WidthFolding")
struct WidthFoldingTests {
    @Test("U+FF01〜U+FF5E の全域が半角へ畳まれる")
    func fullRangeFolds() {
        for v in UInt32(0xFF01)...UInt32(0xFF5E) {
            let s = Unicode.Scalar(v)!
            #expect(WidthFolding.fold(s).value == v - 0xFEE0)
        }
    }

    @Test("U+3000 は半角スペースへ")
    func ideographicSpaceFolds() {
        #expect(WidthFolding.fold(Unicode.Scalar(0x3000)!) == " ")
    }

    @Test("半角カナ U+FF61〜U+FF9F は畳まない [NM-02]")
    func halfwidthKanaUntouched() {
        for v in UInt32(0xFF61)...UInt32(0xFF9F) {
            let s = Unicode.Scalar(v)!
            #expect(WidthFolding.fold(s) == s)
        }
    }

    @Test("畳んでもスカラー数が変わらない（添字の一対一対応を支える性質）")
    func lengthPreserved() {
        for s in TextNormalizerInvariants.samples {
            #expect(WidthFolding.fold(s).unicodeScalars.count == s.unicodeScalars.count)
            #expect(WidthFolding.fold(s).count == s.count)
        }
    }

    @Test("畳む必要がなければ元の文字列を返す")
    func noFoldingNeeded() {
        #expect(WidthFolding.needsFolding("abc") == false)
        #expect(WidthFolding.needsFolding("ＡＢＣ") == true)
        #expect(WidthFolding.needsFolding("　") == true)
        #expect(WidthFolding.fold("abc") == "abc")
    }
}

// MARK: - trimWhitespace / canonicalWidth

@Suite("trimWhitespace / canonicalWidth")
struct TrimAndCanonicalWidthTests {
    @Test("前後の空白だけを落とし、内部は保つ [WS-05]")
    func trimsOnlyEdges() {
        #expect(TextNormalizer.trimWhitespace("  ブラック  ジャック  ") == "ブラック  ジャック")
        #expect(TextNormalizer.trimWhitespace("　全角　") == "全角")
        #expect(TextNormalizer.trimWhitespace("\tタブ\t") == "タブ")
        #expect(TextNormalizer.trimWhitespace("\u{00A0}NBSP\u{00A0}") == "NBSP")
    }

    @Test("空白だけの文字列は空になる")
    func allWhitespace() {
        #expect(TextNormalizer.trimWhitespace("   ") == "")
        #expect(TextNormalizer.trimWhitespace("　\t ") == "")
        #expect(TextNormalizer.trimWhitespace("") == "")
    }

    @Test("canonicalWidth は内部の空白を畳まない [WS-05]")
    func canonicalWidthKeepsInnerSpaces() {
        #expect(TextNormalizer.canonicalWidth("Ａ　Ｂ  Ｃ") == "A B  C")
        #expect(TextNormalizer.canonicalWidth("  前後  ") == "  前後  ")
    }

    @Test("canonicalWidth はケースを変えない")
    func canonicalWidthKeepsCase() {
        #expect(TextNormalizer.canonicalWidth("ＡｂＣ") == "AbC")
    }
}

// MARK: - searchKey

@Suite("searchKey [SR-06][DB-03]")
struct SearchKeyTests {
    @Test("ひらがなはカタカナへ統一される")
    func hiraganaBecomesKatakana() {
        #expect(TextNormalizer.searchKey("ぶらっくじゃっく") == "ブラックジャック")
        #expect(TextNormalizer.searchKey("ぁぃぅぇぉ") == "ァィゥェォ")
    }

    @Test("normalize の効果も併せて効く")
    func inheritsNormalize() {
        #expect(TextNormalizer.searchKey("　ＡＢＣ　あいう　") == "abc アイウ")
    }

    @Test("カタカナはそのまま")
    func katakanaUnchanged() {
        #expect(TextNormalizer.searchKey("ブラックジャック") == "ブラックジャック")
    }

    @Test("ひらがなを含まなければ normalize と同じ")
    func noHiraganaShortcut() {
        #expect(TextNormalizer.searchKey("ＡＢＣ") == TextNormalizer.normalize("ＡＢＣ"))
    }

    @Test("結合濁点はカタカナと共通なので位置がずれない")
    func combiningVoicedMarkStable() {
        // NFC 済みなので「ば」は 1 スカラー。カタカナ化して「バ」になる。
        #expect(TextNormalizer.searchKey("ばびぶべぼ") == "バビブベボ")
    }

    @Test("冪等である")
    func idempotent() {
        for s in TextNormalizerInvariants.samples {
            let once = TextNormalizer.searchKey(s)
            #expect(TextNormalizer.searchKey(once) == once)
        }
    }

    /// 対応表は `compactMap` で作るため、無効なスカラーがあれば黙って縮む。
    /// 縮んでいれば添字がずれて誤変換になるので、長さと両端を固定する。
    @Test("ひらがな→カタカナ対応表が欠けていない")
    func katakanaTableIsComplete() {
        #expect(TextNormalizer.katakanaTable.count == TextNormalizer.katakanaTableExpectedCount)
        #expect(TextNormalizer.katakana(for: Unicode.Scalar(0x3041)!) == Unicode.Scalar(0x30A1)!) // ぁ→ァ
        #expect(TextNormalizer.katakana(for: Unicode.Scalar(0x3096)!) == Unicode.Scalar(0x30F6)!) // ゖ→ヶ
        #expect(TextNormalizer.katakana(for: Unicode.Scalar(0x309D)!) == Unicode.Scalar(0x30FD)!) // ゝ→ヽ
        #expect(TextNormalizer.katakana(for: Unicode.Scalar(0x309E)!) == Unicode.Scalar(0x30FE)!) // ゞ→ヾ
        // 範囲外は素通し
        #expect(TextNormalizer.katakana(for: Unicode.Scalar(0x30A2)!) == Unicode.Scalar(0x30A2)!) // ア
        #expect(TextNormalizer.katakana(for: Unicode.Scalar(0x3099)!) == Unicode.Scalar(0x3099)!) // 結合濁点
    }
}

// MARK: - NormalizedString

@Suite("NormalizedString [N-03][NM-06]")
struct NormalizedStringTests {
    @Test("原文が違っても正規化が同じなら等しい")
    func equalityUsesKey() {
        let a = NormalizedString("ＡＢＣ")
        let b = NormalizedString("abc")
        #expect(a == b)
        #expect(a.raw == "ＡＢＣ")      // 表示は原文のまま [N-03]
        #expect(b.raw == "abc")
        #expect(Set([a, b]).count == 1)
    }

    @Test("NFD と NFC の原文は同一視される [R-03]")
    func nfdAndNFCUnify() {
        let nfd = NormalizedString("パピプペポ".decomposedStringWithCanonicalMapping)
        let nfc = NormalizedString("パピプペポ".precomposedStringWithCanonicalMapping)
        #expect(nfd == nfc)
        #expect(Set([nfd, nfc]).count == 1)
    }

    @Test("空判定は key を見る")
    func isEmptyUsesKey() {
        #expect(NormalizedString("   ").isEmpty)
        #expect(NormalizedString("").isEmpty)
        #expect(!NormalizedString(" a ").isEmpty)
    }

    @Test("保存済みの値から復元できる")
    func restoreFromStorage() {
        let r = NormalizedString(raw: "佐藤秀峰", key: "佐藤秀峰")
        #expect(r.raw == "佐藤秀峰")
        #expect(r.description == "佐藤秀峰")
    }
}

// MARK: - Whitespace

@Suite("Whitespace [WS-03][WS-04][NM-03]")
struct WhitespaceTests {
    @Test("空白とみなす文字 [NM-03]")
    func whitespaceSet() {
        for c in [" ", "　", "\t", "\u{00A0}", "\n", "\r"] {
            #expect(Whitespace.isWhitespace(Character(c)), "\(c.unicodeScalars.first!)")
        }
        for c in ["a", "あ", "ー", "-"] {
            #expect(!Whitespace.isWhitespace(Character(c)))
        }
    }

    @Test("合成文字は空白ではない")
    func combinedGraphemeIsNotWhitespace() {
        #expect(!Whitespace.isWhitespace(Character("が".decomposedStringWithCanonicalMapping)))
    }

    @Test("フォーマットの保存時正規化: 連続空白 → 半角 1 個 [WS-02][WS-03]")
    func normalizeLiteral() {
        // WSI-01: `] @title` `]@title` `]　@title` はいずれも `] @title` になる…
        // ではなく、空白の有無自体は保たれる（弾力的空白 WS-01 が照合時に吸収する）。
        #expect(Whitespace.normalizeLiteral("] @title") == "] @title")
        #expect(Whitespace.normalizeLiteral("]@title") == "]@title")
        #expect(Whitespace.normalizeLiteral("]　@title") == "] @title")
        #expect(Whitespace.normalizeLiteral("]   @title") == "] @title")
        #expect(Whitespace.normalizeLiteral("]\t\t@title") == "] @title")
    }

    @Test("先頭・末尾の空白は 1 個に畳んで残す")
    func edgesCollapseButRemain() {
        #expect(Whitespace.normalizeLiteral("  a  ") == " a ")
        #expect(Whitespace.normalizeLiteral("") == "")
        #expect(Whitespace.normalizeLiteral("   ") == " ")
    }
}

// MARK: - searchKey(joining:)

@Suite("複数の値をまとめた検索キー [SR-03]")
struct SearchKeyJoiningTests {

    @Test("部品ごとに正規化してから繋ぐ")
    func normalizesEachPart() throws {
        let key = TextNormalizer.searchKey(joining: ["ＡＢＣ", "ぶらっく", nil])
        #expect(key == "abc\u{1F}ブラック")
    }

    @Test("nil と空は落とす")
    func dropsEmptyParts() throws {
        #expect(TextNormalizer.searchKey(joining: [nil, "", "   ", "あ"]) == "ア")
        #expect(TextNormalizer.searchKey(joining: [nil, nil]).isEmpty)
    }

    /// ファイル名の stem がタイトルと一致するのは自動抽出ではごく普通で、
    /// 落とさないと索引 `mf_search` が理由もなく倍の大きさになる。
    @Test("同じ値は 1 つだけ持つ")
    func dropsDuplicates() throws {
        #expect(TextNormalizer.searchKey(joining: ["作品", "作品"]) == "作品")
        // 正規化した結果が同じなら 1 つ（全角と半角）。
        #expect(TextNormalizer.searchKey(joining: ["ＡＢＣ", "abc"]) == "abc")
    }

    /// **これがこの関数の存在理由。** 空白で繋ぐと `normalize` の空白畳み込みで
    /// 1 本の文字列になり、部品をまたいだ語が当たってしまう。
    @Test("区切りは normalize を素通りし、空白にならない")
    func theSeparatorSurvivesNormalization() throws {
        let key = TextNormalizer.searchKey(joining: ["ゼータ", "イータ"])
        #expect(key.contains(TextNormalizer.searchKeyPartSeparator))
        // 問い合わせ側の鍵は 1 部品なので、区切りを含む形には決してならない。
        let query = TextNormalizer.searchKey("ゼータ イータ")
        #expect(!query.contains(TextNormalizer.searchKeyPartSeparator))
        #expect(!key.contains(query), "部品をまたいで一致してはいけない")
    }

    @Test("区切り自体は空白でも全角の写像域でもない")
    func theSeparatorIsNotWhitespaceOrFolded() throws {
        let sep = TextNormalizer.searchKeyPartSeparator
        #expect(!Whitespace.isWhitespace(sep))
        #expect(TextNormalizer.normalize(String(sep)) == String(sep))
    }
}
