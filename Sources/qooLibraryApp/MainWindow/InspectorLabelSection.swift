//
//  右ペインのラベル設定 [RL-01〜RL-07][RP-02]。
//
//  判定は `LabelEditorModel`（`QooApplication`）が持ち、この View は描くだけ
//  ——`InspectorRatingSection` と同じ分け方。そうしないと三状態の畳み込みや
//  アーカイブ済みの出し分け [LA-03][RL-05] を自動テストで固定できない。
//
//  一覧の並べ方は**ラベルフィルタと同じ** [RL-04]（`PinnedLabelListing`）。
//
import QooApplication
import QooKit
import SwiftUI

struct InspectorLabelSection: View {
    let model: LabelEditorModel
    /// 書き込みのあとに一覧と件数を読み直す。
    let onChanged: () -> Void

    @Environment(\.locale) private var locale
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openWindow) private var openWindow
    @State private var isAddingLabel = false

    var body: some View {
        switch model.state {
        case .notApplicable:
            // ライブラリ経由で開いていない。**枠ごと出さない** [LF-01 と同じ判断]。
            EmptyView()
        case .loading:
            section { ProgressView().controlSize(.small) }
        case .notInLibrary:
            // DB に行が無い。**枠ごと出さない**——理由の文は置かない
            //［ユーザー指摘、2026-09-02］ので、空の枠だけが残るのは意味が無い
            //（`InspectorVaultSection` / `InspectorProtectionSection` と同じ）。
            EmptyView()
        case .failed(let reason):
            section {
                Text(reason)
                    .font(.system(size: Tokens.fontSize.caption))
                    .foregroundStyle(Tokens.Colors.dangerText)
                    .lineLimit(3)
            }
        case .ready(let subject):
            section {
                ForEach(model.displayGroups) { group in
                    groupSection(group)
                }
                // **対象外が混ざったことを黙って隠さない** [RP-02]。
                // 「10 件選んだのに 8 件にしか付かなかった」を数字で見せる。
                if subject.skippedCount > 0 {
                    Text(String(format: String(localized: "inspector.labels.skipped",
                                               locale: locale), "\(subject.skippedCount)"))
                        .font(.system(size: Tokens.fontSize.caption))
                        .foregroundStyle(.secondary)
                }
                Button {
                    isAddingLabel = true
                } label: {
                    Label("inspector.labels.add", systemImage: "plus")
                        .font(.system(size: Tokens.fontSize.caption))
                }
                .buttonStyle(.link)
                .disabled(model.allGroups.isEmpty)
            }
            .onChange(of: isAddingLabel) { _, presenting in
                // [RL-02] グループ → 既存／新規 の 2 段。独立したモーダル
                // ウインドウで出す（この画面の入力ダイアログの約束）。
                guard presenting else { return }
                isAddingLabel = false
                DialogWindowPresenter.shared.present(
                    title: String(localized: "inspector.labels.addTitle", locale: locale)
                ) { _ in
                    AddLabelDialog(model: model, onChanged: onChanged)
                }
            }
        }
    }

    // MARK: - 部品

    /// **見出しは置かない**［ユーザー指摘、2026-09-02］——ラベルのチップが
    /// 並んでいれば、何の節かは読める。
    @ViewBuilder
    private func section(@ViewBuilder _ content: () -> some View) -> some View {
        Divider()
        VStack(alignment: .leading, spacing: Tokens.spacing.xs) {
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .font(.system(size: Tokens.fontSize.caption))
    }

    @ViewBuilder
    private func groupSection(_ group: LabelGroupSummary) -> some View {
        DisclosureGroup(isExpanded: expansionBinding(group)) {
            ForEach(model.visibleLabels(in: group)) { label in
                labelRow(label, in: group)
            }
            if model.hasMoreLabels(in: group) {
                Button { model.revealedGroups.insert(group.id) } label: {
                    Text("labelFilter.showMore").font(.system(size: Tokens.fontSize.caption))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
            } else if model.revealedGroups.contains(group.id) {
                TextField("labelFilter.searchLabels", text: searchBinding(group))
                    .editableFieldChrome()
                    .font(.system(size: Tokens.fontSize.caption))
                Button {
                    model.revealedGroups.remove(group.id)
                    model.searchText[group.id] = nil
                } label: {
                    Text("labelFilter.showLess").font(.system(size: Tokens.fontSize.caption))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
            }
        } label: {
            HStack(spacing: Tokens.spacing.xs) {
                Circle().fill(groupColor(group)).frame(width: 8, height: 8)
                Text(group.name)
                    .font(.system(size: Tokens.fontSize.caption, weight: .medium))
                    .lineLimit(1)
                // **鍵はフィールド見出しに出す** [PR-02][PR-03]。保護の単位は
                // フィールドであってラベル 1 つずつではないので、チップに
                // 印を付けると単位を取り違えて読める。
                if model.isFieldProtected(group) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: Tokens.fontSize.caption))
                        .foregroundStyle(.secondary)
                        .help(String(localized: "inspector.labels.protected"))
                }
            }
        }
    }

    private func labelRow(_ label: LabelSummary, in group: LabelGroupSummary) -> some View {
        let assignment = model.assignment(of: label)
        return HStack(spacing: Tokens.spacing.xs) {
            // **三状態が要る** [RP-02]ので `Toggle` ではなく AppKit のチェック
            // ボックスを使う（SwiftUI の `Toggle` は中間状態を表せない）。
            MixedStateCheckbox(state: checkboxState(assignment)) {
                Task { await toggle(label) }
            }
            LabelChip(name: label.name,
                      color: labelColor(label, in: group),
                      count: label.fileCount)
                // 改名・統合・保管庫へ送る導線 [LB-06][LB-07][LA-01]。
                // ここでは付け外ししかできないので、編集は 15.2 のウインドウへ。
                .contextMenu {
                    Button("labelEditor.editLabelsEllipsis", systemImage: "tag") {
                        // ラベルの属するフィールドを選んだ状態で開く [RL3-04]。
                        LabelEditorNavigation.open(libraryID: group.libraryID,
                                                   groupID: group.id,
                                                   openWindow: openWindow)
                    }
                }
            Spacer(minLength: 0)
            // 複数選択で一部にだけ付いているとき、何件かを添える [RP-02]。
            if assignment.checkState == .some {
                Text("\(assignment.assignedCount)/\(assignment.targetCount)")
                    .font(.system(size: Tokens.fontSize.caption))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func checkboxState(_ a: LabelEditorModel.Assignment) -> MixedStateCheckbox.State {
        switch a.checkState {
        case .none: .off
        case .some: .mixed
        case .all: .on
        }
    }

    private func expansionBinding(_ group: LabelGroupSummary) -> Binding<Bool> {
        Binding(
            get: { model.expandedGroups.contains(group.id) },
            set: { expanded in
                if expanded { model.expandedGroups.insert(group.id) }
                else { model.expandedGroups.remove(group.id) }
            })
    }

    private func searchBinding(_ group: LabelGroupSummary) -> Binding<String> {
        Binding(get: { model.searchText[group.id] ?? "" },
                set: { model.searchText[group.id] = $0 })
    }

    private func groupColor(_ group: LabelGroupSummary) -> Color {
        let hex = colorScheme == .dark ? group.colorHexDark : group.colorHexLight
        return Color(labelHex: hex) ?? .secondary
    }

    /// ラベル固有色が無ければグループ色を継承する [CO-06]。
    private func labelColor(_ label: LabelSummary, in group: LabelGroupSummary) -> LabelColor {
        guard let hex = label.colorHex else {
            return LabelColor(hexLight: group.colorHexLight, hexDark: group.colorHexDark)
        }
        return LabelColor(hexLight: hex, hexDark: hex)
    }

    // MARK: - 操作

    private func toggle(_ label: LabelSummary) async {
        do {
            try await model.toggle(label)
            onChanged()
        } catch {
            await NotificationRouter.shared.presentError(
                error, whatHappened: String(localized: "error.setLabelFailed", locale: locale))
        }
    }
}
