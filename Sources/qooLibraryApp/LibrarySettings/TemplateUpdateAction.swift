//
//  プリセット改訂の検出・通知・差分ビューの提示 [LT-12][LT-13][LT-16]。
//
//  **設定ウインドウからも通知履歴からも、同じ実装を呼ぶ**——同じに見える
//  操作に独立した経路を作ると、片方だけ直して取り残す（1-12 のアプリ
//  関連付けで実際に踏んだ形）。
//
//  提示は `DialogWindowPresenter`（`NSApp.keyWindow` へ重ねる）で行い、
//  View の環境値を経由しない——検出は起動直後の非同期処理なので、要求を
//  View 越しに回すと「メインウインドウが閉じていると黙って何も起きない」
//  形になる［既知の失敗］。
//
import QooApplication
import QooInfrastructure
import QooKit
import SwiftUI

@MainActor
enum TemplateUpdateAction {

    // MARK: - 起動時の検出と通知 [LT-10][LT-12]

    private static var hasAnnouncedThisLaunch = false

    /// 通知済みの改訂 [LT-12]。`ライブラリの UUID → 通知した版`。
    ///
    /// **これが無いと、保留を選んだ利用者に毎起動 1 件ずつ同じ通知が積まれる**
    /// ——保持上限 [NT-07] を無関係な行で圧迫し、本当に見てほしい行を押し流す
    /// ［code-review の指摘。走査結果には `ScanFindingsDigest` が同じ問題を
    /// 塞いでいる］。
    private static let announcedKey = "qoo.templateUpdate.announcedVersions"

    private static func announcedVersion(for uuid: UUID) -> Int? {
        (UserDefaults.standard.dictionary(forKey: announcedKey)?[uuid.uuidString]) as? Int
    }

    private static func rememberAnnouncement(_ version: Int, for uuid: UUID) {
        var all = UserDefaults.standard.dictionary(forKey: announcedKey) ?? [:]
        all[uuid.uuidString] = version
        UserDefaults.standard.set(all, forKey: announcedKey)
    }

    /// 起動後、最初のメインウインドウの `.task` から一度だけ呼ぶ。
    ///
    /// **割り込まない** [LT-11]。設定には一切触れず、強度 4（一時通知）で
    /// 履歴とバッジにだけ残す——改訂は急ぐ話ではないうえ、起動のたびに
    /// シートが出ると本当に見てほしい 1 枚まで読み飛ばされるようになる。
    static func announceOnce(locale: Locale) {
        guard !hasAnnouncedThisLaunch else { return }
        hasAnnouncedThisLaunch = true
        Task { await announce(locale: locale) }
    }

    private static func announce(locale: Locale) async {
        guard await waitUntilReady() else { return }
        // **一覧を読み直してから判定する**——`isReady` は DB が開いた瞬間に
        // 真になるが、`libraries` の初回読み込みは `bootstrap()` の末尾で走る
        // （`LibrarySetupPrompt` が実機で踏んだ競合と同じ形）。
        await LibraryServices.shared.refreshLibraries()

        for pending in await TemplateUpdateModel.pending(services: LibraryServices.shared) {
            // **同じ改訂は 1 度だけ知らせる。** 見送った利用者へ毎起動
            // 出し直さない——ただし設定ウインドウの案内カードは出続けるので、
            // 気が変わったときの導線は失われない。
            guard (announcedVersion(for: pending.libraryUUID) ?? 0) < pending.toVersion
            else { continue }
            rememberAnnouncement(pending.toVersion, for: pending.libraryUUID)
            Log.app.info("""
                テンプレートの改訂を検出: \(Log.redactable(pending.libraryName)) \
                v\(pending.fromVersion) → v\(pending.toVersion) [LT-12]
                """)
            _ = await NotificationRouter.shared.present(NotificationItem(
                category: .info,
                severity: .transient,
                target: .library(uuid: pending.libraryUUID, name: pending.libraryName),
                title: String(localized: "library.templateUpdate.title", locale: locale),
                body: String(format: String(localized: "library.templateUpdate.body",
                                            locale: locale),
                             pending.presetName, pending.fromVersion, pending.toVersion,
                             pending.libraryName),
                actions: [RecoveryAction(
                    id: NotificationRouteAction.reviewTemplateUpdate,
                    title: String(localized: "library.templateUpdate.review", locale: locale),
                    kind: .openWindow(NotificationRouteAction.reviewTemplateUpdate))]))
        }
    }

