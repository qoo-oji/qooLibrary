import QooInfrastructure
import QooKit
import SwiftUI

/// 環境設定「キーボード」タブ [15.10 節、KB2-01〜03]。`ActionID.allCases`
/// を一覧表示し、各操作の `KeyCombo` を追加・削除できる。永続化は既存の
/// `UserDefaultsKeyBindingStore.shared`（`KeyBindingStore` プロトコル）を
/// そのまま使い、新規の永続化コードは書かない。
///
/// `KeyBindingStore` は `@Observable` ではないプレーンなプロトコルのため、
/// 変更のたびに `bindings`（`@State`）へ明示的に読み直して再描画のきっかけに
/// している。
struct KeyboardPreferencesTab: View {
    private let store: KeyBindingStore = UserDefaultsKeyBindingStore.shared
    @State private var bindings: [KeyBinding] = []
    @State private var recordingAction: ActionID?
    @State private var conflictAlert: ConflictAlert?
    /// `String(localized:)` は SwiftUI の `.environment(\.locale)` を自動的には
    /// 見ない（`Text` の `LocalizedStringKey` 解決だけがこの environment を
    /// 見る）ため、動的に組み立てる文字列（衝突アラートの本文）向けに明示的に
    /// 読んで渡す。
    @Environment(\.locale) private var locale

    private struct ConflictAlert {
        let combo: KeyCombo
        let action: ActionID
        let conflictingActions: [ActionID]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.spacing.s) {
            List(bindings) { binding in
                HStack(alignment: .top, spacing: Tokens.spacing.m) {
                    Text(displayName(for: binding.id))
                        .frame(width: 140, alignment: .leading)
                    WrappingComboChips(
                        combos: binding.combos,
                        onRemove: { combo in remove(combo, from: binding.id) }
                    )
                    Spacer()
                    KeyComboRecorder(
                        isRecording: Binding(
                            get: { recordingAction == binding.id },
                            set: { recordingAction = $0 ? binding.id : nil }
                        ),
                        onCapture: { combo in add(combo, to: binding.id) }
                    )
                }
                .padding(.vertical, Tokens.spacing.xs)
            }
            .listStyle(.inset)

            HStack {
                Spacer()
                Button("preferences.resetToDefaults") { // [KB2-02][KB-05]
                    store.resetToDefaults()
                    refresh()
                }
            }
        }
        .padding(Tokens.spacing.l)
        .task { refresh() }
        .alert(
            "preferences.keyboard.conflictTitle",
            isPresented: Binding(get: { conflictAlert != nil }, set: { if !$0 { conflictAlert = nil } }),
            presenting: conflictAlert
        ) { alert in
            Button("preferences.keyboard.conflictAssign") {
                reassign(alert.combo, to: alert.action, removingFrom: alert.conflictingActions)
            }
            Button("common.cancel", role: .cancel) {}
        } message: { alert in
            let conflictNames = alert.conflictingActions.map { displayName(for: $0) }
                .formatted(.list(type: .and).locale(locale))
            let actionName = displayName(for: alert.action)
            // `String(format:)` を使うのは、複数の値を埋め込む文を
            // `String.LocalizationValue` の文字列補間キーとして書くと、Xcode の
            // 自動抽出が実際に生成する `%1$@`/`%2$@` 形式のプレースホルダ表記を
            // 手書きで正確に再現する必要があり事故りやすいため。`%@` テンプレート
            // + `String(format:)` の方が明確で安全 [1-12 ローカライズ方針]。
            let template = String(localized: "preferences.keyboard.conflictMessage", locale: locale)
            Text(String(format: template, conflictNames, actionName))
        }
    }

    private func refresh() {
        bindings = ActionID.allCases.map { store.binding(for: $0) }
    }

    private func add(_ combo: KeyCombo, to action: ActionID) {
        let conflicting = store.conflicts(of: combo).filter { $0 != action } // [KB-04]
        if !conflicting.isEmpty {
            conflictAlert = ConflictAlert(combo: combo, action: action, conflictingActions: conflicting)
            return
        }
        var combos = store.binding(for: action).combos
        guard !combos.contains(combo) else { return }
        combos.append(combo)
        try? store.setBinding(combos, for: action)
        refresh()
    }

    private func reassign(_ combo: KeyCombo, to action: ActionID, removingFrom conflicting: [ActionID]) {
        for other in conflicting {
            let remaining = store.binding(for: other).combos.filter { $0 != combo }
            try? store.setBinding(remaining, for: other)
        }
        var combos = store.binding(for: action).combos
        if !combos.contains(combo) {
            combos.append(combo)
        }
        try? store.setBinding(combos, for: action)
        refresh()
    }

    private func remove(_ combo: KeyCombo, from action: ActionID) {
        let combos = store.binding(for: action).combos.filter { $0 != combo }
        try? store.setBinding(combos, for: action)
        refresh()
    }

    /// アクションの表示名。`ActionID` 自体は `QooKit`（Foundation のみ）
    /// にあり UI 文字列を持たせられない [A-01] ため、View 層のここに置く。
    /// `Text(_:)` の `LocalizedStringKey` 解決と違い `String(localized:)` は
    /// environment を自動的に見ないため、`self.locale`（`@Environment`）を
    /// 明示的に渡す [1-12 ローカライズ方針、CLAUDE.md 参照]。
    private func displayName(for action: ActionID) -> String {
        let key: String.LocalizationValue = switch action {
        case .newTab: "action.newTab"
        case .open: "action.open"
        case .goToParent: "action.goToParent"
        case .goBack: "action.goBack"
        case .goForward: "action.goForward"
        case .rename: "action.rename"
        case .moveToTrash: "action.moveToTrash"
        case .deletePermanently: "action.deletePermanently"
        case .quickLook: "action.quickLook"
        case .toggleThumbnails: "action.toggleThumbnails"
        case .newFolder: "action.newFolder"
        case .copy: "action.copy"
        case .paste: "action.paste"
        case .cut: "action.cut"
        case .focusSearch: "action.focusSearch"
        case .toggleDisplayMode: "action.toggleDisplayMode"
        case .clearLabelFilter: "action.clearLabelFilter"
        case .moveToVault: "action.moveToVault"
        case .undo: "action.undo"
        case .redo: "action.redo"
        case .selectAll: "action.selectAll"
        case .duplicate: "folder.duplicate" // 既存のコンテキストメニュー表記と同じキーを再利用
        case .makeAlias: "folder.createAlias" // 同上
        case .compress: "action.compress"
        case .newFolderWithSelection: "action.newFolderWithSelection"
        }
        return String(localized: key, locale: locale)
    }
}

