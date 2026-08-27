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

    /// 設定を確認・調整させてから有効化し、続けて初回スキャンを走らせる
    /// [LT-01〜LT-03][LS-01][HP-05]。
    ///
    /// **テンプレートを選ぶだけの画面ではない**［ユーザー指摘: 「その選択肢で
    /// 何がどう変化するのかわからない」］。中身を見て、その場で直して、
    /// 実ファイル名に当てた結果まで確かめてから決められる。
    /// - Parameter openWindow: 走査結果のシートから未解決ファイルの整理
    ///   ウインドウを開くために持ち回る [UR2-02]。**`@Environment(\.openWindow)`
    ///   は View からしか取れない**ので、呼び出し側（View）から渡してもらう
    ///   ——受け皿へ預ける形にすると、預ける前に走査が終わった場合に黙って
    ///   開かなくなる。
    static func begin(folder: RegisteredFolder, url: URL, locale: Locale,
                      openWindow: OpenWindowAction) {
        let services = LibraryServices.shared
        guard services.isReady else {
            presentUnavailable(services.startupFailure)
            return
        }
        let templates = services.presetTemplates
        guard let volumeSets = services.volumeSetDefinition else { return }

        let model = LibraryEnableModel(
            folderName: folder.displayName, folderURL: url,
            templates: templates, volumeSets: volumeSets,
            // 型付き照合 [TY-01] の候補は他ライブラリの型名も含む。渡さないと
            // プレビューの結果が実際の走査とずれる。
            otherTypeNames: services.libraries.map(\.libraryTypeName),
            otherDisplayNames: services.libraries.map(\.displayName))

        DialogWindowPresenter.shared.present(
            title: String(localized: "library.enable.title", locale: locale)
        ) { _ in
            LibraryEnableView(model: model) { draft, template in
                Task {
                    await enable(folder: folder, url: url, draft: draft,
                                 template: template, locale: locale,
                                 openWindow: openWindow)
                }
            }
        }
    }

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

        do {
            let summary = try await task.run {
                try await LibraryServices.shared.scan(
                    libraryID: libraryID, root: url,
                    onProgress: { count, name in
                        Task { @MainActor in
                            OperationProgressCenter.shared.update(
                                handle,
                                progress: OperationProgress(completedItems: count,
                                                            currentItemName: name),
                                detail: name)
                        }
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
                id: Self.reviewUnresolvedActionID,
                title: String(localized: "library.scan.reviewUnresolved", locale: locale),
                kind: .openWindow(Self.reviewUnresolvedActionID)))
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
                id: Self.reviewVolumesActionID,
                title: String(localized: "library.scan.reviewVolumes", locale: locale),
                kind: .openWindow(Self.reviewVolumesActionID)))
        }
        // **同一性の確認待ち** [ID-05]。名前は同じだが inode が違うので、
        // 自動では紐づけない。走り切ってからまとめて聞く——差し替え
        // （スキャン版を電子版へ、など）は日常的に起こるので、1 件ずつ
        // 止めていては使い物にならない。
        if summary.candidatesForReview > 0 {
            lines.append(String(format: String(localized: "library.scan.identityMatches",
                                               locale: locale),
                                summary.candidatesForReview))
            actions.append(RecoveryAction(
                id: Self.reviewIdentityActionID,
                title: String(localized: "library.scan.reviewIdentity", locale: locale),
                kind: .openWindow(Self.reviewIdentityActionID)))
        }
        guard !lines.isEmpty else { return }

        let chosen = await NotificationRouter.shared.present(NotificationItem(
            category: .warning,
            // 判断を促すものなので強度 2 [ER-02]。強度 4（一時通知）は
            // フェーズ 1 の時点で提示先が無く、ログだけになって届かない。
            severity: .sheet,
            title: String(format: String(localized: "library.scan.reviewTitle", locale: locale),
                          displayName),
            body: lines.joined(separator: "\n"),
            actions: actions))

        // **ここでダイアログを出す。**要求を View 越しに回すと、メイン
        // ウインドウが閉じているときに黙って何も起きない［既知の失敗］。
        if chosen?.id == Self.reviewVolumesActionID, let libraryID {
            VolumeDecisionAction.present(libraryID: libraryID, locale: locale)
        }
        if chosen?.id == Self.reviewIdentityActionID, let libraryID {
            IdentityDecisionAction.present(libraryID: libraryID, locale: locale)
        }
        if chosen?.id == Self.reviewUnresolvedActionID, let libraryID {
            UnresolvedFilesNavigation.open(libraryID: libraryID, openWindow: openWindow)
        }
    }

    /// 自動走査（FSEvents の追随・定期フルスキャン）の結果を受けて、
    /// **判断が要るものだけ**を知らせる [ID-05]［ユーザー判断、2026-08］。
    ///
    /// **孤立・未解決・1 冊扱いの解除は出さない。** それらは「知らせるだけ」
    /// なので、自動で走るたびに出すと雑音になる——利用者が自分で消した
    /// ファイルに「N 件が見つからなくなりました」と言うことになる。
    /// 差し替えの確認は**放置すると記録が失われたままになる**ので別扱い。
    ///
    /// **同じ確認待ちを何度も出すことにはならない。** `candidatesForReview` は
    /// 走査が `.nameOnly` [ID-03]③ を新しく検出したときにしか数えられず、
    /// 既に確認待ちのものは次の走査では（新しい行が同一性で引けるので）
    /// この経路を通らない。
    @MainActor
    static func notifyAutomaticScan(libraryID: LibraryID, summary: ScanSummary,
                                    locale: Locale) {
        guard summary.candidatesForReview > 0 else { return }
        Task {
            let chosen = await NotificationRouter.shared.present(NotificationItem(
                category: .warning,
                severity: .sheet,
                title: String(localized: "library.scan.identityTitle", locale: locale),
                body: String(format: String(localized: "library.scan.identityMatches",
                                            locale: locale), summary.candidatesForReview),
                actions: [RecoveryAction(
                    id: Self.reviewIdentityActionID,
                    title: String(localized: "library.scan.reviewIdentity", locale: locale),
                    kind: .openWindow(Self.reviewIdentityActionID))]))
            if chosen?.id == Self.reviewIdentityActionID {
                IdentityDecisionAction.present(libraryID: libraryID, locale: locale)
            }
        }
    }

    /// 走査結果の通知から同一性の確認を開くアクションの識別子 [ID-05]。
    /// **ドットを含めない**（上の理由と同じ）。
    private static let reviewIdentityActionID = "review-identity-matches"
    private static let reviewUnresolvedActionID = "review-unresolved-files"

    /// 走査結果の通知から巻数の確認を開くアクションの識別子 [EM-32]。
    ///
    /// **ドットを含めない。**`library.volumeDecision` のような形にすると
    /// 文字列カタログの鍵と見分けが付かず、`check-localization-keys` が
    /// 「未定義の鍵」として拾う。内部の識別子なので鍵と紛らわしい形にしない。
    private static let reviewVolumesActionID = "review-volume-decisions"

    private static func presentUnavailable(_ failure: StoreStartupFailure?) {
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
