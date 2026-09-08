import AppKit
import QooApplication
import QooInfrastructure
import QooKit
import SwiftUI

/// 環境設定「リセット」タブ [ユーザー要望、要件定義書には無い]。
///
/// **消す操作だけを置く**（ライブラリのデータの削除・サムネイルの削除）。
/// バックアップ・書き出し／読み込み・復元・データベースの点検は
/// 「バックアップ」タブ（`BackupPreferencesTab`）へ分けた［ユーザー判断 A3、
/// 2026-09-07。「リセット」に復元やバックアップの設定があるのは名前と
/// 中身が合わない］。文字列カタログの鍵は `preferences.reset.*` のまま。
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
/// 「一括削除より先にエクスポート/インポートを実装する」という制約は
/// 「バックアップ」タブが**サイドバーでこのタブの直前に並ぶ**ことで保つ。
struct ResetPreferencesTab: View {
    @Environment(\.locale) private var locale

    @State private var libraries: [LibraryRow] = []
    @State private var selection: LibraryID?
    @State private var isLoading = true
    @State private var thumbnailBytes: Int64?
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
            librarySection
            thumbnailSection
        }
        .formStyle(.grouped)
        .padding(Tokens.spacing.l)
        .task {
            await reload()
            await refreshThumbnailSize()
        }
        // 他の経路（フォルダツリーの登録・登録解除）で増減したときも追随する。
        .onChange(of: LibraryServices.shared.libraries) {
            Task { await reload() }
        }
        // 切り離し [RG4-02] は `libraries` を減らして `detachedLibraries` を
        // 増やすので、片方だけ見ていると一覧が追随しない。
        .onChange(of: LibraryServices.shared.detachedLibraries) {
            Task { await reload() }
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
            title: AppStrings.text("preferences.reset.deleteConfirmTitle", locale: locale)
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
                            whatHappened: AppStrings.text("preferences.reset.deleteFailed",
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
                    Text(PreferencesByteCount.string(thumbnailBytes)).foregroundStyle(.secondary)
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
        // **切り離し行 [RG4-02] もここに出す。** 登録を解除してデータだけ
        // 残したライブラリを片付けられる唯一の場所で、他の窓（設定・
        // メンテナンス・フィールド編集）からは意図的に隠してある [RG4-06]。
        let summaries = LibraryServices.shared.libraries
            + LibraryServices.shared.detachedLibraries
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
            Text(String(format: AppStrings.text("preferences.reset.fileCount"),
                        row.summary.fileCount))
                .font(.system(size: Tokens.fontSize.caption))
                .foregroundStyle(.secondary)
        }
    }
}

/// 削除の確認 [RG-06]。
///
/// **何が失われるかを言ってから消す。** ここは「消す操作だけ」の場所なので
/// 残す選択肢は置かない——残したいなら登録解除の側で選ぶ [RG4-01]。
/// 切り離した行 [RG4-02] を片付けられる唯一の場所でもある。
struct LibraryDeleteConfirmationDialog: View {
    @Environment(\.locale) private var locale
    @Environment(\.dialogDismiss) private var dismiss

    let row: ResetPreferencesTab.LibraryRow
    let onConfirm: () -> Void

    var body: some View {
        DialogScaffold(
            width: 440,
            confirm: DialogButton(
                title: AppStrings.text("preferences.reset.deleteLibraryConfirm", locale: locale),
                role: .destructive
            ) {
                onConfirm()
                dismiss()
            },
            cancel: DialogButton(
                title: AppStrings.text("common.cancel", locale: locale), role: .cancel
            ) { dismiss() }
        ) {
            VStack(alignment: .leading, spacing: Tokens.spacing.s) {
                Text(String(
                    format: AppStrings.text("preferences.reset.deleteExplanation", locale: locale),
                    row.summary.displayName, row.summary.fileCount))
                    .fixedSize(horizontal: false, vertical: true)
                Text("preferences.reset.deleteWarning")
                    .font(.system(size: Tokens.fontSize.caption))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                // **登録が残っているかで言うことが変わる** [RG4-06]。
                // 切り離した行（登録を解除してデータだけ残したもの）に
                // 「フォルダの登録は残ります」と言うと嘘になる——この一覧に
                // 切り離し行が並ぶようになって初めて表に出た［制御口での
                // 実機検証で発見］。
                Text(row.hasRegistration
                     ? "preferences.reset.deleteKeepsFiles"
                     : "preferences.reset.deleteKeepsFilesDetached")
                    .font(.system(size: Tokens.fontSize.caption))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
