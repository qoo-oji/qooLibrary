import AppKit
import QooApplication
import QooInfrastructure
import QooKit
import SwiftUI

/// 環境設定「リセット」タブ [ユーザー要望、要件定義書には無い]。
///
/// ## ここが「DB の側から見た唯一の窓口」である
/// フォルダツリーの「ライブラリ機能を無効にする」は**登録フォルダの行から**
/// 辿る経路なので、登録が先に消えた場合や、そもそも登録と対応しない行が
/// DB に残った場合には届かない。このタブは `library` テーブルを直接一覧
/// するので、**縮退状態（オフライン・ゴミ箱・消失 [1-17]）も、登録が
/// 見つからない孤児も片付けられる。**
///
/// 削除は DB の行を消すだけで、ボリュームにも実ファイルにも触れない
/// ——縮退状態こそ片付けたい場面で手段が消えてはならない
/// [`LibraryMenuVisibility` の型コメント参照]。
///
/// ## 削除の前に書き出せることが前提［ユーザーからの制約］
/// 「一括削除より先にエクスポート/インポートを実装する」という制約に従い、
/// **バックアップのセクションを削除の上に置く**。順序そのものが案内になる。
struct ResetPreferencesTab: View {
    @Environment(\.locale) private var locale

    @State private var libraries: [LibraryRow] = []
    @State private var selection: LibraryID?
    @State private var isLoading = true
    @State private var backupState = LibraryBackupAction.State()
    @State private var thumbnailBytes: Int64?
    @State private var backupGenerations: [BackupGeneration] = []
    /// 世代数 [BK-01「環境設定で変更可能」]。`BackupService` が**剪定のたびに
    /// 読み直す**ので、変えたその場から効く（次の起動を待たない）。
    @AppStorage(BackupService.PreferenceKeys.documentGenerations)
    private var documentGenerations = AppLimits.Backup.defaultDocumentGenerations
    @AppStorage(BackupService.PreferenceKeys.storeGenerations)
    private var storeGenerations = AppLimits.Backup.defaultStoreGenerations
    @State private var isClearingThumbnails = false

    /// 一覧の 1 行。DB の行に、登録フォルダ側の状態を重ねたもの。
    struct LibraryRow: Identifiable, Equatable {
        var summary: LibrarySummary
        /// 対応する登録フォルダが `registeredFolders.json` にあるか。
        /// **無ければフォルダツリーからは一切辿れない**ので、このタブが
        /// 唯一の片付け手段になる。
        var hasRegistration: Bool
        var id: LibraryID { summary.id }
    }

    var body: some View {
        Form {
            automaticBackupSection
            backupSection
            librarySection
            thumbnailSection
        }
        .formStyle(.grouped)
        .padding(Tokens.spacing.l)
        .task {
            await reload()
            await refreshThumbnailSize()
            refreshBackupGenerations()
        }
        // 他の経路（フォルダツリーの有効化・無効化）で増減したときも追随する。
        // **世代の件数も読み直す**——ライブラリの削除・取り込みはどちらも
        // スナップショットを取る契機なので、ここが古いままだと
        // 「安全網が働いたか」を確かめに来た画面で嘘をつく［code-review で発見］。
        .onChange(of: LibraryServices.shared.libraries) {
            Task {
                await reload()
                refreshBackupGenerations()
            }
        }
    }

    // MARK: - 自動バックアップ [BK-01][BK-02][BK2-03]

