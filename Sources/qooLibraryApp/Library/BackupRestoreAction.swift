import AppKit
import QooApplication
import QooInfrastructure
import QooKit
import SwiftUI

/// 自動バックアップの世代に対する操作 [BK-03][BK-04][IE-16]。
///
/// `LibraryBackupAction`（JSON の書き出し・取り込み）と同じく、**パネルの
/// 提示からエラー表示までを 1 箇所にまとめる**——同じ操作に独立した経路を
/// 作ると片方だけ直して取り残す。
///
/// ## 復元は「予約して終了する」
///
/// ここでは何も差し替えない。予約を置いてアプリを終了し、**次の起動で
/// `QooDatabase.open` の前に**差し替える（理由は `PendingRestore` の doc）。
/// この型がするのは「確認を取り、予約し、終了する」までである。
@MainActor
enum BackupRestoreAction {

    // MARK: - 復元 [BK-03][IE-16]

    static func confirmRestore(_ generation: BackupGeneration, locale: Locale,
                               onFinished: @escaping () -> Void) {
        DialogWindowPresenter.shared.present(
            title: AppStrings.text("preferences.reset.restoreConfirmTitle", locale: locale)
        ) { _ in
            BackupRestoreConfirmationDialog(generation: generation) {
                restore(generation, locale: locale, onFinished: onFinished)
            }
        }
    }

    private static func restore(_ generation: BackupGeneration, locale: Locale,
                                onFinished: @escaping () -> Void) {
        Task {
            do {
                // **検分は実 I/O**（`PRAGMA integrity_check`）。同期で呼ぶと
                // 押した瞬間に画面が固まる——`BackupService.requestRestore`
                // が `FileIO` の上で回す。
                try await LibraryServices.shared.requestRestore(generation)
            } catch {
                onFinished()
                await NotificationRouter.shared.presentError(
                    error,
                    whatHappened: AppStrings.text("preferences.reset.restoreFailed",
                                         locale: locale))
                return
            }
            // **すぐ終了する。** 予約を置いたまま使い続けると、そのあとの
            // 編集は次の起動の差し替えで捨てられる——「戻す」と決めた後の
            // 作業を黙って失わせないため。**自動では起動し直さない**
            // （`PendingRestore` の doc）。
            //
            // **メインアクタのジョブの外から呼ぶ**［実機検証で発見、2026-09-06］。
            // `NSApplication.terminate:` は `AppDelegate` が `.terminateLater` を
            // 返すと、**メインスレッドを入れ子のイベントループで占有したまま**
            // 返答を待つ（`_shouldTerminate` → `nextEventMatchingMask:`。
            // `sample` のスタックで確認した）。この `Task` の中から呼ぶと、
            // **メインアクタの現在のジョブが終わらない**ので、`AppDelegate` が
            // 返答用に作る `Task` が 1 つも走れず**永久に終了できなくなる**
            // ——しかも以後は Quit メニューまで無効になり、強制終了しか
            // 手が無くなる（＝復元を頼んだ利用者が、そのあとの作業を
            // まるごと失う。この関数がまさに防ごうとしていること）。
            //
            // **`DispatchQueue.main.async` では直らない**［同日、2 度目の実測］。
            // 入れ子のループのスタックには
            // `__CFRUNLOOP_IS_SERVICING_THE_MAIN_DISPATCH_QUEUE__` が現れない
            // ——**メインキューのドレインの中から `terminate:` を呼ぶと、その
            // 入れ子ループはメインキューを再入ドレインできない**（dispatch の
            // 規則）。`Task`（メインアクタのジョブ＝メインキューのブロック）も
            // `DispatchQueue.main.async` も、どちらもドレインの中である。
            //
            // **ランループのブロックとして呼ぶ**とドレインの外へ出られる
            // ——通常の ⌘Q（AppKit のイベント処理から呼ばれる）と同じ位置で、
            // 入れ子のループがメインキューを普通に捌けるようになる。
            RunLoop.main.perform(inModes: [.common]) {
                MainActor.assumeIsolated { NSApp.terminate(nil) }
            }
        }
    }

    // MARK: - 任意フォルダへの書き出し [BK-04]

