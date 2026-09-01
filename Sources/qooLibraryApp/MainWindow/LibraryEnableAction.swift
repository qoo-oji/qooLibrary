//
//  登録フォルダをライブラリとして有効化する [RG-01][LT-03]。
//
//  フェーズ 2 の成果（DB・パーサ・スキャン）がアプリから初めて呼ばれる場所。
//
import QooApplication
import QooInfrastructure
import QooKit
import SwiftUI

/// 有効化と初回スキャンの実処理。**フォルダツリーとメニューの両方から
/// 同じ実装を呼ぶ**——同じに見える操作に独立した経路を作ると、片方だけ
/// 直して取り残す（1-12 のアプリ関連付けで実際に踏んだ形）。
@MainActor
enum LibraryEnableAction {

    /// 有効化済みのライブラリを走査し直す [SY-05]。
    static func rescan(folder: RegisteredFolder, url: URL, locale: Locale,
                       openWindow: OpenWindowAction) {
        guard let summary = LibraryServices.shared.library(registrationUUID: folder.id) else { return }
        Task { await scan(libraryID: summary.id, displayName: folder.displayName,
                          url: url, locale: locale, openWindow: openWindow) }
    }

    /// ライブラリだけを手がかりに走査し直す [SY-05]。
    ///
    /// **根の URL を呼び出し側に要求しない。** 設定ウインドウのように
    /// フォルダツリーを持たない画面からも呼べるようにするため、登録フォルダの
    /// 解決をここで行う——View 越しに要求を回す作りにすると、メインウインドウが
    /// 閉じていると黙って何も起きない（実機検証でそうなった）。
    static func rescan(library: LibrarySummary, locale: Locale,
                       openWindow: OpenWindowAction) {
        Task {
            let folders = await RegisteredFolderStore.shared.folders(kind: .library)
                + RegisteredFolderStore.shared.folders(kind: .temporary)
            guard let folder = folders.first(where: { $0.id == library.uuid }),
                  let url = await RegisteredFolderStore.shared.resolvedURL(for: folder) else {
                await NotificationRouter.shared.presentError(
                    LibraryRootUnavailableError(displayName: library.displayName),
                    whatHappened: String(localized: "library.scan.failed", locale: locale))
                return
            }
            await scan(libraryID: library.id, displayName: library.displayName,
                       url: url, locale: locale, openWindow: openWindow)
        }
    }

    /// 登録ウィザードの確定 [RG3-25][RG3-26]。登録 → 有効化 → 初回走査を
    /// 1 本の経路で行う。**「登録」を押すまで DB には何も書かれていない**——
    /// ウィザードが集めた草案とフォルダをここで初めて永続化する。
    static func registerAndEnable(url: URL, displayName: String?,
                                  draft: LibrarySettingsDraft,
                                  template: LibraryTypeTemplate?,
                                  locale: Locale, openWindow: OpenWindowAction) {
        Task {
            let result: RegisteredFolderStore.RegistrationResult
            do {
                result = try await RegisteredFolderStore.shared.register(
                    url: url, kind: .library, displayName: displayName)
            } catch {
                await NotificationRouter.shared.presentError(
                    error,
                    whatHappened: String(localized: "folderTree.registrationFailedTitle",
                                         locale: locale))
                return
            }
            // 登録の増減はアプリ全体の信号で知らせる（フォルダツリーの
            // 登録ルート行は各行の監視ではなくこの信号で読み直す）。
            SessionState.shared.reloadToken += 1
            // 登録は通ったが知らせるべきこと [FS-06][NV-87]。
            if !result.warnings.isEmpty {
                await NotificationRouter.shared.present(NotificationItem(
                    category: .warning, severity: .transient,
                    title: String(localized: "folderTree.registeredWithWarningTitle",
                                  locale: locale),
                    body: result.warnings
                        .map { registrationWarningDescription($0, locale: locale) }
                        .joined(separator: "\n")
                ))
            }
            await enable(folder: result.folder, url: url, draft: draft,
                         template: template, locale: locale, openWindow: openWindow)
        }
    }

