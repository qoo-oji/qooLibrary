//
//  ライブラリフォルダの登録ウィザード [RG3-20〜RG3-28][19章 §19.3]。
//
//  **登録＝ライブラリ化。** 「登録してから右クリックで有効にする」という
//  2 段階をやめ、フォルダを選ぶところから初回走査の開始までを 1 本の
//  導線にする。ウィザードが教育的な説明（ライブラリとは何か・前提と自由）を
//  担い、確認ステップで「登録するとこうなる」を実ファイル名で見せる。
//  **「登録」を押すまで DB には何も書かない** [RG3-25]。
//
//  実装は既存の有効化画面の資産をそのまま使う——サンプル収集と草案・
//  プレビューは `LibraryEnableModel`、適合計算は `LibraryPreview`（QooKit の
//  純粋関数）、確定処理は `LibraryEnableAction.registerAndEnable`。
//  ここに新しい判定は 1 つも無い。
//
import AppKit
import QooApplication
import QooInfrastructure
import QooKit
import SwiftUI

// MARK: - 入口

@MainActor
enum LibraryRegistrationWizard {

    /// ライブラリフォルダの「＋」から呼ぶ [RG3-20]。
    static func begin(locale: Locale, openWindow: OpenWindowAction) {
        let services = LibraryServices.shared
        guard services.isReady else {
            LibraryEnableAction.presentUnavailable(services.startupFailure)
            return
        }
        guard let volumeSets = services.volumeSetDefinition else { return }
        let model = LibraryRegistrationWizardModel(
            templates: services.presetTemplates,
            volumeSets: volumeSets,
            otherTypeNames: services.libraries.map(\.libraryTypeName),
            otherDisplayNames: services.libraries.map(\.displayName))
        DialogWindowPresenter.shared.present(
            title: String(localized: "libraryWizard.title", locale: locale)
        ) { _ in
            LibraryRegistrationWizardView(model: model) { url, name, draft, template in
                LibraryEnableAction.registerAndEnable(
                    url: url, displayName: name, draft: draft, template: template,
                    locale: locale, openWindow: openWindow)
            }
        }
    }

    /// 登録済みだが未有効の登録を、**ステップ 3（テンプレートの選択）から
    /// 再開する**［§19.10 ステージ 2・§19.3 移行］。
    ///
    /// フォルダは登録で決まっているので選び直させない（戻れるのはステップ 3
    /// まで）。**登録はし直さない**——確定は既存登録の有効化
    /// （`LibraryEnableAction.enableRegistered`）で、コード経路を 2 つ
    /// 作らない。
    static func resume(folder: RegisteredFolder, url: URL, locale: Locale,
                       openWindow: OpenWindowAction,
                       onFinished: (@MainActor () -> Void)? = nil) {
        let services = LibraryServices.shared
        guard services.isReady, let volumeSets = services.volumeSetDefinition else { return }
        let model = LibraryRegistrationWizardModel(
            templates: services.presetTemplates,
            volumeSets: volumeSets,
            otherTypeNames: services.libraries.map(\.libraryTypeName),
            otherDisplayNames: services.libraries.map(\.displayName),
            minStep: .template)
        model.step = .template
        // サンプル収集は提示と並行に走らせる。`chooseFolder` は先頭で
        // `enable` を同期的に作るので、テンプレート一覧は空振りしない
        // （適合率と推奨はサンプルが揃った時点で埋まる）。
        Task { await model.chooseFolder(url) }
        DialogWindowPresenter.shared.present(
            title: String(localized: "libraryWizard.title", locale: locale)
        ) { _ in
            LibraryRegistrationWizardView(model: model) { _, _, draft, template in
                Task {
                    await LibraryEnableAction.enableRegistered(
                        folder: folder, url: url, draft: draft, template: template,
                        locale: locale, openWindow: openWindow)
                    onFinished?()
                }
            }
        }
    }
}

// MARK: - 状態

@MainActor
@Observable
final class LibraryRegistrationWizardModel {

    enum Step: Int, CaseIterable, Identifiable {
        case intro, folder, template, customize, confirm
        var id: Int { rawValue }

        var titleKey: LocalizedStringKey {
            switch self {
            case .intro:     "libraryWizard.step.intro"
            case .folder:    "libraryWizard.step.folder"
            case .template:  "libraryWizard.step.template"
            case .customize: "libraryWizard.step.customize"
            case .confirm:   "libraryWizard.step.confirm"
            }
        }
    }

    var step: Step = .intro
    /// 戻れる最初のステップ。起動時の再開 [§19.10 ステージ 2] では
    /// `.template`——フォルダは登録で決まっているので選び直させない。
    let minStep: Step
    private(set) var folderURL: URL?

    /// 有効化画面と同じモデルを内側に持つ。サンプル収集 [HP-05]・草案・
    /// プレビューをそのまま再利用するためで、フォルダが決まった時点で作る。
    private(set) var enable: LibraryEnableModel?

    let templates: [LibraryTypeTemplate]
    private let volumeSets: VolumeSetDefinition
    private let otherTypeNames: [String]
    private let otherDisplayNames: [String]

    /// (A)/(B) を 1 つに畳んだテンプレート [ユーザー指摘: A/B の実差は
    /// フォルダ階層を使うかどうかだけで、それはテンプレートの選択ではなく
    /// 「フォルダ分けの扱い」という独立した選択にすべき]。
    struct MergedTemplate: Identifiable {
        /// フォルダを使わない側（旧 (A)）の key を代表 ID にする。
        let id: String
        /// 「(A)」「(B)」を落とした表示名。
        let displayName: String
        /// フォルダ階層を使わない側（folderLevels が空）。
        let flat: LibraryTypeTemplate
        /// フォルダ階層を使う側。無いテンプレートもあり得る。
        let foldered: LibraryTypeTemplate?

        func variant(folderUsage: Bool) -> LibraryTypeTemplate {
            folderUsage ? (foldered ?? flat) : flat
        }
    }

