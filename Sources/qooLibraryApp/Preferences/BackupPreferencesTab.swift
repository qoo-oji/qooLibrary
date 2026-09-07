import AppKit
import QooApplication
import QooInfrastructure
import QooKit
import SwiftUI

/// 環境設定「バックアップ」タブ［ユーザー判断 A3、2026-09-07］。
///
/// 「消す前に戻せるようにしておく」側をここへ集めた——自動バックアップの
/// 設定と世代の一覧・復元・書き出し [BK-01〜BK-07][IE-16]、ライブラリの
/// データの書き出し／読み込み [IE-01〜IE-14]、データベースの点検 [RB-02]。
/// 以前は前 2 つが「リセット」タブ、点検が「詳細」タブにあり、タブの名前と
/// 中身が合っていなかった。**サイドバーでは「リセット」の直前に並ぶ**——
/// 「一括削除より先にエクスポート／インポート」というユーザーの制約を
/// 並びで保つ。文字列カタログの鍵は移す前のまま（`preferences.reset.*`、
/// `preferences.advanced.*`）。
struct BackupPreferencesTab: View {
    @Environment(\.locale) private var locale

    @State private var backupState = LibraryBackupAction.State()
    @State private var backupGenerations: [BackupGeneration] = []
    /// 一覧で選んでいる世代 [BK-03]。
    @State private var generationSelection: BackupGeneration.ID?
    /// 世代数 [BK-01「環境設定で変更可能」]。`BackupService` が**剪定のたびに
    /// 読み直す**ので、変えたその場から効く（次の起動を待たない）。
    @AppStorage(BackupService.PreferenceKeys.documentGenerations)
    private var documentGenerations = AppLimits.Backup.defaultDocumentGenerations
    @AppStorage(BackupService.PreferenceKeys.storeGenerations)
    private var storeGenerations = AppLimits.Backup.defaultStoreGenerations
    /// 実行の可否と頻度 [BK-07]。**既定はすべて OFF**——この機能を必要とする
    /// 利用者は既に Time Machine を使っている可能性が高く、独自に世代を溜めると
    /// 気づかないうちに容量を使う［ユーザー判断］。
    ///
    /// **`if` 条件では読まない**（値の束縛にだけ使う）——ビュー構造を
    /// `@AppStorage` で決めると Observation が無限に再評価してハングする
    /// ［タブバー表示トグルで実際に踏んだ既知の不具合］。
    @AppStorage(BackupSettings.PreferenceKeys.launchInterval)
    private var launchInterval = BackupSettings.LaunchInterval.default
    @AppStorage(BackupSettings.PreferenceKeys.beforeDestructive)
    private var beforeDestructive = BackupSettings.defaultBeforeDestructive
    @AppStorage(BackupSettings.PreferenceKeys.beforeMigration)
    private var beforeMigration = BackupSettings.defaultBeforeMigration
    @State private var integrityReport: IntegrityReport?
    @State private var integritySelection: Set<IntegrityFinding.ID> = []
    @State private var isChecking = false

    var body: some View {
        Form {
            automaticBackupSection
            backupSection
            integritySection
        }
        .formStyle(.grouped)
        .padding(Tokens.spacing.l)
        .task { refreshBackupGenerations() }
        // ライブラリの削除・取り込みはどちらもスナップショットを取る契機
        // なので、世代の件数も読み直す——ここが古いままだと「安全網が
        // 働いたか」を確かめに来た画面で嘘をつく［code-review で発見］。
        .onChange(of: LibraryServices.shared.libraries) { refreshBackupGenerations() }
    }

    // MARK: - 自動バックアップ [BK-01][BK-02][BK2-03]

    /// **一番上に置く。** 「消す前に戻せるようにしておく」という、このタブの
    /// 並びが表している順序 [RS-01 の趣旨] の先頭がここになる——手で書き出す
    /// 前に、そもそも自動で控えが取られていることを見せる。
    private static func intervalLabel(_ interval: BackupSettings.LaunchInterval) -> LocalizedStringKey {
        switch interval {
        case .everyLaunch: "preferences.reset.backupInterval.everyLaunch"
        case .daily:       "preferences.reset.backupInterval.daily"
        case .weekly:      "preferences.reset.backupInterval.weekly"
        case .never:       "preferences.reset.backupInterval.never"
        }
    }

