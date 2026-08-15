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
