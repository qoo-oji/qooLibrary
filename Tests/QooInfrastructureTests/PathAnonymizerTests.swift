import Foundation
import Testing

@testable import QooInfrastructure

/// パス匿名化 [LG2-06][CB-23] の検証。
@Suite struct PathAnonymizerTests {
    private let anonymizer = PathAnonymizer(salt: "test-salt")

    @Test func sameAbsolutePathAlwaysProducesTheSameToken() {
        // [CB-23] 追跡可能性の維持。別インスタンスでも同じソルトなら一致する。
        let other = PathAnonymizer(salt: "test-salt")
        let path = "/Volumes/External/Comics/Series/Vol01.cbz"

        #expect(anonymizer.anonymizePath(path) == anonymizer.anonymizePath(path))
        #expect(anonymizer.anonymizePath(path) == other.anonymizePath(path))
    }

    @Test func differentSaltsProduceDifferentTokens() {
        let path = "/Volumes/External/Comics"
        #expect(anonymizer.anonymizePath(path) != PathAnonymizer(salt: "other-salt").anonymizePath(path))
    }

    @Test func siblingFilesKeepTheirSharedParentTokens() {
        // 成分ごとに置換する狙いはここ: 「同じフォルダにある別ファイル」が
        // ログ上で追える。
        let first = anonymizer.anonymizePath("/Volumes/External/Comics/Series/Vol01.cbz")
        let second = anonymizer.anonymizePath("/Volumes/External/Comics/Series/Vol02.cbz")

        let firstComponents = first.split(separator: "/").map(String.init)
        let secondComponents = second.split(separator: "/").map(String.init)

        #expect(firstComponents.count == secondComponents.count)
        #expect(firstComponents.dropLast() == secondComponents.dropLast())
        #expect(firstComponents.last != secondComponents.last)
    }

    @Test func identicallyNamedFoldersInDifferentPlacesGetDifferentTokens() {
        // 成分名ではなく「そこまでのパス接頭辞」からトークンを導くため、
        // 別の場所にある同名フォルダが同一視されない。
        let a = anonymizer.anonymizePath("/Volumes/A/Comics")
        let b = anonymizer.anonymizePath("/Volumes/B/Comics")
        #expect(a.split(separator: "/").last != b.split(separator: "/").last)
    }

    @Test func lastComponentKeepsItsExtension() {
        #expect(anonymizer.anonymizePath("/Volumes/External/Vol01.cbz").hasSuffix(".cbz"))
        #expect(anonymizer.anonymizePath("/Volumes/External/movie.mkv").hasSuffix(".mkv"))
        // 拡張子を持たないフォルダには何も足さない。
        #expect(!anonymizer.anonymizePath("/Volumes/External/Comics").contains("."))
    }

    @Test func wellKnownComponentsAreKeptVerbatim() {
        let anonymized = anonymizer.anonymizePath("/Users/someone/Documents/Secret.cbz")
        #expect(anonymized.hasPrefix("/Users/"))
        #expect(anonymized.contains("/Documents/"))
        // ユーザー名は個人を特定し得るので必ず置換される。
        #expect(!anonymized.contains("someone"))
        #expect(!anonymized.contains("Secret"))
    }

    @Test func fullyStandardPathIsUnchanged() {
        let path = "/Library/Application Support/qooLibrary/Logs"
        #expect(anonymizer.anonymizePath(path) == path)
    }

    @Test func relativePathsAndPlainTextAreUntouched() {
        #expect(anonymizer.anonymizePath("Comics/Vol01.cbz") == "Comics/Vol01.cbz")
        #expect(anonymizer.anonymize("圧縮完了: 12 件 / 比率 3/4") == "圧縮完了: 12 件 / 比率 3/4")
    }