    /// 登録時の警告 [FS-06][NV8-04] をユーザー向けの文にする。
    /// 登録の経路が 2 つ（ウィザード・テンポラリのパネル）あるため、
    /// 文言はここ 1 箇所に置く。
    static func registrationWarningDescription(_ warning: RegistrationWarning,
                                               locale: Locale) -> String {
        switch warning {
        case .networkVolumeFSEventsUnreliable:
            return String(localized: "folderTree.warning.networkVolume", locale: locale)
        case let .cloudSyncedLocation(provider):
            guard let provider else {
                return String(localized: "folderTree.warning.cloudSynced", locale: locale)
            }
            return String(
                format: String(localized: "folderTree.warning.cloudSyncedNamed", locale: locale),
                provider)
        }
    }

    static func disable(folder: RegisteredFolder) {
        Task {
            do {
                try await LibraryServices.shared.disable(registrationUUID: folder.id)
            } catch {
                await NotificationRouter.shared.presentError(
                    error, whatHappened: String(localized: "library.disable.failed"))
            }
        }
    }

    /// 既存の登録を有効化する（起動時の再開ウィザード [§19.10 ステージ 2] の
    /// 確定）。**登録はし直さない**——`registerAndEnable` と違い、フォルダは
    /// もう `RegisteredFolderStore` にある。
    static func enableRegistered(folder: RegisteredFolder, url: URL,
                                 draft: LibrarySettingsDraft,
                                 template: LibraryTypeTemplate?,
                                 locale: Locale, openWindow: OpenWindowAction) async {
        await enable(folder: folder, url: url, draft: draft, template: template,
                     locale: locale, openWindow: openWindow)
    }

    // MARK: - 実処理

    private static func enable(folder: RegisteredFolder, url: URL,
                               draft: LibrarySettingsDraft,
                               template: LibraryTypeTemplate?, locale: Locale,
                               openWindow: OpenWindowAction) async {
        do {
            let id = try await LibraryServices.shared.enable(
                registrationUUID: folder.id,
                displayName: folder.displayName,
                url: url,
                bookmarkData: folder.bookmarkData,
                draft: draft,
                template: template)
            await scan(libraryID: id, displayName: folder.displayName, url: url,
                       locale: locale, openWindow: openWindow)
        } catch {
            await NotificationRouter.shared.presentError(
                error, whatHappened: String(localized: "library.enable.failed"))
        }
    }

    /// 走査そのもの。進捗は既存の受け皿（アプリ全体で 1 つの窓）へ流す [UI-09]。
    ///
    /// **取り消せるようにしておく** [A-04]。ライブラリは数万件になり得るので、
    /// 始めたら終わるまで止められない作りにしてはならない。ファイルシステムに
    /// 対しては読み取りしかしないため、途中で止めても利用者のファイルは変わらない。
    private static func scan(libraryID: LibraryID, displayName: String,
                             url: URL, locale: Locale,
                             openWindow: OpenWindowAction) async {
        let task = ScanTaskBox()
        let handle = OperationProgressCenter.shared.begin(
            title: String(format: String(localized: "library.scan.progressTitle", locale: locale),
                          displayName),
            cancel: { task.cancel() })
        defer { OperationProgressCenter.shared.finish(handle) }

        // ファイル単位の報告 [RG3-32] を 10 回/秒に間引いてから UI へ流す。
        // エンジンは間引かない（`ScanEngine.scan` の注記）——間引きは表示側の
        // 仕事で、実装は転送・展開と同じ `ProgressThrottle` を使う。
        // 副題は**件数**（転送と同じ鍵で「N 件中 M 件目 — 残り K 件」）。
        // ファイル名を渡してはいけない——進捗ウインドウは
        // `currentItemName` を自分の行で出すので、同じ名前が 2 行並ぶ
        // ［実機検証で発見、§19.10 ステージ 2］。
        let throttled = ProgressThrottle.wrap(ProgressReporter { progress in
            Task { @MainActor in
                OperationProgressCenter.shared.update(
                    handle, progress: progress,
                    detail: scanDetailText(progress, locale: locale))
            }
        }, totalItems: 0, totalBytes: 0)
        do {
            let summary = try await task.run {
                try await LibraryServices.shared.scan(
                    libraryID: libraryID, root: url,
                    onProgress: { scan in
                        throttled.report(OperationProgress(
                            completedItems: scan.processed,
                            totalItems: scan.total,
                            currentItemName: scan.currentName))
                    })
            }
            guard !summary.cancelled else { return }
            await notifyIfNoteworthy(summary, displayName: displayName,
                                     libraryID: libraryID, locale: locale,
                                     openWindow: openWindow)
            // **ここで要約を再掲しない。** `ScanEngine` が同じ数字を
            // `[Scan] スキャン完了` として既に書いており、二重に出るだけで
            // 情報が増えない。しかもこの関数は初回と再スキャンの両方から
            // 呼ばれるので、「初回スキャン完了」と書くと再スキャンのときに
            // 嘘になる（実機のログで実際にそうなっていた）。
        } catch is CancellationError {
            // 利用者が止めた。通知しない。
        } catch {
            await NotificationRouter.shared.presentError(
                error, whatHappened: String(localized: "library.scan.failed"))
        }
    }


