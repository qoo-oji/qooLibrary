//
//  正規表現の実測 [SE-25 の層 ③、05章 §5.6]。
//
//  ここが固定するのは**「いつ測るか」の規則**であって、何が危険かの判定では
//  ない（そちらは `RegexSafetyTests`）。層 ③ は 2026-09-08 まで**誰からも
//  呼ばれておらず**、危ない正規表現を書いても警告が 1 度も出なかった。
//
import Foundation
import Testing
@testable import QooKit
@testable import QooUI

@Suite("正規表現の実測 [SE-25 の層 ③]")
@MainActor
struct RegexMeasurementMonitorTests {

    /// 測定そのものは差し替える——ここで見たいのは「いつ・何回測るか」で、
    /// 実際の所要時間ではない。
    private final class Spy: @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [RegexMeasurementKey] = []
        var calls: [RegexMeasurementKey] { lock.lock(); defer { lock.unlock() }; return _calls }
        func record(_ key: RegexMeasurementKey) { lock.lock(); _calls.append(key); lock.unlock() }
    }

    private func makeMonitor(_ spy: Spy,
                             issues: @escaping @Sendable () -> [LibrarySettingsIssue] = { [] })
    -> RegexMeasurementMonitor {
        RegexMeasurementMonitor(delay: .milliseconds(1)) { draft, _ in
            spy.record(draft.regexMeasurementKey)
            return issues()
        }
    }

    private func draft(volume: [String] = ["(?<volume>[0-9]+)巻"],
                       tokens: [String] = [],
                       fieldName: String = "著者") -> LibrarySettingsDraft {
        var d = LibrarySettingsDraft()
        d.displayName = "X"
        d.volumeFormats = volume.map { VolumeFormatDraft(source: $0) }
        d.protectedTokens = tokens.map { ProtectedToken(pattern: $0) }
        d.fields = [FieldDraft(index: 1, name: fieldName,
                               colorHexLight: "#000000", colorHexDark: "#FFFFFF")]
        return d
    }

    /// **`nonisolated` にする**——`RegexMeasurementMonitor` はメインアクタの
    /// 外で測るので、差し替えた測定も外から呼べなければならない。
    private nonisolated static func warning() -> [LibrarySettingsIssue] {
        [.init(severity: .warning, section: .volumeFormats, message: "遅い")]
    }

    @Test("草案が落ち着いたら測り、結果が不備として出る")
    func measuresOnceSettled() async {
        let spy = Spy()
        let monitor = makeMonitor(spy, issues: Self.warning)
        #expect(monitor.issues.isEmpty)
        monitor.update(for: draft())
        await monitor.waitForMeasurement()
        #expect(monitor.issues.count == 1)
        #expect(spy.calls.count == 1)
    }

    /// **これが無いと `validate()` に混ぜたのと変わらない。** 草案は 1 打鍵ごとに
    /// 書き換わるので、実測の入力が同じなら測り直してはならない。
    @Test("実測が読まない項目だけを変えても測り直さない")
    func doesNotRemeasureWhenTheMeasuredInputIsUnchanged() async {
        let spy = Spy()
        let monitor = makeMonitor(spy, issues: Self.warning)
        monitor.update(for: draft(fieldName: "著者"))
        await monitor.waitForMeasurement()
        #expect(spy.calls.count == 1)

        // フィールド名を打っただけ——巻数フォーマットも保護文字列も動いていない。
        for name in ["著者名", "著者名前", "著者名前A"] {
            monitor.update(for: draft(fieldName: name))
        }
        await monitor.waitForMeasurement()
        #expect(spy.calls.count == 1)
        // **警告が消えないこと**が要点（利用者から見れば「勝手に消えた」になる）。
        #expect(monitor.issues.count == 1)
    }

    @Test("正規表現を変えたら測り直す")
    func remeasuresWhenAPatternChanges() async {
        let spy = Spy()
        let monitor = makeMonitor(spy, issues: Self.warning)
        monitor.update(for: draft(volume: ["(?<volume>[0-9]+)巻"]))
        await monitor.waitForMeasurement()
        monitor.update(for: draft(volume: ["(?<volume>[0-9]+)話"]))
        await monitor.waitForMeasurement()
        #expect(spy.calls.count == 2)
    }

    @Test("保護文字列を変えても測り直す")
    func remeasuresWhenAProtectedTokenChanges() async {
        let spy = Spy()
        let monitor = makeMonitor(spy)
        monitor.update(for: draft(tokens: ["\\(完\\)"]))
        await monitor.waitForMeasurement()
        monitor.update(for: draft(tokens: ["\\(完結\\)"]))
        await monitor.waitForMeasurement()
        #expect(spy.calls.count == 2)
    }

    /// 前の結果は**別のパターンについての**警告なので、そのまま出し続けない。
    @Test("正規表現を変えた瞬間に、古い実測結果を捨てる")
    func dropsStaleResultsAsSoonAsThePatternChanges() async {
        let spy = Spy()
        let monitor = makeMonitor(spy, issues: Self.warning)
        monitor.update(for: draft(volume: ["(a+)+$"]))
        await monitor.waitForMeasurement()
        #expect(monitor.issues.count == 1)

        monitor.update(for: draft(volume: ["[0-9]+"]))
        #expect(monitor.issues.isEmpty)   // 測り終わるのを待たずに、その場で捨てる
    }

    @Test("草案が無くなったら結果も捨てる")
    func clearsWhenTheDraftGoesAway() async {
        let spy = Spy()
        let monitor = makeMonitor(spy, issues: Self.warning)
        monitor.update(for: draft())
        await monitor.waitForMeasurement()
        #expect(monitor.issues.count == 1)
        monitor.update(for: nil)
        #expect(monitor.issues.isEmpty)
    }

    /// 実測の鍵は**有効なパターンの綴りだけ**を見る [SE-25]。
    @Test("無効にしたパターンは実測の入力に入らない")
    func disabledPatternsAreNotPartOfTheKey() {
        var enabled = draft(volume: ["(a+)+$"])
        var disabled = enabled
        disabled.volumeFormats[0].isEnabled = false
        #expect(enabled.regexMeasurementKey != disabled.regexMeasurementKey)
        enabled.volumeFormats[0].isEnabled = false
        #expect(enabled.regexMeasurementKey == disabled.regexMeasurementKey)
    }

    /// **層 ③ が実際に危険なパターンを捕まえる**ことを、差し替えなしで確かめる
    /// ——ここだけは本物の `measuredIssues` を通す。
    @Test("本物の実測が、破裂する正規表現を警告する")
    func theRealMeasurementFindsACatastrophicPattern() async {
        let monitor = RegexMeasurementMonitor(delay: .milliseconds(1))
        monitor.update(for: draft(volume: ["(a+)+$"]))
        await monitor.waitForMeasurement()
        #expect(!monitor.issues.isEmpty)
        // **警告どまり**——実行時は `SafeRegex` のウォッチドッグが必ず打ち切る
        // ので、保存を妨げる理由が無い [三層防御の ①]。
        #expect(monitor.issues.allSatisfy { $0.severity == .warning })
    }

    /// **これが無いと層 ③ が誰にも届かない**——2026-09-08 まで、実測は
    /// 実装されていながら 1 度も呼ばれていなかった。
    @Test("画面に出す不備は、静的検査と実測の両方を含む")
    func theDisplayedListCarriesBothLayers() async {
        let spy = Spy()
        let monitor = makeMonitor(spy, issues: Self.warning)
        let statics: [LibrarySettingsIssue] =
            [.init(severity: .error, section: .basics, message: "静的")]

        #expect(monitor.merged(with: statics).map(\.message) == ["静的"])
        monitor.update(for: draft())
        await monitor.waitForMeasurement()
        // **静的検査が先**——実測は遅れて増えるので、後ろへ足すほうが行が動かない。
        #expect(monitor.merged(with: statics).map(\.message) == ["静的", "遅い"])
    }

    /// 実測は**静的検査とは別のことを言う**。同じ文言なら層を分けた意味が無い。
    ///
    /// この形は層 ② も「量指定子の入れ子」として警告するが、層 ③ は
    /// **実際に破裂させた標本**を挙げる——直す手がかりが違う。
    @Test("実測の警告は、静的検査の警告とは別の文言になる")
    func theMeasuredWarningSaysSomethingTheStaticCheckCannot() async {
        let d = draft(volume: ["(a+)+$"])
        let statics = Set(d.validate().map(\.message))
        let measured = d.measuredIssues()
        #expect(!measured.isEmpty)
        #expect(measured.allSatisfy { !statics.contains($0.message) })
    }
}
