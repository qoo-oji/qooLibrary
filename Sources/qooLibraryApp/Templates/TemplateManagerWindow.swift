//
//  テンプレート管理ウインドウ [LT-02][LT-05][LT-06]。
//
//  3 ペイン: 左＝テンプレート一覧（プリセット／自分の）／中央＝設定項目
//  グループ／右＝編集。**中央と右は設定ウインドウと同じ実装を共有する**
//  ——同じ編集を 2 つ作らない（`TemplateManagerModel` の解説）。
//
//  置き場所は専用ウインドウ［ユーザー判断、2026-09-04］。テンプレートは
//  ライブラリに属さないアプリ全体の持ち物なので、ライブラリ 1 つを前提に
//  する設定ウインドウの中には収まらない。
//
import QooApplication
import QooKit
import SwiftUI
import UniformTypeIdentifiers

/// このウインドウを開く唯一の入口。
@MainActor
@Observable
final class TemplateManagerNavigation {
    static let shared = TemplateManagerNavigation()
    private init() {}

    func open(openWindow: OpenWindowAction) {
        openWindow(id: "templateManager")
    }
}

struct TemplateManagerWindow: View {
    @Environment(\.locale) private var locale
    @State private var model = TemplateManagerModel()
    @State private var isPresentingDelete = false

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            templateList
                .navigationSplitViewColumnWidth(min: 180, ideal: 230, max: 320)
        } content: {
            sectionList
                .navigationSplitViewColumnWidth(min: 170, ideal: 200, max: 280)
        } detail: {
            detailPane
                .navigationSplitViewColumnWidth(min: 420, ideal: 560)
        }
        .navigationTitle(Text("templates.windowTitle"))
        .frame(minWidth: 900, minHeight: 540)
        .task { await model.prepare() }
        // 起動と同時に状態復元で開かれた場合、テンプレートの読み込みはまだ
        // 終わっていない——遅れて届いたら選択を合わせ直す（設定ウインドウと同じ）。
        .onChange(of: LibraryServices.shared.userTemplates) { _, _ in
            Task { await model.prepare() }
        }
        .onChange(of: LibraryServices.shared.presetTemplates.map(\.key)) { _, _ in
            Task { await model.prepare() }
        }
    }

    // MARK: - 左: テンプレート一覧

    private var templateList: some View {
        List(selection: Binding(
            get: { model.selection },
            set: { model.select($0) })
        ) {
            if !model.userTemplates.isEmpty {
                Section("templates.mineHeader") {
                    ForEach(model.userTemplates) { template in
                        Text(template.name)
                            .tag(TemplateManagerModel.Selection.user(id: template.id))
                    }
                }
            }
            Section("templates.presetsHeader") {
                ForEach(model.presets) { preset in
                    Text(preset.displayName)
                        .tag(TemplateManagerModel.Selection.preset(key: preset.key))
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                Divider()
                HStack(spacing: Tokens.spacing.s) {
                    // 白紙から新規作成 [LT-02]。**既定フィールド 5 種と巻数
                    // フォーマットだけ入った草案**から始める（`blankDraft` の
                    // 解説——フォーマットが 1 本も無いのは「まだ何も決めて
                    // いない」を素直に表す正しい状態）。
                    Button {
                        createBlankTemplate()
                    } label: {
                        Label("templates.new", systemImage: "plus")
                    }
                    Button {
                        importTemplates()
                    } label: {
                        Label("templates.import", systemImage: "square.and.arrow.down")
                    }
                    Button {
                        exportTemplates()
                    } label: {
                        Label("templates.export", systemImage: "square.and.arrow.up")
                    }
                    .disabled(model.userTemplates.isEmpty)
                    Spacer(minLength: 0)
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .padding(.horizontal, Tokens.spacing.m)
                .padding(.vertical, Tokens.spacing.s)
            }
            .background(.bar)
        }
    }

    // MARK: - 中央: 設定項目

    private var sectionList: some View {
        VStack(spacing: 0) {
            List(selection: $model.section) {
                ForEach(LibrarySettingsSection.standard) { section in
                    Label {
                        HStack(spacing: Tokens.spacing.xs) {
                            Text(section.titleKey)
                            Spacer(minLength: 0)
                            issueBadge { $0 == section }
                        }
                    } icon: {
                        Image(systemName: section.systemImage)
                    }
                    .tag(section)
                }
            }
            Divider()
            advancedButton
        }
        .disabled(!model.hasSelection)
    }

    private var advancedButton: some View {
        Button {
            presentAdvanced()
        } label: {
            HStack(spacing: Tokens.spacing.xs) {
                Image(systemName: "slider.horizontal.3")
                    .frame(width: 18)
                Text("librarySettings.advanced")
                Spacer(minLength: 0)
                issueBadge { $0.isAdvanced }
                Image(systemName: "chevron.right")
                    .font(.system(size: Tokens.fontSize.caption))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, Tokens.spacing.m)
        .padding(.vertical, Tokens.spacing.s)
    }

    @ViewBuilder
    private func issueBadge(matching predicate: (LibrarySettingsSection) -> Bool) -> some View {
        let matching = model.issues.filter { predicate(LibrarySettingsSection($0.section)) }
        if matching.contains(where: { $0.severity == .error }) {
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
        } else if !matching.isEmpty {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }

    private func presentAdvanced(initial: LibrarySettingsSection? = nil) {
        guard model.hasSelection else { return }
        DialogWindowPresenter.shared.present(
            title: String(localized: "librarySettings.advanced.title", locale: locale)
        ) { _ in
            AdvancedSettingsDialog(draft: $model.draft, initialSection: initial)
        }
    }

    // MARK: - 右: 編集

    @ViewBuilder
    private var detailPane: some View {
        if !model.hasSelection {
            ContentUnavailableView("templates.selectTemplate", systemImage: "sidebar.leading")
        } else {
            VStack(spacing: 0) {
                nameField
                Divider()
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

    private var nameField: some View {
        InspectorRow("templates.name") {
            TextField("templates.name", text: $model.name)
                .labelsHidden()
                .editableFieldChrome()
        }
        .padding(.horizontal, Tokens.spacing.l)
        .padding(.vertical, Tokens.spacing.m)
    }

    @ViewBuilder
    private var sectionEditor: some View {
        switch model.section {
        case .basics:
            // テンプレートには判断待ちの巻数 [EM-31] が無い（ライブラリでは
            // ないので走査していない）。既定の空で渡す。
            LibraryBasicsSettingsView(draft: $model.draft)
        case .fields:          LibraryFieldsSettingsView(draft: $model.draft)
        case .folderLevels:    LibraryFolderLevelsSettingsView(draft: $model.draft)
        case .filenameFormats:
            LibraryFilenameFormatsSettingsView(
                draft: $model.draft,
                selectedFormatID: $model.selectedFilenameFormatID,
                sampleFilename: $model.sampleFilename)
        // 高度なセクションは中央ペインに行が無いので、通常はここへ来ない
        // （不備の行は `presentAdvanced(initial:)` でダイアログを開く）。
        // それでも正しいエディタを出しておく——設定ウインドウと同じ判断。
        case .extensions, .volumeFormats, .seriesTitle, .delimiters,
             .protectedTokens, .bookFolderOpening:
            AdvancedSectionEditor(section: model.section, draft: $model.draft)
        }
    }

    // MARK: - 下端

    private var footer: some View {
        VStack(alignment: .leading, spacing: Tokens.spacing.s) {
            if let error = model.errorText {
                Text(error)
                    .font(.system(size: Tokens.fontSize.caption))
                    .foregroundStyle(.red)
            } else if let outcome = model.lastOutcome {
                Text(outcome)
                    .font(.system(size: Tokens.fontSize.caption))
                    .foregroundStyle(.secondary)
            }
            if !model.errors.isEmpty {
                issueList
            }
            HStack(spacing: Tokens.spacing.s) {
                Button("templates.delete", role: .destructive) {
                    isPresentingDelete = true
                }
                .disabled(model.isPreset || !model.hasSelection)
                Spacer(minLength: 0)
                Button("templates.saveAs") {
                    TemplateSaveAction.present(
                        draft: model.draft, suggestedName: defaultSaveAsName(),
                        locale: locale
                    ) { saved in
                        Task {
                            await model.refresh()
                            model.select(.user(id: saved.id))
                        }
                    }
                }
                .disabled(!model.canSave)
                Button("templates.save") {
                    Task { await model.saveInPlace() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canSaveInPlace || !model.hasUnsavedChanges)
            }
        }
        .padding(Tokens.spacing.l)
        .alert("templates.deleteTitle", isPresented: $isPresentingDelete) {
            Button("common.cancel", role: .cancel) {}
            Button("templates.delete", role: .destructive) {
                Task { await model.delete() }
            }
        } message: {
            // **既存のライブラリには影響しない** [LT-03]——登録時に設定は
            // ライブラリ側へ写るので、消しても無傷。それを言わないと
            // 「消したら蔵書の設定まで変わるのでは」と読める。
            Text("templates.deleteMessage")
        }
    }

    /// 不備の一覧。**押すとその設定を開く**——畳んだ先の不備に気づけないと
    /// 保存できない理由が分からないまま詰まる（設定ウインドウと同じ）。
    private var issueList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(model.errors) { issue in
                    Button {
                        let target = LibrarySettingsSection(issue.section)
                        if target.isAdvanced {
                            presentAdvanced(initial: target)
                        } else {
                            model.reveal(issue)
                        }
                    } label: {
                        Text(issue.message)
                            .font(.system(size: Tokens.fontSize.caption))
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxHeight: 44)
    }

    /// 別名の既定。**プリセットからなら「〈名前〉のコピー」**——同じ名前で
    /// 保存できてしまうと、一覧でどちらがプリセットか読めなくなる。
    private func defaultSaveAsName() -> String {
        String(format: String(localized: "templates.copyName", locale: locale), model.name)
    }

    /// 白紙から新規作成 [LT-02]。
    private func createBlankTemplate() {
        guard let volumeSets = LibraryServices.shared.volumeSetDefinition else { return }
        let draft = TemplateInstantiation.blankDraft(
            volumeSets: volumeSets, displayName: "",
            defaultFieldNames: DefaultFieldNames.localized)
        TemplateSaveAction.present(
            draft: draft,
            suggestedName: String(localized: "templates.newName", locale: locale),
            locale: locale
        ) { saved in
            Task {
                await model.refresh()
                model.select(.user(id: saved.id))
            }
        }
    }

    // MARK: - 入出力 [LT-06]

    private func exportTemplates() {
        Task {
            let document = await model.exportAll()
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "qooLibrary-templates.json"
            panel.allowedContentTypes = [.json]
            panel.prompt = String(localized: "templates.export", locale: locale)
            guard panel.runModal() == .OK, let url = panel.url else { return }
            do {
                try UserTemplateDocument.makeEncoder().encode(document).write(to: url)
            } catch {
                await NotificationRouter.shared.presentError(
                    error,
                    whatHappened: String(localized: "templates.exportFailed", locale: locale))
            }
        }
    }

    private func importTemplates() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "templates.import", locale: locale)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.importTemplates(at: url, locale: locale) }
    }
}
