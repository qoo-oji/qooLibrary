import Foundation
import Testing

@testable import QooKit

/// Finder 相当の一括リネーム。**名前を計算するところだけ**を固定する
/// （ファイルには触らない）。
@Suite struct BulkRenameTests {
    private let comicNames = [
        "(成年コミック) [98765架空社] サンプルプレビュー 第01巻.cbz",
        "(成年コミック) [98765架空社] サンプルプレビュー 第02巻.cbz",
    ]

    // MARK: - テキストを置き換える

    @Test func replacesTextAnywhereInTheName() {
        let changes = BulkRename.plan(names: comicNames, mode: .replaceText(find: "第", replaceWith: "vol."))
        #expect(changes[0].newName == "(成年コミック) [98765架空社] サンプルプレビュー vol.01巻.cbz")
    }

    /// 拡張子も置換の対象（Finder と同じく名前全体を見る）。
    @Test func replaceCanTouchTheExtension() {
        let changes = BulkRename.plan(names: ["a.cbz"], mode: .replaceText(find: "cbz", replaceWith: "zip"))
        #expect(changes[0].newName == "a.zip")
    }

    @Test func emptySearchTextLeavesNamesAlone() {
        let changes = BulkRename.plan(names: ["a.cbz"], mode: .replaceText(find: "", replaceWith: "x"))
        #expect(!changes[0].isChanged)
    }

    // MARK: - テキストを追加

    @Test func addsTextBeforeTheName() {
        let changes = BulkRename.plan(names: ["a.cbz"], mode: .addText("済_", placement: .before))
        #expect(changes[0].newName == "済_a.cbz")
    }

    /// **後ろに足すときは拡張子より前**に入れる。拡張子の後ろに足すと
    /// ファイルの種類が変わってしまい、開けなくなる。
    @Test func addsTextBeforeTheExtensionNotAfterIt() {
        let changes = BulkRename.plan(names: ["a.cbz"], mode: .addText("_済", placement: .after))
        #expect(changes[0].newName == "a_済.cbz")
    }

    @Test func addsTextAtTheEndWhenThereIsNoExtension() {
        let changes = BulkRename.plan(names: ["フォルダ"], mode: .addText("_済", placement: .after))
        #expect(changes[0].newName == "フォルダ_済")
    }

    // MARK: - フォーマット

    @Test func numbersItemsInTheGivenOrder() {
        let changes = BulkRename.plan(
            names: ["b.cbz", "a.cbz"],
            mode: .format(style: .nameAndIndex, customText: "作品", placement: .after, startNumber: 1)
        )
        #expect(changes[0].newName == "作品_1.cbz")
        #expect(changes[1].newName == "作品_2.cbz")
    }

    /// 桁数（ゼロ詰め）［ユーザー要望］。
    @Test func padsTheNumberToTheRequestedWidth() {
        let changes = BulkRename.plan(
            names: ["a.cbz", "b.cbz"],
            mode: .format(
                style: .nameAndIndex, customText: "作品", placement: .after,
                startNumber: 9, digits: 3
            )
        )
        #expect(changes[0].newName == "作品_009.cbz")
        #expect(changes[1].newName == "作品_010.cbz")
    }

    /// **桁数は下限であって上限ではない。** 3 桁指定のまま 1000 件目に
    /// 到達しても、番号を切り詰めて衝突させたりしない。
    @Test func doesNotTruncateNumbersWiderThanTheRequestedWidth() {
        let changes = BulkRename.plan(
            names: ["a.cbz", "b.cbz"],
            mode: .format(
                style: .nameAndIndex, customText: "作品", placement: .after,
                startNumber: 999, digits: 2
            )
        )
        #expect(changes[0].newName == "作品_999.cbz")
        #expect(changes[1].newName == "作品_1000.cbz")
    }

    /// 桁数を指定しなければ従来どおり詰めない。
    @Test func doesNotPadByDefault() {
        let changes = BulkRename.plan(
            names: ["a.cbz"],
            mode: .format(style: .nameAndIndex, customText: "作品", placement: .after, startNumber: 1)
        )
        #expect(changes[0].newName == "作品_1.cbz")
    }

    @Test func honoursTheStartNumber() {
        let changes = BulkRename.plan(
            names: ["a.cbz", "b.cbz"],
            mode: .format(style: .nameAndIndex, customText: "作品", placement: .after, startNumber: 10)
        )
        #expect(changes[0].newName == "作品_10.cbz")
        #expect(changes[1].newName == "作品_11.cbz")
    }

    @Test func counterStyleIsZeroPadded() {
        let changes = BulkRename.plan(
            names: ["a.cbz"],
            mode: .format(style: .nameAndIndex, customText: "作品", placement: .after, startNumber: 1, digits: 5)
        )
        #expect(changes[0].newName == "作品_00001.cbz")
    }

    @Test func numberCanGoBeforeTheName() {
        let changes = BulkRename.plan(
            names: ["a.cbz"],
            mode: .format(style: .nameAndIndex, customText: "作品", placement: .before, startNumber: 3)
        )
        #expect(changes[0].newName == "3_作品.cbz")
    }

    /// `nil` は「元の名前をそのまま使う」（置き換えのチェックが off）。
    @Test func nilCustomTextKeepsTheOriginalStem() {
        let changes = BulkRename.plan(
            names: ["作品A.cbz"],
            mode: .format(style: .nameAndIndex, customText: nil, placement: .after, startNumber: 1)
        )
        #expect(changes[0].newName == "作品A_1.cbz")
    }

