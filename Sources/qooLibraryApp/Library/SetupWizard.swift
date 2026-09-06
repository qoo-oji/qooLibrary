//
//  初回セットアップウィザードの入口 [OB-01、15章 §15.12]。
//
//  起動時の自動提示と、メニュー「初回セットアップをやり直す」の 2 つ。
//  **どちらも同じ `present` を通る**——同じ画面に独立した経路を 2 つ作ると、
//  片方だけ直して取り残す（このリポジトリが繰り返し踏んでいる形）。
//
import QooApplication
import QooInfrastructure
import QooKit
import SwiftUI

@MainActor
enum SetupWizard {

    private static var hasRunThisLaunch = false

    /// 起動後、最初のメインウインドウの `.task` から一度だけ呼ぶ [OB-01]。
    ///
    /// **出したら `true` を返す。** 呼び出し側はそのとき
    /// `LibrarySetupPrompt`（未有効登録の再開）を走らせない [SW-07]——
    /// 実際には条件が排他的（こちらは登録 0 件、あちらは登録があって未有効）
    /// なので競合しないが、将来どちらかの条件が変わったときに窓が重なる
    /// のを構造で防いでおく。
    static func runOnceIfNeeded(locale: Locale, openWindow: OpenWindowAction) async -> Bool {
        guard !hasRunThisLaunch else { return false }
        hasRunThisLaunch = true

        // **判定に DB を使わない** [SW-01]。ライブラリ登録は
        // `RegisteredFolderStore`（JSON）が持っており、概念モデル v3 では
        // 「登録＝ライブラリ化」[RG3-20] なので登録の件数で足りる。DB が
        // 開けなかった起動でもステップ 1〜3（アクセス権・関連付け）は
        // 意味を持つので、そこで諦める理由が無い。
        let registered = await RegisteredFolderStore.shared.folders(kind: .library).count
        guard SetupWizardGate.shouldPresent(hasCompleted: SetupWizardProgress.hasCompleted(),
                                            libraryCount: registered) else { return false }

        Log.app.info("初回セットアップウィザードを表示する（ライブラリ登録 \(registered) 件）[OB-01]")
        present(model: SetupWizardModel(), locale: locale, openWindow: openWindow)
        return true
    }

    /// メニュー「初回セットアップをやり直す」[OB-01]。
    ///
    /// **先頭から始め、完了印も落とす** [SW-06 の注記]——やり直したまま途中で
    /// 閉じたら、次の起動でも続きから出るのが「やり直し」の意味に合う。
    static func rerun(locale: Locale, openWindow: OpenWindowAction) {
        SetupWizardProgress.reset()
        present(model: SetupWizardModel(startingAt: .welcome),
                locale: locale, openWindow: openWindow)
    }

    private static func present(model: SetupWizardModel, locale: Locale,
                                openWindow: OpenWindowAction) {
        DialogWindowPresenter.shared.present(
            title: String(localized: "setupWizard.title", locale: locale)
        ) { _ in
            SetupWizardView(model: model) {
                // 最後まで進んだら**登録ウィザードへ引き渡す** [SW-02][RG3-28]。
                // 1 サイクル遅らせるのは、閉じたばかりの窓と同じフレームで
                // 次を出すと提示先（`NSApp.keyWindow`）がまだ入れ替わって
                // いないため。
                Task { @MainActor in
                    // **準備完了を待ってから渡す** [code-review の指摘]。
                    // `bootstrap()` の最中に呼ぶと `begin` が「利用できません」
                    // を出す（または `volumeSetDefinition` が nil で黙って
                    // 返る）一方、`finish()` で完了印は既に立っているので、
                    // OB-01 の経路が行き止まりになる。待てなかった場合は
                    // `begin` 自身が理由を出す [ER-01][ER-03]。
                    _ = await LibraryServices.shared.waitUntilReady()
                    LibraryRegistrationWizard.begin(locale: locale, openWindow: openWindow)
                }
            }
        }
    }
}
