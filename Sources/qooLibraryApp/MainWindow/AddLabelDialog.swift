import QooApplication
import QooKit
import SwiftUI

/// ラベルを付ける [RL-02][RL-03]。
///
/// 要件が段取りを名指ししている——「**まずどのラベルグループを設定するのかを
/// 選択し、次にそのラベルグループの既存ラベルを使うのか、新規ラベルを作成して
/// 使うのかを選べること**」[RL-02]。常設の一覧（`InspectorLabelSection`）は
/// ピン留めと付与済みしか出さない [RL-04][RL-05] ので、そこに無いものへ届く
/// 唯一の経路がここになる。
///
/// **独立したモーダルウインドウで出す**（`DialogWindowPresenter`）——右ペインは
/// 幅が狭く、グループ選択・検索・新規名の入力を縦に積むと必ずどれかが隠れる
/// （ライブラリ設定のフォーマット編集で 3 度直して分かったこと）。
struct AddLabelDialog: View {
    let model: LabelEditorModel
    let onChanged: () -> Void

    @Environment(\.locale) private var locale
    @Environment(\.dialogDismiss) private var dismiss

    private enum Mode: Hashable { case existing, new }

    @State private var groupID: LabelGroupID?
    @State private var mode: Mode = .existing
    @State private var searchText = ""
    @State private var selectedLabel: LabelID?
    @State private var newName = ""
    @FocusState private var isNameFocused: Bool

    var body: some View {
        DialogScaffold(
            width: 420,
            confirm: DialogButton(title: String(localized: "inspector.labels.addConfirm",
                                                locale: locale)) { add() },
            cancel: DialogButton(title: String(localized: "common.cancel", locale: locale),
                                 role: .cancel) { dismiss() },
            confirmDisabled: !canConfirm
        ) {
            // [RL-02] ① まずグループを選ぶ。**ラベル 0 件のグループも出す**
            // ——新しいラベルを作る先として要る。
            LabeledContent("inspector.labels.group") {
                Picker("", selection: Binding(
                    get: { groupID ?? model.allGroups.first?.id },
                    set: { groupID = $0 }
                )) {
                    ForEach(model.allGroups) { group in
                        Text(group.name).tag(Optional(group.id))
                    }
                }
                .labelsHidden()
            }

            // [RL-02] ② 既存を使うか、新しく作るか。
            Picker("", selection: $mode) {
                Text("inspector.labels.useExisting").tag(Mode.existing)
                Text("inspector.labels.createNew").tag(Mode.new)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()

            switch mode {
            case .existing:
                TextField("labelFilter.searchLabels", text: $searchText)
                    .editableFieldChrome()
                    .font(.system(size: Tokens.fontSize.caption))
                // **選択できる高さを固定する。**可変にすると、候補の件数で
                // ウインドウが伸び縮みして落ち着かない（固定サイズのダイアログで
                // 可変高さの領域を 2 つ持たない、の一般形）。
                List(selection: $selectedLabel) {
                    ForEach(filteredLabels) { label in
                        Text(label.name)
                            .font(.system(size: Tokens.fontSize.caption))
                            .tag(label.id)
                    }
                }
                .frame(height: 160)
                .border(Color.secondary.opacity(0.3))
                if filteredLabels.isEmpty {
                    Text("inspector.labels.noCandidates")
                        .font(.system(size: Tokens.fontSize.caption))
                        .foregroundStyle(.secondary)
                }
            case .new:
                TextField("inspector.labels.newNamePlaceholder", text: $newName)
                    .editableFieldChrome()
                    .focused($isNameFocused)
            }
        }
        .onAppear { groupID = groupID ?? model.allGroups.first?.id }
        .onChange(of: mode) { _, newValue in
            isNameFocused = newValue == .new
        }
        .onChange(of: groupID) { _, _ in
            // グループが変われば候補も変わる。前の選択を持ち越さない。
            selectedLabel = nil
            searchText = ""
        }
    }

    // MARK: - 判定

    private var currentGroup: LabelGroupSummary? {
        let id = groupID ?? model.allGroups.first?.id
        return model.allGroups.first { $0.id == id }
    }

    /// 既存ラベルの候補 [RL-02][LA-03]。アーカイブ済みは出さない。
    private var filteredLabels: [LabelSummary] {
        guard let currentGroup else { return [] }
        let all = model.addableLabels(in: currentGroup)
        guard !searchText.isEmpty else { return all }
        return all.filter { NameFilter.matches(name: $0.name, query: searchText) }
    }

    private var canConfirm: Bool {
        guard currentGroup != nil else { return false }
        switch mode {
        case .existing:
            return selectedLabel != nil
        case .new:
            return !newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    // MARK: - 操作

    private func add() {
        guard let currentGroup else { return }
        let mode = mode
        let selectedLabel = selectedLabel
        let newName = newName
        dismiss()
        Task {
            do {
                switch mode {
                case .existing:
                    guard let id = selectedLabel,
                          let label = model.addableLabels(in: currentGroup)
                            .first(where: { $0.id == id }) else { return }
                    try await model.add(label)
                case .new:
                    // 同じ正規化名が既にあればそれを使う [LB-01][N-03]
                    // ——重複の判断は `ensureLabel` が持つ。
                    try await model.createAndAdd(groupID: currentGroup.id, name: newName)
                }
                onChanged()
            } catch {
                await NotificationRouter.shared.presentError(
                    error, whatHappened: String(localized: "error.setLabelFailed", locale: locale))
            }
        }
    }
}
