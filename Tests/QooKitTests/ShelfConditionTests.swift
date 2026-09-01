//
//  シェルフの条件 [SH-02][SH-05][SH-06][SH-07]。
//
import Testing
import Foundation
@testable import QooKit

@Suite("シェルフの条件 [SH-02][SH-05〜SH-07]")
struct ShelfConditionTests {
    private func label(_ n: Int64) -> LabelID { LabelID(rawValue: n) }

    @Test("ラベルの並びを正規化する——選んだ順序で別物にならない [SH-08]")
    func normalizesLabelOrder() {
        let a = ShelfCondition(labelIDs: [label(9), label(3), label(5)])
        let b = ShelfCondition(labelIDs: [label(3), label(5), label(9)])
        #expect(a.labelIDs == [label(3), label(5), label(9)])
        #expect(a == b, "同じ集合を選んだのに、順序の違いで別のシェルフに見えてはならない")
    }

    @Test("空白だけの検索語は条件として持たない")
    func blankSearchTextIsDropped() {
        #expect(ShelfCondition(labelIDs: [], searchText: "   ").searchText == nil)
        #expect(ShelfCondition(labelIDs: [], searchText: " 作品 ").searchText == "作品")
    }

    @Test("条件が 1 つも無ければ保存させない [SH-07]")
    func isActiveOnlyCountsFilters() {
        // 並べ替えと表示モードは絞り込みではないので数えない。
        #expect(!ShelfCondition(labelIDs: [],
                                sort: .init(key: .title, ascending: false),
                                displayMode: .libraryFlat).isActive)
        #expect(ShelfCondition(labelIDs: [label(1)]).isActive)
        #expect(ShelfCondition(labelIDs: [], rating: .init(stars: 3)).isActive)
        #expect(ShelfCondition(labelIDs: [], searchText: "作品").isActive)
    }

    @Test("解決できないラベルは落ちる [SH-05]——画面のチェックに現れない条件を効かせない")
    func groupedSelectionDropsUnknownLabels() {
        let condition = ShelfCondition(labelIDs: [label(1), label(2), label(3)])
        let groups: [LabelID: LabelGroupID] = [
            label(1): LabelGroupID(rawValue: 10),
            label(3): LabelGroupID(rawValue: 20),
        ]
        let selection = condition.groupedSelection { groups[$0] }
        #expect(selection == [LabelGroupID(rawValue: 10): [label(1)],
                              LabelGroupID(rawValue: 20): [label(3)]])
        // 記録そのものは残す——ラベル削除を ⌘Z で戻すと同じ ID で復活するので、
        // 落とすのは「いま解決できない」ぶんだけ。
        #expect(condition.labelIDs.count == 3)
    }

    @Test("グループごとの選択から作れる")
    func buildsFromGroupedSelection() {
        let c = ShelfCondition.from(
            selection: [LabelGroupID(rawValue: 1): [label(7), label(2)],
                        LabelGroupID(rawValue: 2): [label(5)]],
            rating: .init(stars: 4, mode: .exact), searchText: "x",
            sort: .init(key: .rating, ascending: false), displayMode: .libraryFlat)
        #expect(c.labelIDs == [label(2), label(5), label(7)])
        #expect(c.rating == .init(stars: 4, mode: .exact))
    }

    // MARK: - 符号化

    @Test("往復しても同じ条件になる")
    func codableRoundTrip() throws {
        let original = ShelfCondition(
            labelIDs: [label(4), label(1)], rating: .init(stars: 2, mode: .exact),
            searchText: "作品名", sort: .init(key: .series, ascending: false),
            displayMode: .libraryFlat)
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(ShelfCondition.self, from: data) == original)
    }

    @Test("キーの無い古い JSON も読める——既定へ落とす")
    func decodesPartialJSON() throws {
        let json = Data(#"{"labelIDs":[{"rawValue":3}]}"#.utf8)
        let c = try JSONDecoder().decode(ShelfCondition.self, from: json)
        #expect(c.labelIDs == [label(3)])
        #expect(c.sort == .byFilename)
        #expect(c.displayMode == .libraryFlat)
        #expect(c.rating == nil)
    }

    @Test("復号でも星の範囲を丸める [SH-06]——決して一致しない条件を作らせない")
    func decodingClampsRatingStars() throws {
        let json = Data(#"{"labelIDs":[],"rating":{"stars":9,"mode":"atLeast"}}"#.utf8)
        let c = try JSONDecoder().decode(ShelfCondition.self, from: json)
        #expect(c.rating?.stars == 5)
    }
}
