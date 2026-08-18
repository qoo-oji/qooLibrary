//
//  登録フォルダをライブラリとして有効化する [RG-01][LT-03]。
//
//  フェーズ 2 の成果（DB・パーサ・スキャン）がアプリから初めて呼ばれる場所。
//
import QooApplication
import QooInfrastructure
import QooKit
import SwiftUI

/// ライブラリタイプを選ぶダイアログ [LT-01]。
///
/// **有効化を自動で行わず、1 件ずつ明示的に選ばせる**［ユーザー判断］。
/// フェーズ 1 の登録フォルダはライブラリタイプの概念を持たないため、
/// 起動時に全件へ既定の型を当てて自動生成すると、**推測した型で実蔵書
/// 数千件をいきなり走査する**ことになる。ここで 1 件ずつ選ばせれば、
/// 使い捨てのボリュームで先に試してから実蔵書へ当てられる。
struct LibraryTypeChooserDialog: View {
    @Environment(\.locale) private var locale
    @Environment(\.dialogDismiss) private var dismiss

    let folderName: String
    let templates: [LibraryTypeTemplate]
    let onCommit: (LibraryTypeTemplate) -> Void

    @State private var selectedKey: String

    init(folderName: String,
         templates: [LibraryTypeTemplate],
         onCommit: @escaping (LibraryTypeTemplate) -> Void) {
        self.folderName = folderName
        self.templates = templates
        self.onCommit = onCommit
        _selectedKey = State(initialValue: templates.first?.key ?? "")
    }

    private var selected: LibraryTypeTemplate? {
        templates.first { $0.key == selectedKey }
    }

    var body: some View {
        DialogScaffold(
            width: 420,
            confirm: DialogButton(title: String(localized: "library.enable.confirm", locale: locale)) {
                if let selected { onCommit(selected) }
                dismiss()
            },
            cancel: DialogButton(
                title: String(localized: "common.cancel", locale: locale), role: .cancel
            ) { dismiss() },
            confirmDisabled: selected == nil
        ) {
            VStack(alignment: .leading, spacing: Tokens.spacing.m) {
                Text(String(
                    format: String(localized: "library.enable.explanation", locale: locale),
                    folderName))
                    .fixedSize(horizontal: false, vertical: true)

                Picker(selection: $selectedKey) {
                    ForEach(templates) { template in
                        Text(template.displayName).tag(template.key)
                    }
                } label: {
                    Text("library.enable.typeLabel")
                }
                .pickerStyle(.inline)
                .labelsHidden()

                Text("library.enable.footnote")
                    .font(.system(size: Tokens.fontSize.caption))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// 有効化と初回スキャンの実処理。**フォルダツリーとメニューの両方から
/// 同じ実装を呼ぶ**——同じに見える操作に独立した経路を作ると、片方だけ
/// 直して取り残す（1-12 のアプリ関連付けで実際に踏んだ形）。
@MainActor
enum LibraryEnableAction {

    /// ライブラリタイプを選ばせてから有効化し、続けて初回スキャンを走らせる。
    static func begin(folder: RegisteredFolder, url: URL, locale: Locale) {
        let services = LibraryServices.shared
        guard services.isReady else {
            presentUnavailable(services.startupFailure)
            return
        }
        let templates = services.presetTemplates
        guard !templates.isEmpty else { return }

        DialogWindowPresenter.shared.present(
            title: String(localized: "library.enable.title", locale: locale)
        ) { _ in
            LibraryTypeChooserDialog(folderName: folder.displayName, templates: templates) { template in
                Task { await enable(folder: folder, url: url, template: template, locale: locale) }
            }
        }
    }

    /// 有効化済みのライブラリを走査し直す [SY-05]。
    static func rescan(folder: RegisteredFolder, url: URL, locale: Locale) {
        guard let summary = LibraryServices.shared.library(registrationUUID: folder.id) else { return }
        Task { await scan(libraryID: summary.id, displayName: folder.displayName,
                          url: url, locale: locale) }
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
                               template: LibraryTypeTemplate, locale: Locale) async {
        do {
            let id = try await LibraryServices.shared.enable(
                registrationUUID: folder.id,
                displayName: folder.displayName,
                url: url,
                bookmarkData: folder.bookmarkData,
                template: template)
            await scan(libraryID: id, displayName: folder.displayName, url: url, locale: locale)
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
                             url: URL, locale: Locale) async {
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
            await notifyIfNoteworthy(summary, displayName: displayName, locale: locale)
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
                                           locale: Locale) async {
        var lines: [String] = []
        if summary.orphaned > 0 {
            lines.append(String(format: String(localized: "library.scan.orphaned", locale: locale),
                                summary.orphaned))
        }
        if summary.unresolvedNames > 0 {
            lines.append(String(format: String(localized: "library.scan.unresolved", locale: locale),
                                summary.unresolvedNames))
        }
        if !summary.bookFoldersReleased.isEmpty {
            lines.append(String(format: String(localized: "library.scan.bookFoldersReleased", locale: locale),
                                summary.bookFoldersReleased.count))
        }
        guard !lines.isEmpty else { return }

        await NotificationRouter.shared.present(NotificationItem(
            category: .warning,
            // 判断を促すものなので強度 2 [ER-02]。強度 4（一時通知）は
            // フェーズ 1 の時点で提示先が無く、ログだけになって届かない。
            severity: .sheet,
            title: String(format: String(localized: "library.scan.reviewTitle", locale: locale),
                          displayName),
            body: lines.joined(separator: "\n")))
    }

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
