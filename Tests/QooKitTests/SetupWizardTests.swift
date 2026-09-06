import Foundation
import Testing

@testable import QooKit

@Suite("初回セットアップウィザードのドメイン [OB-01、15章 §15.12]")
struct SetupWizardTests {

    // MARK: ステップの遷移

    @Test("自前で持つのは 3 ステップだけ [SW-02]")
    func stepCount() {
        // 要件は 7 ステップだが、4 以降は登録ウィザードへ引き渡す [RG3-28]。
        #expect(SetupStep.count == 3)
        #expect(SetupStep.allCases == [.welcome, .accessGrant, .appAssociations])
    }

    @Test("前後の関係と端の判定")
    func traversal() {
        #expect(SetupStep.welcome.isFirst)
        #expect(!SetupStep.welcome.isLast)
        #expect(SetupStep.welcome.next == .accessGrant)
        #expect(SetupStep.welcome.previous == nil)

        #expect(SetupStep.appAssociations.isLast)
        #expect(!SetupStep.appAssociations.isFirst)
        #expect(SetupStep.appAssociations.next == nil)
        #expect(SetupStep.appAssociations.previous == .accessGrant)

        #expect(SetupStep.welcome.position == 1)
        #expect(SetupStep.appAssociations.position == 3)
    }

    // MARK: 初回かどうかの判定 [SW-01]

    @Test("完了印が無く、かつ登録が 0 件のときだけ出す [SW-01]")
    func gateRequiresBothConditions() {
        // 初回。
        #expect(SetupWizardGate.shouldPresent(hasCompleted: false, libraryCount: 0))
        // 一度完了している。
        #expect(!SetupWizardGate.shouldPresent(hasCompleted: true, libraryCount: 0))
        // 完了印が無くても、自分でライブラリを登録済みなら出さない
        // ——ウィザードを使わずに始めた利用者に今さら案内しない。
        #expect(!SetupWizardGate.shouldPresent(hasCompleted: false, libraryCount: 1))
        #expect(!SetupWizardGate.shouldPresent(hasCompleted: true, libraryCount: 3))
    }

    @Test("完了印と登録の両方を要求する——片方だけの実装と区別する [SW-01]")
    func gateNeedsBothSignals() {
        // 「完了印だけ」の実装なら真になってしまう組み合わせ。
        #expect(!SetupWizardGate.shouldPresent(hasCompleted: true, libraryCount: 0))
        // 「登録の件数だけ」の実装なら真になってしまう組み合わせ。
        #expect(!SetupWizardGate.shouldPresent(hasCompleted: false, libraryCount: 2))
    }

    // MARK: ステップ 3 の既定選択 [AS-05][SW-03][SW-09]

    private func candidate(_ bundleID: String, _ name: String) -> AppCandidate {
        AppCandidate(bundleID: bundleID, name: name,
                     url: URL(fileURLWithPath: "/Applications/\(name).app"))
    }

    @Test("既に設定済みならそれを選ぶ——qooViewer より優先する [SW-03]")
    func currentAssignmentWins() {
        let candidates = [candidate(SetupViewerChoice.qooViewerBundleID, "qooViewer"),
                          candidate("com.example.other", "Other")]
        // やり直し [OB-01] のときに、利用者が自分で選んだアプリを黙って
        // qooViewer へ戻さない。
        #expect(SetupViewerChoice.resolve(candidates: candidates,
                                          current: "com.example.other")
                == .app("com.example.other"))
    }

    @Test("未設定なら qooViewer を既定にする [AS-05]")
    func prefersQooViewer() {
        let candidates = [candidate("com.example.other", "Other"),
                          candidate(SetupViewerChoice.qooViewerBundleID, "qooViewer")]
        #expect(SetupViewerChoice.resolve(candidates: candidates, current: nil)
                == .app(SetupViewerChoice.qooViewerBundleID))
    }

    @Test("qooViewer が無ければシステムの既定のまま [AS2-01]")
    func fallsBackToSystemDefault() {
        let candidates = [candidate("com.example.other", "Other")]
        #expect(SetupViewerChoice.resolve(candidates: candidates, current: nil)
                == .systemDefault)
    }

    @Test("候補に無い設定値は無視する")
    func ignoresUninstalledCurrent() {
        // 設定済みのアプリが削除された場合 [AS2-05]。候補に無い bundle ID を
        // そのまま返すと、ポップアップがどの項目も選べない状態になる。
        let candidates = [candidate(SetupViewerChoice.qooViewerBundleID, "qooViewer")]
        #expect(SetupViewerChoice.resolve(candidates: candidates,
                                          current: "com.example.deleted")
                == .app(SetupViewerChoice.qooViewerBundleID))
    }

    // MARK: 書き込むべきか [code-review の指摘]

    @Test("読み込み前は 1 バイトも書かない——既存の関連付けを消さない")
    func neverWritesBeforeLoading() {
        // `setPrimary(nil, for:)` は「システムの既定に戻す」＝**消す**書き込み。
        // 読み込みが終わる前に「完了」まで進めると、環境設定で設定した
        // pdf/epub の関連付けが黙って消える経路ができる。
        #expect(!SetupViewerChoice.shouldApply(.notLoaded, initial: .notLoaded))
        #expect(!SetupViewerChoice.shouldApply(.notLoaded, initial: .systemDefault))
    }

    @Test("利用者が触っていなければ書かない [OB-01 のやり直しで消さない]")
    func doesNotWriteWhenUnchanged() {
        #expect(!SetupViewerChoice.shouldApply(.systemDefault, initial: .systemDefault))
        #expect(!SetupViewerChoice.shouldApply(.app("com.example.a"),
                                               initial: .app("com.example.a")))
    }

    @Test("明示的に変えたときだけ書く——「システムの既定」への変更も含む")
    func writesOnExplicitChange() {
        #expect(SetupViewerChoice.shouldApply(.app("com.example.a"), initial: .systemDefault))
        // 利用者が意図して解除した場合は書く（＝関連付けを消す）。
        #expect(SetupViewerChoice.shouldApply(.systemDefault, initial: .app("com.example.a")))
        #expect(SetupViewerChoice.shouldApply(.app("com.example.b"),
                                              initial: .app("com.example.a")))
    }

    // MARK: 対象拡張子 [AS-03]

    @Test("コミック形式は 8 種で、定義は 1 箇所 [AS-03]")
    func comicFormats() {
        #expect(ComicFormats.extensions
                == ["zip", "cbz", "7z", "cb7", "rar", "cbr", "pdf", "epub"])
    }
}