    private(set) var merged: [MergedTemplate] = []
    /// 一覧の選択。統合テンプレートの id か、白紙の番兵。
    private(set) var listSelection: String?
    static let blankSelection = "__blank__"

    /// フォルダ名を整理の手がかりに使うか [RG3-24]。旧 (A)/(B) の実体。
    private(set) var folderUsageOn = false
    /// サンプルの配置（サブフォルダ内の比率）から推定した既定値。
    private(set) var folderUsageSuggested = false

    /// テンプレートごとの適合結果 [RG3-23]。ステップ 3 の一覧と推奨判定に使う。
    /// **判定は常にフォルダを使わない側で行う**——フォルダを使う側は
    /// `@title` だけの万能フォーマットを持ち、どの種別でも全件一致になって
    /// 種別の判別ができないため。鍵は `MergedTemplate.id`。
    private(set) var outcomes: [String: LibraryPreview.Outcome] = [:]
    /// 適合率が最も高い統合テンプレート。同率なら定義順 [RG3-23]。
    private(set) var recommendedID: String?
    private(set) var isEvaluating = false

    init(templates: [LibraryTypeTemplate], volumeSets: VolumeSetDefinition,
         otherTypeNames: [String], otherDisplayNames: [String],
         minStep: Step = .intro) {
        self.templates = templates
        self.volumeSets = volumeSets
        self.otherTypeNames = otherTypeNames
        self.otherDisplayNames = otherDisplayNames
        self.minStep = minStep
        self.merged = Self.mergeVariants(templates)
    }

    /// 「一般コミック(A)」「一般コミック(B)」を 1 行に畳む。判定は名前の
    /// 接尾辞ではなく **folderLevels が空かどうか**で行う（実体で判定する）。
    static func mergeVariants(_ templates: [LibraryTypeTemplate]) -> [MergedTemplate] {
        func baseName(_ name: String) -> String {
            name.replacingOccurrences(of: "(A)", with: "")
                .replacingOccurrences(of: "(B)", with: "")
                .replacingOccurrences(of: "（A）", with: "")
                .replacingOccurrences(of: "（B）", with: "")
                .trimmingCharacters(in: .whitespaces)
        }
        var order: [String] = []
        var groups: [String: [LibraryTypeTemplate]] = [:]
        for template in templates {
            let base = baseName(template.displayName)
            if groups[base] == nil { order.append(base) }
            groups[base, default: []].append(template)
        }
        return order.compactMap { base in
            guard let members = groups[base] else { return nil }
            let flat = members.first { $0.folderLevels.isEmpty } ?? members[0]
            let foldered = members.first { !$0.folderLevels.isEmpty }
            return MergedTemplate(id: flat.key, displayName: base,
                                  flat: flat, foldered: foldered)
        }
    }

    /// ステップ 2: フォルダが選ばれた。サンプルを集めて全テンプレートを試す。
    func chooseFolder(_ url: URL) async {
        folderURL = url
        let model = LibraryEnableModel(
            folderName: url.lastPathComponent, folderURL: url,
            templates: templates, volumeSets: volumeSets,
            otherTypeNames: otherTypeNames, otherDisplayNames: otherDisplayNames)
        enable = model
        isEvaluating = true
        await model.loadSamples()
        // フォルダ分けされた蔵書か [RG3-24]。過半数がサブフォルダの中なら、
        // フォルダ名を手がかりに使う側を既定にする。
        folderUsageSuggested = model.sampleNestedCount * 2 > model.sampleNames.count
            && !model.sampleNames.isEmpty
        folderUsageOn = folderUsageSuggested
        evaluateTemplates()
        isEvaluating = false
    }

    /// 全統合テンプレートへ実ファイル名を通し、最も適合するものを推奨にする
    /// [RG3-23]。全滅（すべて 0 件一致）でも最上位の推測＝定義順の先頭を
    /// 推奨のまま進める。判定はフォルダを使わない側で行う（`outcomes` の注記）。
    private func evaluateTemplates() {
        guard let model = enable else { return }
        var map: [String: LibraryPreview.Outcome] = [:]
        var best: (id: String, rate: Double, matched: Int)?
        for item in merged {
            let draft = TemplateInstantiation.draft(
                from: item.flat, volumeSets: volumeSets,
                displayName: model.folderName,
                otherLibraryTypeNames: otherTypeNames,
                otherLibraryDisplayNames: otherDisplayNames)
            let outcome = LibraryPreview.run(filenames: model.sampleNames, draft: draft,
                                             truncated: model.sampleTruncated)
            map[item.id] = outcome
            // 「厳密に上回ったときだけ」入れ替える——同率は定義順を保つ。
            if let current = best {
                if outcome.matchRate > current.rate
                    || (outcome.matchRate == current.rate && outcome.matched > current.matched) {
                    best = (item.id, outcome.matchRate, outcome.matched)
                }
            } else {
                best = (item.id, outcome.matchRate, outcome.matched)
            }
        }
        outcomes = map
        recommendedID = best?.id
        if let id = recommendedID {
            select(id)
        }
    }

    var currentMerged: MergedTemplate? {
        guard let id = listSelection, id != Self.blankSelection else { return nil }
        return merged.first { $0.id == id }
    }

    /// ステップ 3 の選択。**起点を変えたら草案は作り直し**（編集は捨てる。
    /// 別のテンプレートへ移るのは「やり直す」という意思表示——
    /// `LibraryEnableModel.origin` と同じ判断）。
    func select(_ id: String?) {
        guard let model = enable else { return }
        listSelection = id
        if let id, id != Self.blankSelection,
           let item = merged.first(where: { $0.id == id }) {
            model.origin = .template(key: item.variant(folderUsage: folderUsageOn).key)
        } else if id == Self.blankSelection {
            model.origin = .blank
        }
    }

