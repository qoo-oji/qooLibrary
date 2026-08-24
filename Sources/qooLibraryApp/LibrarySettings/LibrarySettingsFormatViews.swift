//
//  ライブラリ設定 — ラベルグループ・ファイル名フォーマット・階層割り当て・巻数 [15.1 節]。
//
//  「テンプレートは雛形でしかない」を成立させる中心。テンプレートが与えるのは
//  ここの初期値だけで、以後は自由に組み替えられる [LT-03]。
//
import AppKit
import QooKit
import SwiftUI

// MARK: - ラベルグループ

/// ラベルグループの一覧と編集 [LG-03][LE-01][LE-02][LE-10][CO-04]。
///
/// **ライブラリ設定ウインドウとラベルグループ編集ウインドウで共有する**
/// ［ユーザー判断］。§15.2 は 3 ペインの中央にグループ一覧を置くと定めるが、
/// その中身（改名・予約語紐づけ）は設定ウインドウに既にある——同じ編集を
/// 2 箇所に実装すると片方だけ直して取り残す（このリポジトリで 3 度踏んだ形）。
///
/// 違うのは `selection` の有無だけ。設定ウインドウは `nil` を渡して一覧として
/// 見せ、編集ウインドウは束縛を渡して「どのグループのラベルを右に出すか」を決める。
struct LibraryLabelGroupsSettingsView: View {
    @Binding var draft: LibrarySettingsDraft
    /// 選択中のグループ（`LabelGroupDraft.id`）。`nil` を渡すと選択させない。
    var selection: Binding<UUID?>?
    /// 見出しと説明を出すか。編集ウインドウでは中央ペインの幅が狭いので省く。
    var showsHeader: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.spacing.l) {
            if showsHeader {
                SettingsSectionHeader(title: "librarySettings.section.labelGroups",
                                      explanation: "librarySettings.labelGroups.explanation")
            }

            VStack(spacing: 0) {
                header
                Divider()
                ForEach($draft.labelGroups) { $group in
                    row($group)
                        .background(isSelected($group.wrappedValue)
                                    ? Color(nsColor: .selectedContentBackgroundColor).opacity(0.25)
                                    : Color.clear)
                        .contentShape(Rectangle())
                        .onTapGesture { selection?.wrappedValue = $group.wrappedValue.id }
                    Divider()
                }
            }
            .frame(maxWidth: 620, alignment: .leading)

            HStack {
                Button("librarySettings.labelGroups.add") { addGroup() }
                    .disabled(draft.nextAvailableLabelGroupIndex == nil)
                Text("librarySettings.labelGroups.limit")
                    .font(.system(size: Tokens.fontSize.caption))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var header: some View {
        HStack(spacing: Tokens.spacing.s) {
            Text("librarySettings.labelGroups.number").frame(width: 90, alignment: .leading)
            Text("librarySettings.labelGroups.name").frame(minWidth: 120, alignment: .leading)
            Text("librarySettings.labelGroups.color").frame(width: 24, alignment: .leading)
            Spacer(minLength: Tokens.spacing.m)
            Text("librarySettings.labelGroups.semantic").frame(width: 130, alignment: .leading)
            Text("librarySettings.labelGroups.autoAssign").frame(width: 60, alignment: .center)
            Color.clear.frame(width: 22)
        }
        .font(.system(size: Tokens.fontSize.caption))
        .foregroundStyle(.secondary)
        .padding(.vertical, Tokens.spacing.xs)
    }

    private func row(_ group: Binding<LabelGroupDraft>) -> some View {
        HStack(spacing: Tokens.spacing.s) {
            // `@labelgroupN` の N。**フォーマットから参照される番号**なので、
            // 付け替えるとフォーマットの意味が変わる。検証が実在確認を行う。
            Text(verbatim: "@labelgroup\(group.wrappedValue.index)")
                .font(.system(size: Tokens.fontSize.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .leading)
            TextField("", text: group.name)
                .labelsHidden()
                .editableFieldChrome()
                .frame(minWidth: 120)
            // グループ色 [LE-10][CO-04]。ライト・ダークの両方とコントラスト
            // 警告 [CO-05] はポップオーバーの中で扱う。
            LabelColorWell(color: colorBinding(for: group),
                           defaultColor: defaultColor(for: group.wrappedValue),
                           previewName: group.wrappedValue.name)
            Spacer(minLength: Tokens.spacing.m)
            FixedWidthPopUp(items: semanticItems(for: group.wrappedValue.index),
                            selection: semanticBinding(for: group.wrappedValue.index))
                .frame(width: 130)
            Toggle("", isOn: group.assignsAutomatically)
                .labelsHidden()
                .frame(width: 60, alignment: .center)
            Button {
                removeGroup(group.wrappedValue)
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .frame(width: 22)
        }
        .padding(.vertical, Tokens.spacing.xs)
    }

    private func isSelected(_ group: LabelGroupDraft) -> Bool {
        selection?.wrappedValue == group.id
    }

    private func colorBinding(for group: Binding<LabelGroupDraft>) -> Binding<LabelColor> {
        Binding(
            get: { LabelColor(hexLight: group.wrappedValue.colorHexLight,
                              hexDark: group.wrappedValue.colorHexDark) },
            set: {
                group.wrappedValue.colorHexLight = $0.hexLight
                group.wrappedValue.colorHexDark = $0.hexDark
            })
    }

    /// 「既定に戻す」で戻す先 [CO-01][MT-13]。**リテラルの表を持たず**、
    /// そのときのグループ数に応じて色相環を等分して生成する
    /// ——グループを増減しても既定色が破綻しない。
    private func defaultColor(for group: LabelGroupDraft) -> LabelColor? {
        let ordered = draft.labelGroups.map(\.index).sorted()
        guard let position = ordered.firstIndex(of: group.index) else { return nil }
        let palette = LabelColorPalette.palette(count: max(ordered.count, 1))
        guard position < palette.count else { return nil }
        return palette[position]
    }

    /// セマンティック予約語の紐づけ [LE-01][RW-12]。**1 対 1 を UI で守る**
    /// [LE-02][RW-14]——別のグループに付け替えると、元の紐づけを外す。
    private func semanticBinding(for index: Int) -> Binding<String> {
        Binding(
            get: { draft.semanticBindings.first { $0.value == index }?.key.rawValue ?? "" },
            set: { raw in
                for (keyword, value) in draft.semanticBindings where value == index {
                    draft.semanticBindings[keyword] = nil
                }
                guard let keyword = SemanticKeyword(rawValue: raw) else { return }
                draft.semanticBindings[keyword] = index      // 他のグループから奪う
            })
    }

    private func semanticItems(for index: Int) -> [FixedWidthPopUp<String>.Item] {
        var items: [FixedWidthPopUp<String>.Item] = [
            .init(title: String(localized: "librarySettings.labelGroups.noSemantic"), tag: "")
        ]
        for keyword in SemanticKeyword.allCases {
            items.append(.init(title: keyword.rawValue, tag: keyword.rawValue))
        }
        _ = index
        return items
    }

    private func addGroup() {
        guard let index = draft.nextAvailableLabelGroupIndex else { return }
        let colors = LabelColorPalette.palette(count: max(draft.labelGroups.count + 1, 1))
        let color = colors[min(draft.labelGroups.count, colors.count - 1)]
        draft.labelGroups.append(LabelGroupDraft(
            index: index,
            name: String(format: String(localized: "librarySettings.labelGroups.newName"), index),
            colorHexLight: color.hexLight, colorHexDark: color.hexDark))
    }

    /// **ラベルごと消える**ので確認を挟む [LB-05]。保存するまで実際には
    /// 消えないが、保存の段で警告するのでは遅い（そのときには何を消したか
    /// 忘れている）。
    private func removeGroup(_ group: LabelGroupDraft) {
        DialogWindowPresenter.shared.present(
            title: String(localized: "librarySettings.labelGroups.removeTitle")
        ) { _ in
            RemoveLabelGroupDialog(groupName: group.name, groupIndex: group.index) {
                draft.labelGroups.removeAll { $0.id == group.id }
                for (keyword, value) in draft.semanticBindings where value == group.index {
                    draft.semanticBindings[keyword] = nil
                }
            }
        }
    }
}

private struct RemoveLabelGroupDialog: View {
    @Environment(\.locale) private var locale
    @Environment(\.dialogDismiss) private var dismiss

    let groupName: String
    let groupIndex: Int
    let onConfirm: () -> Void

    var body: some View {
        DialogScaffold(
            width: 440,
            confirm: DialogButton(title: String(localized: "librarySettings.labelGroups.remove",
                                                locale: locale), role: .destructive) {
                onConfirm()
                dismiss()
            },
            cancel: DialogButton(title: String(localized: "common.cancel", locale: locale),
                                 role: .cancel) { dismiss() }
        ) {
            VStack(alignment: .leading, spacing: Tokens.spacing.s) {
                Text(String(format: String(localized: "librarySettings.labelGroups.removeExplanation",
                                           locale: locale), groupName))
                    .fixedSize(horizontal: false, vertical: true)
                Text(String(format: String(localized: "librarySettings.labelGroups.removeWarning",
                                           locale: locale), groupIndex))
                    .font(.system(size: Tokens.fontSize.caption))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - ファイル名フォーマット

struct LibraryFilenameFormatsSettingsView: View {
    @Binding var draft: LibrarySettingsDraft
    /// 選択中の行とサンプル入力は**束縛として受け取る**。以前は
    /// `LibrarySettingsModel` を丸ごと要求していたが、それだと DB 上の
    /// ライブラリを前提とする型に縛られ、**有効化前（まだ行が無い）の
    /// 編集画面で再利用できない**。必要なのはこの 2 つだけ。
    @Binding var selectedFormatID: UUID?
    @Binding var sampleFilename: String

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.spacing.l) {
            SettingsSectionHeader(title: "librarySettings.section.filenameFormats",
                                  explanation: "librarySettings.filenameFormats.explanation")
            formatList
        }
    }

    /// 選択中の 1 本を**別ダイアログ**で編集する [ユーザー指摘: プレビューに
    /// 隠れて見つけづらい]。
    ///
    /// 以前は一覧の下にインラインで置いていたが、**縦に積む限りどこかで
    /// 隠れる**——一覧の高さ・不備メッセージの行数・プレビューの取り分が
    /// どれか変わるたびに押し出された（実機で 3 度作り直した）。編集を独立した
    /// ウインドウへ出せば、予約語パレットもサンプル試行も一度に見える。
    private func openEditor(for index: Int) {
        let format = draft.filenameFormats[index]
        let context = draft
        DialogWindowPresenter.shared.present(
            title: String(localized: "librarySettings.filenameFormats.editorTitle")
        ) { _ in
            FilenameFormatEditorDialog(source: format.source, draft: context) { edited in
                // 添字ではなく id で引き直す。ダイアログを開いている間に
                // 並べ替えや削除が起きても、別の行を書き換えない。
                guard let current = draft.filenameFormats.firstIndex(where: { $0.id == format.id })
                else { return }
                draft.filenameFormats[current].source = edited
            }
        }
    }

    private var selectedIndex: Int? {
        guard let id = selectedFormatID else { return nil }
        return draft.filenameFormats.firstIndex { $0.id == id }
    }

    private var formatList: some View {
        VStack(alignment: .leading, spacing: Tokens.spacing.xs) {
            // 上にあるものほど先に試される [FF-03]。並べ替えで優先順が変わる。
            Text("librarySettings.filenameFormats.orderHint")
                .font(.system(size: Tokens.fontSize.caption))
                .foregroundStyle(.secondary)
            // **高さを内容にあわせて伸ばさない。** 伸ばすと、下にある
            // 「選択中のフォーマット」の編集欄が `ScrollView` の外へ押し出され、
            // 「編集する手段が見当たらない」状態になる（実機で報告された）。
            EditableListChrome(height: 132) {
            List(selection: $selectedFormatID) {
                ForEach($draft.filenameFormats) { $format in
                    HStack(spacing: Tokens.spacing.s) {
                        Toggle("", isOn: $format.isEnabled)
                            .labelsHidden()
                            .help(Text("librarySettings.filenameFormats.enabledHelp"))
                        Text(verbatim: format.source.isEmpty
                             ? String(localized: "librarySettings.filenameFormats.empty")
                             : format.source)
                            .font(.system(size: Tokens.fontSize.body, design: .monospaced))
                            .foregroundStyle(format.isEnabled ? .primary : .secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 0)
                        if let error = compileError(format.source) {
                            Image(systemName: "exclamationmark.circle.fill")
                                .foregroundStyle(format.isEnabled ? .red : .orange)
                                .help(Text(verbatim: error))
                        }
                    }
                    .tag(format.id)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        guard let index = draft.filenameFormats
                            .firstIndex(where: { $0.id == format.id }) else { return }
                        selectedFormatID = format.id
                        openEditor(for: index)
                    }
                }
                .onMove { source, destination in
                    draft.filenameFormats.move(fromOffsets: source, toOffset: destination)
                }
                .onDelete { offsets in
                    draft.filenameFormats.remove(atOffsets: offsets)
                }
            }
            } buttons: {
                ListEditButton(kind: .add, help: "librarySettings.filenameFormats.add") {
                    let new = FilenameFormatDraft(source: "")
                    draft.filenameFormats.append(new)
                    selectedFormatID = new.id
                    // 空の行だけ増えても何もできない。そのまま編集へ入る。
                    openEditor(for: draft.filenameFormats.count - 1)
                }
                ListEditButton(kind: .remove, help: "librarySettings.filenameFormats.remove") {
                    guard let index = selectedIndex else { return }
                    draft.filenameFormats.remove(at: index)
                    selectedFormatID = draft.filenameFormats.first?.id
                }
                .disabled(selectedIndex == nil)
                // ダブルクリックでも開くが、**見えるボタンも要る**——
                // 「編集する手段が見当たらない」という指摘の出発点がそこだった。
                Button {
                    guard let index = selectedIndex else { return }
                    openEditor(for: index)
                } label: {
                    Image(systemName: "pencil")
                        .frame(width: 20, height: 16)
                        .contentShape(Rectangle())
                }
                .help(Text("librarySettings.filenameFormats.edit"))
                .disabled(selectedIndex == nil)
            }
        }
        .frame(maxWidth: 620, alignment: .leading)
    }

    private func compileError(_ source: String) -> String? {
        guard !source.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        do {
            _ = try FormatCompiler.compile(source, context: draft.compilationContext)
            return nil
        } catch {
            return error.whatHappened
        }
    }
}

/// フォーマット 1 本の編集支援 [HP-01〜HP-06]。
///
/// **予約語パレットとサンプルプレビューを必ず添える。** 網羅的な文法説明は
/// アプリ内に持たない方針 [HP-08] なので、「押せば入る」「打てば結果が出る」で
/// 分かる形にしないと、そもそも書けない（要件定義書 R-04）。
struct FilenameFormatEditorDialog: View {
    @Environment(\.locale) private var locale
    @Environment(\.dialogDismiss) private var dismiss

    /// **草案を直接書き換えない。** 手元で編集し、確定したときだけ返す
    /// ——キャンセルで元に戻せる。
    @State private var source: String
    /// サンプルはダイアログ 1 回ぶん。開き直せば消える（打ち直しの手間より、
    /// 前回の入力が残っている方が紛らわしい場面が多い）。
    @State private var sample: String = ""
    let draft: LibrarySettingsDraft
    let onCommit: (String) -> Void

    init(source: String, draft: LibrarySettingsDraft, onCommit: @escaping (String) -> Void) {
        _source = State(initialValue: source)
        self.draft = draft
        self.onCommit = onCommit
    }

    private var compileFailure: String? {
        guard !source.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        do {
            _ = try FormatCompiler.compile(source, context: draft.compilationContext)
            return nil
        } catch {
            return error.whatHappened
        }
    }

    var body: some View {
        DialogScaffold(
            width: 560,
            confirm: DialogButton(title: String(localized: "common.ok", locale: locale)) {
                onCommit(source)
                dismiss()
            },
            cancel: DialogButton(title: String(localized: "common.cancel", locale: locale),
                                 role: .cancel) { dismiss() }
        ) {
            editorBody
        }
    }

    private var editorBody: some View {
        VStack(alignment: .leading, spacing: Tokens.spacing.m) {
            TextField("", text: $source)
                .labelsHidden()
                .font(.system(size: Tokens.fontSize.body, design: .monospaced))
                .editableFieldChrome()

            if let compileFailure {
                Label(compileFailure, systemImage: "exclamationmark.circle.fill")
                    .font(.system(size: Tokens.fontSize.caption))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            reservedWordPalette
            samplePreview
        }
        .frame(maxWidth: 620, alignment: .leading)
    }

    // [HP-01][HP-02] ラベルグループに紐づく語には現在の名称を併記する。
    /// パレットの予約語を挿し込む [ユーザー指摘: 挿入した予約語の前に
    /// スペースが入る]。
    ///
    /// **スペースを勝手に足さない。** 以前は「直前がスペースでなければ 1 つ
    /// 足す」造りだったが、`(@librarytype)` のように**括弧の直後へ置きたい**
    /// 場合に `( @librarytype)` となって邪魔になる——実際に書きたい形は
    /// プリセットを見れば分かるとおり括弧に密着したものが多い。
    ///
    /// **カーソル位置へ挿す。** 末尾へ足す造りだと、書き終えたフォーマットの
    /// 途中に 1 つ足したいときに打ち直しになる。フィールドエディタが取れれば
    /// そこへ、取れなければ末尾へ（`InlineRenameSupport` と同じ経路）。
    private func insertReservedWord(_ word: String) {
        guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView else {
            source += word
            return
        }
        // フィールドエディタへ挿すと、`NSTextField` の変更通知を経由して
        // SwiftUI の束縛にも伝わる。伝わらなかった場合に備えて、挿入後の
        // 文字列で束縛を上書きしておく（二重に入ることはない——同じ値になる）。
        editor.insertText(word, replacementRange: editor.selectedRange())
        source = editor.string
    }

    private var reservedWordPalette: some View {
        VStack(alignment: .leading, spacing: Tokens.spacing.xs) {
            Text("librarySettings.filenameFormats.palette")
                .font(.system(size: Tokens.fontSize.caption))
                .foregroundStyle(.secondary)
            FlowRow(spacing: Tokens.spacing.xs) {
                ForEach(paletteEntries, id: \.word) { entry in
                    Button {
                        insertReservedWord(entry.word)
                    } label: {
                        VStack(spacing: 0) {
                            Text(verbatim: entry.word)
                                .font(.system(size: Tokens.fontSize.caption, design: .monospaced))
                            if let note = entry.note {
                                Text(verbatim: note)
                                    .font(.system(size: Tokens.fontSize.caption - 1))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.horizontal, Tokens.spacing.s)
                        .padding(.vertical, Tokens.spacing.xs)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    private var paletteEntries: [(word: String, note: String?)] {
        var entries: [(String, String?)] = [
            ("@title", String(localized: "librarySettings.word.title")),
            ("@volume", String(localized: "librarySettings.word.volume")),
            ("@librarytype", String(localized: "librarySettings.word.libraryType")),
            ("@libraryname", String(localized: "librarySettings.word.libraryName")),
            ("@ignore", String(localized: "librarySettings.word.ignore")),
        ]
        for group in draft.labelGroups.sorted(by: { $0.index < $1.index }) {
            entries.append(("@labelgroup\(group.index)", group.name))
        }
        for keyword in SemanticKeyword.allCases {
            guard let index = draft.semanticBindings[keyword] else { continue }
            entries.append((keyword.rawValue, draft.labelGroupName(at: index)))
        }
        return entries.map { (word: $0.0, note: $0.1) }
    }

    // [HP-05][HP-06] サンプル入力とフィールド分解。**保存しないまま試せる**
    // ことが要点——保存 → 走査 → 結果を見る、という往復では調整しきれない。
    private var samplePreview: some View {
        VStack(alignment: .leading, spacing: Tokens.spacing.xs) {
            Text("librarySettings.filenameFormats.sample")
                .font(.system(size: Tokens.fontSize.caption))
                .foregroundStyle(.secondary)
            TextField("librarySettings.filenameFormats.samplePlaceholder", text: $sample)
                .labelsHidden()
                .editableFieldChrome()
            FormatMatchPreview(sample: sample, draft: draft, source: source)
        }
    }
}

/// 編集中のフォーマット 1 本に対する照合結果。
struct FormatMatchPreview: View {
    let sample: String
    let draft: LibrarySettingsDraft
    let source: String

    private var outcome: [(label: String, value: String)]? {
        let name = sample.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !source.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        // 拡張子はパースの対象外 [4.8]。利用者は拡張子つきで貼り付けるのが普通
        // なので、こちらで落とす（打ち直しを求めない）。
        let stem = (name as NSString).deletingPathExtension
        guard let compiled = try? FormatCompiler.compile(source, context: draft.compilationContext)
        else { return nil }

        var settings = draft.compiledSnapshot()
        settings = LibrarySettingsSnapshot(
            libraryID: settings.libraryID,
            displayName: settings.displayName,
            libraryTypeName: settings.libraryTypeName,
            allLibraryTypeNames: settings.allLibraryTypeNames,
            allLibraryDisplayNames: settings.allLibraryDisplayNames,
            targetExtensions: settings.targetExtensions,
            imageExtensions: settings.imageExtensions,
            delimiters: settings.delimiters,
            protectedTokens: settings.protectedTokens,
            // **編集中の 1 本だけで試す。** 他のフォーマットが先に当たると、
            // 今いじっているものが効いているのかどうか分からない。
            filenameFormats: [compiled],
            folderLevelAssignments: settings.folderLevelAssignments,
            volumeFormats: settings.volumeFormats,
            semanticBindings: settings.semanticBindings,
            normalization: settings.normalization,
            seriesTitleCompositionFormat: settings.seriesTitleCompositionFormat)

        guard let result = FilenameParser().parse(stem, settings: settings, purpose: .preview)
        else { return nil }

        var rows = result.spans.compactMap { span -> (label: String, value: String)? in
            guard let value = result.fields[span.field] else { return nil }
            return (label: Self.label(for: span.field, draft: draft), value: value.text)
        }
        // **フィールドの切り出しだけでは足りない。** シリーズ名と巻数は
        // `@title` から導出されることが多く [SE-02][RW-10]、そこまで見せないと
        // 「タイトルに巻数が残ったままなのはなぜか」が分からない——実際に
        // 記録される値を出す。
        let fields = FieldPostProcessor.postProcess(result, settings: settings)
        if let series = fields.seriesName, result.fields[.series] == nil {
            rows.append((label: String(localized: "librarySettings.word.series"), value: series))
        }
        if fields.volume.kind != .none, result.fields[.volume] == nil {
            // 原文表記（`第01巻` `上巻`）を出す。数値へ畳んだ値だけだと
            // 「どこを巻数と読んだか」が分からない。
            rows.append((label: String(localized: "librarySettings.word.volume"),
                         value: fields.volume.raw ?? ""))
        }
        return rows
    }

    var body: some View {
        Group {
            if sample.trimmingCharacters(in: .whitespaces).isEmpty {
                EmptyView()
            } else if let outcome, !outcome.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Label("librarySettings.filenameFormats.matched", systemImage: "checkmark.circle.fill")
                        .font(.system(size: Tokens.fontSize.caption))
                        .foregroundStyle(.green)
                    ForEach(Array(outcome.enumerated()), id: \.offset) { _, pair in
                        HStack(alignment: .firstTextBaseline, spacing: Tokens.spacing.s) {
                            Text(verbatim: pair.label)
                                .font(.system(size: Tokens.fontSize.caption))
                                .foregroundStyle(.secondary)
                                .frame(width: 120, alignment: .trailing)
                            Text(verbatim: pair.value)
                                .font(.system(size: Tokens.fontSize.caption, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }
                }
            } else {
                Label("librarySettings.filenameFormats.notMatched",
                      systemImage: "xmark.circle.fill")
                    .font(.system(size: Tokens.fontSize.caption))
                    .foregroundStyle(.orange)
            }
        }
    }

    static func label(for field: FieldRef, draft: LibrarySettingsDraft) -> String {
        switch field {
        case .title:       String(localized: "librarySettings.word.title")
        // **予約語の綴りではなく訳語を出す。** `@author` と書くと、
        // 意味束縛でラベルにも流れたとき「@author: 著者値A ・ 著者: 著者値A」と
        // 並び、同じ値が 2 回出ている理由が読み取れない。訳語なら
        // 「著者名（＝ファイルの属性）」と「著者（＝ラベル）」の違いが分かる。
        case .series:      String(localized: "librarySettings.word.series")
        case .author:      String(localized: "librarySettings.word.author")
        case .volume:      String(localized: "librarySettings.word.volume")
        case .libraryType: String(localized: "librarySettings.word.libraryType")
        case .libraryName: String(localized: "librarySettings.word.libraryName")
        case .ignore:      String(localized: "librarySettings.word.ignore")
        case .labelGroup(let n): draft.labelGroupName(at: n) ?? "@labelgroup\(n)"
        }
    }
}

// MARK: - フォルダ階層割り当て

struct LibraryFolderLevelsSettingsView: View {
    @Binding var draft: LibrarySettingsDraft

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.spacing.l) {
            SettingsSectionHeader(title: "librarySettings.section.folderLevels",
                                  explanation: "librarySettings.folderLevels.explanation")
            VStack(spacing: 0) {
                ForEach($draft.folderLevels) { $level in
                    row($level)
                    Divider()
                }
            }
            .frame(maxWidth: 620, alignment: .leading)
            Button("librarySettings.folderLevels.add") {
                let next = (draft.folderLevels.map(\.level).max() ?? 0) + 1
                draft.folderLevels.append(FolderLevelDraft(level: next, assignment: .none))
            }
        }
    }

    private func row(_ level: Binding<FolderLevelDraft>) -> some View {
        HStack(spacing: Tokens.spacing.s) {
            Text(String(format: String(localized: "librarySettings.folderLevels.level"),
                        level.wrappedValue.level))
                .frame(width: 110, alignment: .leading)
            FixedWidthPopUp(items: kindItems, selection: kindBinding(level))
                .frame(width: 150)
            switch level.wrappedValue.assignment {
            case .none:
                Text("librarySettings.folderLevels.noneHint")
                    .font(.system(size: Tokens.fontSize.caption))
                    .foregroundStyle(.secondary)
            case .singleLabelGroup:
                FixedWidthPopUp(items: groupItems, selection: groupBinding(level))
                    .frame(width: 160)
            case .format:
                TextField("", text: formatBinding(level))
                    .labelsHidden()
                    .font(.system(size: Tokens.fontSize.body, design: .monospaced))
                    .editableFieldChrome()
            }
            Spacer(minLength: 0)
            Button {
                draft.folderLevels.removeAll { $0.id == level.wrappedValue.id }
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, Tokens.spacing.xs)
    }

    private var kindItems: [FixedWidthPopUp<String>.Item] {
        [.init(title: String(localized: "librarySettings.folderLevels.kindNone"), tag: "none"),
         .init(title: String(localized: "librarySettings.folderLevels.kindGroup"), tag: "group"),
         .init(title: String(localized: "librarySettings.folderLevels.kindFormat"), tag: "format")]
    }

    private var groupItems: [FixedWidthPopUp<Int>.Item] {
        draft.labelGroups.sorted { $0.index < $1.index }
            .map { .init(title: "\($0.index): \($0.name)", tag: $0.index) }
    }

    private func kindBinding(_ level: Binding<FolderLevelDraft>) -> Binding<String> {
        Binding(
            get: {
                switch level.wrappedValue.assignment {
                case .none: "none"
                case .singleLabelGroup: "group"
                case .format: "format"
                }
            },
            set: { kind in
                switch kind {
                case "group":
                    level.wrappedValue.assignment =
                        .singleLabelGroup(index: draft.labelGroups.first?.index ?? 1)
                case "format":
                    level.wrappedValue.assignment = .format(source: "")
                default:
                    level.wrappedValue.assignment = .none
                }
            })
    }

    private func groupBinding(_ level: Binding<FolderLevelDraft>) -> Binding<Int> {
        Binding(
            get: {
                if case .singleLabelGroup(let index) = level.wrappedValue.assignment { return index }
                return draft.labelGroups.first?.index ?? 1
            },
            set: { level.wrappedValue.assignment = .singleLabelGroup(index: $0) })
    }

    private func formatBinding(_ level: Binding<FolderLevelDraft>) -> Binding<String> {
        Binding(
            get: {
                if case .format(let source) = level.wrappedValue.assignment { return source }
                return ""
            },
            set: { level.wrappedValue.assignment = .format(source: $0) })
    }
}

// MARK: - 巻数フォーマット

struct LibraryVolumeFormatsSettingsView: View {
    @Binding var draft: LibrarySettingsDraft
    @State private var selectedID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.spacing.l) {
            SettingsSectionHeader(title: "librarySettings.section.volumeFormats",
                                  explanation: "librarySettings.volumeFormats.explanation")
            // **最長一致。同長なら登録順** [SE-21 の実測による改訂]。順序だけで
            // 決めると `作品 第01巻` が `01巻` と読まれ、シリーズ名が `作品 第`
            // になる（実データの一般コミックは 94% が `第??巻`）。
            Text("librarySettings.volumeFormats.matchingHint")
                .font(.system(size: Tokens.fontSize.caption))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("librarySettings.volumeFormats.regexHint")
                .font(.system(size: Tokens.fontSize.caption))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            EditableListChrome(height: 200) {
                List(selection: $selectedID) {
                    ForEach($draft.volumeFormats) { $pattern in
                        HStack(spacing: Tokens.spacing.s) {
                            Toggle("", isOn: $pattern.isEnabled).labelsHidden()
                            TextField("", text: $pattern.source)
                                .labelsHidden()
                                .font(.system(size: Tokens.fontSize.body, design: .monospaced))
                                .editableFieldChrome()
                            FixedWidthPopUp(items: VolumePatternKind.popUpItems,
                                            selection: $pattern.kind)
                                .frame(width: 100)
                            if let warning = firstFinding(for: pattern) {
                                Image(systemName: warning.isError
                                      ? "exclamationmark.circle.fill" : "exclamationmark.triangle.fill")
                                    .foregroundStyle(warning.isError ? .red : .orange)
                                    .help(Text(verbatim: warning.message))
                            }
                        }
                        .tag(pattern.id)
                        .padding(.vertical, Tokens.spacing.xs)
                    }
                    .onMove { source, destination in
                        draft.volumeFormats.move(fromOffsets: source, toOffset: destination)
                    }
                    .onDelete { offsets in
                        draft.volumeFormats.remove(atOffsets: offsets)
                    }
                }
            } buttons: {
                ListEditButton(kind: .add, help: "librarySettings.volumeFormats.add") {
                    let new = VolumeFormatDraft(source: "")
                    draft.volumeFormats.append(new)
                    selectedID = new.id
                }
                ListEditButton(kind: .remove, help: "librarySettings.volumeFormats.remove") {
                    guard let selectedID else { return }
                    draft.volumeFormats.removeAll { $0.id == selectedID }
                    self.selectedID = nil
                }
                .disabled(selectedID == nil)
            }
            .frame(maxWidth: 620, alignment: .leading)
        }
    }

    /// 行に出す 1 件。**静的検査だけ**を使う——`body` は入力のたびに評価されるので、
    /// 実測（`measuredIssues`）をここへ持ち込むと画面が重くなる。
    private func firstFinding(for pattern: VolumeFormatDraft) -> RegexSafetyFinding? {
        let source = pattern.source.trimmingCharacters(in: .whitespaces)
        guard !source.isEmpty else { return nil }
        let findings = RegexSafety.staticFindings(pattern.source)
        if let error = findings.first(where: \.isError) { return error }
        // 巻数種別はキャプチャグループが 1 つ必要。どこから値を取るか決まらないため。
        if pattern.kind == .volume, let regex = try? SafeRegex(pattern.source) {
            if regex.captureGroupCount == 0 {
                return RegexSafetyFinding(kind: .invalidSyntax(
                    String(localized: "librarySettings.volumeFormats.noCaptureGroup")))
            }
            if regex.captureGroupCount > 1, !regex.hasNamedVolumeGroup {
                return RegexSafetyFinding(kind: .invalidSyntax(
                    String(localized: "librarySettings.volumeFormats.ambiguousCaptureGroup")))
            }
        }
        return findings.first
    }
}

extension VolumePatternKind {
    /// 種別の選択肢。**序列巻数は廃止した**ので、巻数か区切りかの 2 択になる。
    static var popUpItems: [FixedWidthPopUp<VolumePatternKind>.Item] {
        [.init(title: String(localized: "librarySettings.volumeFormats.kindVolume"), tag: .volume),
         .init(title: String(localized: "librarySettings.volumeFormats.kindSeparator"), tag: .separator)]
    }
}

// MARK: - 折り返すレイアウト

/// 予約語パレットのように、幅に応じて折り返したい並びのための最小の `Layout`。
struct FlowRow: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 600
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: width, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += lineHeight + spacing
                lineHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
