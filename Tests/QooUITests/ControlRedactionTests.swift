#if DEBUG
import Testing
@testable import QooUI

/// 制御口が返す文字列の伏字 [MT-33][MT-32]。
///
/// **この検査が守っているのは規則の形そのもの**——「許可語を含むか」の部分一致に
/// すると、プリセットの語（本の種別など）を含むだけで未知のファイル名が丸ごと
/// 素通りする。実際にその形の事故を起こしている。
@MainActor
struct ControlRedactionTests {
    /// テスト環境の `Bundle.main` は文字列カタログを持たないので、許可語は
    /// `extraAllowed` から来る分だけになる——規則そのものを試すのに好都合。
    private func withAllowed(_ words: [String], _ body: () -> Void) {
        let previous = ControlRedaction.extraAllowed
        ControlRedaction.isEnabled = true
        ControlRedaction.extraAllowed = words
        body()
        ControlRedaction.extraAllowed = previous
    }

    @Test func 許可語で覆い切れる文字列はそのまま通る() {
        withAllowed(["ライブラリの設定"]) {
            #expect(ControlRedaction.apply("ライブラリの設定") == "ライブラリの設定")
        }
    }

    @Test func 記号と数字は残っていてもよい() {
        withAllowed(["件を試して", "件が一致"]) {
            #expect(ControlRedaction.apply("5 件を試して 5 件が一致") == "5 件を試して 5 件が一致")
        }
    }

    @Test func 許可語を含むだけでは通さない() {
        // **この 1 件がこの型の存在理由。** 「成年コミック」を許可語に持つと、
        // それを含む実ファイル名が素通りする——過去に起きた事故そのもの。
        withAllowed(["成年コミック"]) {
            let name = "(成年コミック) [著者] 実在しそうな作品名.cbz"
            #expect(ControlRedaction.apply(name) != name)
            #expect(ControlRedaction.apply(name).hasPrefix("⟨"))
        }
    }

    @Test func 覆われない文字列は文字数だけを残す() {
        withAllowed([]) {
            #expect(ControlRedaction.apply("作品名A") == "⟨4 文字⟩")
        }
    }

    @Test func 空文字はそのまま返す() {
        withAllowed([]) {
            #expect(ControlRedaction.apply("") == "")
        }
    }

    @Test func 伏字を切れば素通しする() {
        let previous = ControlRedaction.isEnabled
        ControlRedaction.isEnabled = false
        #expect(ControlRedaction.apply("実在しそうな作品名") == "実在しそうな作品名")
        ControlRedaction.isEnabled = previous
    }
}
#endif
