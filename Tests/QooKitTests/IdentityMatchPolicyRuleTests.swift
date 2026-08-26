import Foundation
import QooKit
import Testing

//
//  「どこまでを黙って同じファイルとみなすか」の規則 [ID-13]。
//
//  **この判断は 1 箇所にしか無い。** 走査（`ScanEngine`）も、走査後の
//  引き直しも、同じ関数を通す——2 箇所に条件を書くと「自動で引き継いだはずの
//  ものが確認一覧にも出る」という食い違いになる。だからここで真理値表ごと
//  固定しておく。
//

@Suite("同一性の判定を緩める設定 [ID-13]")
struct IdentityMatchPolicyRuleTests {

    /// 表の 12 マスをすべて書く。**「①②は常に自動」という不変条件が
    /// いちばん壊れやすい**——設定を足すときに、そこまで巻き込んで
    /// 「確認する」にしてしまうと、単に上書き保存しただけでラベルを
    /// 失うようになる。
    @Test("確度と設定の組み合わせ", arguments: [
        (IdentityMatchPolicy.alwaysConfirm, ReidentificationCandidate.Confidence.pathAndSize, true),
        (.alwaysConfirm, .nameAndSize, true),
        (.alwaysConfirm, .pathOnly,    false),
        (.alwaysConfirm, .nameOnly,    false),
        (.samePath,      .pathAndSize, true),
        (.samePath,      .nameAndSize, true),
        (.samePath,      .pathOnly,    true),
        (.samePath,      .nameOnly,    false),
        (.sameName,      .pathAndSize, true),
        (.sameName,      .nameAndSize, true),
        (.sameName,      .pathOnly,    true),
        (.sameName,      .nameOnly,    true),
    ])
    func truthTable(policy: IdentityMatchPolicy,
                    confidence: ReidentificationCandidate.Confidence,
                    expected: Bool) {
        #expect(policy.acceptsAutomatically(confidence) == expected)
    }

    /// **中身が同じなら、どの設定でも自動。** ①②は差し替えではないので、
    /// ここを設定で動かしてはならない。
    @Test("中身が同じ一致は、どの設定でも尋ねない")
    func sizeMatchesIsNeverAsked() {
        for policy in IdentityMatchPolicy.allCases {
            #expect(policy.acceptsAutomatically(.pathAndSize))
            #expect(policy.acceptsAutomatically(.nameAndSize))
        }
    }

    /// 既定は「尋ねない」［ユーザー判断］。差し替えは日常的に起きるので、
    /// 既定で確認を挟むと邪魔になる。
    @Test("既定は sameName")
    func defaultIsSameName() {
        #expect(IdentityMatchPolicy.default == .sameName)
    }

    /// 孤立一覧の候補から確度を**復元**できること。走査とあとからの
    /// 引き直しで同じ物差しを使うために要る。
    @Test("候補の 2 つの旗から確度を復元する", arguments: [
        (true,  true,  ReidentificationCandidate.Confidence.pathAndSize),
        (false, true,  .nameAndSize),
        (true,  false, .pathOnly),
        (false, false, .nameOnly),
    ])
    func reconstructsConfidence(samePath: Bool, sizeMatches: Bool,
                                expected: ReidentificationCandidate.Confidence) {
        #expect(ReidentificationCandidate.Confidence(
            samePath: samePath, sizeMatches: sizeMatches) == expected)
    }

    /// 宣言順＝確度の高い順。`findCandidates` はこの順で並べ替えるので、
    /// 順序が崩れると「いちばん確からしい候補」が先頭に来なくなる。
    @Test("確度は高い順に並ぶ")
    func confidenceOrdering() {
        #expect(ReidentificationCandidate.Confidence.allCases
            == [.pathAndSize, .nameAndSize, .pathOnly, .nameOnly])
        #expect(ReidentificationCandidate.Confidence.pathAndSize < .nameOnly)
    }
}