    @Test func replacesPathsEmbeddedInALogLine() {
        let line = "2026-08-14 12:00:00.000+09:00 [I] [FileOps] move 完了: /Volumes/External/A.cbz → /Volumes/External/Sub/"
        let anonymized = anonymizer.anonymize(line)

        #expect(anonymized.hasPrefix("2026-08-14 12:00:00.000+09:00 [I] [FileOps] move 完了: "))
        #expect(!anonymized.contains("External"))
        #expect(!anonymized.contains("A.cbz"))
        #expect(anonymized.contains(".cbz")) // 拡張子は残る
        #expect(anonymized.contains("/Volumes/"))
        #expect(anonymized.hasSuffix("/")) // 末尾スラッシュの形を保つ
    }

    @Test func markedPathsKeepTheProseAroundThemIntact() {
        // 印で範囲が明示されていれば、直後の文字がパスに巻き込まれない。
        let anonymized = anonymizer.anonymize("見つかりません: \(Log.path("/Volumes/External/Missing.cbz"))。")
        #expect(anonymized.hasSuffix(".cbz。"))
        #expect(!anonymized.contains("Missing"))
    }

    @Test func unmarkedPathsAbsorbTrailingPunctuationRatherThanLeakingIt() {
        // 印の無い素のパス（`localizedDescription` など）では、末尾の記号が
        // ファイル名の一部かどうかを判別できない。`作品名！` のように名前の
        // 末尾が記号で終わることは珍しくないため、**パス側へ含める**
        // （＝ハッシュ化する）安全な方に倒している。
        let anonymized = anonymizer.anonymize("見つかりません: /Volumes/External/Missing.cbz。")
        #expect(!anonymized.contains("Missing"))
        #expect(anonymized.hasPrefix("見つかりません: /Volumes/"))
    }

    @Test func fileURLFormKeepsItsSchemeAndSlashes() {
        let anonymized = anonymizer.anonymize("url=file:///Volumes/External/A.cbz")
        #expect(anonymized.hasPrefix("url=file:///Volumes/"))
        #expect(!anonymized.contains("External"))
    }

    @Test func markedNamesAreRedactedEvenWithoutAnAbsolutePath() {
        // [LG2-06] 絶対パスが手元に無いユーザー由来の名前
        // （解決できない登録フォルダの表示名、アーカイブ内のエントリ名）は
        // `Log.redactable(_:)` の印を頼りに匿名化する。
        let line = "登録フォルダのブックマークを解決できません: \(Log.redactable("マイ作品集")) (library)"
        let anonymized = anonymizer.anonymize(line)

        #expect(!anonymized.contains("マイ作品集"))
        // 印は出力に残さない（読む人には不要な目印のため）。
        #expect(!anonymized.contains(PathAnonymizer.redactionOpen))
        #expect(anonymized.hasPrefix("登録フォルダのブックマークを解決できません: "))
        #expect(anonymized.hasSuffix(" (library)"))
    }

    @Test func theSameMarkedNameAlwaysProducesTheSameToken() {
        let a = anonymizer.anonymize(Log.redactable("同じ名前"))
        let b = anonymizer.anonymize("別の行: \(Log.redactable("同じ名前"))")
        #expect(!a.isEmpty)
        #expect(b.hasSuffix(a))
    }

    @Test func textWithoutMarkersIsLeftAlone() {
        let line = "展開完了: 12 件 / 拒否 0 件"
        #expect(anonymizer.anonymize(line) == line)
    }

    @Test func anUnclosedMarkerDoesNotSwallowTheRestOfTheLine() {
        // 印が壊れていても（閉じ括弧が無い）、残りの行を失わない。
        #expect(anonymizer.anonymize("壊れた印: ⟨開いたまま") == "壊れた印: ⟨開いたまま")
        #expect(anonymizer.anonymize("壊れた印: ⟪開いたまま") == "壊れた印: ⟪開いたまま")
    }

