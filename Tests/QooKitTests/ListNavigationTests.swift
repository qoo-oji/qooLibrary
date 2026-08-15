import Foundation
import Testing

@testable import QooKit

/// 先頭一致（type-select 用）[ユーザー要望]。絞り込みと同じ「見た目の一致」で
/// 揃っていることを固定する。
@Suite struct NameFilterPrefixTests {
    @Test func matchesFromTheStartOnly() {
        #expect(NameFilter.hasPrefix(name: "readme.txt", prefix: "re"))
        #expect(!NameFilter.hasPrefix(name: "readme.txt", prefix: "ad"))
    }

    @Test func ignoresCase() {
        #expect(NameFilter.hasPrefix(name: "README.txt", prefix: "re"))
        #expect(NameFilter.hasPrefix(name: "readme.txt", prefix: "RE"))
    }

    /// 日本語入力のまま英数字を打つと全角になる。**入力の幅までユーザーに
    /// 合わせさせない**（絞り込み側と同じ方針）。
    @Test func ignoresWidth() {
        #expect(NameFilter.hasPrefix(name: "cbz-sample.cbz", prefix: "ｃｂｚ"))
        #expect(NameFilter.hasPrefix(name: "サンプルプレビュー.cbz", prefix: "ｻﾝﾌﾟ"))
    }

    @Test func emptyPrefixNeverMatches() {
        #expect(!NameFilter.hasPrefix(name: "anything", prefix: ""))
    }

    /// この分野で普通に現れる名前でも先頭から拾えること。
    @Test func matchesRealWorldFileNames() {
        let name = "(成年コミック) [98765架空社] サンプルプレビュー.cbz"
        #expect(NameFilter.hasPrefix(name: name, prefix: "("))
        #expect(NameFilter.hasPrefix(name: name, prefix: "(成年"))
        #expect(!NameFilter.hasPrefix(name: name, prefix: "98765"))
    }
}

/// アイコン表示の格子上の移動。**端の扱い**が要点で、ここが崩れると
/// 矢印キーが行をまたいで勝手に折り返す（Finder はしない）。
@Suite struct GridNavigationTests {
    /// 3 列 × 7 項目:
    /// ```
    /// 0 1 2
    /// 3 4 5
    /// 6
    /// ```
    private let count = 7
    private let columns = 3

    private func target(_ from: Int, _ direction: ListKeyboardNavigation.Direction) -> Int? {
        ListKeyboardNavigation.gridTarget(from: from, direction: direction, count: count, columns: columns)
    }

    @Test func movesWithinARow() {
        #expect(target(0, .right) == 1)
        #expect(target(1, .left) == 0)
    }

    @Test func movesBetweenRows() {
        #expect(target(1, .down) == 4)
        #expect(target(4, .up) == 1)
    }

    /// **行をまたいで折り返さない。** ← を押し続けても前の行の末尾へ回り込まない。
    @Test func stopsAtTheEdgesOfARow() {
        #expect(target(0, .left) == nil)
        #expect(target(2, .right) == nil)
        #expect(target(3, .left) == nil)
    }

    @Test func stopsAtTheTopAndBottom() {
        #expect(target(0, .up) == nil)
        #expect(target(6, .down) == nil)
    }

    /// 最終行がそろっていないとき、↓ はその列に項目が無ければ**最後の項目**へ
    /// 寄せる（寄せないと最下段の右側へ辿り着けない）。
    @Test func fallsBackToTheLastItemWhenTheColumnIsMissing() {
        #expect(target(4, .down) == 6)
        #expect(target(5, .down) == 6)
    }

    @Test func returnsNilForOutOfRangeInput() {
        #expect(ListKeyboardNavigation.gridTarget(from: 0, direction: .down, count: 0, columns: 3) == nil)
        #expect(ListKeyboardNavigation.gridTarget(from: 9, direction: .down, count: 7, columns: 3) == nil)
    }
}

/// type-select の飛び先。
@Suite struct TypeSelectTargetTests {
    private let items = ["apple.txt", "banana.txt", "berry.txt", "cherry.txt"]

    private func target(_ prefix: String, from current: Int?) -> Int? {
        ListKeyboardNavigation.typeSelectTarget(in: items, prefix: prefix, currentIndex: current) { $0 }
    }

    @Test func findsTheFirstMatchFromTheStart() {
        #expect(target("b", from: nil) == 1)
    }

    /// 同じ文字を続けて打つと、同じ頭文字の項目を順に送れる（Finder と同じ）。
    @Test func singleCharacterCyclesThroughMatches() {
        #expect(target("b", from: 1) == 2)
        #expect(target("b", from: 2) == 1) // 一周する
    }

    /// 打鍵が積み上がっている間は先頭から探す — "be" と打った時点で
    /// `berry` に居るのに次の候補へ飛ぶと、絞り込むつもりの操作と食い違う。
    @Test func multiCharacterPrefixSearchesFromTheBeginning() {
        #expect(target("be", from: 2) == 2)
    }

    @Test func returnsNilWhenNothingMatches() {
        #expect(target("z", from: nil) == nil)
    }

    /// 打鍵が途切れたら積み上げをやめる。
    @Test func bufferResetsAfterAPause() {
        var buffer = ListKeyboardNavigation.TypeSelectBuffer()
        #expect(buffer.append("a") == "a")
        #expect(buffer.append("b") == "ab")
        buffer.reset()
        #expect(buffer.append("c") == "c")
    }
}
