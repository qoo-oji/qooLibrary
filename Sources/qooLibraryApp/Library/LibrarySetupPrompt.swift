//
//  未有効登録の起動時セットアップ導線 [§19.10 ステージ 2][§19.3 移行]。
//
//  登録済みだが DB にライブラリ行が無い（＝旧「有効化」を経ていない）
//  ライブラリフォルダを起動時に見つけ、登録ウィザードを**ステップ 3 から
//  再開**して有効化まで導く。概念モデル v3 では「登録＝ライブラリ化」なので、
//  この中間状態は旧版からの移行でしか生まれない——導線が無いと、その登録は
//  ツリーに並ぶだけで永久にカタログ化されない。
//
//  ## キャンセルはこの起動では聞き直さない
//  ウィザードを閉じたら、この起動中は同じ登録について再提示しない（次回の
//  起動でまた出る）。完了（有効化）した場合だけ、残りの未有効登録があれば
//  続けて提示する——複数を一度に押し付けず、1 件ずつ納得して進められる。
//
import QooApplication
import QooInfrastructure
import QooKit
import SwiftUI

@MainActor
enum LibrarySetupPrompt {

    private static var hasRunThisLaunch = false

    /// 起動後、最初のメインウインドウの `.task` から一度だけ呼ぶ。
    static func runOnce(locale: Locale, openWindow: OpenWindowAction) {
        guard !hasRunThisLaunch else { return }
        hasRunThisLaunch = true
        Task { await presentNextIfNeeded(locale: locale, openWindow: openWindow) }
    }

    private static func presentNextIfNeeded(locale: Locale,
                                            openWindow: OpenWindowAction) async {
        // DB の準備を待つ（`bootstrap()` は起動時に走っている）。開けなかった
        // 起動では何もしない——有効化しようとした時点で理由付きで断られる
        // [ER-03] ほうが、起動直後に説明なしのウィザードが出るより読める。
        guard await waitUntilServicesReady() else { return }
        let services = LibraryServices.shared
        // **一覧を読み直してから判定する**——`isReady` は DB が開いた瞬間に
        // 真になるが、`libraries` の初回読み込みは `bootstrap()` の末尾で走る。
        // 読み込み前に判定すると有効化済みの登録がすべて「未有効」に見え、
        // **ウィザードが毎起動誤発火する**［実機検証で発見、§19.10 ステージ 2。
        // 実際に全登録が有効化済みの環境で毎回出ていた］。
        await services.refreshLibraries()

        for folder in await RegisteredFolderStore.shared.folders(kind: .library) {
            // `library.uuid` は登録フォルダ ID をそのまま持つ [07章 §7.3]。
            guard services.library(registrationUUID: folder.id) == nil else { continue }
            // オフライン・消失の登録は対象外——サンプルを読めないので
            // ウィザードが成立しない。接続された次の起動で拾う。
            guard let url = await RegisteredFolderStore.shared.resolvedURL(for: folder)
            else { continue }
            Log.app.info("未有効のライブラリ登録を見つけた。ウィザードを再開する: \(Log.redactable(folder.displayName)) [§19.10 Stage 2]")
            LibraryRegistrationWizard.resume(
                folder: folder, url: url, locale: locale, openWindow: openWindow
            ) {
                // 有効化まで済んだら、残りの未有効登録も続けて提示する。
                // キャンセル（ウィザードを閉じただけ）ではここへ来ないので、
                // この起動ではもう聞かない。
                Task { await presentNextIfNeeded(locale: locale, openWindow: openWindow) }
            }
            return   // 1 度に 1 件だけ
        }
    }

    /// `LibraryServices` の準備完了を待つ。上限を過ぎたら諦める（起動が
    /// 失敗している・初回でテーブル作成に時間がかかっている等）。
    private static func waitUntilServicesReady() async -> Bool {
        for _ in 0..<60 {   // 250ms × 60 = 15 秒
            if LibraryServices.shared.isReady { return true }
            if LibraryServices.shared.startupFailure != nil { return false }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return LibraryServices.shared.isReady
    }
}
