//
//  ラベルグループ編集ウインドウの右ペイン [LE-03〜LE-12][LB-04〜LB-07][LA-01][LA-08]。
//
//  判定（並べ替え・検索・0 件・保管庫・統合先）は `LabelGroupEditorModel` が
//  持ち、ここは描くだけ。**この分担を崩さないこと**——View に判定を書くと
//  `swift test` から触れなくなる。
//
import QooApplication
import QooKit
import SwiftUI

struct LabelListPane: View {
    @Bindable var model: LabelGroupEditorModel
    @Environment(\.locale) private var locale
    @Environment(\.colorScheme) private var colorScheme

    /// 行内で改名中のラベル。Finder 流のインライン編集にはせず、
    /// 一覧の下の編集欄で扱う——一覧の行は選択と複数選択に使うため。
    @State private var draftName: String = ""
    @State private var newLabelName: String = ""
    @State private var errorText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            toolbar
            Divider()
            content
            Divider()
            footer
        }
    }

    // MARK: - 上部: 並べ替えと検索 [LE-12]

    private var toolbar: some View {
        HStack(spacing: Tokens.spacing.m) {
            Picker("", selection: $model.sortOrder) {
                Text("labelEditor.sort.name").tag(LabelGroupEditorModel.SortOrder.name)
                Text("labelEditor.sort.count").tag(LabelGroupEditorModel.SortOrder.fileCount)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 180)

            TextField("labelEditor.searchPlaceholder", text: $model.searchText)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 140)
        }
        .padding(Tokens.spacing.m)
    }

    // MARK: - 一覧

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .notReady:
            placeholder("labelEditor.notReady", systemImage: "externaldrive.badge.xmark")
        case .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .noSelection:
            placeholder("labelEditor.selectGroup", systemImage: "tag")
        case .failed(let reason):
            placeholder(LocalizedStringKey(reason), systemImage: "exclamationmark.triangle")
        case .ready:
            list
        }
    }

    private func placeholder(_ key: LocalizedStringKey, systemImage: String) -> some View {
        ContentUnavailableView { Label(key, systemImage: systemImage) }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var list: some View {
        List(selection: $model.selection) {
            ForEach(model.rows) { row in
                LabelRowView(row: row, groupColor: currentGroupColor)
                    .tag(row.id)
                    .contextMenu { rowMenu(row) }
            }
        }
        .overlay {
            if model.rows.isEmpty {
                ContentUnavailableView {
                    Label(model.searchText.isEmpty
                          ? "labelEditor.noLabels" : "labelEditor.noMatches",
                          systemImage: "tag")
                }
            }
        }
    }

    /// 選択中のグループの色。ラベル固有色が無ければこれを継承する [CO-06]。
    private var currentGroupColor: LabelColor {
        guard let id = model.selectedGroupID,
              let group = model.groups.first(where: { $0.id == id }) else {
            return LabelColor(hexLight: "#DDDDDD", hexDark: "#555555")
        }
        return LabelColor(hexLight: group.colorHexLight, hexDark: group.colorHexDark)
    }

    // MARK: - 下部: 操作

    private var footer: some View {
        VStack(alignment: .leading, spacing: Tokens.spacing.m) {
            if let errorText {
                Text(errorText)
                    .font(.system(size: Tokens.fontSize.caption))
                    .foregroundStyle(Color("DangerText"))
                    .fixedSize(horizontal: false, vertical: true)
            }
            addRow
            if let single = singleSelection { editRow(single) }
            batchRow
        }
        .padding(Tokens.spacing.m)
    }

    /// 追加 [LE-07]。グループが未保存（DB に行が無い）なら押せない。
    private var addRow: some View {
        HStack(spacing: Tokens.spacing.s) {
            TextField("labelEditor.newLabelPlaceholder", text: $newLabelName)
                .textFieldStyle(.roundedBorder)
                .onSubmit { perform { try await model.createLabel(named: newLabelName)
                                      newLabelName = "" } }
            Button("labelEditor.add") {
                perform { try await model.createLabel(named: newLabelName); newLabelName = "" }
            }
            .disabled(newLabelName.trimmingCharacters(in: .whitespaces).isEmpty
                      || model.selectedGroupID == nil)
        }
    }

    private var singleSelection: LabelSummary? {
        model.selection.count == 1 ? model.selectedLabels.first : nil
    }

    /// 1 件だけ選んでいるときの編集（改名・色・ピン・統合）。
    private func editRow(_ label: LabelSummary) -> some View {
        VStack(alignment: .leading, spacing: Tokens.spacing.s) {
            HStack(spacing: Tokens.spacing.s) {
                TextField("labelEditor.namePlaceholder", text: $draftName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { perform { try await model.rename(label, to: draftName) } }
                LabelColorWell(color: colorBinding(for: label), shape: .single,
                               defaultColor: currentGroupColor, previewName: label.name)
                Button {
                    perform { try await model.setPinned(label, !label.isPinned) }
                } label: {
                    Image(systemName: label.isPinned ? "pin.fill" : "pin")
                }
                .buttonStyle(.borderless)
                .help("labelEditor.togglePin")
                Menu("labelEditor.merge") {
                    ForEach(LabelGroupEditorModel.mergeTargets(
                        from: model.allLabels, excluding: label.id), id: \.id) { target in
                        Button(target.name) { confirmMerge(label, into: target) }
                    }
                }
                .frame(width: 92)
                .disabled(model.allLabels.count < 2)
            }
            .onChange(of: label.id) { _, _ in draftName = label.name }
            .onAppear { draftName = label.name }
        }
    }

    /// 複数まとめて扱えるもの [LE-07][LE-09]。
    private var batchRow: some View {
        HStack(spacing: Tokens.spacing.s) {
            Text(String(format: String(localized: "labelEditor.selectedCount", locale: locale),
                        model.selection.count))
                .font(.system(size: Tokens.fontSize.caption))
                .foregroundStyle(.secondary)
            Spacer()
            Button(model.archiveActionArchives
                   ? "labelEditor.moveToVault" : "labelEditor.restoreFromVault") {
                perform { try await model.setSelectedArchived(model.archiveActionArchives) }
            }
            .disabled(model.selection.isEmpty)
            Button("labelEditor.delete", role: .destructive) { confirmDelete() }
                .disabled(model.selection.isEmpty)
        }
    }

    @ViewBuilder
    private func rowMenu(_ row: LabelGroupEditorModel.Row) -> some View {
        Button(row.isPinned ? "labelEditor.unpin" : "labelEditor.pin", systemImage: "pin") {
            perform { try await model.setPinned(row.label, !row.isPinned) }
        }
        Button(row.isArchived
               ? "labelEditor.restoreFromVault" : "labelEditor.moveToVault",
               systemImage: "archivebox") {
            model.selection = [row.id]
            perform { try await model.setSelectedArchived(!row.isArchived) }
        }
        Divider()
        Button("labelEditor.delete", systemImage: "trash", role: .destructive) {
            model.selection = [row.id]
            confirmDelete()
        }
    }

    /// ラベル固有色 [CO-06]。**書き込みはコマンド経由**なので ⌘Z で戻せる。
    ///
    /// `LabelColorWell` は 1 色のとき light/dark に同じ値を書くので、読むのは
    /// `hexLight` だけでよい（`labelColor(_:in:)` の読み方と揃えてある）。
    private func colorBinding(for label: LabelSummary) -> Binding<LabelColor> {
        Binding(
            get: {
                guard let hex = label.colorHex else { return currentGroupColor }
                return LabelColor(hexLight: hex, hexDark: hex)
            },
            set: { picked in
                // 継承へ戻す（グループ色と同じ値を選んだ）なら nil を書く [CO-06]
                let hex: String? = picked == currentGroupColor ? nil : picked.hexLight
                perform { try await model.setColor(label, hex: hex) }
            })
    }

    // MARK: - 確認

    /// **削除は取り消せるが、確認は挟む** [LE-08]。何件のファイルから外れるかを
    /// 見せる——件数を出さないと「使われていないつもり」で消してしまう。
    private func confirmDelete() {
        let targets = model.selectedLabels
        guard !targets.isEmpty else { return }
        DialogWindowPresenter.shared.present(
            title: String(localized: "labelEditor.deleteTitle", locale: locale)
        ) { _ in
            DeleteLabelsDialog(labels: targets) {
                perform { try await model.deleteSelected() }
            }
        }
    }

    private func confirmMerge(_ source: LabelSummary, into target: LabelSummary) {
        DialogWindowPresenter.shared.present(
            title: String(localized: "labelEditor.mergeTitle", locale: locale)
        ) { _ in
            MergeLabelsDialog(source: source, target: target) {
                perform { try await model.merge(source, into: target) }
            }
        }
    }

    // MARK: - 実行

    /// 失敗の理由を画面に残す。
    ///
    /// **改名の衝突 [LE-11] はここで受ける。** `LabelEditError` はどれも
    /// 「次に何ができるか」が言える失敗なので、素の文言に落とさず訳す。
    private func perform(_ work: @escaping () async throws -> Void) {
        Task {
            do {
                try await work()
                errorText = nil
            } catch let error as LabelEditError {
                errorText = Self.message(for: error, locale: locale)
            } catch {
                errorText = error.localizedDescription
            }
        }
    }

    static func message(for error: LabelEditError, locale: Locale) -> String {
        switch error {
        case .nameAlreadyExists(_, let name):
            return String(format: String(localized: "labelEditor.error.nameExists",
                                         locale: locale), name)
        case .crossGroupMerge:
            return String(localized: "labelEditor.error.crossGroupMerge", locale: locale)
        case .labelNotFound:
            return String(localized: "labelEditor.error.notFound", locale: locale)
        }
    }
}

// MARK: - 行

/// 一覧の 1 行 [LE-03][LE-04][LE-06]。
struct LabelRowView: View {
    let row: LabelGroupEditorModel.Row
    let groupColor: LabelColor

    var body: some View {
        HStack(spacing: Tokens.spacing.s) {
            LabelChip(name: row.name, color: color, count: row.fileCount)
                // 0 件は赤字 [LE-04][RC-07]、保管庫はグレー [LE-06]
                .foregroundStyle(row.isOrphaned ? Color("DangerText") : Color.primary)
                .opacity(row.isArchived ? 0.55 : 1)
            if row.isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: Tokens.fontSize.caption))
                    .foregroundStyle(.secondary)
            }
            if row.isArchived {
                // 保管庫にあることを示すバッジ [LE-06]
                Image(systemName: "archivebox.fill")
                    .font(.system(size: Tokens.fontSize.caption))
                    .foregroundStyle(.secondary)
                    .help("labelEditor.inVault")
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 1)
    }

    /// ラベル固有色が無ければグループ色を継承 [CO-06]。
    private var color: LabelColor {
        guard let hex = row.colorHex else { return groupColor }
        return LabelColor(hexLight: hex, hexDark: hex)
    }
}
