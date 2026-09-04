import AppKit
import QooApplication
import QooInfrastructure
import QooKit
import SwiftUI
import UniformTypeIdentifiers

/// JSON バックアップの書き出しと取り込み [IE-01〜IE-14][BK-04]。
///
/// `DiagnosticExportAction` と同じく、**パネルの提示からエラー表示までを
/// 1 箇所にまとめる**——同じ操作に独立した経路を作ると片方だけ直して
/// 取り残す（1-12 のアプリ関連付けで実際に踏んだ形）。
///
/// **ネットワーク送信は行わない** [SC-01]。書き出した JSON をユーザーが
/// 自分で保管する [BK-04]。
@MainActor
enum LibraryBackupAction {

    @Observable
    final class State {
        var isBusy = false
    }

    // MARK: - 書き出し [IE-01][IE-02][BK-04]

    static func export(locale: Locale, state: State? = nil) {
        guard state?.isBusy != true else { return }
        let services = LibraryServices.shared
        guard services.isReady else {
            presentUnavailable(services.startupFailure)
            return
        }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = defaultFilename()
        panel.allowedContentTypes = [.json]
        panel.prompt = String(localized: "backup.exportPanelPrompt", locale: locale)
        panel.message = String(localized: "backup.exportPanelMessage", locale: locale)
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        state?.isBusy = true
        let handle = OperationProgressCenter.shared.begin(
            title: String(localized: "backup.exporting", locale: locale))
        Task {
            defer {
                state?.isBusy = false
                OperationProgressCenter.shared.finish(handle)
            }
            do {
                let document = try await services.exportBackup()
                let data = try BackupCoding.encode(document)
                // 書き込みは協調プールの外で待つ [NV6-01]。書き出し先が
                // ネットワークやクラウドのこともある。
                try await FileIO.perform {
                    try data.write(to: destination, options: .atomic)
                }
                // 「どこへ保存されたか分からない」を防ぐ。これ以上の共有は
                // アプリ側では一切行わない [SC-01]。
                NSWorkspace.shared.activateFileViewerSelecting([destination])
            } catch {
                await NotificationRouter.shared.presentError(
                    error, whatHappened: String(localized: "backup.exportFailed", locale: locale))
            }
        }
    }

