//
//  ライブラリ有効化の画面 [LT-01〜LT-03][LS-01][HP-05、ユーザー要望]。
//
//  ユーザー指摘:「登録済みフォルダに対してライブラリを有効化する際に、
//  ユーザーはその選択肢で何がどう変化するのかわからない」。
//
//  **設定ウインドウと同じ 3 ペイン構成にする**［ユーザー判断］。有効化前と後で
//  同じ UI になるので覚え直しが要らず、エディタ 8 種をそのまま再利用できる。
//
import QooApplication
import QooKit
import SwiftUI

struct LibraryEnableView: View {
    @Environment(\.locale) private var locale
    @Environment(\.dialogDismiss) private var dismiss

    @State private var model: LibraryEnableModel
    let onCommit: (LibrarySettingsDraft, LibraryTypeTemplate?) -> Void

    init(model: LibraryEnableModel,
         onCommit: @escaping (LibrarySettingsDraft, LibraryTypeTemplate?) -> Void) {
        _model = State(initialValue: model)
        self.onCommit = onCommit
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                originList
                Divider()
                sectionList
                Divider()
                detailPane
            }
            Divider()
            footer
        }
        .frame(width: 980, height: 860)
        .task { await model.loadSamples() }
    }

    // MARK: - 見出し

    private var header: some View {
        HStack(spacing: Tokens.spacing.s) {
            Image(systemName: "books.vertical")
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 1) {
                Text(String(format: String(localized: "libraryEnable.headerTitle", locale: locale),
                            model.folderName))
                    .font(.system(size: Tokens.fontSize.body, weight: .semibold))
                Text("libraryEnable.headerExplanation")
                    .font(.system(size: Tokens.fontSize.caption))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(Tokens.spacing.m)
    }

    // MARK: - 左: 起点の選択

    private var originList: some View {
        List(selection: Binding(
            get: { model.origin },
            set: { if let new = $0 { model.origin = new } })
        ) {
            Section("libraryEnable.templatesHeader") {
                ForEach(model.templates) { template in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(template.displayName)
                        Text(String(format: String(localized: "libraryEnable.templateSummary",
                                                   locale: locale),
                                    template.labelGroups.count, template.filenameFormats.count))
                            .font(.system(size: Tokens.fontSize.caption))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .tag(LibraryEnableModel.Origin.template(key: template.key))
                }
            }
            // 白紙から作る [LT-02]。**プリセットのどれとも違う命名規則を
            // 持つ蔵書**では、近いものを選んで直すより空から組む方が早い。
            Section {
                VStack(alignment: .leading, spacing: 1) {
                    Text("libraryEnable.blank")
                    Text("libraryEnable.blankSummary")
                        .font(.system(size: Tokens.fontSize.caption))
                        .foregroundStyle(.secondary)
                        // 幅で切れていた（実機で「…— 自」まで出て途切れた）。
                        .fixedSize(horizontal: false, vertical: true)
                }
                .tag(LibraryEnableModel.Origin.blank)
            }
        }
        .frame(width: 226)
    }

    // MARK: - 中央: 設定項目

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
        .frame(width: 190)
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

    // MARK: - 右: 編集とプレビュー

    /// 編集側の実測高さ [ユーザー指摘: まだかなりの空きスペースがある]。
    /// **固定値では必ずどれかのセクションが余る**——中身の量がセクションごとに
    /// 違い、しかもラベルグループやフォーマットは件数で変わる。
    @State private var editorContentHeight: CGFloat = 300

    private var detailPane: some View {
        // **編集側は中身のぶんだけ取り、残りをプレビューへ回す。**
        // 固定値で上限を決めると、セクションごとに中身の量が違うぶん
        // どれかが必ず余る——実機で「まだかなりの空きスペースがある」と
        // 指摘された。実測して縮め、多すぎるときだけ上限で止める。
        VSplitView {
            ScrollView {
                sectionEditor
                    .padding(Tokens.spacing.l)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // 測定そのものがレイアウトへ影響しないよう `background` に置く。
                    .background(
                        GeometryReader { geo in
                            Color.clear
                                .onAppear { editorContentHeight = geo.size.height }
                                .onChange(of: geo.size.height) { _, new in
                                    editorContentHeight = new
                                }
                        }
                    )
            }
            .frame(minHeight: min(editorContentHeight, 180),
                   idealHeight: min(editorContentHeight, 460),
                   maxHeight: min(editorContentHeight, 460))

            // **残りは全部プレビューへ** [ユーザー要望: 表示できるプレビューを
            // 増やす]。ここが「その選択で何がどう変わるか」を答える場所なので、
            // 数行しか見えないと傾向が掴めない。
            LibraryEnablePreviewPane(model: model)
                .frame(minHeight: 220, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var sectionEditor: some View {
        // **設定ウインドウとまったく同じエディタを使う。** 同じ編集 UI を
        // 2 つ持つと、片方だけ直したときに挙動が食い違う。
        switch model.section {
        // 埋め込みメタデータの節は基本へ統合された [§19.7]。**判断待ちは
        // 有効化前には存在しない**（まだ 1 度も走査していない）ので、
        // 空のまま既定で渡る——空の一覧への導線を出しても押す先が無い。
        case .basics:          LibraryBasicsSettingsView(draft: $model.draft)
        case .extensions:      LibraryExtensionsSettingsView(draft: $model.draft)
        case .labelGroups:     LibraryLabelGroupsSettingsView(draft: $model.draft)
        case .filenameFormats:
            LibraryFilenameFormatsSettingsView(
                draft: $model.draft,
                selectedFormatID: $model.selectedFormatID,
                sampleFilename: $model.sampleFilename)
        case .folderLevels:    LibraryFolderLevelsSettingsView(draft: $model.draft)
        case .volumeFormats:   LibraryVolumeFormatsSettingsView(draft: $model.draft)
        case .delimiters:      LibraryDelimitersSettingsView(draft: $model.draft)
        case .protectedTokens: LibraryProtectedTokensSettingsView(draft: $model.draft)
        case .seriesTitle:     LibrarySeriesTitleSettingsView(draft: $model.draft)
        case .bookFolderOpening:
            LibraryBookFolderOpeningSettingsView(draft: $model.draft)
        }
    }

    // MARK: - フッター

    private var footer: some View {
        VStack(alignment: .leading, spacing: Tokens.spacing.s) {
            if !model.issues.isEmpty {
                // **高さを固定する。** ウインドウが固定サイズなので、ここが
                // 内容に応じて伸びると上の編集ペインを押し潰す——実機で、
                // フォーマットを 1 本足して不備が 1 件出た瞬間に、編集欄が
                // 画面外へ消えた。不備は全件出す（1 件ずつしか分からないと
                // 直すたびに試す往復になる）が、はみ出す分は中でスクロールさせる。
                ScrollView {
                    VStack(alignment: .leading, spacing: Tokens.spacing.xs) {
                        issueRows
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 52)
            }
            QooDialogFooter(
                confirm: DialogButton(
                    title: String(localized: "library.enable.confirm", locale: locale)
                ) {
                    onCommit(model.draft, model.selectedTemplate)
                    dismiss()
                },
                cancel: DialogButton(title: String(localized: "common.cancel", locale: locale),
                                     role: .cancel) { dismiss() },
                confirmDisabled: !model.canEnable)
        }
        .padding(Tokens.spacing.m)
    }

    /// 不備の一覧。クリックでその設定項目へ移動できる。
    @ViewBuilder
    private var issueRows: some View {
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
}

// MARK: - プレビュー

/// 草案を実ファイル名へ当てた結果 [HP-05]。
///
/// **これが「何がどう変化するのか」への答え。** テンプレートの中身を並べても、
/// 自分の蔵書がどう解釈されるかは分からない。
struct LibraryEnablePreviewPane: View {
    @Environment(\.locale) private var locale
    @Environment(\.colorScheme) private var colorScheme
    let model: LibraryEnableModel

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.spacing.s) {
            summaryRow
            Divider()
            if model.isSampling {
                HStack(spacing: Tokens.spacing.xs) {
                    ProgressView().controlSize(.small)
                    Text("libraryEnable.preview.sampling")
                        .font(.system(size: Tokens.fontSize.caption))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, Tokens.spacing.m)
            } else if let failure = model.samplingFailure {
                Text(failure)
                    .font(.system(size: Tokens.fontSize.caption))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Tokens.spacing.m)
            } else if model.sampleNames.isEmpty {
                Text("libraryEnable.preview.noFiles")
                    .font(.system(size: Tokens.fontSize.caption))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Tokens.spacing.m)
            } else {
                itemList
            }
        }
        .padding(.vertical, Tokens.spacing.s)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var summaryRow: some View {
        let outcome = model.preview
        return HStack(spacing: Tokens.spacing.m) {
            Text("libraryEnable.preview.title")
                .font(.system(size: Tokens.fontSize.body, weight: .semibold))
            if !model.isSampling && !model.sampleNames.isEmpty {
                Text(String(format: String(localized: "libraryEnable.preview.summary",
                                           locale: locale),
                            outcome.total, outcome.matched, outcome.unresolved))
                    .font(.system(size: Tokens.fontSize.caption))
                    .foregroundStyle(outcome.unresolved == 0 ? .secondary : .primary)
                if outcome.excluded > 0 {
                    // 対象拡張子で外した件数 [AL-11]。出さないと、有効化した
                    // 後の走査結果と数が合わない理由が分からない。
                    Text(String(format: String(localized: "libraryEnable.preview.excluded",
                                               locale: locale), outcome.excluded))
                        .font(.system(size: Tokens.fontSize.caption))
                        .foregroundStyle(.secondary)
                }
                if outcome.libraryTypeMismatched > 0 {
                    Label(String(format: String(localized: "libraryEnable.preview.mismatch",
                                                locale: locale), outcome.libraryTypeMismatched),
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: Tokens.fontSize.caption))
                        .foregroundStyle(.orange)
                }
                if outcome.truncated {
                    Text(String(format: String(localized: "libraryEnable.preview.truncated",
                                               locale: locale), outcome.total))
                        .font(.system(size: Tokens.fontSize.caption))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Tokens.spacing.m)
    }

    private var itemList: some View {
        // **未解決が先頭に来る**（`LibraryPreview.run` が並べ替え済み）。
        // 調整が要るのはそこなので、探させない。
        // 行の余白を詰めて件数を稼ぐ [ユーザー要望]。1 件 2 行（ファイル名と
        // 分解）は変えない——分解が見えないと「どう解釈されたか」が分からず、
        // 件数だけ増やしても意味が無い。
        List(model.preview.items) { item in
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: Tokens.spacing.xs) {
                    Image(systemName: icon(for: item))
                        .foregroundStyle(color(for: item))
                    Text(item.filename)
                        .font(.system(size: Tokens.fontSize.caption, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if item.matched {
                    Text(fieldSummary(item))
                        .font(.system(size: Tokens.fontSize.caption))
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("libraryEnable.preview.unresolvedHint")
                        .font(.system(size: Tokens.fontSize.caption))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 0)
            .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
        }
        .listStyle(.inset)
        .environment(\.defaultMinListRowHeight, 8)
    }

    private func icon(for item: LibraryPreview.Item) -> String {
        if !item.matched { return "questionmark.circle.fill" }
        if item.libraryTypeMismatch { return "exclamationmark.triangle.fill" }
        return "checkmark.circle.fill"
    }

    private func color(for item: LibraryPreview.Item) -> Color {
        if !item.matched { return .orange }
        if item.libraryTypeMismatch { return .orange }
        return .green
    }

    /// 「タイトル: ○○ ・ サークル: ○○」の形にする。**ラベルグループは
    /// 番号ではなく名前で出す**——`@labelgroup3` と言われても何のことか分からない。
    ///
    /// ラベルへ流れる値には**フィールドの色を敷く** [§19.10 ステージ 2]。
    /// どの値がどのフィールドのラベルになるかが一目で分かり、色はそのまま
    /// カスタマイズ（フィールドの色）へ追随する。1 本の `AttributedString` に
    /// するのは、行数の多い一覧でチップの部品を並べるより軽く、自然に
    /// 折り返せるため。
    private func fieldSummary(_ item: LibraryPreview.Item) -> AttributedString {
        var out = AttributedString()
        for (offset, field) in item.fields.enumerated() {
            if offset > 0 { out += AttributedString("  ") }
            var label = AttributedString(
                "\(FormatMatchPreview.label(for: field.ref, draft: model.draft)): ")
            label.foregroundColor = .secondary
            out += label
            var value = AttributedString(field.value)
            if let hex = FormatMatchPreview.colorHex(for: field.ref, draft: model.draft,
                                                     darkMode: colorScheme == .dark),
               let background = Color(labelHex: hex) {
                value.backgroundColor = background
                if let fgHex = LabelColorPalette.readableForeground(on: hex),
                   let foreground = Color(labelHex: fgHex) {
                    value.foregroundColor = foreground
                }
            }
            out += value
        }
        return out
    }
}
