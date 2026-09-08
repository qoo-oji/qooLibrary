import Foundation
import Testing

@testable import QooKit

/// 既定の正規表現セット `ES-Standard` / `SS-Standard` / `DS-Standard` [MF-09][MF-19]。
///
/// **`volume-sets.json` に書いた綴りをそのまま試す。** 正規表現は文字列なので、
/// ICU が受け付けない書き方をしても**コンパイル時には何も起きず**、
/// `VolumePatternCompiler.compile` が `nil` を返して静かに 1 本消えるだけになる
/// ——「なぜか話数が取れないライブラリ」として現れる。
@Suite("メディア向けの既定セット [MF-09]")
struct MediaPatternSetTests {

    private static let sets = try! BuiltInTemplates.volumeSets()

    private func patterns(_ name: String, _ role: PatternRole) throws -> [CompiledVolumePattern] {
        let list = try #require(Self.sets.patterns(named: name, role: role))
        let compiled = VolumePatternCompiler.compileAll(list)
        // **1 本でも落ちたら失敗**。読めない正規表現は黙って消える。
        #expect(compiled.count == list.count, "\(name) の正規表現が \(list.count - compiled.count) 本読めない")
        return compiled
    }

    /// 最長一致の候補（`VolumeMatcher.matches` は長い順に返す [SE-21]）。
    private func best(_ text: String, _ patterns: [CompiledVolumePattern],
                      _ role: PatternRole) -> VolumeMatch? {
        VolumeMatcher.matches(in: Array(text), at: 0, patterns: patterns,
                              role: role, includeBareDigits: false).first
    }

    // MARK: - 話数

    @Test("ES-Standard が実測にある表記と一般規約を読む [MF-09]",
          arguments: [("第12話", 12.0), ("12話", 12.0), ("S01E05", 5.0), ("s2e10", 10.0),
                      ("1x03", 3.0), ("EP07", 7.0), ("ep.7", 7.0), ("E04", 4.0), ("#08", 8.0)])
    func episodeForms(_ text: String, _ expected: Double) throws {
        let p = try patterns("ES-Standard", .episode)
        let m = try #require(best(text, p, .episode), "\(text) に一致しない")
        #expect(m.value.number == expected)
        #expect(m.range.count == text.count, "\(text) の一部にしか当たっていない")
    }

    /// **`S01E05` は話数 5 でなければならない。**`(?<season>…)` が第 1 グループなので、
    /// 素の「唯一のキャプチャ」規則ではシーズン 1 を話数として返す——数字が出るので
    /// 画面からは誤りに気づけない [MF-06]。
    @Test("SxxEyy はシーズンではなく話数を返し、シーズンも同時に持つ")
    func seasonAndEpisodeFromOneMatch() throws {
        let p = try patterns("ES-Standard", .episode)
        let m = try #require(best("S02E11", p, .episode))
        #expect(m.value.number == 11)
        #expect(m.impliedSeason == 2)
    }

    /// **語の途中を拾わない。** `Sleep01` の `ep01`、`Blue7` の `e7` を話数にすると、
    /// 作品名の一部が話数として切り出される（Jellyfin が踏んでいる形 [MF-21]）。
    @Test("英字に続く 1 文字の印は話数にしない", arguments: ["Sleep01", "Blue7", "Life3"])
    func lettersBeforeTheMarkerBlockTheMatch(_ text: String) throws {
        let p = try patterns("ES-Standard", .episode)
        let chars = Array(text)
        for index in chars.indices {
            let m = VolumeMatcher.matches(in: chars, at: index, patterns: p,
                                          role: .episode, includeBareDigits: false)
            #expect(m.isEmpty, "\(text) の \(index) 文字目から話数を拾った")
        }
    }

    // MARK: - シーズン

    @Test("SS-Standard がシーズンの表記を読む",
          arguments: [("第2期", 2.0), ("Season 3", 3.0), ("season4", 4.0),
                      ("シーズン5", 5.0), ("2nd Season", 2.0), ("S06", 6.0)])
    func seasonForms(_ text: String, _ expected: Double) throws {
        let p = try patterns("SS-Standard", .season)
        let m = try #require(best(text, p, .season), "\(text) に一致しない")
        #expect(m.value.number == expected)
    }

    /// **素の数字には当てない** [MF-21]。解像度や作品名の数字がシーズンになる。
    @Test("素の数字はシーズンにしない", arguments: ["1080", "2024", "07"])
    func bareDigitsAreNotSeasons(_ text: String) throws {
        let p = try patterns("SS-Standard", .season)
        #expect(best(text, p, .season) == nil)
    }

    // MARK: - 日付

    @Test("DS-Standard が ISO 8601 の部分形を組み立てる [MF-19]",
          arguments: [("2024-01-15", "2024-01-15"), ("2024.1.5", "2024-01-05"),
                      ("20240115", "2024-01-15"), ("2024-01", "2024-01"),
                      ("(2024)", "2024"), ("[1999]", "1999")])
    func dateForms(_ text: String, _ expected: String) throws {
        let p = try patterns("DS-Standard", .date)
        let m = try #require(DateMatcher.matches(in: FoldedSubject(Array(text)), at: 0,
                                                 patterns: p).first, "\(text) に一致しない")
        #expect(m.value == expected)
    }

    /// **素の 4 桁数字には当てない** [MF-21]。`1080` が年号になると、解像度が
    /// 公開日として保存される。
    @Test("素の 4 桁数字は日付にしない", arguments: ["1080", "2024p", "480"])
    func bareYearsAreNotDates(_ text: String) throws {
        let p = try patterns("DS-Standard", .date)
        let chars = Array(text)
        for index in chars.indices {
            let m = DateMatcher.matches(in: FoldedSubject(chars), at: index, patterns: p)
            #expect(m.isEmpty, "\(text) の \(index) 文字目から日付を拾った")
        }
    }

    // MARK: - 役割

    /// **役割は集合の名前ではなく呼び出し側が決める** [MF-07]。同じ集合を別の
    /// 役割で引けば、その役割のパターンとして返る。
    @Test("役割は patterns(named:role:) の引数が決める")
    func theCallerDecidesTheRole() throws {
        let asEpisode = try #require(Self.sets.patterns(named: "ES-Standard", role: .episode))
        let asVolume = try #require(Self.sets.patterns(named: "ES-Standard"))
        #expect(asEpisode.allSatisfy { $0.role == .episode })
        #expect(asVolume.allSatisfy { $0.role == .volume })
        #expect(asEpisode.map(\.source) == asVolume.map(\.source))
    }

    /// **役割で絞ってから照合する** [MF-07]。話数のパターンが巻数として拾われると、
    /// 「巻数がいつのまにか話数になる」という読み解けない壊れ方をする。
    @Test("役割の違うパターンは候補にならない")
    func patternsOfAnotherRoleAreNotCandidates() throws {
        let p = try patterns("ES-Standard", .episode)
        #expect(best("第12話", p, .volume) == nil)
        #expect(best("第12話", p, .episode) != nil)
    }
}