    private var automaticBackupSection: some View {
        Section {
            if backupGenerations.isEmpty {
                Text("preferences.reset.noGenerations").foregroundStyle(.secondary)
            } else {
                List(backupGenerations, selection: $generationSelection) { generation in
                    BackupGenerationRowView(generation: generation)
                        .tag(generation.id)
                }
                .frame(height: 132)
                .listStyle(.bordered)

                HStack {
                    // **復元できるのはストア複製だけ** [IE-16]。JSON は
                    // ライブラリの行を作れない（ブックマークを持てない）ので、
                    // そちらの戻し方は「取り込み」[IE-11] のほうである。
                    // ボタンは出したまま**無効にする**——種別によって項目が
                    // 消えると、何ができるのかが選択のたびに変わって読めない。
                    Button("preferences.reset.restore", systemImage: "clock.arrow.circlepath") {
                        if let selected, selected.kind == .store {
                            BackupRestoreAction.confirmRestore(selected, locale: locale) {}
                        } else if let selected {
                            LibraryBackupAction.import(locale: locale, state: backupState,
                                                       source: selected.url)
                        }
                    }
                    .disabled(selected == nil || (selected?.kind == .document
                                                  && !LibraryServices.shared.isReady))
                    Button("preferences.reset.exportGeneration",
                           systemImage: "square.and.arrow.up") {
                        if let selected { BackupRestoreAction.exportToFolder(selected, locale: locale) }
                    }
                    .disabled(selected == nil)
                    Spacer()
                    Button("common.delete", systemImage: "trash", role: .destructive) {
                        if let selected {
                            BackupRestoreAction.confirmDelete(selected, locale: locale) {
                                generationSelection = nil
                                refreshBackupGenerations()
                            }
                        }
                    }
                    .disabled(selected == nil)
                }
            }
            HStack {
                Text("preferences.reset.autoBackupStored")
                Spacer()
                Text(String(format: AppStrings.text("preferences.reset.autoBackupCount",
                                           locale: locale), backupGenerations.count))
                    .foregroundStyle(.secondary)
                Text(PreferencesByteCount.string(backupTotalBytes))
                    .foregroundStyle(.secondary)
            }
            Picker(selection: $launchInterval) {
                ForEach(BackupSettings.LaunchInterval.allCases, id: \.self) { interval in
                    Text(Self.intervalLabel(interval)).tag(interval)
                }
            } label: {
                Text("preferences.reset.backupLaunchInterval")
            }
            Toggle("preferences.reset.backupBeforeDestructive", isOn: $beforeDestructive)
            Toggle("preferences.reset.backupBeforeMigration", isOn: $beforeMigration)
            Stepper(value: $documentGenerations,
                    in: AppLimits.Backup.minGenerations ... AppLimits.Backup.maxGenerations) {
                HStack {
                    Text("preferences.reset.documentGenerations")
                    Spacer()
                    Text("\(documentGenerations)").foregroundStyle(.secondary)
                }
            }
            Stepper(value: $storeGenerations,
                    in: AppLimits.Backup.minGenerations ... AppLimits.Backup.maxGenerations) {
                HStack {
                    Text("preferences.reset.storeGenerations")
                    Spacer()
                    Text("\(storeGenerations)").foregroundStyle(.secondary)
                }
            }
            Button("preferences.reset.revealBackups", systemImage: "folder") {
                revealBackupFolder()
            }
            // 調整系の設定には必ず「既定に戻す」を付ける
            // [ユーザー指摘、`CachePreferencesTab` と同じ]。
            Button("preferences.resetToDefaults") {
                documentGenerations = AppLimits.Backup.defaultDocumentGenerations
                storeGenerations = AppLimits.Backup.defaultStoreGenerations
                launchInterval = BackupSettings.LaunchInterval.default
                beforeDestructive = BackupSettings.defaultBeforeDestructive
                beforeMigration = BackupSettings.defaultBeforeMigration
            }
        } header: {
            Text("preferences.reset.autoBackupHeader")
        } footer: {
            Text("preferences.reset.autoBackupFooter")
                .font(.system(size: Tokens.fontSize.caption))
                .foregroundStyle(.secondary)
        }
    }

