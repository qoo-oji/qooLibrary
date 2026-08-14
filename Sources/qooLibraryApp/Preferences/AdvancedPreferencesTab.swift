import AppKit
import QooInfrastructure
import QooKit
import SwiftUI

/// 環境設定「詳細」タブ [15.10 節、1-15]。現時点では診断ログ
/// [LG2-01〜LG2-08] 関連のみを扱う。
///
/// 仕様書 §15.10 の「詳細」タブはこのほかに整合性チェック [RB-02]、復旧手順
/// [IE-16][MG-24]、Undo スタック深さ [UD-05]、操作履歴保持期間 [HS-04] を
/// 挙げているが、いずれも SwiftData（フェーズ2）または未実装の基盤に依存する。
/// 展開上限 [EX-22] は先に実装した「圧縮／展開」タブに置いてあり、こちらへ
/// 移す予定は無い（形式ごとのオプションと同じ場所にある方が探しやすいため）。
/// フェーズ2で残りを実装する担当者は、このタブへ追加すること。
struct AdvancedPreferencesTab: View {
    /// `LogLevel` は `Int` の `rawValue` を持つが、**識別子文字列で永続化する**。
    /// `UserDefaults` を直接覗いたときに意味が読み取れること、`Int` だと
    /// 「キーが無い（0 が返る）」と「`error`（= 0）が選ばれている」を
    /// 区別できないことの 2 点による [`DiagnosticLogPreferences.storedLevel`]。
    @AppStorage(DiagnosticLogPreferences.logLevelKey)
    private var logLevelIdentifier: String = AppLimits.Logging.defaultLevel.identifier

    /// [LG2-06] 既定は匿名化**しない**。
    @AppStorage(DiagnosticLogPreferences.anonymizePathsKey)
    private var anonymizePaths: Bool = false

    @Environment(\.locale) private var locale

    @State private var exportState = DiagnosticExportAction.State()
    @State private var logTotalBytes: Int64?

    private var logLevel: Binding<LogLevel> {
        Binding(
            get: { LogLevel(identifier: logLevelIdentifier) ?? AppLimits.Logging.defaultLevel },
            set: { logLevelIdentifier = $0.identifier }
        )
    }

    var body: some View {
        Form {
            Section {
                Picker("preferences.advanced.logLevel", selection: logLevel) {
                    Text("preferences.advanced.logLevelError").tag(LogLevel.error)
                    Text("preferences.advanced.logLevelWarning").tag(LogLevel.warning)
                    Text("preferences.advanced.logLevelInfo").tag(LogLevel.info)
                    Text("preferences.advanced.logLevelDebug").tag(LogLevel.debug)
                }
                // 選択と同時に反映する（アプリの再起動を要求しない）。
                .onChange(of: logLevelIdentifier) { _, newValue in
                    DiagnosticLog.shared.currentLevel = LogLevel(identifier: newValue) ?? AppLimits.Logging.defaultLevel
                }

                HStack {
                    Text("preferences.advanced.logSize")
                    Spacer()
                    if let logTotalBytes {
                        Text(Self.byteCountString(logTotalBytes))
                            .foregroundStyle(.secondary)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }

                Button("preferences.advanced.revealLogs") {
                    revealLogFolder()
                }
            } header: {
                Text("preferences.advanced.logHeader")
            } footer: {
                Text("preferences.advanced.logFooter")
                    .font(.system(size: Tokens.fontSize.caption))
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("preferences.advanced.anonymizePaths", isOn: $anonymizePaths)
                Button("preferences.advanced.exportDiagnostics") {
                    DiagnosticExportAction.run(locale: locale, state: exportState)
                }
                .disabled(exportState.isExporting)
            } header: {
                Text("preferences.advanced.exportHeader")
            } footer: {
                Text("preferences.advanced.exportFooter")
                    .font(.system(size: Tokens.fontSize.caption))
                    .foregroundStyle(.secondary)
            }

            Section {
                Button("preferences.resetToDefaults") {
                    logLevelIdentifier = AppLimits.Logging.defaultLevel.identifier
                    anonymizePaths = false
                }
            }
        }
        .formStyle(.grouped)
        .padding(Tokens.spacing.l)
        .task {
            await refreshLogSize()
        }
        // 書き出しが終わるとローテーション後のサイズが変わっていることがある。
        .onChange(of: exportState.isExporting) { _, isExporting in
            guard !isExporting else { return }
            Task { await refreshLogSize() }
        }
    }

    private func refreshLogSize() async {
        let files = await DiagnosticLog.shared.logFileURLs()
        logTotalBytes = files.reduce(Int64(0)) { total, url in
            total + ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64 ?? 0)
        }
    }

    /// ログはユーザーが直接読める平文なので、Finder で開けるようにしておく
    /// （書き出しバンドルを作るほどでもない、その場の確認用）。
    private func revealLogFolder() {
        let directory = DiagnosticLog.defaultLogDirectory()
        // 一度も書き込まれていない場合はディレクトリ自体が無く、Finder が
        // 何も反応しないように見える。その場合は親を開く。
        if FileManager.default.fileExists(atPath: directory.path) {
            NSWorkspace.shared.activateFileViewerSelecting([directory])
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([directory.deletingLastPathComponent()])
        }
    }

    /// `ByteCountFormatter` は 0 バイトを「Zero KB」と表記する
    /// [`CachePreferencesTab` と同じ実機指摘への対応]。
    private static func byteCountString(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "0 KB" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