    @Test func namesInsideQuotesAreRedactedAsASafetyNet() {
        // [LG2-06 の安全網] 絶対パスでも `Log.redactable(_:)` の印でもない
        // 自由文のエラーメッセージ（`FileOperationService` が投げる文言や
        // Foundation の `localizedDescription`）向け。
        let line = "エラー: 「作品A 第01巻.cbz」という名前の項目はすでに存在します。"
        let anonymized = anonymizer.anonymize(line)

        #expect(!anonymized.contains("作品A"))
        #expect(!anonymized.contains("第01巻"))
        #expect(anonymized.hasPrefix("エラー: 「"))
        #expect(anonymized.hasSuffix("」という名前の項目はすでに存在します。"))
    }

    @Test func redactsTheCurlyQuotesFoundationUsesInItsErrorMessages() {
        // Foundation は “foo.txt” couldn't be moved… の形で名前を埋め込む。
        let line = "move に失敗: \u{201C}Secret.cbz\u{201D} couldn\u{2019}t be moved."
        let anonymized = anonymizer.anonymize(line)

        #expect(!anonymized.contains("Secret"))
        #expect(anonymized.contains("\u{201C}"))
        #expect(anonymized.contains("couldn\u{2019}t be moved."))
    }

    @Test func theSameQuotedNameAlwaysProducesTheSameToken() {
        let a = anonymizer.anonymize("「同じ名前」")
        let b = anonymizer.anonymize("別の行: 「同じ名前」を移動")
        #expect(b.contains(a.trimmingCharacters(in: CharacterSet(charactersIn: "「」"))))
    }

    @Test func anUnclosedQuoteDoesNotSwallowTheRestOfTheLine() {
        let line = "壊れた引用: 「閉じていない"
        #expect(anonymizer.anonymize(line) == line)
    }

    @Test func emptyQuotesAreLeftAlone() {
        #expect(anonymizer.anonymize("空: 「」") == "空: 「」")
    }

    @Test func tokensAreEightHexCharacters() {
        let anonymized = anonymizer.anonymizePath("/Volumes/External")
        let token = anonymized.split(separator: "/").last.map(String.init) ?? ""
        #expect(token.count == 8)
        #expect(token.allSatisfy { $0.isHexDigit })
    }

    /// **絶対パスでない中身が `⟪…⟫` の印で届いても、素通ししない**
    /// [フェーズ1完了時の監査で発見]。書き込み側が「ユーザーデータ」と明示した
    /// 範囲なので、パスとして分解できなければ丸ごと伏せる（印の経路は引用符の
    /// 安全網も通らないため、素通しは印が無いより悪い）。
    @Test func markedContentThatIsNotAnAbsolutePathIsStillRedacted() {
        let line = "対象: \u{27EA}(成年コミック) [作家名] 作品名.cbz\u{27EB} を処理"
        let anonymized = anonymizer.anonymize(line)
        #expect(!anonymized.contains("成年コミック"))
        #expect(!anonymized.contains("作品名"))
        #expect(anonymized.contains("対象: "))
        #expect(anonymized.contains(" を処理"))
    }

    /// 日本語の句読点の直後に置かれた素の絶対パスも匿名化される
    /// [フェーズ1完了時の監査で発見]。Foundation 由来の文
    /// （`…できませんでした。/Volumes/…`）で `。` が境界と見なされず
    /// パスが素通りしていた。
    @Test func barePathsAfterJapanesePunctuationAreAnonymized() {
        for line in [
            "操作を完了できませんでした。/Volumes/PRO-G40/成年コミック/作品.cbz",
            "対象：/Volumes/PRO-G40/成年コミック/作品.cbz",
            "読めません、/Volumes/PRO-G40/成年コミック/作品.cbz",
        ] {
            let anonymized = anonymizer.anonymize(line)
            #expect(!anonymized.contains("成年コミック"), "素通り: \(anonymized)")
            #expect(!anonymized.contains("作品"), "素通り: \(anonymized)")
        }
    }
}