/// `KeyCombo` を折り返し表示するチップ群 [KB2-01: 割り当て済みキーの一覧表示]。
private struct WrappingComboChips: View {
    let combos: [KeyCombo]
    let onRemove: (KeyCombo) -> Void

    var body: some View {
        HStack(spacing: Tokens.spacing.xs) {
            if combos.isEmpty {
                Text("preferences.keyboard.unassigned")
                    .font(.system(size: Tokens.fontSize.caption))
                    .foregroundStyle(.secondary)
            }
            ForEach(combos, id: \.self) { combo in
                HStack(spacing: Tokens.spacing.xs) {
                    Text(combo.displayString)
                        .font(.system(size: Tokens.fontSize.caption, design: .monospaced))
                    Button {
                        onRemove(combo)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: Tokens.fontSize.caption))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
                .padding(.horizontal, Tokens.spacing.xs)
                .padding(.vertical, 2)
                .background(Color.secondary.opacity(0.15))
                .clipShape(Capsule())
            }
        }
    }
}

/// `KeyCombo` を macOS 標準の記号（⌘⇧⌥⌃）で表示する [KB2-01 のチップ表示用]。
private extension KeyCombo {
    var displayString: String {
        var result = ""
        if modifiers.contains(.control) { result += "⌃" }
        if modifiers.contains(.option) { result += "⌥" }
        if modifiers.contains(.shift) { result += "⇧" }
        if modifiers.contains(.command) { result += "⌘" }
        switch key {
        case "space": result += "Space"
        case "return", "enter": result += "↩"
        case "delete": result += "⌫"
        case "up": result += "↑"
        case "down": result += "↓"
        case "left": result += "←"
        case "right": result += "→"
        case "escape": result += "⎋"
        case "tab": result += "⇥"
        default: result += key.uppercased()
        }
        return result
    }
}