    /// 走査の結果のうち、**利用者が知るべきもの**だけを提示する
    /// [ER-01][ER-11][IF-05]。
    ///
    /// ## 何も無ければ黙る［ユーザー判断］
    /// 「今すぐ再スキャン」は日常的に走らせる操作なので、変化が無いのに毎回
    /// ダイアログが出ると、**本当に見てほしいときの 1 枚まで読み飛ばされる**
    /// ようになる。出すのは次の 3 つが 1 つでもあるときだけ:
    ///
    /// - **孤立**: 登録済みの実体が見つからなくなった [ID-06]。「ファイルが
    ///   消えた」という意味なので、黙って進めてよい情報ではない。
    /// - **未解決**: どのフォーマットにも一致しなかった [AL-31]。ラベルが
    ///   付かないまま埋もれる。
    /// - **1 冊扱いの解除**: 仕様が「通知する」と明示している [IF-05]。
    ///   孤立とは違い**実体はまだそこにある**ので、取り違えないよう別の文で書く。
    ///
    /// 成功そのものの要約は `ScanEngine` が診断ログへ書いている。
    ///
    /// - Note: どのファイルが孤立したかを一覧で見て片付ける手段
    ///   （`OR-01〜05` の整理ウインドウ）は 2-14 の担当［ユーザー判断: 今は
    ///   件数を知らせるだけにする］。ここで一覧を出す造りにはしない。
    /// 走査の進捗の副題。「2,501 件中 300 件目 — 残り 2,201 件」——転送
    /// （`FolderOperations.progressDetail`）と同じ鍵で見え方を揃える [RG3-32]。
    /// 列挙の段（総数が未確定＝ `totalItems == 0`）は見つけた件数だけを出す。
    ///
    /// 走査の `processed` は「いま処理しているファイルの通し番号」（1 始まり）
    /// なので、転送側と違い +1 しない。
    private static func scanDetailText(_ progress: OperationProgress,
                                       locale: Locale) -> String? {
        if progress.totalItems > 1 {
            let current = min(max(progress.completedItems, 1), progress.totalItems)
            var parts = [String(format: String(localized: "progress.itemCount", locale: locale),
                               current, progress.totalItems)]
            let remaining = progress.totalItems - current
            if remaining > 0 {
                parts.append(String(format: String(localized: "progress.remainingItems", locale: locale),
                                    remaining))
            }
            return parts.joined(separator: " — ")
        }
        if progress.completedItems > 0 {
            return String(format: String(localized: "progress.scanFound", locale: locale),
                          progress.completedItems)
        }
        return nil
    }

