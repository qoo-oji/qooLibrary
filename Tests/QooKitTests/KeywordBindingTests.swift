//
//  参照名の束縛 UI が拠る判定 [MF-22]。
//
//  ステージ 5 で予約語割り当てポップアップを撤去した [§19.7][§19.8] のは、
//  **既定フィールド 6 種を付け替えられてしまう**のが害だったから——
//  「著者フィールドへ `@genre` が流れる」ような、後から辿れない設定が作れた。
//  ここで戻すのは**既定 6 種以外の軸だけ**で、その線引きがこの suite の主題。
//
import Testing
import Foundation
@testable import QooKit

@Suite("参照名の束縛 [MF-22]")
struct KeywordBindingTests {

    private func draft(fields: [Int],
                       bindings: [SemanticKeyword: Int]) -> LibrarySettingsDraft {
        LibrarySettingsDraft(
            displayName: "L",
            targetExtensions: ["cbz"],
            fields: fields.map {
                FieldDraft(index: $0, name: "F\($0)",
                           colorHexLight: "#000000", colorHexDark: "#FFFFFF")
            },
            semanticBindings: bindings)
    }

    /// **付け替えてよい軸と既定 6 種で、意味予約語を過不足なく分ける。**
    ///
    /// case を足したときに**どちらの一覧にも入れ忘れる**と、その軸は画面から
    /// 束縛できず（`bindableKeywords` に出ない）、しかも付け替えの後始末
    /// （`bindKeyword` の掃除）からも漏れる——どちらも「何も起きない」形の
    /// 壊れ方なので、ここで機械的に止める。
    @Test("付け替えてよい軸と既定 6 種で、意味予約語を尽くす")
    func theTwoListsPartitionEverySemanticKeyword() {
        let assignable = Set(LibrarySettingsDraft.assignableKeywords)
        let defaults = Set(SemanticKeyword.defaultFields)
        #expect(assignable.isDisjoint(with: defaults))
        #expect(assignable.union(defaults) == Set(SemanticKeyword.allCases))
    }

    // MARK: - 何が並ぶか

    @Test("束縛の無いフィールドには、空いている軸がすべて並ぶ")
    func anUnboundFieldOffersEveryFreeKeyword() {
        let d = draft(fields: [1, 2], bindings: [.author: 1])
        #expect(d.bindableKeywords(forFieldAt: 2) == LibrarySettingsDraft.assignableKeywords)
        #expect(d.boundKeyword(forFieldAt: 2) == nil)
    }

    /// 1 予約語 → 複数フィールドは検証が拒む [RW-14] ので、選べる形にしても
    /// 保存できない選択肢が並ぶだけになる。
    @Test("他のフィールドが使っている軸は並ばない")
    func aKeywordTakenByAnotherFieldIsNotOffered() {
        let d = draft(fields: [1, 2], bindings: [.actor: 1])
        #expect(!d.bindableKeywords(forFieldAt: 2).contains(.actor))
        #expect(d.bindableKeywords(forFieldAt: 1).contains(.actor))
    }

    /// 外さない限り、選択中の値がポップアップから消えてはならない。
    @Test("自分が今使っている軸は並ぶ")
    func theFieldsOwnKeywordStaysInTheList() {
        let d = draft(fields: [1], bindings: [.season: 1])
        #expect(d.bindableKeywords(forFieldAt: 1).contains(.season))
        #expect(d.boundKeyword(forFieldAt: 1) == .season)
    }

    // MARK: - 既定フィールドは触れない

    @Test("既定 6 種のフィールドは既定フィールドと判定される")
    func defaultFieldsAreRecognisedByBinding() {
        let d = draft(fields: [1, 2], bindings: [.author: 1, .season: 2])
        #expect(d.isDefaultField(at: 1))
        #expect(!d.isDefaultField(at: 2))
    }

    /// ボタン側の出し分けと二重の守り。ステージ 5 が消した問題を再現させない。
    @Test("既定フィールドは付け替えられない")
    func aDefaultFieldCannotBeRebound() {
        var d = draft(fields: [1], bindings: [.author: 1])
        d.bindKeyword(.actor, toFieldAt: 1)
        #expect(d.semanticBindings == [.author: 1])
        d.bindKeyword(nil, toFieldAt: 1)
        #expect(d.semanticBindings == [.author: 1])
    }

    // MARK: - 付け替え

    @Test("付け替えると、前の軸が外れて新しい軸だけが残る")
    func bindingReplacesThePreviousKeyword() {
        var d = draft(fields: [1], bindings: [.keyword2: 1])
        d.bindKeyword(.actor, toFieldAt: 1)
        #expect(d.semanticBindings == [.actor: 1])
    }

    @Test("「—」を選ぶと束縛が外れる")
    func choosingNoneClearsTheBinding() {
        var d = draft(fields: [1], bindings: [.series: 1])
        d.bindKeyword(nil, toFieldAt: 1)
        #expect(d.semanticBindings.isEmpty)
    }

    /// 他のフィールドの束縛を巻き添えにしない。
    @Test("付け替えは他のフィールドの束縛に触れない")
    func bindingLeavesOtherFieldsAlone() {
        var d = draft(fields: [1, 2, 3], bindings: [.author: 1, .actor: 2, .keyword3: 3])
        d.bindKeyword(.keyword2, toFieldAt: 3)
        #expect(d.semanticBindings == [.author: 1, .actor: 2, .keyword2: 3])
    }

    /// 付け替えた結果がそのまま保存できること——検証が拒む形を作らない。
    @Test("付け替えた草案は検証を通る")
    func theReboundDraftValidates() {
        var d = draft(fields: [1, 2], bindings: [.author: 1])
        d.filenameFormats = [FilenameFormatDraft(source: "[@author] @title [@keyword2]",
                                                 isEnabled: true)]
        #expect(d.validate().contains { $0.severity == .error })   // 未束縛のうちは不備
        d.bindKeyword(.keyword2, toFieldAt: 2)
        #expect(!d.validate().contains { $0.severity == .error })
    }

    /// **`@keyword2` は `@keyword` を部分文字列として含む** [MF-22]。
    ///
    /// 素の `contains` で未束縛を判定していた頃は、カスタム軸を書いただけで
    /// 「`@keyword` が束縛されていません」という存在しない不備が出て、
    /// **設定を一切保存できなかった**（この束縛 UI を作って初めて踏んだ）。
    @Test("カスタム軸を書いても、名前が前方一致する軸の不備は出ない")
    func aCustomAxisDoesNotTriggerTheShorterKeyword() {
        var d = draft(fields: [1, 2], bindings: [.author: 1, .keyword2: 2])
        d.filenameFormats = [FilenameFormatDraft(source: "[@author] @title [@keyword2]",
                                                 isEnabled: true)]
        let issues = d.validate().filter { $0.severity == .error }
        #expect(issues.isEmpty, "\(issues.map(\.message))")
        #expect(!LibrarySettingsDraft.references(.keyword, in: "[@keyword2]"))
        #expect(LibrarySettingsDraft.references(.keyword, in: "[@keyword]"))
        #expect(LibrarySettingsDraft.references(.keyword2, in: "[@keyword2]"))
    }
}