    /// フォルダ分けの扱いを切り替える [RG3-24]。**起点の切替（＝草案の
    /// 作り直し）にはしない**——カスタマイズ済みのフィールドや名前を捨てない
    /// ため、差分（フォルダ階層の割り当てと、フォルダを使う側だけが持つ
    /// 追加フォーマット）だけを草案へ足し引きする。
    func setFolderUsage(_ on: Bool) {
        guard folderUsageOn != on else { return }
        folderUsageOn = on
        guard let model = enable, let item = currentMerged,
              let foldered = item.foldered else { return }
        // フォルダを使う側だけが持つフォーマット（例: `@title` 単独）。
        let flatSources = Set(item.flat.filenameFormats)
        let extraSources = foldered.filenameFormats.filter { !flatSources.contains($0) }
        if on {
            model.draft.folderLevels = foldered.folderLevels
                .sorted { (Int($0.key) ?? 0) < (Int($1.key) ?? 0) }
                .compactMap { level, spec in
                    let assignment: FolderLevelDraft.Assignment
                    switch spec.kind {
                    case .singleLabelGroup:
                        guard let index = spec.labelGroup else { return nil }
                        assignment = .singleLabelGroup(index: index)
                    case .format:
                        guard let source = spec.format else { return nil }
                        assignment = .format(source: source)
                    case .none:
                        assignment = FolderLevelDraft.Assignment.none
                    }
                    return FolderLevelDraft(level: Int(level) ?? 1, assignment: assignment)
                }
            let existing = Set(model.draft.filenameFormats.map(\.source))
            for source in extraSources where !existing.contains(source) {
                model.draft.filenameFormats.append(FilenameFormatDraft(source: source))
            }
        } else {
            model.draft.folderLevels = []
            let removable = Set(extraSources)
            model.draft.filenameFormats.removeAll { removable.contains($0.source) }
        }
    }

    // MARK: 開くアプリ [ユーザー要望: 含まれる形式ごとに既定アプリを選ぶ]

    /// 画像フォルダ（ブックフォルダ）行の擬似キー。定義は `QooKit` の
    /// `AppAssociationKeys`（読む側＝ IF-18 の開く経路と共有する。2 か所に
    /// 持つと保存した設定を誰も読まない迷子になる）。
    static let folderViewerKey = AppAssociationKeys.folder

    /// 形式ごとに選んだ「開くアプリ」。鍵は拡張子（小文字）または
    /// `folderViewerKey`。**含まれていない形式は並べない**——選ばなかった
    /// 形式はシステムの既定のまま［ユーザー指定］。
    var viewerSelections: [String: String] = [:]

    /// このフォルダに実際に含まれる対象形式（対象拡張子との積、定義順）。
    func presentExtensions(draft: LibrarySettingsDraft) -> [String] {
        guard let counts = enable?.sampleExtensionCounts else { return [] }
        return draft.targetExtensions.map { $0.lowercased() }
            .filter { (counts[$0] ?? 0) > 0 }
    }

    /// 画像ファイルが含まれるか（＝画像フォルダ［ブックフォルダ IF-01］が
    /// ありそうか）。ウィザードの推定はこれで足りる——正確な判定は走査が行う。
    func hasImageFolders(draft: LibrarySettingsDraft) -> Bool {
        guard let counts = enable?.sampleExtensionCounts else { return false }
        return draft.imageExtensions.contains { (counts[$0.lowercased()] ?? 0) > 0 }
    }

    /// 「N 階層目 = サークル」の形の説明 [RG3-24]。singleLabelGroup は
    /// フィールド名で、format 指定はフォーマット文字列そのままで言う。
    func folderLevelsDescription(_ template: LibraryTypeTemplate,
                                 locale: Locale) -> String {
        template.folderLevels
            .sorted { (Int($0.key) ?? 0) < (Int($1.key) ?? 0) }
            .map { level, spec in
                let what: String
                switch spec.kind {
                case .singleLabelGroup:
                    what = spec.labelGroup
                        .flatMap { index in
                            template.labelGroups.first { $0.index == index }?.name
                        } ?? "?"
                case .format:
                    what = spec.format ?? "?"
                case .none:
                    what = "—"
                }
                return String(format: String(localized: "libraryWizard.folderUsage.level",
                                             locale: locale),
                              Int(level) ?? 0, what)
            }
            .joined(separator: " ／ ")
    }

    // MARK: 進行の判定

    var canGoNext: Bool {
        switch step {
        case .intro:     return true
        case .folder:    return folderURL != nil && !isEvaluating
        case .template:  return enable != nil && listSelection != nil
        case .customize: return enable?.canEnable ?? false
        case .confirm:   return enable?.canEnable ?? false
        }
    }

    func goNext() {
        guard let next = Step(rawValue: step.rawValue + 1) else { return }
        step = next
    }

    func goBack() {
        guard step.rawValue > minStep.rawValue,
              let prev = Step(rawValue: step.rawValue - 1) else { return }
        step = prev
    }
}

// MARK: - 画面