    static func defaultFilename() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return "qooLibrary-\(formatter.string(from: Date())).json"
    }

    // MARK: - 取り込み [IE-11][IE-12][JS-06]

    static func `import`(locale: Locale, state: State? = nil) {
        guard state?.isBusy != true else { return }
        let services = LibraryServices.shared
        guard services.isReady else {
            presentUnavailable(services.startupFailure)
            return
        }

        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = String(localized: "backup.importPanelPrompt", locale: locale)
        panel.message = String(localized: "backup.importPanelMessage", locale: locale)
        guard panel.runModal() == .OK, let source = panel.url else { return }

        state?.isBusy = true
        Task {
            do {
                let data = try await FileIO.perform { try Data(contentsOf: source) }
                let document = try BackupCoding.decode(data)
                // **実行前に必ず数えて見せる** [IE-11]。取り込みは既存の
                // ラベル・評価を書き換えるので、承認なしに実行しない。
                let plan = try await services.planImport(document)
                state?.isBusy = false
                // **取り込めるものが 1 つも無いなら、確認ではなく通知にする。**
                // 押せない決定ボタンを見せて眺めさせるのは、承認を求める形を
                // しているだけで何も選ばせていない（実機で実際にそうなっていた）。
                // 理由を言って終わるほうが親切。
                // **テンプレートだけでも取り込む**［code-review で発見］。
                // ライブラリが 1 つも一致しなくても、テンプレートは戻せる
                // ——復旧の手順が「有効化 → 再スキャン → 取り込み」[MG-24] で
                // ある以上、ライブラリを作る前に取り込む場面が普通にある。
                let hasLibraries = plan.libraries.contains { $0.kind == .update }
                guard hasLibraries || plan.templatesAdded > 0 else {
                    presentNothingToImport(plan, locale: locale)
                    return
                }
                presentConfirmation(plan: plan, document: document, locale: locale, state: state)
            } catch {
                state?.isBusy = false
                await NotificationRouter.shared.presentError(
                    error, whatHappened: String(localized: "backup.importFailed", locale: locale))
            }
        }
    }

    /// 取り込める対象が 1 つも無かった [IE-11]。
    ///
    /// 文書が空のときと、書かれているライブラリがどれも DB に無いときの
    /// 両方がここへ来る。**後者は「先に有効化してください」という次の手が
    /// あるので、どのライブラリのことかを必ず並べる。**
    private static func presentNothingToImport(_ plan: ImportPlan, locale: Locale) {
        let lines: [String]
        if plan.libraries.isEmpty {
            lines = [String(localized: "backup.importPlanEmpty", locale: locale)]
        } else {
            lines = [String(format: String(localized: "backup.importResultMissing", locale: locale),
                            plan.missingLibraries.count),
                     plan.missingLibraries.map(\.displayName).joined(separator: "\n")]
        }
        Task {
            await NotificationRouter.shared.present(NotificationItem(
                category: .warning,
                severity: .sheet,
                title: String(localized: "backup.nothingToImportTitle", locale: locale),
                body: lines.joined(separator: "\n")))
        }
    }

    private static func presentConfirmation(plan: ImportPlan, document: BackupDocument,
                                            locale: Locale, state: State?) {
        DialogWindowPresenter.shared.present(
            title: String(localized: "backup.importConfirmTitle", locale: locale)
        ) { _ in
            BackupImportConfirmationDialog(plan: plan) {
                state?.isBusy = true
                let handle = OperationProgressCenter.shared.begin(
                    title: String(localized: "backup.importing", locale: locale))
                Task {
                    defer {
                        state?.isBusy = false
                        OperationProgressCenter.shared.finish(handle)
                    }
                    do {
                        let applied = try await LibraryServices.shared.importBackup(document)
                        presentResult(applied, locale: locale)
                    } catch {
                        await NotificationRouter.shared.presentError(
                            error,
                            whatHappened: String(localized: "backup.importFailed", locale: locale))
                    }
                }
            }
        }
    }

    /// 結果を伝える [ER-01]。**取り込めなかったライブラリがあるときは
    /// 必ず言う**——黙って一部だけ取り込むと、戻ったつもりで戻っていない
    /// 状態になる。
    private static func presentResult(_ plan: ImportPlan, locale: Locale) {
        var lines = [String(format: String(localized: "backup.importResultBody", locale: locale),
                            plan.filesUpdated, plan.labelsAdded, plan.fileLabelsAdded)]
        if !plan.missingLibraries.isEmpty {
            lines.append("")
            lines.append(String(
                format: String(localized: "backup.importResultMissing", locale: locale),
                plan.missingLibraries.count))
            lines.append(plan.missingLibraries.map(\.displayName).joined(separator: "\n"))
        }
        if plan.filesMissing > 0 {
            lines.append("")
            lines.append(String(
                format: String(localized: "backup.importResultFilesMissing", locale: locale),
                plan.filesMissing))
        }
        if plan.templatesAdded > 0 {
            lines.append("")
            lines.append(String(
                format: String(localized: "backup.importResultTemplates", locale: locale),
                plan.templatesAdded))
        }
        Task {
            await NotificationRouter.shared.present(NotificationItem(
                category: plan.missingLibraries.isEmpty ? .info : .warning,
                severity: .sheet,
                title: String(localized: "backup.importResultTitle", locale: locale),
                body: lines.joined(separator: "\n")))
        }
    }

    private static func presentUnavailable(_ failure: StoreStartupFailure?) {
        Task {
            await NotificationRouter.shared.presentError(
                LibraryUnavailableError(failure: failure),
                whatHappened: String(localized: "library.unavailable"))
        }
    }
}

/// 取り込みの承認 [IE-11][JS-06]。
struct BackupImportConfirmationDialog: View {
    @Environment(\.locale) private var locale
    @Environment(\.dialogDismiss) private var dismiss

    let plan: ImportPlan
    let onConfirm: () -> Void

    var body: some View {
        DialogScaffold(
            width: 460,
            confirm: DialogButton(title: String(localized: "backup.importConfirm", locale: locale)) {
                onConfirm()
                dismiss()
            },
            cancel: DialogButton(
                title: String(localized: "common.cancel", locale: locale), role: .cancel
            ) { dismiss() },
        ) {
            VStack(alignment: .leading, spacing: Tokens.spacing.m) {
                // 取り込める対象が 1 件以上あるときにしか開かない（`import`
                // が先に数えて振り分ける）ので、空の場合の分岐は持たない。
                ForEach(plan.libraries) { change in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: Tokens.spacing.xs) {
                            Image(systemName: change.kind == .missing
                                  ? "exclamationmark.triangle" : "arrow.down.circle")
                                .foregroundStyle(change.kind == .missing ? .orange : .secondary)
                            Text(change.displayName).fontWeight(.medium)
                        }
                        Text(detail(for: change))
                            .font(.system(size: Tokens.fontSize.caption))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Text("backup.importFootnote")
                    .font(.system(size: Tokens.fontSize.caption))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func detail(for change: ImportPlan.LibraryChange) -> String {
        switch change.kind {
        case .missing:
            String(localized: "backup.importPlanMissing", locale: locale)
        case .update:
            String(format: String(localized: "backup.importPlanUpdate", locale: locale),
                   change.filesUpdated, change.labelsAdded, change.fileLabelsAdded,
                   change.filesMissing)
        }
    }
}