    private static func notifyIfNoteworthy(_ summary: ScanSummary,
                                           displayName: String,
                                           libraryID: LibraryID?,
                                           locale: Locale,
                                           openWindow: OpenWindowAction) async {
        var lines: [String] = []
        if summary.orphaned > 0 {
            lines.append(String(format: String(localized: "library.scan.orphaned", locale: locale),
                                summary.orphaned))
        }
        var actions: [RecoveryAction] = []
        if summary.unresolvedNames > 0 {
            lines.append(String(format: String(localized: "library.scan.unresolved", locale: locale),
                                summary.unresolvedNames))
            // **整理ウインドウへの導線を出す** [UR2-02][AL-30]。孤立
            // （件数を知らせるだけ）と扱いを変えているのは、未解決は放置すると
            // **ラベルが 1 つも付かないまま蔵書に埋もれる**ため——ラベル
            // フィルタからは永久に辿り着けない。§4.11 が導線を名指ししている。
            actions.append(RecoveryAction(
                id: NotificationRouteAction.reviewUnresolved,
                title: String(localized: "library.scan.reviewUnresolved", locale: locale),
                kind: .openWindow(NotificationRouteAction.reviewUnresolved)))
        }
        if !summary.bookFoldersReleased.isEmpty {
            lines.append(String(format: String(localized: "library.scan.bookFoldersReleased", locale: locale),
                                summary.bookFoldersReleased.count))
        }
        // **巻数の判断待ち** [EM-26][EM-31]。`ComicInfo.xml` の `Number` と
        // `Volume` が食い違っていて、どちらが巻数か機械的に決められない。
        // スキャンは止めずに走り切ってから、まとめて聞く。
        if summary.volumeConflicts > 0 {
            lines.append(String(format: String(localized: "library.scan.volumeConflicts", locale: locale),
                                summary.volumeConflicts))
            actions.append(RecoveryAction(
                id: NotificationRouteAction.reviewVolumes,
                title: String(localized: "library.scan.reviewVolumes", locale: locale),
                kind: .openWindow(NotificationRouteAction.reviewVolumes)))
        }
        guard !lines.isEmpty else { return }

        let chosen = await NotificationRouter.shared.present(NotificationItem(
            category: .warning,
            // **手動の再スキャンは従来どおり強度 2（シート）** [ER-02]。
            // 自分で走らせた操作の結果は、その場で見せるのが素直である
            // ——強度 4 へ移すと「押したのに何も出ない」ことになる。
            // 通知履歴には全強度が残る [NT-01 の改訂] ので、後から読み返せる。
            severity: .sheet,
            target: target(for: libraryID, displayName: displayName),
            title: String(format: String(localized: "library.scan.reviewTitle", locale: locale),
                          displayName),
            body: lines.joined(separator: "\n"),
            actions: actions))

        // **ここでダイアログを出す。**要求を View 越しに回すと、メイン
        // ウインドウが閉じているときに黙って何も起きない［既知の失敗］。
        // 行き先の解決は `NotificationRouteAction` 1 箇所——通知履歴の行から
        // 押したときも同じ経路を通る [NT-05]。
        if let chosen, let libraryID {
            NotificationRouteAction.perform(actionID: chosen.id, libraryID: libraryID,
                                            locale: locale, openWindow: openWindow)
        }
    }

    /// 通知の対象 [NT-04]。**行 ID ではなく外部識別子（`library.uuid`）を持つ**
    /// ——登録解除で行 ID は再利用されうるし、通知は登録が消えたあとも残る。
    @MainActor
    private static func target(for libraryID: LibraryID?,
                               displayName: String) -> NotificationTarget? {
        guard let libraryID,
              let library = LibraryServices.shared.libraries.first(where: { $0.id == libraryID })
        else { return nil }
        return .library(uuid: library.uuid, name: library.displayName)
    }