    /// 世代を利用者が選んだ場所へ写す [BK-04]。
    ///
    /// **`FileOperationService` を通す** [FO-01]。行き先はユーザーに見える
    /// 場所なので、`BackupStore` の免除（アプリ内部の領域だから）はここには
    /// 及ばない——この区別は 07章 §7.6 に明記してある。
    static func exportToFolder(_ generation: BackupGeneration, locale: Locale) {
        // **保存パネルではなくフォルダを選ばせる。** 世代のファイル名は
        // 日時・理由・種別を綴った意味のある名前で（`BackupFileName`）、
        // 名前を変えられると**戻すときに世代として解釈できなくなる**。
        // `FileOperationService.copy` が行き先フォルダを取るのとも噛み合う。
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = AppStrings.text("preferences.reset.exportGenerationPrompt", locale: locale)
        panel.message = AppStrings.text("preferences.reset.exportGenerationMessage", locale: locale)
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        let destination = folder.appendingPathComponent(generation.fileName, isDirectory: false)

        let handle = OperationProgressCenter.shared.begin(
            title: AppStrings.text("preferences.reset.exportingGeneration", locale: locale))
        Task {
            defer { OperationProgressCenter.shared.finish(handle) }
            do {
                _ = try await FileOperationService.shared.copy(
                    [generation.url], to: folder,
                    options: OpOptions(conflictPolicy: .replace))
                // **どこへ保存されたか分からない**を防ぐ（書き出しと同じ）。
                NSWorkspace.shared.activateFileViewerSelecting([destination])
            } catch {
                await NotificationRouter.shared.presentError(
                    error,
                    whatHappened: AppStrings.text("preferences.reset.exportGenerationFailed",
                                         locale: locale))
            }
        }
    }

    // MARK: - 削除

    static func confirmDelete(_ generation: BackupGeneration, locale: Locale,
                              onFinished: @escaping () -> Void) {
        DialogWindowPresenter.shared.present(
            title: AppStrings.text("preferences.reset.deleteGenerationTitle", locale: locale)
        ) { _ in
            BackupGenerationDeleteDialog(generation: generation) {
                do {
                    try LibraryServices.shared.removeBackupGeneration(generation)
                } catch {
                    Task {
                        await NotificationRouter.shared.presentError(
                            error,
                            whatHappened: String(
                                localized: "preferences.reset.deleteGenerationFailed",
                                locale: locale))
                    }
                }
                onFinished()
            }
        }
    }

    // MARK: - 起動直後に 1 度だけ [BK-03][RB-03][RB-06]

    private static var hasRunThisLaunch = false

    /// 起動後、最初のメインウインドウの `.task` から一度だけ呼ぶ
    /// （`LibrarySetupPrompt.runOnce` と同じ位置づけ・同じ理由——
    /// `@Environment(\.openWindow)` は View からしか取れない）。
    static func runOnce(locale: Locale, openWindow: OpenWindowAction) {
        guard !hasRunThisLaunch else { return }
        hasRunThisLaunch = true
        Task {
            guard await waitUntilBootstrapFinished() else { return }
            // 順序が意味を持つ——**まず「戻した」ことを伝え**、そのうえで
            // まだ不調なら提案する。逆にすると、復元が効いていないときに
            // 「復元しました」と「壊れています」が同時に出て読めなくなる。
            //
            // **`await` で連ねる**［code-review で発見］。独立した `Task` を
            // 2 つ起こすと開始順は投入順と一致せず、**この順序は保証されない**
            // ——操作履歴と通知履歴の追記でまったく同じ形を踏んで、明示的な
            // 直列化で直したばかりである。
            await reportOutcomeIfAny(locale: locale)
            await proposeRecoveryIfNeeded(locale: locale, openWindow: openWindow)
        }
    }