    /// 置き換えるが文字列が空なら、区切り文字と番号だけになる［ユーザー要望］。
    @Test func emptyCustomTextLeavesOnlyTheSeparatorAndNumber() {
        let changes = BulkRename.plan(
            names: ["作品A.cbz"],
            mode: .format(style: .nameAndIndex, customText: "", placement: .after, startNumber: 1)
        )
        #expect(changes[0].newName == "_1.cbz")
    }

    /// **番号のみ**［ユーザー要望: 元の名前もカスタム文字列も使わない］。
    @Test func numberOnlyIgnoresTheOriginalNameAndCustomText() {
        let changes = BulkRename.plan(
            names: ["作品A.cbz", "作品B.jpg"],
            mode: .format(
                style: .numberOnly, customText: "無視される", placement: .before,
                startNumber: 1, digits: 3
            )
        )
        #expect(changes[0].newName == "001.cbz")
        #expect(changes[1].newName == "002.jpg")
    }

    /// 区切り文字は選べる［ユーザー要望: 既定のスペースは行儀が良くない］。
    @Test func separatorCanBeChosen() {
        func name(_ separator: BulkRename.Separator) -> String {
            BulkRename.plan(
                names: ["a.cbz"],
                mode: .format(
                    style: .nameAndIndex, customText: "作品", placement: .after,
                    startNumber: 1, digits: 1, separator: separator
                )
            )[0].newName
        }
        #expect(name(.underscore) == "作品_1.cbz")
        #expect(name(.hyphen) == "作品-1.cbz")
        #expect(name(.space) == "作品 1.cbz")
        #expect(name(.none) == "作品1.cbz")
    }

    @Test func dateStyleUsesAFileSafeFormat() {
        var components = DateComponents()
        components.year = 2026; components.month = 8; components.day = 15
        components.hour = 17; components.minute = 4; components.second = 5
        let date = Calendar(identifier: .gregorian).date(from: components)!
        let changes = BulkRename.plan(
            names: ["a.cbz"],
            mode: .format(style: .nameAndDate, customText: "作品", placement: .after, startNumber: 1),
            date: date, locale: Locale(identifier: "en_US_POSIX")
        )
        // `/` と `:` はファイル名に使えない（`:` は Finder 上で `/` に化ける）。
        let colon: Character = ":"
        #expect(!changes[0].newName.contains(colon))
        #expect(changes[0].newName.hasPrefix("作品_2026-08-15"))
    }

    // MARK: - 衝突 [BR-09]

    @Test func flagsDuplicatesAmongTheNewNames() {
        let changes = BulkRename.plan(names: ["a.cbz", "b.cbz"], mode: .replaceText(find: "b", replaceWith: "a"))
        let allConflict = changes.allSatisfy { $0.conflicts }
        #expect(allConflict)
    }

    @Test func flagsCollisionsWithItemsThatAreNotBeingRenamed() {
        let changes = BulkRename.plan(
            names: ["a.cbz"], mode: .replaceText(find: "a", replaceWith: "c"),
            existingNames: ["c.cbz"]
        )
        #expect(changes[0].conflicts)
    }

    /// macOS の既定のファイルシステムは大文字小文字を区別しない。区別する
    /// 前提で通すと、実行して初めて失敗する。
    @Test func caseOnlyDifferencesCountAsCollisions() {
        let changes = BulkRename.plan(
            names: ["a.cbz"], mode: .replaceText(find: "a.cbz", replaceWith: "B.CBZ"),
            existingNames: ["b.cbz"]
        )
        #expect(changes[0].conflicts)
    }

    @Test func emptyResultingNameIsAConflict() {
        let changes = BulkRename.plan(names: ["a"], mode: .replaceText(find: "a", replaceWith: ""))
        #expect(changes[0].conflicts)
    }

    @Test func nonCollidingPlanHasNoConflicts() {
        let changes = BulkRename.plan(names: comicNames, mode: .addText("済_", placement: .before))
        let noneConflict = changes.allSatisfy { !$0.conflicts }
        #expect(noneConflict)
    }

    // MARK: - 2 パス [BR-10]

    /// A→B, B→A のような入れ替えは、一時名を経由しないと途中で衝突する。
    @Test func detectsThatSwappingNamesNeedsTwoPasses() {
        let changes = [
            BulkRename.Change(originalName: "a.cbz", newName: "b.cbz"),
            BulkRename.Change(originalName: "b.cbz", newName: "a.cbz"),
        ]
        #expect(BulkRename.requiresTwoPass(changes))
    }

    /// ずらすだけ（1→2, 2→3）でも、既存の名前を踏むので 2 パスが要る。
    @Test func detectsThatShiftingNamesNeedsTwoPasses() {
        let changes = [
            BulkRename.Change(originalName: "1.cbz", newName: "2.cbz"),
            BulkRename.Change(originalName: "2.cbz", newName: "3.cbz"),
        ]
        #expect(BulkRename.requiresTwoPass(changes))
    }

    /// 誰の元の名前とも被らないなら 1 パスで足りる（余計なリネームを増やさない）。
    @Test func independentRenamesDoNotNeedTwoPasses() {
        let changes = [
            BulkRename.Change(originalName: "a.cbz", newName: "x.cbz"),
            BulkRename.Change(originalName: "b.cbz", newName: "y.cbz"),
        ]
        #expect(!BulkRename.requiresTwoPass(changes))
    }
}