struct LibraryRegistrationWizardView: View {
    @Environment(\.locale) private var locale
    @Environment(\.dialogDismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    @State private var model: LibraryRegistrationWizardModel
    /// 確定 [RG3-25]。(フォルダ, 表示名, 草案, 起点テンプレート)。
    let onCommit: (URL, String, LibrarySettingsDraft, LibraryTypeTemplate?) -> Void

    init(model: LibraryRegistrationWizardModel,
         onCommit: @escaping (URL, String, LibrarySettingsDraft, LibraryTypeTemplate?) -> Void) {
        _model = State(initialValue: model)
        self.onCommit = onCommit
    }

    var body: some View {
        VStack(spacing: 0) {
            stepIndicator
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(width: 880, height: 640)
    }

    // MARK: 進行表示

    private var stepIndicator: some View {
        // 再開モード [§19.10 ステージ 2] では、飛ばしたステップ（説明と
        // フォルダ選択）を出さない——戻れない丸が並ぶと「戻れそうで戻れない」
        // 見た目になる。
        let steps = LibraryRegistrationWizardModel.Step.allCases
            .filter { $0.rawValue >= model.minStep.rawValue }
        return HStack(spacing: Tokens.spacing.m) {
            ForEach(steps) { step in
                HStack(spacing: Tokens.spacing.xs) {
                    ZStack {
                        Circle()
                            .fill(step.rawValue <= model.step.rawValue
                                  ? Color.accentColor : Color(nsColor: .quaternaryLabelColor))
                            .frame(width: 20, height: 20)
                        if step.rawValue < model.step.rawValue {
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white)
                        } else {
                            Text("\(step.rawValue + 1)")
                                .font(.system(size: Tokens.fontSize.caption, weight: .bold))
                                .foregroundStyle(step.rawValue <= model.step.rawValue
                                                 ? .white : .secondary)
                        }
                    }
                    Text(step.titleKey)
                        .font(.system(size: Tokens.fontSize.caption,
                                      weight: step == model.step ? .semibold : .regular))
                        .foregroundStyle(step == model.step ? .primary : .secondary)
                }
                if step != .confirm {
                    Rectangle()
                        .fill(Color(nsColor: .separatorColor))
                        .frame(height: 1)
                        .frame(maxWidth: 32)
                }
            }
        }
        .padding(Tokens.spacing.m)
    }

    @ViewBuilder
    private var content: some View {
        switch model.step {
        case .intro:     introStep
        case .folder:    folderStep
        case .template:  templateStep
        case .customize: customizeStep
        case .confirm:   confirmStep
        }
    }

    // MARK: ステップ 1: ライブラリとは [RG3-21]

    private var introStep: some View {
        VStack(spacing: Tokens.spacing.l) {
            Spacer(minLength: 0)
            Text("libraryWizard.intro.headline")
                .font(.system(size: Tokens.fontSize.title3, weight: .semibold))
            // フォルダ → 解析 → 蔵書一覧、の流れを絵で見せる。
            HStack(spacing: Tokens.spacing.l) {
                flowNode(systemImage: "folder.fill", captionKey: "libraryWizard.intro.flow1")
                Image(systemName: "arrow.right")
                    .foregroundStyle(.secondary)
                flowNode(systemImage: "wand.and.stars", captionKey: "libraryWizard.intro.flow2")
                Image(systemName: "arrow.right")
                    .foregroundStyle(.secondary)
                flowNode(systemImage: "books.vertical.fill", captionKey: "libraryWizard.intro.flow3")
            }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())],
                      spacing: Tokens.spacing.m) {
                introCard(systemImage: "lock.shield",
                          titleKey: "libraryWizard.intro.card1.title",
                          bodyKey: "libraryWizard.intro.card1.body")
                introCard(systemImage: "textformat.abc",
                          titleKey: "libraryWizard.intro.card2.title",
                          bodyKey: "libraryWizard.intro.card2.body")
                introCard(systemImage: "doc.zipper",
                          titleKey: "libraryWizard.intro.card3.title",
                          bodyKey: "libraryWizard.intro.card3.body")
                introCard(systemImage: "arrow.triangle.2.circlepath",
                          titleKey: "libraryWizard.intro.card4.title",
                          bodyKey: "libraryWizard.intro.card4.body")
            }
            .frame(maxWidth: 720)
            Spacer(minLength: 0)
        }
        .padding(Tokens.spacing.l)
    }

    private func flowNode(systemImage symbol: String, captionKey: LocalizedStringKey) -> some View {
        VStack(spacing: Tokens.spacing.xs) {
            Image(systemName: symbol)
                .font(.system(size: 28))
                .foregroundStyle(Color.accentColor)
                .frame(height: 34)
            Text(captionKey)
                .font(.system(size: Tokens.fontSize.caption))
                .foregroundStyle(.secondary)
        }
        .frame(width: 130)
    }

    private func introCard(systemImage symbol: String, titleKey: LocalizedStringKey,
                           bodyKey: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: Tokens.spacing.s) {
            Image(systemName: symbol)
                .font(.system(size: 20))
                .foregroundStyle(Color.accentColor)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(titleKey)
                    .font(.system(size: Tokens.fontSize.body, weight: .semibold))
                Text(bodyKey)
                    .font(.system(size: Tokens.fontSize.caption))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(Tokens.spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .quaternarySystemFill),
                    in: RoundedRectangle(cornerRadius: Tokens.radius.m))
    }

    // MARK: ステップ 2: フォルダの選択 [RG3-22]

    private var folderStep: some View {
        VStack(spacing: Tokens.spacing.l) {
            Spacer(minLength: 0)
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 44))
                .foregroundStyle(Color.accentColor)
            if let url = model.folderURL {
                VStack(spacing: Tokens.spacing.s) {
                    HStack(spacing: Tokens.spacing.xs) {
                        Image(systemName: "folder.fill")
                            .foregroundStyle(Color.accentColor)
                        Text(url.lastPathComponent)
                            .font(.system(size: Tokens.fontSize.title3, weight: .semibold))
                    }
                    Text(url.path)
                        .font(.system(size: Tokens.fontSize.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 560)
                    if model.isEvaluating {
                        HStack(spacing: Tokens.spacing.xs) {
                            ProgressView().controlSize(.small)
                            Text("libraryWizard.folder.sampling")
                                .font(.system(size: Tokens.fontSize.caption))
                                .foregroundStyle(.secondary)
                        }
                    } else if let enable = model.enable {
                        Text(String(format: String(localized: "libraryWizard.folder.sampled",
                                                   locale: locale),
                                    enable.sampleNames.count))
                            .font(.system(size: Tokens.fontSize.caption))
                            .foregroundStyle(.secondary)
                    }
                    Button("libraryWizard.folder.changeEllipsis") { presentFolderPanel() }
                        .controlSize(.small)
                }
            } else {
                Text("libraryWizard.folder.explanation")
                    .font(.system(size: Tokens.fontSize.body))
                    .foregroundStyle(.secondary)
                Button("libraryWizard.folder.chooseEllipsis") { presentFolderPanel() }
                    .keyboardShortcut(.defaultAction)
            }
            Spacer(minLength: 0)
        }
        .padding(Tokens.spacing.l)
        .frame(maxWidth: .infinity)
    }

    private func presentFolderPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        // ボタンは「選択」——この時点では登録されない [RG3-25]
        // ［ユーザー指摘: 「登録」だとこの時点で登録されるように見える］。
        panel.prompt = String(localized: "libraryWizard.folder.panelPrompt", locale: locale)
        panel.message = String(localized: "folderTree.chooseLibraryFolder", locale: locale)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.chooseFolder(url) }
    }

    // MARK: ステップ 3: テンプレートの選択 [RG3-23]

    @ViewBuilder
    private var templateStep: some View {
        if let enable = model.enable {
            HStack(spacing: 0) {
                templateList(enable: enable)
                Divider()
                // 右側は有効化画面のプレビューをそのまま使う——
                // 「その選択で何がどう変わるか」を答える唯一の実装 [HP-05]。
                LibraryEnablePreviewPane(model: enable)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private func templateList(enable: LibraryEnableModel) -> some View {
        // (A)/(B) は 1 行に統合してある [ユーザー指摘]。フォルダの扱いは
        // テンプレートの差ではなく、次のカスタマイズで独立して選ぶ。
        List(selection: Binding(
            get: { model.listSelection },
            set: { model.select($0) })
        ) {
            Section("libraryWizard.template.header") {
                ForEach(model.merged) { item in
                    templateRow(item)
                        .tag(item.id)
                }
            }
            Section {
                VStack(alignment: .leading, spacing: 1) {
                    Text("libraryEnable.blank")
                    Text("libraryEnable.blankSummary")
                        .font(.system(size: Tokens.fontSize.caption))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .tag(LibraryRegistrationWizardModel.blankSelection)
            }
        }
        .frame(width: 340)
    }

    private func templateRow(_ item: LibraryRegistrationWizardModel.MergedTemplate) -> some View {
        let outcome = model.outcomes[item.id]
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: Tokens.spacing.xs) {
                Text(item.displayName)
                if item.id == model.recommendedID {
                    Text("libraryWizard.template.recommended")
                        .font(.system(size: 9, weight: .semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.accentColor, in: Capsule())
                        .foregroundStyle(.white)
                }
                Spacer(minLength: 0)
            }
            if let outcome {
                // 実ファイルでの適合率が「どれを選ぶべきか」の答え [HP-05]。
                Text(String(format: String(localized: "libraryWizard.template.matchCount",
                                           locale: locale),
                            outcome.total, outcome.matched))
                    .font(.system(size: Tokens.fontSize.caption))
                    .foregroundStyle(outcome.matched > 0 ? Color.secondary : Color.orange)
            }
            if let example = item.flat.filenameFormats.first {
                Text(example)
                    .font(.system(size: Tokens.fontSize.caption, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.vertical, 1)
    }

    // MARK: ステップ 4: 基本的なカスタマイズ [RG3-24]

    @ViewBuilder
    private var customizeStep: some View {
        if let enable = model.enable {
            @Bindable var enableModel = enable
            ScrollView {
                VStack(alignment: .leading, spacing: Tokens.spacing.l) {
                    // ライブラリの名前欄は置かない——**フォルダ名＝表示名**
                    // ［ユーザー指示: 表示名という概念は廃止。同名のライブラリが
                    // 複数できうる点は、一覧側がパスの併記で区別する（§19.3）］。
                    // フィールド [ユーザー指定の並び]。追加・削除・
                    // 色まで設定ウインドウと同じエディタ。
                    VStack(alignment: .leading, spacing: Tokens.spacing.xs) {
                        Text("libraryWizard.customize.fields")
                            .font(.system(size: Tokens.fontSize.body, weight: .semibold))
                        Text("libraryWizard.customize.fieldsExplanation")
                            .font(.system(size: Tokens.fontSize.caption))
                            .foregroundStyle(.secondary)
                        LibraryLabelGroupsSettingsView(draft: $enableModel.draft)
                    }
                    Divider()
                    // フォルダ名によるラベル分類 [RG3-24][ユーザー指摘: フォルダは
                    // 重要な概念。意図的に分けない人も、きっちり分けたい人もいる]。
                    if model.currentMerged?.foldered != nil {
                        VStack(alignment: .leading, spacing: Tokens.spacing.xs) {
                            Text("libraryWizard.customize.folders")
                                .font(.system(size: Tokens.fontSize.body, weight: .semibold))
                            Picker("libraryWizard.customize.folders", selection: Binding(
                                get: { model.folderUsageOn },
                                set: { model.setFolderUsage($0) }
                            )) {
                                Text("libraryWizard.folderUsage.off").tag(false)
                                Text("libraryWizard.folderUsage.on").tag(true)
                            }
                            .pickerStyle(.radioGroup)
                            .labelsHidden()
                            Text(model.folderUsageSuggested
                                 ? "libraryWizard.folderUsage.suggestedNested"
                                 : "libraryWizard.folderUsage.suggestedFlat")
                                .font(.system(size: Tokens.fontSize.caption))
                                .foregroundStyle(.secondary)
                            if model.folderUsageOn {
                                // 階層の割り当ては設定ウインドウと同じエディタを
                                // そのまま使う——同じ編集 UI を 2 つ作らない。
                                LibraryFolderLevelsSettingsView(draft: $enableModel.draft)
                            }
                        }
                    }
                    Divider()
                    // ファイル名によるラベル分類 [ユーザー指摘: ファイル名
                    // フォーマットは高度な機能ではない]。フォルダ名の分類と
                    // 対になる語で並べる。エディタは設定ウインドウと同じ。
                    VStack(alignment: .leading, spacing: Tokens.spacing.xs) {
                        Text("libraryWizard.customize.filenameRules")
                            .font(.system(size: Tokens.fontSize.body, weight: .semibold))
                        LibraryFilenameFormatsSettingsView(
                            draft: $enableModel.draft,
                            selectedFormatID: $enableModel.selectedFormatID,
                            sampleFilename: $enableModel.sampleFilename)
                    }
                    Divider()
                    // 本を開くアプリ [ユーザー指定: フォルダ配下に**含まれる形式**
                    // （画像フォルダ含む）の一覧と、それぞれの既定アプリ]。
                    // 含まれていない形式は並べない＝システムの既定のまま。
                    viewerSection(enable: enable)
                    Divider()
                    // 「こういうものがカスタマイズできる」のカタログ [ユーザー
                    // 要望]。中身の要約だけを見せ、編集は下のボタンから。
                    VStack(alignment: .leading, spacing: Tokens.spacing.xs) {
                        HStack(spacing: Tokens.spacing.s) {
                            Text("libraryWizard.customize.advancedHeader")
                                .font(.system(size: Tokens.fontSize.body, weight: .semibold))
                            Text("libraryWizard.customize.advancedBadge")
                                .font(.system(size: 10))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color(nsColor: .quaternarySystemFill), in: Capsule())
                                .foregroundStyle(.secondary)
                        }
                        ForEach(advancedCatalog(draft: enable.draft), id: \.0) { entry in
                            HStack(alignment: .firstTextBaseline, spacing: Tokens.spacing.s) {
                                Image(systemName: entry.0.systemImage)
                                    .foregroundStyle(Color.accentColor)
                                    .frame(width: 20)
                                Text(entry.0.titleKey)
                                    .font(.system(size: Tokens.fontSize.caption, weight: .medium))
                                    .frame(width: 160, alignment: .leading)
                                Text(entry.1)
                                    .font(.system(size: Tokens.fontSize.caption))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 2)
                        }
                        // この場で直接編集したい人のための入口 [ユーザー要望]。
                        Button("libraryWizard.customize.advancedOpen") {
                            presentAdvanced()
                        }
                        .padding(.top, Tokens.spacing.xs)
                    }
                }
                .padding(Tokens.spacing.l)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// 本を開くアプリ。**このフォルダに実際に含まれる形式だけ**を並べる。
    private func viewerSection(enable: LibraryEnableModel) -> some View {
        let extensions = model.presentExtensions(draft: enable.draft)
        let hasFolders = model.hasImageFolders(draft: enable.draft)
        return VStack(alignment: .leading, spacing: Tokens.spacing.xs) {
            Text("libraryWizard.customize.viewer")
                .font(.system(size: Tokens.fontSize.body, weight: .semibold))
            Text("libraryWizard.customize.viewerExplanation")
                .font(.system(size: Tokens.fontSize.caption))
                .foregroundStyle(.secondary)
            if extensions.isEmpty && !hasFolders {
                Text("libraryWizard.customize.viewerNone")
                    .font(.system(size: Tokens.fontSize.caption))
                    .foregroundStyle(.secondary)
            }
            ForEach(extensions, id: \.self) { ext in
                viewerRow(key: ext, title: ".\(ext)",
                          candidates: AppAssociationStore.shared.candidates(for: ext))
            }
            if hasFolders {
                viewerRow(key: LibraryRegistrationWizardModel.folderViewerKey,
                          title: String(localized: "libraryWizard.customize.viewerFolderRow",
                                        locale: locale),
                          candidates: AppAssociationStore.shared.candidatesForFolders())
            }
        }
    }

    private func viewerRow(key: String, title: String,
                           candidates: [AppCandidate]) -> some View {
        HStack(spacing: Tokens.spacing.s) {
            Text(title)
                .font(.system(size: Tokens.fontSize.caption, design: .monospaced))
                .frame(width: 110, alignment: .leading)
            Picker(title, selection: Binding(
                get: { model.viewerSelections[key] },
                set: { model.viewerSelections[key] = $0 }
            )) {
                Text("libraryWizard.customize.viewerDefault").tag(String?.none)
                ForEach(candidates, id: \.bundleID) { candidate in
                    Text(candidate.name).tag(String?.some(candidate.bundleID))
                }
            }
            .labelsHidden()
            .frame(maxWidth: 300)
            Spacer(minLength: 0)
        }
    }

    /// 高度な設定をこの場で編集する [ユーザー要望]。設定ウインドウと同じ
    /// エディタ群を、登録前の草案に対して入れ子のモーダルで開く。
    private func presentAdvanced() {
        guard let enable = model.enable else { return }
        DialogWindowPresenter.shared.present(
            title: String(localized: "libraryWizard.advanced.title", locale: locale)
        ) { _ in
            AdvancedDraftSettingsDialog(model: enable)
        }
    }

    /// 高度な設定の一覧（設定ウインドウのセクション定義, 現在の中身の要約）。
    /// 題とアイコンは設定ウインドウと同じものを使う——登録後に開く画面と
    /// 同じ語・同じ絵で予告する。ファイル名フォーマットは高度ではないので
    /// ここには入れない（「ファイル名によるラベル分類」として上にある）。
    private func advancedCatalog(draft: LibrarySettingsDraft)
        -> [(LibrarySettingsSection, String)] {
        func count(_ n: Int) -> String {
            String(format: String(localized: "libraryWizard.customize.countItems",
                                  locale: locale), n)
        }
        return [
            (.extensions, draft.targetExtensions.joined(separator: ", ")),
            (.volumeFormats, count(draft.volumeFormats.count)),
            (.delimiters, ""),
            (.protectedTokens, count(draft.protectedTokens.count)),
            (.embeddedMetadata, String(localized: draft.readsEmbeddedMetadata
                ? "libraryWizard.customize.metadataOn"
                : "libraryWizard.customize.metadataOff", locale: locale)),
        ]
    }

    // MARK: ステップ 5: 確認 [RG3-25]

    @ViewBuilder
    private var confirmStep: some View {
        if let enable = model.enable {
            let outcome = enable.preview
            VStack(alignment: .leading, spacing: Tokens.spacing.m) {
                VStack(alignment: .leading, spacing: Tokens.spacing.xs) {
                    Text(String(format: String(localized: "libraryWizard.confirm.header",
                                               locale: locale),
                                enable.draft.displayName,
                                model.currentMerged?.displayName
                                    ?? String(localized: "libraryEnable.blank", locale: locale)))
                        .font(.system(size: Tokens.fontSize.title3, weight: .semibold))
                    Text(String(format: String(localized: "libraryWizard.confirm.summary",
                                               locale: locale),
                                outcome.total, outcome.matched))
                        .font(.system(size: Tokens.fontSize.body))
                    if outcome.unresolved > 0 {
                        Label(String(format: String(localized: "libraryWizard.confirm.unresolved",
                                                    locale: locale), outcome.unresolved),
                              systemImage: "tray")
                            .font(.system(size: Tokens.fontSize.caption))
                            .foregroundStyle(.secondary)
                    }
                    if let item = model.currentMerged, item.foldered != nil {
                        // フォルダの扱いも確認に出す [ユーザー指摘]。
                        Label(model.folderUsageOn
                              ? String(format: String(localized: "libraryWizard.confirm.folderUsageOn",
                                                      locale: locale),
                                       model.folderLevelsDescription(item.foldered!,
                                                                     locale: locale))
                              : String(localized: "libraryWizard.confirm.folderUsageOff",
                                       locale: locale),
                              systemImage: "folder")
                            .font(.system(size: Tokens.fontSize.caption))
                            .foregroundStyle(.secondary)
                    }
                    if !fieldTallies(outcome, draft: enable.draft).isEmpty {
                        HStack(spacing: Tokens.spacing.s) {
                            Text("libraryWizard.confirm.fieldsHeader")
                                .font(.system(size: Tokens.fontSize.caption, weight: .semibold))
                            ForEach(fieldTallies(outcome, draft: enable.draft)) { tally in
                                Text("\(tally.name) \(tally.count)")
                                    .font(.system(size: Tokens.fontSize.caption))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color(nsColor: .quaternarySystemFill),
                                                in: Capsule())
                            }
                        }
                    }
                }
                Divider()
                // 登録後のライブラリの見え方のモック [RG3-25]。実ファイル名から
                // 作ったカードを並べ、「具体的にどうなるのか」を絵で答える。
                mockLibraryGrid(outcome: outcome, draft: enable.draft)
                HStack(spacing: Tokens.spacing.xs) {
                    Image(systemName: "hand.raised")
                        .foregroundStyle(.secondary)
                    Text("libraryWizard.confirm.note")
                        .font(.system(size: Tokens.fontSize.caption))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(Tokens.spacing.l)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private struct FieldTally: Identifiable {
        let id: String
        let name: String
        let count: Int
    }

    /// フィールドごとに付く値の種類数 [RG3-25]。タイトル・シリーズ・巻は
    /// フィールドではないので数えない。
    private func fieldTallies(_ outcome: LibraryPreview.Outcome,
                              draft: LibrarySettingsDraft) -> [FieldTally] {
        var values: [FieldRef: Set<String>] = [:]
        for item in outcome.items where item.matched {
            for field in item.fields {
                switch field.ref {
                case .author, .labelGroup:
                    values[field.ref, default: []].insert(field.value)
                default:
                    continue
                }
            }
        }
        func order(_ ref: FieldRef) -> Int {
            switch ref {
            case .author: return 0
            case .labelGroup(let index): return index
            default: return 99
            }
        }
        return values.keys.sorted { order($0) < order($1) }.map { ref in
            FieldTally(id: FormatMatchPreview.label(for: ref, draft: draft),
                       name: FormatMatchPreview.label(for: ref, draft: draft),
                       count: values[ref]?.count ?? 0)
        }
    }

    /// ライブラリ表示モードのモック。カバーは仮（グラデーション＋本のアイコン）で、
    /// タイトル・巻・ラベルチップは実ファイル名から取った本物の値。
    private func mockLibraryGrid(outcome: LibraryPreview.Outcome,
                                 draft: LibrarySettingsDraft) -> some View {
        let cards = Array(outcome.items.filter(\.matched).prefix(8))
        return ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Tokens.spacing.m),
                                     count: 4),
                      spacing: Tokens.spacing.m) {
                ForEach(cards) { item in
                    mockCard(item, draft: draft)
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func mockCard(_ item: LibraryPreview.Item,
                          draft: LibrarySettingsDraft) -> some View {
        let title = item.fields.first { $0.ref == .title }?.value
            ?? (item.filename as NSString).deletingPathExtension
        let series = item.fields.first { $0.ref == .series }?.value
        let volume = item.fields.first { $0.ref == .volume }?.value
        let chips: [(ref: FieldRef, value: String)] = item.fields.compactMap { field in
            switch field.ref {
            case .author, .labelGroup: return (ref: field.ref, value: field.value)
            default: return nil
            }
        }
        return VStack(alignment: .leading, spacing: Tokens.spacing.xs) {
            RoundedRectangle(cornerRadius: Tokens.radius.s)
                .fill(LinearGradient(colors: [Color.accentColor.opacity(0.35),
                                              Color.accentColor.opacity(0.15)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(height: 76)
                .overlay {
                    Image(systemName: "book.closed.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(Color.accentColor.opacity(0.8))
                }
            Text(title)
                .font(.system(size: Tokens.fontSize.caption, weight: .semibold))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            if let series {
                Text(volume.map { "\(series) \($0)" } ?? series)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if !chips.isEmpty {
                HStack(spacing: 3) {
                    // チップはフィールドの色 [RG3-25][§19.10 ステージ 2]。
                    // 実際のライブラリのラベルチップと同じ見え方になり、
                    // カスタマイズで選んだ色がそのまま確認できる。
                    ForEach(Array(chips.prefix(2)), id: \.value) { chip in
                        mockChip(chip, draft: draft)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(Tokens.spacing.s)
        .frame(maxWidth: .infinity, minHeight: 158, alignment: .topLeading)
        .background(Color(nsColor: .quinarySystemFill),
                    in: RoundedRectangle(cornerRadius: Tokens.radius.m))
    }

    private func mockChip(_ chip: (ref: FieldRef, value: String),
                          draft: LibrarySettingsDraft) -> some View {
        let hex = FormatMatchPreview.colorHex(for: chip.ref, draft: draft,
                                              darkMode: colorScheme == .dark)
        let background = hex.flatMap { Color(labelHex: $0) }
            ?? Color(nsColor: .quaternarySystemFill)
        let foreground = hex.flatMap { LabelColorPalette.readableForeground(on: $0) }
            .flatMap { Color(labelHex: $0) } ?? .primary
        return Text(chip.value)
            .font(.system(size: 9))
            .lineLimit(1)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(background, in: Capsule())
            .foregroundStyle(foreground)
    }

    // MARK: フッター

    private var footer: some View {
        VStack(alignment: .leading, spacing: Tokens.spacing.s) {
            // 草案の不備は進めない理由なので、カスタマイズ以降で見せる。
            if model.step == .customize || model.step == .confirm,
               let enable = model.enable, !enable.errors.isEmpty {
                ForEach(enable.errors) { issue in
                    Label(issue.message, systemImage: "exclamationmark.circle.fill")
                        .font(.system(size: Tokens.fontSize.caption))
                        .foregroundStyle(.red)
                }
            }
            QooDialogFooter(
                confirm: DialogButton(
                    title: model.step == .confirm
                        ? String(localized: "libraryWizard.register", locale: locale)
                        : String(localized: "libraryWizard.next", locale: locale)
                ) {
                    if model.step == .confirm {
                        commit()
                    } else {
                        model.goNext()
                    }
                },
                cancel: DialogButton(title: String(localized: "common.cancel", locale: locale),
                                     role: .cancel) { dismiss() },
                extra: model.step == model.minStep ? [] : [
                    DialogButton(title: String(localized: "libraryWizard.back", locale: locale)) {
                        model.goBack()
                    }
                ],
                confirmDisabled: !model.canGoNext)
        }
        .padding(Tokens.spacing.m)
    }

    private func commit() {
        guard let url = model.folderURL, let enable = model.enable else { return }
        onCommit(url, enable.draft.displayName, enable.draft, enable.selectedTemplate)
        // 開くアプリの選択 [AS-01]。選んだ形式だけへ書く（既存の関連付け
        // 機構。ビューアタブからいつでも変えられる）。画像フォルダ行は
        // 擬似キー `folder` で保存する——開く側の配線は後のステージで行う。
        if !model.viewerSelections.isEmpty {
            let selections = model.viewerSelections
            Task {
                for (key, bundleID) in selections {
                    try? await AppAssociationStore.shared.setPrimary(bundleID, for: key)
                }
            }
        }
        dismiss()
    }
}


// MARK: - 高度な設定（登録前の草案に対して）

/// 「高度な設定をいま編集…」[ユーザー要望]。設定ウインドウと同じセクション
/// エディタを、まだ登録されていない草案に対して開く。プレビュー付きなので
/// 編集の効果をその場で確かめられる [HP-05]。
private struct AdvancedDraftSettingsDialog: View {
    @Environment(\.locale) private var locale
    @Environment(\.dialogDismiss) private var dismiss

    let model: LibraryEnableModel
    @State private var section: LibrarySettingsSection = .extensions

    var body: some View {
        @Bindable var enableModel = model
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                List(selection: $section) {
                    ForEach(LibrarySettingsSection.allCases) { section in
                        Label {
                            Text(section.titleKey)
                        } icon: {
                            Image(systemName: section.systemImage)
                        }
                        .tag(section)
                    }
                }
                .frame(width: 200)
                Divider()
                ScrollView {
                    editor(draft: $enableModel.draft, enable: enableModel)
                        .padding(Tokens.spacing.l)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Divider()
            LibraryEnablePreviewPane(model: model)
                .frame(height: 210)
            Divider()
            QooDialogFooter(
                confirm: DialogButton(
                    title: String(localized: "libraryWizard.advanced.done", locale: locale)
                ) { dismiss() },
                cancel: nil)
                .padding(Tokens.spacing.m)
        }
        .frame(width: 920, height: 680)
    }

    @ViewBuilder
    private func editor(draft: Binding<LibrarySettingsDraft>,
                        enable: LibraryEnableModel) -> some View {
        @Bindable var enableModel = enable
        // **設定ウインドウとまったく同じエディタを使う**（`LibraryEnableView`
        // と同じ判断）。同じ編集 UI を 2 つ持たない。
        switch section {
        case .basics:          LibraryBasicsSettingsView(draft: draft)
        case .extensions:      LibraryExtensionsSettingsView(draft: draft)
        case .labelGroups:     LibraryLabelGroupsSettingsView(draft: draft)
        case .filenameFormats:
            LibraryFilenameFormatsSettingsView(
                draft: draft,
                selectedFormatID: $enableModel.selectedFormatID,
                sampleFilename: $enableModel.sampleFilename)
        case .folderLevels:    LibraryFolderLevelsSettingsView(draft: draft)
        case .volumeFormats:   LibraryVolumeFormatsSettingsView(draft: draft)
        case .delimiters:      LibraryDelimitersSettingsView(draft: draft)
        case .protectedTokens: LibraryProtectedTokensSettingsView(draft: draft)
        case .embeddedMetadata:
            LibraryEmbeddedMetadataSettingsView(draft: draft, pending: [], onReview: {})
        }
    }
}