    /// `bootstrap()` の**完了**を待つ。
    ///
    /// **`isReady` だけを待ってはならない** [RB-03]——開けなかった起動こそ
    /// 復元を提案したい場面で、そこでは `isReady` が永久に偽になる。
    private static func waitUntilBootstrapFinished() async -> Bool {
        for _ in 0 ..< 60 {   // 250ms × 60 = 15 秒
            let services = LibraryServices.shared
            if services.isReady || services.startupFailure != nil { return true }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return false
    }

    // MARK: - 起動時の報告 [BK-03]

    /// 直前の起動で予約されていた復元の結果を 1 度だけ伝える。
    ///
    /// **成功も失敗も言う。** 成功を黙ると「戻したはずだが戻ったのか
    /// 分からない」、失敗を黙ると**戻っていないのに戻ったと思ったまま
    /// 使い続ける**ことになる。
    static func reportOutcomeIfAny(locale: Locale) async {
        guard let outcome = LibraryServices.shared.restoreOutcome else { return }
        let item: NotificationItem
        if let failure = outcome.failure {
            item = NotificationItem(
                category: .error, severity: .sheet,
                title: AppStrings.text("preferences.reset.restoreFailedTitle", locale: locale),
                body: message(for: failure, locale: locale),
                technicalDetail: String(describing: failure))
        } else {
            // **束が戻らなかったことは伝える** [BK-06]［code-review で発見］
            // ——`library.uuid` は登録フォルダ ID そのものなので、DB だけ
            // 戻ってブックマークが現在のままだと、**行はあるのに実体へ
            // 到達できないライブラリ**ができる。黙ると原因が分からない。
            var body = AppStrings.text("preferences.reset.restoredBody", locale: locale)
            if !outcome.appDataRestored {
                body += "\n\n"
                    + AppStrings.text("preferences.reset.restoredWithoutAppData", locale: locale)
            }
            item = NotificationItem(
                category: .info, severity: .sheet,
                title: AppStrings.text("preferences.reset.restoredTitle", locale: locale),
                body: body)
        }
        await NotificationRouter.shared.present(item)
    }

    // MARK: - 起動時の提案 [RB-03][RB-06]

    /// ストアが壊れている／開けないときに、復元を提案する [RB-03][RB-06]。
    ///
    /// **`startupFailure` を待たない。** あれは利用者が何かをしようとした
    /// ときにだけ出るので、**いちばん復元が要る場面で誰も気づかない**
    /// ——起動した時点で言うのが RB-03 の趣旨である。
    ///
    /// 行き先は環境設定「リセット」タブの世代一覧。**専用のダイアログに
    /// 一覧を作らない**——同じ一覧が 2 箇所にできると、片方だけ直して
    /// 取り残す（このリポジトリが繰り返し踏んでいる形）。
    static func proposeRecoveryIfNeeded(locale: Locale,
                                        openWindow: OpenWindowAction) async {
        let services = LibraryServices.shared
        let health = services.storeHealth
        guard health.needsRecovery else { return }
        // 控えが 1 件も無ければ提案しない——押しても何もできない画面へ
        // 送ることになる。事実だけを伝える。
        let hasStoreCopy = ((try? services.backupGenerations()) ?? [])
            .contains { $0.kind == .store }

        var actions: [RecoveryAction] = []
        if hasStoreCopy {
            actions.append(RecoveryAction(
                id: openRestore,
                title: AppStrings.text("preferences.reset.openRestore", locale: locale),
                kind: .openWindow(openRestore)))
        }
        let chosen = await NotificationRouter.shared.present(NotificationItem(
            category: .error, severity: .appModal,
            title: AppStrings.text("library.storeUnhealthyTitle", locale: locale),
            body: body(for: health, hasStoreCopy: hasStoreCopy, locale: locale),
            technicalDetail: String(describing: services.startupFailure),
            actions: actions))
        if chosen?.id == openRestore { openRestoreTab(openWindow: openWindow) }
    }

    /// 「リセット」タブを開く導線の識別子。**ドットを含めない**——
    /// `check-localization-keys` が文字列カタログの鍵と誤検出するため。
    static let openRestore = "open-backup-restore"

    /// 環境設定「リセット」タブを開く。**行き先を先に予約してから開く**
    /// ——既に開いているウインドウが前面に来ただけのときにも届くように
    /// （`PreferencesNavigation` の doc、`AccessDeniedRow` と同じ形）。
    static func openRestoreTab(openWindow: OpenWindowAction) {
        PreferencesNavigation.shared.pendingCategory = .reset
        openWindow(id: "preferences")
    }

    private static func body(for health: StoreHealth, hasStoreCopy: Bool,
                             locale: Locale) -> String {
        let cause: String = switch health {
        case .corrupt: "library.storeCorrupt"
        // **中身は読めた**ことを必ず言う [RB-06]——「データは残っている」と
        // 分かるかどうかで、利用者の次の一手がまったく変わる。
        case .unopenableButReadable: "library.storeUnopenableButReadable"
        case .tooNew: "library.storeTooNew"
        case .healthy: "library.storeCorrupt"
        }
        let next: String = health == .tooNew
            ? "library.storeUpdateApp"
            : (hasStoreCopy ? "library.storeRestoreAvailable" : "library.storeNoBackup")
        return AppStrings.text(cause, locale: locale) + "\n\n"
            + AppStrings.text(next, locale: locale)
    }

    private static func message(for failure: RestoreOutcome.Failure, locale: Locale) -> String {
        switch failure {
        case .generationMissing:
            AppStrings.text("preferences.reset.restoreFailedMissing", locale: locale)
        case .sourceCorrupt:
            AppStrings.text("preferences.reset.restoreFailedCorrupt", locale: locale)
        case .sourceTooNew:
            AppStrings.text("preferences.reset.restoreFailedTooNew", locale: locale)
        case .swapFailed:
            AppStrings.text("preferences.reset.restoreFailedSwap", locale: locale)
        }
    }
}

/// 復元の確認 [BK-03][IE-16]。
///
/// **3 つを必ず言う**——①いま入っているデータが差し替わること
/// ②差し替え前の状態も控えとして残ること ③**アプリを終了すること**。
/// ③を言わないと、押した瞬間にアプリが消えたように見える。
struct BackupRestoreConfirmationDialog: View {
    @Environment(\.locale) private var locale
    @Environment(\.dialogDismiss) private var dismiss