    private var selected: BackupGeneration? {
        backupGenerations.first { $0.id == generationSelection }
    }

    /// 一覧の足し算ではなく実占有を出す [BK-06]——`appData` を一覧から
    /// 除いてあるうえ、共有プールは世代ではないので数に入らない。
    @State private var backupTotalBytes: Int64 = 0

    private func refreshBackupGenerations() {
        // **`appData` は一覧に出さない** [BK-06]。`store` と必ず対で取られ、
        // 単独では復元できない（`requestRestore` は `.store` しか受けない）
        // ので、行を増やしても「どれを選べばよいか」が分かりにくくなるだけ。
        // 束があること自体はフッターの説明で伝える。
        backupGenerations = ((try? BackupStore().generations()) ?? [])
            .filter { $0.kind != .appData }
        backupTotalBytes = (try? BackupStore().totalByteCount()) ?? 0
        // **消えた世代を指したままにしない**——剪定・削除・復元のあと、
        // 選択だけが残ると押せるボタンが何にも作用しなくなる
        // （中央ペインが `entries` に無い選択を落とすのと同じ）。
        if let generationSelection,
           !backupGenerations.contains(where: { $0.id == generationSelection }) {
            self.generationSelection = nil
        }
    }

    private func revealBackupFolder() {
        let directory = BackupStore().directory
        // 一度もスナップショットを取っていなければディレクトリ自体が無く、
        // Finder が何も反応しないように見える。その場合は親を開く
        // [`AdvancedPreferencesTab.revealLogFolder` と同じ]。
        if FileManager.default.fileExists(atPath: directory.path) {
            NSWorkspace.shared.activateFileViewerSelecting([directory])
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([directory.deletingLastPathComponent()])
        }
    }

    // MARK: - バックアップ [IE-01][BK-04]

