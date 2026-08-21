//
//  巻数の確認ダイアログを出す [EM-32][EM-33][15.1.2]。
//
//  **設定ウインドウからも走査完了の通知からも、同じ実装を呼ぶ**——同じに
//  見える操作に独立した経路を作ると、片方だけ直して取り残す（1-12 のアプリ
//  関連付けで実際に踏んだ形）。
//
//  提示は `DialogWindowPresenter`（`NSApp.keyWindow` へ重ねる）で行い、
//  **View の環境値を経由しない**。走査は非同期に終わるので、要求を View 越しに
//  回すと「メインウインドウが閉じていると黙って何も起きない」形になる
//  ［実機で踏んだ既知の失敗、CLAUDE.md「View を経由して要求を回さない」］。
//
import QooApplication
import QooKit
import SwiftUI

@MainActor
enum VolumeDecisionAction {

    /// 判断待ちを読み込んで確認ダイアログを出す。**0 件なら何もしない。**
    static func present(libraryID: LibraryID, locale: Locale,
                        onFinished: (@MainActor () -> Void)? = nil) {
        Task {
            let candidates: [VolumeDecisionCandidate]
            do {
                candidates = try await LibraryServices.shared
                    .filesAwaitingVolumeDecision(libraryID: libraryID)
            } catch {
                await NotificationRouter.shared.presentError(
                    error, whatHappened: String(localized: "librarySettings.volumeDecision.failed",
                                                locale: locale))
                return
            }
            guard !candidates.isEmpty else { return }
            present(candidates: candidates, libraryID: libraryID, locale: locale,
                    onFinished: onFinished)
        }
    }

    /// 既に読み込んである一覧で出す。
    ///
    /// **一覧は呼び出し側が固定して渡す。**開いている間に走査が走って件数が
    /// 変わると、利用者が見て選んだ集合と適用先がずれる。
    static func present(candidates: [VolumeDecisionCandidate], libraryID: LibraryID,
                        locale: Locale, onFinished: (@MainActor () -> Void)? = nil) {
        guard !candidates.isEmpty else { return }
        DialogWindowPresenter.shared.present(
            title: String(localized: "librarySettings.volumeDecision.title", locale: locale)
        ) { _ in
            VolumeDecisionDialog(candidates: candidates) { choices, remembered in
                Task {
                    await apply(choices, rememberFor: remembered,
                                libraryID: libraryID, locale: locale)
                    onFinished?()
                }
            }
        }
    }

    /// 判断を確定する [EM-33]。
    ///
    /// - Parameter rememberedSource: 非 nil なら**以後このライブラリでは聞かない**
    ///   ように設定も書き換える。**その場で保存する**——判断のダイアログを
    ///   閉じた人が、設定ウインドウを開いて「保存」を押すことまで期待するのは無理がある。
    static func apply(_ choices: [FileID: ComicInfoVolumeSource],
                      rememberFor rememberedSource: ComicInfoVolumeSource?,
                      libraryID: LibraryID, locale: Locale) async {
        do {
            for source in [ComicInfoVolumeSource.number, .volume] {
                let ids = choices.filter { $0.value == source }.map(\.key)
                guard !ids.isEmpty else { continue }
                try await LibraryServices.shared.resolveVolumeConflicts(ids, using: source)
            }
            if let rememberedSource,
               var draft = try await LibraryServices.shared.settingsDraft(libraryID: libraryID) {
                draft.comicInfoVolumeSource = rememberedSource
                try await LibraryServices.shared.updateSettings(draft, libraryID: libraryID)
            }
        } catch {
            await NotificationRouter.shared.presentError(
                error, whatHappened: String(localized: "librarySettings.volumeDecision.failed",
                                            locale: locale))
        }
    }
}