    /// 自動走査（FSEvents の追随・定期フルスキャン）の結果を受け取る。
    ///
    /// **割り込まない。** 孤立 [ID-06]・未解決 [AL-31]・1 冊扱いの解除 [IF-05] は
    /// 強度 4 で履歴とバッジにだけ残す。以前ここでシートを出していた
    /// 「差し替えの確認待ち」[ID-05] は同一性確認の撤去 [§19.8] とともに消えた
    /// ——差し替えは走査が自動で引き継ぐので、割り込む理由が無くなった。
    ///
    /// 強度 4 は 1-12b の時点では出せなかった（提示先が無くログだけに
    /// なって届かない）。通知履歴とステータスバーのバッジ [NT-02] が
    /// できたことで初めて成立する。
    @MainActor
    static func notifyAutomaticScan(libraryID: LibraryID, summary: ScanSummary,
                                    locale: Locale) {
        let library = LibraryServices.shared.libraries.first { $0.id == libraryID }
        let displayName = library?.displayName ?? ""
        let target = library.map { NotificationTarget.library(uuid: $0.uuid,
                                                              name: $0.displayName) }
        recordQuietFindings(summary, libraryID: libraryID, displayName: displayName,
                            target: target, locale: locale)

    }

    /// 自動走査で同じ知らせを繰り返さないための番人 [NT-07]。
    /// **`ScanSummary` の件数は差分ではない**——理由は `ScanFindingsDigest` の doc。
    @MainActor
    private static let digest = ScanFindingsDigest()

    /// 割り込まずに履歴へ残す [OR2-05][UR2-02][IF-05][NT-01]。
    ///
    /// **何も無ければ黙る。** 変化があるたびに「12 件を取り込みました」と
    /// 残すと、外部でファイルを整理するだけで保持上限 1,000 件 [NT-07] を
    /// 数十回の操作で使い切る［ユーザー判断］。判断軸は手動の再スキャンと
    /// 同じにしてある——**どちらの経路でも同じものが残る。**
    ///
    /// **前回と同じ内容なら黙る** [`ScanFindingsDigest`]。差分走査は
    /// 恒久的に未解決なファイルを毎回数え直すので、これが無いと同じ行が
    /// 際限なく積み上がる［レビューで発見］。
    ///
    /// **導線は付ける。** 走査結果のシートに孤立の導線を足さないと決めた
    /// のは 2-14 の判断だが、それは**割り込むモーダルにボタンを増やさない**
    /// という話で、履歴の行は事情が違う——導線が無ければ、記録を読んでも
    /// そこから何もできない行き止まりになる。
    @MainActor
    private static func recordQuietFindings(_ summary: ScanSummary, libraryID: LibraryID,
                                            displayName: String,
                                            target: NotificationTarget?, locale: Locale) {
        let findings = ScanFindingsDigest.Findings(
            orphaned: summary.orphaned,
            unresolved: summary.unresolvedNames,
            bookFoldersReleased: summary.bookFoldersReleased.count)
        guard digest.shouldRecord(findings, for: libraryID) else { return }

        var lines: [String] = []
        var actions: [RecoveryAction] = []
        if summary.orphaned > 0 {
            lines.append(String(format: String(localized: "library.scan.orphaned", locale: locale),
                                summary.orphaned))
            actions.append(RecoveryAction(
                id: NotificationRouteAction.reviewOrphans,
                title: String(localized: "library.scan.reviewOrphans", locale: locale),
                kind: .openWindow(NotificationRouteAction.reviewOrphans)))
        }
        if summary.unresolvedNames > 0 {
            lines.append(String(format: String(localized: "library.scan.unresolved", locale: locale),
                                summary.unresolvedNames))
            actions.append(RecoveryAction(
                id: NotificationRouteAction.reviewUnresolved,
                title: String(localized: "library.scan.reviewUnresolved", locale: locale),
                kind: .openWindow(NotificationRouteAction.reviewUnresolved)))
        }
        if !summary.bookFoldersReleased.isEmpty {
            lines.append(String(format: String(localized: "library.scan.bookFoldersReleased",
                                               locale: locale),
                                summary.bookFoldersReleased.count))
        }
        guard !lines.isEmpty else { return }
        let item = NotificationItem(
            category: .warning,
            // 強度 4＝一時通知。**提示はされず履歴とバッジにだけ残る** [NT-02]。
            severity: .transient,
            target: target,
            title: String(format: String(localized: "library.scan.reviewTitle", locale: locale),
                          displayName),
            body: lines.joined(separator: "\n"),
            actions: actions)
        Task { await NotificationRouter.shared.present(item) }
    }

