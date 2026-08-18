//
//  ライブラリの設定ウインドウ [LS-01〜LS-03][15.1 節]。
//
//  3 ペイン: 左＝ライブラリ一覧／中央＝設定項目グループ／右＝詳細。
//  `PreferencesView` と同じ `NavigationSplitView` を使い、見た目を揃える [CP-01]。
//
import QooApplication
import QooKit
import SwiftUI

struct LibrarySettingsWindow: View {
    @Environment(\.locale) private var locale
    @State private var model = LibrarySettingsModel()

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            libraryList
                .navigationSplitViewColumnWidth(min: 160, ideal: 200, max: 280)
        } content: {
            sectionList
                .navigationSplitViewColumnWidth(min: 170, ideal: 200, max: 280)
        } detail: {
            detailPane
                .navigationSplitViewColumnWidth(min: 420, ideal: 560)
        }
        .navigationTitle(Text("librarySettings.windowTitle"))
        .frame(minWidth: 860, minHeight: 520)
        .task { await model.prepare(preferring: LibrarySettingsNavigation.shared.pendingLibraryID) }
        // 起動と同時に状態復元で開かれた場合、DB の準備はまだ終わっていない
        // ——一覧が遅れて届いたら選択を合わせ直す（`syncSelection` 参照）。
        .onChange(of: model.libraries.map(\.id)) { _, _ in
            guard model.selectedLibraryID == nil else { return }
            model.syncSelection()
        }
        .onChange(of: LibrarySettingsNavigation.shared.pendingLibraryID) {
            guard let pending = LibrarySettingsNavigation.shared.pendingLibraryID else { return }
            LibrarySettingsNavigation.shared.pendingLibraryID = nil
            Task { await model.prepare(preferring: pending) }
        }
    }

    // MARK: - 左: ライブラリ一覧

    private var libraryList: some View {
        List(selection: Binding(
            get: { model.selectedLibraryID },
            set: { requestLibrarySwitch(to: $0) })
        ) {
            Section("librarySettings.librariesHeader") {
                ForEach(model.libraries, id: \.id) { library in
                    Label {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(library.displayName)
                            Text(String(format: String(localized: "librarySettings.fileCount",
                                                       locale: locale), library.fileCount))
                                .font(.system(size: Tokens.fontSize.caption))
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: library.isOnline ? "books.vertical" : "books.vertical.circle")
                            .foregroundStyle(library.isOnline ? Color.accentColor : .secondary)
                    }
                    .tag(library.id)
                }
            }
        }
        .overlay {
            if model.libraries.isEmpty {
                ContentUnavailableView {
                    Label("librarySettings.noLibraries", systemImage: "books.vertical")
                } description: {
                    Text("librarySettings.noLibrariesHint")
                }
            }
        }
    }

    /// 未保存の変更があるまま別のライブラリへ移ると、編集内容が黙って消える。
    /// **黙って捨てない**——どちらを選ぶかは利用者が決める。
    private func requestLibrarySwitch(to id: LibraryID?) {
        guard id != model.selectedLibraryID else { return }
        guard model.isDirty else {
            model.selectedLibraryID = id
            return
        }
        DialogWindowPresenter.shared.present(
            title: String(localized: "librarySettings.unsavedTitle", locale: locale)
        ) { _ in
            UnsavedChangesDialog(
                libraryName: model.selectedLibraryName,
                onDiscard: {
                    model.revert()
                    model.selectedLibraryID = id
                },
                onSave: {
                    Task {
                        if await model.save() { model.selectedLibraryID = id }
                    }
                })
        }
    }

    // MARK: - 中央: 設定項目グループ

    private var sectionList: some View {
        List(selection: $model.section) {
            ForEach(LibrarySettingsSection.allCases) { section in
                Label {
                    HStack(spacing: Tokens.spacing.xs) {
                        Text(section.titleKey)
                        Spacer(minLength: 0)
                        issueBadge(for: section)
                    }
                } icon: {
                    Image(systemName: section.systemImage)
                }
                .tag(section)
            }
        }
        .disabled(model.draft == nil)
    }

    @ViewBuilder
    private func issueBadge(for section: LibrarySettingsSection) -> some View {
        let matching = model.issues.filter { LibrarySettingsSection($0.section) == section }
        if matching.contains(where: { $0.severity == .error }) {
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
        } else if !matching.isEmpty {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }

    // MARK: - 右: 詳細

    @ViewBuilder
    private var detailPane: some View {
        if let failure = model.loadFailure {
            QooErrorPlaceholder(message: failure)
        } else if model.draft == nil {
            ContentUnavailableView("librarySettings.selectLibrary", systemImage: "sidebar.leading")
        } else {
            VStack(spacing: 0) {
                ScrollView {
                    sectionEditor
                        .padding(Tokens.spacing.l)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Divider()
                footer
            }
        }
    }

    @ViewBuilder
    private var sectionEditor: some View {
        // 草案は `@Bindable` ではなく `Binding` を組み立てて渡す。`draft` は
        // Optional なので、各エディタには非 Optional の束縛だけを見せる。
        let bound = Binding(
            get: { model.draft ?? LibrarySettingsDraft() },
            set: { model.draft = $0 })
        switch model.section {
        case .basics:          LibraryBasicsSettingsView(draft: bound)
        case .extensions:      LibraryExtensionsSettingsView(draft: bound)
        case .labelGroups:     LibraryLabelGroupsSettingsView(draft: bound)
        case .filenameFormats: LibraryFilenameFormatsSettingsView(draft: bound, model: model)
        case .folderLevels:    LibraryFolderLevelsSettingsView(draft: bound)
        case .volumeFormats:   LibraryVolumeFormatsSettingsView(draft: bound)
        case .delimiters:      LibraryDelimitersSettingsView(draft: bound)
        case .protectedTokens: LibraryProtectedTokensSettingsView(draft: bound)
        }
    }

    // MARK: - 保存バー

    private var footer: some View {
        VStack(alignment: .leading, spacing: Tokens.spacing.s) {
            if !model.issues.isEmpty {
                issueList
            }
            HStack(spacing: Tokens.spacing.s) {
                if model.isDirty {
                    Label("librarySettings.unsavedChanges", systemImage: "pencil.circle")
                        .font(.system(size: Tokens.fontSize.caption))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("librarySettings.revert") { model.revert() }
                    .disabled(!model.isDirty || model.isBusy)
                Button("librarySettings.save") { performSave() }
                    .keyboardShortcut("s", modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canSave)
            }
        }
        .padding(Tokens.spacing.m)
    }

    private var issueList: some View {
        VStack(alignment: .leading, spacing: Tokens.spacing.xs) {
            // **不備は全件出す**——1 件ずつしか分からないと、直すたびに保存を
            // 試す往復になる。クリックでその設定項目へ移動できる。
            ForEach(model.issues) { issue in
                Button {
                    model.reveal(issue)
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: Tokens.spacing.xs) {
                        Image(systemName: issue.severity == .error
                              ? "exclamationmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(issue.severity == .error ? Color.red : Color.orange)
                        Text(issue.message)
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                    }
                    .font(.system(size: Tokens.fontSize.caption))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func performSave() {
        guard let library = model.libraries.first(where: { $0.id == model.selectedLibraryID })
        else { return }
        Task {
            guard await model.save() else { return }
            // [LS-02][AT-04] 設定を変えても、既に取り込んだファイルのラベルは
            // 走査し直すまで変わらない。**黙って古いままにしない。**
            DialogWindowPresenter.shared.present(
                title: String(localized: "librarySettings.rescanTitle", locale: locale)
            ) { _ in
                RescanPromptDialog(libraryName: library.displayName) {
                    LibraryEnableAction.rescan(library: library, locale: locale)
                }
            }
        }
    }
}

/// 読み込みに失敗したときの置き換え表示 [ER-01]。
private struct QooErrorPlaceholder: View {
    let message: String
    var body: some View {
        ContentUnavailableView {
            Label("librarySettings.loadFailed", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        }
    }
}

// MARK: - 確認ダイアログ

private struct UnsavedChangesDialog: View {
    @Environment(\.locale) private var locale
    @Environment(\.dialogDismiss) private var dismiss

    let libraryName: String
    let onDiscard: () -> Void
    let onSave: () -> Void

    var body: some View {
        DialogScaffold(
            width: 420,
            confirm: DialogButton(title: String(localized: "librarySettings.save", locale: locale)) {
                onSave()
                dismiss()
            },
            cancel: DialogButton(title: String(localized: "common.cancel", locale: locale),
                                 role: .cancel) { dismiss() },
            extra: [DialogButton(title: String(localized: "librarySettings.discard", locale: locale),
                                 role: .destructive) {
                onDiscard()
                dismiss()
            }]
        ) {
            Text(String(format: String(localized: "librarySettings.unsavedExplanation",
                                       locale: locale), libraryName))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct RescanPromptDialog: View {
    @Environment(\.locale) private var locale
    @Environment(\.dialogDismiss) private var dismiss

    let libraryName: String
    let onRescan: () -> Void

    var body: some View {
        DialogScaffold(
            width: 440,
            confirm: DialogButton(title: String(localized: "librarySettings.rescanNow", locale: locale)) {
                onRescan()
                dismiss()
            },
            cancel: DialogButton(title: String(localized: "librarySettings.rescanLater", locale: locale),
                                 role: .cancel) { dismiss() }
        ) {
            VStack(alignment: .leading, spacing: Tokens.spacing.s) {
                Text(String(format: String(localized: "librarySettings.rescanExplanation",
                                           locale: locale), libraryName))
                    .fixedSize(horizontal: false, vertical: true)
                Text("librarySettings.rescanNote")
                    .font(.system(size: Tokens.fontSize.caption))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