    private static func waitUntilReady() async -> Bool {
        for _ in 0..<60 {   // 250ms × 60 = 15 秒
            if LibraryServices.shared.isReady { return true }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return false
    }

    // MARK: - 差分ビュー [LT-13]

    /// 差分を読み込んでダイアログを出す。**改訂が無ければ何もしない。**
    static func present(libraryID: LibraryID, locale: Locale,
                        openWindow: OpenWindowAction,
                        onFinished: (@MainActor () -> Void)? = nil) {
        Task {
            let services = LibraryServices.shared
            guard let pending = await TemplateUpdateModel.pending(services: services)
                .first(where: { $0.libraryID == libraryID })
            else {
                // **黙って返らない** [ER-01]。通知履歴の行は改訂を確認した
                // あとも残るので、そこから来た人には「もう終わっている」と
                // 伝わる必要がある［code-review の指摘］。
                _ = await NotificationRouter.shared.present(NotificationItem(
                    category: .info, severity: .sheet,
                    title: String(localized: "librarySettings.templateUpdate.title",
                                  locale: locale),
                    body: String(localized: "librarySettings.templateUpdate.alreadyReviewed",
                                 locale: locale)))
                return
            }

            let model = TemplateUpdateModel()
            await model.load(libraryID: libraryID, services: services)
            switch model.state {
            case .ready:
                break
            case .failed(let message):
                await NotificationRouter.shared.present(NotificationItem(
                    category: .error, severity: .sheet,
                    title: String(localized: "librarySettings.templateUpdate.failed",
                                  locale: locale),
                    body: message))
                return
            default:
                return   // 対象外・最新——案内カードが出ていないはずの状態
            }

            DialogWindowPresenter.shared.present(
                title: String(localized: "librarySettings.templateUpdate.title", locale: locale)
            ) { _ in
                TemplateUpdateDialog(pending: pending, model: model) {
                    Task {
                        await apply(model, libraryID: libraryID, locale: locale,
                                    openWindow: openWindow)
                        onFinished?()
                    }
                }
            }
        }
    }

    /// 適用して、必要なら既存ファイルへ再適用する [LT-16][AT-04]。
    ///
    /// **確認は挟まず、そのまま走査する**——設定ウインドウの保存と同じ扱い
    /// ［ユーザー指示: 走査は結果が変わりうる契機で自動実行すればよい。
    /// 手動の「今すぐ再スキャン」は廃止］。AT-04 が「確認を伴う」と書いて
    /// いるのは、その指示より前の版である。
    private static func apply(_ model: TemplateUpdateModel, libraryID: LibraryID,
                              locale: Locale, openWindow: OpenWindowAction) async
    {
        do {
            let changed = try await model.apply(libraryID: libraryID,
                                                services: LibraryServices.shared,
                                                stack: CommandStack.shared)
            // **設定が変わったときだけ走らせる。** 見送った（1 件も選ばな
            // かった）場合はファイルの解釈が変わらないので、走らせる意味が無い。
            guard changed,
                  let library = LibraryServices.shared.libraries.first(where: { $0.id == libraryID })
            else { return }
            LibraryEnableAction.rescan(library: library, locale: locale, openWindow: openWindow)
        } catch {
            await NotificationRouter.shared.presentError(
                error, whatHappened: String(localized: "librarySettings.templateUpdate.failed",
                                            locale: locale))
        }
    }
}