    static func presentUnavailable(_ failure: StoreStartupFailure?) {
        Task {
            await NotificationRouter.shared.presentError(
                LibraryUnavailableError(failure: failure),
                whatHappened: String(localized: "library.unavailable"))
        }
    }
}

/// 取り消しのために走査タスクを掴んでおく箱。
@MainActor
private final class ScanTaskBox {
    private var handle: Task<ScanSummary, Error>?

    /// **`Task` に包んでから待つ**——`cancel()` は進捗の窓のボタンから
    /// 別の呼び出しとして届くので、取り消せる対象を掴んでおく必要がある。
    /// 呼び出し側の `await` をそのまま取り消させることはできない。
    func run(_ body: @escaping @Sendable () async throws -> ScanSummary) async throws -> ScanSummary {
        let task = Task { try await body() }
        handle = task
        return try await task.value
    }

    func cancel() { handle?.cancel() }
}

/// ライブラリ機能が使えないことを ER-03 の三要素で伝える。
struct LibraryUnavailableError: Error, UserPresentableError {
    let failure: StoreStartupFailure?

    var whatHappened: String { String(localized: "library.unavailable") }

    var whyItHappened: String {
        switch failure {
        case .schemaTooNew:
            String(localized: "library.unavailable.schemaTooNew")
        case .migrationFailed:
            String(localized: "library.unavailable.migrationFailed")
        case .templatesUnavailable:
            String(localized: "library.unavailable.templates")
        case .storeLocationUnavailable, .openFailed, .none:
            String(localized: "library.unavailable.openFailed")
        }
    }

    var recoverySuggestions: [RecoveryAction] { [] }
    var recoveryHint: String? { String(localized: "library.unavailable.hint") }
    var technicalDetail: String? {
        guard let failure else { return nil }
        return String(describing: failure)
    }
    var severity: NotificationSeverity { .sheet }
}

/// 走査したいのに根へ到達できない [1-17 の縮退状態]。
struct LibraryRootUnavailableError: Error, UserPresentableError {
    let displayName: String

    var whatHappened: String { String(localized: "library.rootUnavailable") }
    var whyItHappened: String { String(localized: "library.rootUnavailable.why") }
    var recoverySuggestions: [RecoveryAction] { [] }
    var recoveryHint: String? { String(localized: "library.rootUnavailable.hint") }
    var technicalDetail: String? { displayName }
    var severity: NotificationSeverity { .sheet }
}

/// 登録解除でライブラリのデータも消えることを伝える確認 [RG-06]。
///
/// **ラベル保管庫（2-11）が入るまでの暫定。** `LibraryRepository.unregister` は
/// `keepLabels` をまだ見ずに連鎖削除するため、ここで「保持する」を選ばせられない。
/// 選べない以上、せめて**何が失われるかを言ってから**消す。
struct LibraryUnregisterConfirmationDialog: View {
    @Environment(\.locale) private var locale
    @Environment(\.dialogDismiss) private var dismiss

    let folderName: String
    let onConfirm: () -> Void

    var body: some View {
        DialogScaffold(
            width: 420,
            confirm: DialogButton(
                title: String(localized: "folderTree.unregister", locale: locale),
                role: .destructive
            ) { onConfirm() },
            cancel: DialogButton(
                title: String(localized: "common.cancel", locale: locale), role: .cancel
            ) { dismiss() }
        ) {
            VStack(alignment: .leading, spacing: Tokens.spacing.s) {
                Text(String(
                    format: String(localized: "library.unregister.explanation", locale: locale),
                    folderName))
                    .fixedSize(horizontal: false, vertical: true)
                Text("library.unregister.warning")
                    .font(.system(size: Tokens.fontSize.caption))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
