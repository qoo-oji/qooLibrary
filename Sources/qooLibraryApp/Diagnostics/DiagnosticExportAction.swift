import AppKit
import QooApplication
import QooInfrastructure
import SwiftUI

/// 診断ログの書き出し [LG2-05]。**環境設定「詳細」タブとヘルプメニューの
/// 両方から呼ばれる**ため、`NSSavePanel` の提示からエラー表示までを 1 箇所に
/// まとめる。
///
/// 「同じに見える操作に独立した実装経路が複数ある」状態は、片方だけ直して
/// もう片方が取り残される事故のもと（1-12 のアプリ関連付けで、`openEntries`
/// とダブルクリックが別実装になっていた実例がある）。最初から共有させる。
///
/// **ネットワーク送信は行わない** [LG2-08][SC-01]。書き出した zip を
/// ユーザーが自分で共有する。
@MainActor
enum DiagnosticExportAction {
    /// 書き出しの進行状況。ボタンの二重押し防止のために呼び出し側が持つ。
    @Observable
    final class State {
        var isExporting = false
    }

    static func run(locale: Locale, state: State? = nil) {
        guard state?.isExporting != true else { return }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(DiagnosticLog.bundleName()).zip"
        panel.allowedContentTypes = [.zip]
        panel.prompt = String(localized: "diagnostics.exportPanelPrompt", locale: locale)
        panel.message = String(localized: "diagnostics.exportPanelMessage", locale: locale)
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        let anonymize = UserDefaults.standard.bool(forKey: DiagnosticLogPreferences.anonymizePathsKey)
        state?.isExporting = true
        Task {
            defer { state?.isExporting = false }
            do {
                let bundle = try await DiagnosticLog.shared.exportBundle(
                    anonymizePaths: anonymize, to: destination, report: nil
                )
                // Finder で書き出した zip を選択状態にして見せる。「どこへ
                // 保存されたか分からない」を防ぐための導線で、これ以上の
                // 共有（メール送信等）はアプリ側では一切行わない [LG2-08]。
                NSWorkspace.shared.activateFileViewerSelecting([bundle])
            } catch {
                _ = await NotificationRouter.shared.presentError(
                    error,
                    whatHappened: String(localized: "diagnostics.exportFailed", locale: locale)
                )
            }
        }
    }
}