    private var backupSection: some View {
        Section {
            Button("preferences.reset.exportBackup", systemImage: "square.and.arrow.up") {
                LibraryBackupAction.export(locale: locale, state: backupState)
            }
            .disabled(backupState.isBusy || !LibraryServices.shared.isReady)
            Button("preferences.reset.importBackup", systemImage: "square.and.arrow.down") {
                LibraryBackupAction.import(locale: locale, state: backupState)
            }
            .disabled(backupState.isBusy || !LibraryServices.shared.isReady)
        } header: {
            Text("preferences.reset.backupHeader")
        } footer: {
            Text("preferences.reset.backupFooter")
                .font(.system(size: Tokens.fontSize.caption))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - 整合性チェック [RB-02][12章 §12.7]

    /// **見つけて、選ばせて、直す。自動修復はしない**
    /// ［12章 §12.7: 誤った一括修復でラベルを失うリスクを避ける］。
    ///
    /// 直せないもの（外部キー違反）も**一覧には出す**——直し方が無いことと、
    /// 起きていることを知らせないことは別である。
    private var integritySection: some View {
        Section {
            if !LibraryServices.shared.isReady {
                Text("preferences.reset.libraryUnavailable").foregroundStyle(.secondary)
            } else {
                Button("preferences.advanced.checkIntegrity", systemImage: "stethoscope") {
                    runIntegrityCheck()
                }
                .disabled(isChecking)

                if isChecking {
                    HStack { ProgressView().controlSize(.small)
                             Text("preferences.advanced.checkingIntegrity") }
                } else if let report = integrityReport {
                    if report.isEmpty {
                        Text("preferences.advanced.integrityClean").foregroundStyle(.secondary)
                    } else {
                        List(integrityFindings, selection: $integritySelection) { finding in
                            IntegrityFindingRow(finding: finding).tag(finding.id)
                        }
                        .frame(height: 120)
                        .listStyle(.bordered)

                        Button("preferences.advanced.repairSelected", systemImage: "wrench") {
                            repairSelected()
                        }
                        // **直し方のある項目を選んだときだけ押せる。** 外部キー
                        // 違反は一覧に出るが直せない——押せてしまうと「押したのに
                        // 何も起きない」ことになる。
                        .disabled(selectedRepairable.isEmpty)
                    }
                }
            }
        } header: {
            Text("preferences.advanced.integrityHeader")
        } footer: {
            Text("preferences.advanced.integrityFooter")
                .font(.system(size: Tokens.fontSize.caption))
                .foregroundStyle(.secondary)
        }
    }

    private var integrityFindings: [IntegrityFinding] {
        guard let report = integrityReport else { return [] }
        return report.brokenCoverRefs + report.archiveMismatches
            + report.orphanedProtectedTokens + report.foreignKeyViolations
    }

    private var selectedRepairable: [IntegrityFinding] {
        integrityFindings.filter { integritySelection.contains($0.id) && $0.repair != nil }
    }

    private func runIntegrityCheck() {
        isChecking = true
        integritySelection = []
        Task {
            defer { isChecking = false }
            do {
                integrityReport = try await LibraryServices.shared.checkIntegrity()
            } catch {
                await NotificationRouter.shared.presentError(
                    error,
                    whatHappened: AppStrings.text("preferences.advanced.checkIntegrityFailed",
                                         locale: locale))
            }
        }
    }

    private func repairSelected() {
        let targets = selectedRepairable
        Task {
            do {
                let repaired = try await LibraryServices.shared.repairIntegrity(targets)
                // **直したあとは必ず取り直す**——直った項目が一覧に残ったままだと、
                // もう一度押せてしまう（2 度目は何も起きない）。
                integritySelection = []
                integrityReport = try await LibraryServices.shared.checkIntegrity()
                await NotificationRouter.shared.present(NotificationItem(
                    category: .info, severity: .transient,
                    title: AppStrings.text("preferences.advanced.repairedTitle", locale: locale),
                    body: String(format: AppStrings.text("preferences.advanced.repairedBody",
                                                locale: locale), repaired)))
            } catch {
                await NotificationRouter.shared.presentError(
                    error,
                    whatHappened: AppStrings.text("preferences.advanced.repairFailed",
                                         locale: locale))
            }
        }
    }

}

/// バックアップの世代 1 件 [BK-03]。
private struct BackupGenerationRowView: View {
    @Environment(\.locale) private var locale
    let generation: BackupGeneration

    var body: some View {
        HStack(spacing: Tokens.spacing.s) {
            VStack(alignment: .leading, spacing: 1) {
                Text(BackupGenerationFormatting.date(generation.date, locale: locale))
                Text(BackupGenerationFormatting.reason(generation.reason, locale: locale))
                    .font(.system(size: Tokens.fontSize.caption))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(BackupGenerationFormatting.kind(generation.kind, locale: locale))
                .font(.system(size: Tokens.fontSize.caption))
                .foregroundStyle(.secondary)
            Text(PreferencesByteCount.string(generation.byteCount))
                .font(.system(size: Tokens.fontSize.caption))
                .foregroundStyle(.secondary)
        }
    }
}

/// 不整合 1 件 [RB-02]。
private struct IntegrityFindingRow: View {
    let finding: IntegrityFinding

    var body: some View {
        HStack(spacing: Tokens.spacing.s) {
            VStack(alignment: .leading, spacing: 1) {
                Text(finding.subject).lineLimit(1).truncationMode(.middle)
                Text(finding.detail)
                    .font(.system(size: Tokens.fontSize.caption))
                    .foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            // **直せないことを行に出す。** 選んでも「修復」が効かない理由が
            // 分からないと、押しても何も起きないように見える。
            if finding.repair == nil {
                Text("preferences.advanced.notRepairable")
                    .font(.system(size: Tokens.fontSize.caption))
                    .foregroundStyle(.orange)
            }
        }
    }
}