    /// **一番上に置く。** 「消す前に戻せるようにしておく」という、このタブの
    /// 並びが表している順序 [RS-01 の趣旨] の先頭がここになる——手で書き出す
    /// 前に、そもそも自動で控えが取られていることを見せる。
    private var automaticBackupSection: some View {
        Section {
            HStack {
                Text("preferences.reset.autoBackupStored")
                Spacer()
                Text(String(format: String(localized: "preferences.reset.autoBackupCount",
                                           locale: locale), backupGenerations.count))
                    .foregroundStyle(.secondary)
                Text(Self.byteCountString(backupGenerations.reduce(0) { $0 + $1.byteCount }))
                    .foregroundStyle(.secondary)
            }
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
            }
        } header: {
            Text("preferences.reset.autoBackupHeader")
        } footer: {
            Text("preferences.reset.autoBackupFooter")
                .font(.system(size: Tokens.fontSize.caption))
                .foregroundStyle(.secondary)
        }
    }

    private func refreshBackupGenerations() {
        backupGenerations = (try? BackupStore().generations()) ?? []
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

    // MARK: - ライブラリの削除 [RG-06]

    private var librarySection: some View {
        Section {
            if !LibraryServices.shared.isReady {
                Text("preferences.reset.libraryUnavailable")
                    .foregroundStyle(.secondary)
            } else if isLoading {
                HStack { ProgressView().controlSize(.small); Text("preferences.reset.loading") }
            } else if libraries.isEmpty {
                Text("preferences.reset.noLibraries")
                    .foregroundStyle(.secondary)
            } else {
                List(libraries, selection: $selection) { row in
                    LibraryRowView(row: row)
                        .tag(row.id)
                }
                .frame(height: 132)
                .listStyle(.bordered)

                Button("preferences.reset.deleteLibrary", systemImage: "trash", role: .destructive) {
                    confirmDelete()
                }
                .disabled(selection == nil)
            }
        } header: {
            Text("preferences.reset.libraryHeader")
        } footer: {
            Text("preferences.reset.libraryFooter")
                .font(.system(size: Tokens.fontSize.caption))
                .foregroundStyle(.secondary)
        }
    }

    private func confirmDelete() {
        guard let id = selection, let row = libraries.first(where: { $0.id == id }) else { return }
        DialogWindowPresenter.shared.present(
            title: String(localized: "preferences.reset.deleteConfirmTitle", locale: locale)
        ) { _ in
            LibraryDeleteConfirmationDialog(row: row) {
                Task {
                    do {
                        try await LibraryServices.shared.deleteLibrary(id: id)
                        selection = nil
                        await reload()
                    } catch {
                        await NotificationRouter.shared.presentError(
                            error,
                            whatHappened: String(localized: "preferences.reset.deleteFailed",
                                                 locale: locale))
                    }
                }
            }
        }
    }

    // MARK: - サムネイル [IV-09]

    private var thumbnailSection: some View {
        Section {
            HStack {
                Text("preferences.cache.currentSize")
                Spacer()
                if let thumbnailBytes {
                    Text(Self.byteCountString(thumbnailBytes)).foregroundStyle(.secondary)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            Button("preferences.reset.clearThumbnails", systemImage: "photo",
                   role: .destructive) {
                clearThumbnails()
            }
            .disabled(isClearingThumbnails)
        } header: {
            Text("preferences.reset.thumbnailHeader")
        } footer: {
            Text("preferences.reset.thumbnailFooter")
                .font(.system(size: Tokens.fontSize.caption))
                .foregroundStyle(.secondary)
        }
    }

    /// サムネイルを 1 枚残らず消す [IV-09]。
    ///
    /// **`covers/` だけでなく Quick Look 用の書き出しも消す**——どちらも
    /// 同じ「表示のために作った派生物」で、片方だけ残ると「消したのに
    /// 古い絵が出る」ことになる（Quick Look 側はセッション限りのキャッシュ
    /// なので、起動時にも同じことが起きる [QuickLookCoverStore]）。
    private func clearThumbnails() {
        isClearingThumbnails = true
        Task {
            defer { isClearingThumbnails = false }
            await DefaultCoverImageCache.shared.clear()
            await QuickLookCoverStore.shared.purgeAll()
            await refreshThumbnailSize()
        }
    }

    // MARK: - 読み込み

    private func reload() async {
        isLoading = true
        defer { isLoading = false }
        let summaries = LibraryServices.shared.libraries
        // 登録フォルダ側は種別をまたいで見る。ライブラリとして有効化できるのは
        // 現状 `.library` グループだけだが、ここは「片付けの最後の砦」なので
        // 見落としが出ない側に倒す。
        let registered = await RegisteredFolderStore.shared.folders(kind: .library)
            + RegisteredFolderStore.shared.folders(kind: .temporary)
        let known = Set(registered.map(\.id))
        libraries = summaries.map {
            LibraryRow(summary: $0, hasRegistration: known.contains($0.uuid))
        }
        if let selection, !libraries.contains(where: { $0.id == selection }) {
            self.selection = nil
        }
    }

    private func refreshThumbnailSize() async {
        thumbnailBytes = await DefaultCoverImageCache.shared.totalSize()
    }

    /// `ByteCountFormatter` は 0 バイトを「Zero KB」と書く（`CachePreferencesTab`
    /// で実機検証時にユーザーから指摘された既知の癖）。
    private static func byteCountString(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "0 KB" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// 一覧の 1 行。
private struct LibraryRowView: View {
    let row: ResetPreferencesTab.LibraryRow

    var body: some View {
        HStack(spacing: Tokens.spacing.s) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: Tokens.spacing.xs) {
                    Text(row.summary.displayName)
                    if !row.hasRegistration {
                        // フォルダツリーからは辿れない行。**この状態を
                        // 出さないと、ユーザーは何を消しているのか分からない。**
                        Text("preferences.reset.orphanBadge")
                            .font(.system(size: Tokens.fontSize.caption))
                            .foregroundStyle(.orange)
                    }
                }
                Text(row.summary.resolvedPath)
                    .font(.system(size: Tokens.fontSize.caption))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Text(String(format: String(localized: "preferences.reset.fileCount"),
                        row.summary.fileCount))
                .font(.system(size: Tokens.fontSize.caption))
                .foregroundStyle(.secondary)
        }
    }
}

/// 削除の確認 [RG-06]。
///
/// **何が失われるかを言ってから消す。** `unregister` は `keepLabels` を
/// まだ見ずに連鎖削除するので、「保持する」を選ばせられない——選べない
/// 以上、せめて失うものを明示する（ラベル保管庫 2-11 が入ったら選択に変える）。
struct LibraryDeleteConfirmationDialog: View {
    @Environment(\.locale) private var locale
    @Environment(\.dialogDismiss) private var dismiss

    let row: ResetPreferencesTab.LibraryRow
    let onConfirm: () -> Void

    var body: some View {
        DialogScaffold(
            width: 440,
            confirm: DialogButton(
                title: String(localized: "preferences.reset.deleteLibraryConfirm", locale: locale),
                role: .destructive
            ) {
                onConfirm()
                dismiss()
            },
            cancel: DialogButton(
                title: String(localized: "common.cancel", locale: locale), role: .cancel
            ) { dismiss() }
        ) {
            VStack(alignment: .leading, spacing: Tokens.spacing.s) {
                Text(String(
                    format: String(localized: "preferences.reset.deleteExplanation", locale: locale),
                    row.summary.displayName, row.summary.fileCount))
                    .fixedSize(horizontal: false, vertical: true)
                Text("preferences.reset.deleteWarning")
                    .font(.system(size: Tokens.fontSize.caption))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("preferences.reset.deleteKeepsFiles")
                    .font(.system(size: Tokens.fontSize.caption))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