    let generation: BackupGeneration
    let onConfirm: () -> Void

    var body: some View {
        DialogScaffold(
            width: 460,
            confirm: DialogButton(
                title: AppStrings.text("preferences.reset.restoreConfirm", locale: locale),
                role: .destructive
            ) {
                dismiss()
                onConfirm()
            },
            cancel: DialogButton(
                title: AppStrings.text("common.cancel", locale: locale), role: .cancel
            ) { dismiss() }
        ) {
            VStack(alignment: .leading, spacing: Tokens.spacing.s) {
                // どの世代へ戻すのかを最初に示す。日時と契機の 2 つで
                // 十分に見分けられる（一覧と同じ書き方 [BackupGenerationFormatting]）。
                Text(BackupGenerationFormatting.date(generation.date, locale: locale)
                     + " — "
                     + BackupGenerationFormatting.reason(generation.reason, locale: locale))
                    .fontWeight(.medium)
                Text("preferences.reset.restoreExplanation")
                    .fixedSize(horizontal: false, vertical: true)
                Text("preferences.reset.restoreQuitNotice")
                    .font(.system(size: Tokens.fontSize.caption))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// 世代 1 件の削除。
struct BackupGenerationDeleteDialog: View {
    @Environment(\.locale) private var locale
    @Environment(\.dialogDismiss) private var dismiss

    let generation: BackupGeneration
    let onConfirm: () -> Void

    var body: some View {
        DialogScaffold(
            width: 420,
            confirm: DialogButton(
                title: AppStrings.text("common.delete", locale: locale), role: .destructive
            ) {
                onConfirm()
                dismiss()
            },
            cancel: DialogButton(
                title: AppStrings.text("common.cancel", locale: locale), role: .cancel
            ) { dismiss() }
        ) {
            VStack(alignment: .leading, spacing: Tokens.spacing.s) {
                Text(String(format: AppStrings.text("preferences.reset.deleteGenerationBody",
                                           locale: locale),
                            BackupGenerationFormatting.date(generation.date, locale: locale)))
                    .fixedSize(horizontal: false, vertical: true)
                Text("preferences.reset.deleteGenerationNotice")
                    .font(.system(size: Tokens.fontSize.caption))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// 世代を画面に出すときの言葉 [BK-03]。**一覧とダイアログで 1 箇所にする**
/// ——同じ世代が場所によって違う書き方で出ると、どれのことか分からなくなる。
enum BackupGenerationFormatting {
    static func date(_ date: Date, locale: Locale) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    static func reason(_ reason: BackupReason, locale: Locale) -> String {
        AppStrings.text(key(for: reason), locale: locale)
    }

    /// **網羅的な `switch`**——契機を足した人がここで必ず言葉を決めることになる。
    private static func key(for reason: BackupReason) -> String {
        switch reason {
        case .launch: "backup.reason.launch"
        case .schemaMigration: "backup.reason.schemaMigration"
        case .jsonImport: "backup.reason.jsonImport"
        case .bulkLabelDelete: "backup.reason.bulkLabelDelete"
        case .templateApply: "backup.reason.templateApply"
        case .libraryDelete: "backup.reason.libraryDelete"
        case .beforeRestore: "backup.reason.beforeRestore"
        }
    }

    static func kind(_ kind: BackupGeneration.Kind, locale: Locale) -> String {
        switch kind {
        case .document: AppStrings.text("backup.kind.document", locale: locale)
        case .store: AppStrings.text("backup.kind.store", locale: locale)
        case .appData: AppStrings.text("backup.kind.appData", locale: locale)
        }
    }
}
