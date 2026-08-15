import Testing

@testable import QooKit

/// [1-16 検索] 名前での絞り込みの一致判定。
///
/// **実際に扱うファイル名の形を標本にする** — 1-15 の匿名化テストで
/// 「きれいな例だけを標本にすると、その分野で最も普通の入力を取りこぼす」
/// 教訓を得ているため（CLAUDE.md 参照）。
struct NameFilterTests {
    private let sample = "(成年コミック) [98765架空社] サンプルプレビュー.cbz"

    @Test func matchesPlainSubstring() {
        #expect(NameFilter.matches(name: sample, query: "cbz"))
        #expect(NameFilter.matches(name: sample, query: "サンプ"))
        #expect(NameFilter.matches(name: sample, query: "成年"))
    }

    @Test func ignoresCase() {
        #expect(NameFilter.matches(name: sample, query: "CBZ"))
        #expect(NameFilter.matches(name: "Chapter 01.ZIP", query: "zip"))
    }

    /// **日本語入力がオンのまま打った全角英数字でも一致する** [実機で発見]。
    /// `localizedStandardContains` はここで `false` を返してしまい、ユーザーに
    /// 入力の幅を合わせさせることになっていた。
    @Test func ignoresFullWidthAlphanumerics() {
        #expect(NameFilter.matches(name: sample, query: "ｃｂｚ"))
        #expect(NameFilter.matches(name: sample, query: "９８７６５"))
    }

    /// 半角カナを含むファイル名・入力も拾う。
    @Test func ignoresHalfWidthKatakana() {
        #expect(NameFilter.matches(name: sample, query: "ｻﾝﾌﾟ"))
        #expect(NameFilter.matches(name: "ﾃｽﾄ資料.pdf", query: "テスト"))
    }

    /// **濁点・半濁点は区別する** [設計判断]。`.diacriticInsensitive` を付けると
    /// 「ハンター」で「バンター」が出るなど、絞り込みとしてかえって分かりにくい。
    @Test func distinguishesVoicedSoundMarks() {
        #expect(!NameFilter.matches(name: "バンター.cbz", query: "ハンター"))
    }

    /// 空・空白のみの入力は絞り込まない（全件が対象のまま）。
    @Test func emptyQueryMatchesEverything() {
        #expect(NameFilter.matches(name: sample, query: ""))
        #expect(NameFilter.matches(name: sample, query: "   "))
    }

    @Test func nonMatchingQueryIsRejected() {
        #expect(!NameFilter.matches(name: sample, query: "rar"))
    }
}
