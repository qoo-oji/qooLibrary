import AppKit
import SwiftUI

/// 左ペイン上半分: フォルダツリー [14章 §14.2]。
/// ボリューム／テンポラリフォルダ／ライブラリフォルダの 3 グループ [LP-01〜LP-08]。
///
/// テンポラリ・ライブラリフォルダの実際の**登録**（永続化）は 1-13 の担当。
/// 現時点では見出しと折りたたみの骨格のみを用意し、登録済みリストは常に空。
struct FolderTreePane: View {
    /// 中央ペインで現在表示中のフォルダ。一致するツリー行をハイライトする [LP-06]。
    let selectedURL: URL?
    let onSelect: (URL) -> Void

    @State private var volumesExpanded = true
    @State private var temporaryExpanded = true
    @State private var libraryExpanded = true
    @State private var expandedNodeIDs: Set<String> = [] // [LP-05]
    @State private var volumes: [FolderTreeNode] = []
    @State private var dropError: String?

    var body: some View {
        List {
            Section {
                if volumesExpanded {
                    ForEach(volumes) { node in
                        FolderTreeRow(
                            node: node, expandedIDs: $expandedNodeIDs, selectedURL: selectedURL, onSelect: onSelect,
                            onDropFailure: { dropError = $0 }
                        )
                    }
                }
            } header: {
                GroupHeader(title: "ボリューム", isExpanded: $volumesExpanded)
            }

            Section {
                if temporaryExpanded {
                    EmptyGroupRow(message: "登録なし（1-13 で実装）")
                }
            } header: {
                GroupHeader(title: "テンポラリフォルダ", isExpanded: $temporaryExpanded, showsAddButton: true) {
                    // [LP-01] + ボタン。フォルダ登録本体は 1-13。
                }
            }

            Section {
                if libraryExpanded {
                    EmptyGroupRow(message: "登録なし（1-13 で実装）")
                }
            } header: {
                GroupHeader(title: "ライブラリフォルダ", isExpanded: $libraryExpanded, showsAddButton: true) {
                    // [LP-02] + ボタン。フォルダ登録本体は 1-13。
                }
            }
        }
        .listStyle(.sidebar)
        .environment(\.defaultMinListRowHeight, 20) // 行間を少し詰める。可変にするのは 1-12（環境設定）で。
        .task {
            volumes = FolderTreeNode.mountedVolumes()
        }
        .alert("操作に失敗しました", isPresented: Binding(get: { dropError != nil }, set: { if !$0 { dropError = nil } })) {
            Button("OK") {}
        } message: {
            Text(dropError ?? "")
        }
    }
}

private struct GroupHeader: View {
    let title: String
    @Binding var isExpanded: Bool
    var showsAddButton: Bool = false
    var onAdd: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: Tokens.spacing.xs) {
            Button {
                isExpanded.toggle() // [LP-07] 各グループは折りたたみ可
            } label: {
                HStack(spacing: Tokens.spacing.xs) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9))
                    Text(title)
                }
            }
            .buttonStyle(.plain)
            Spacer()
            if showsAddButton {
                Button {
                    onAdd?()
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("\(title)を登録（1-13 で実装）")
                Image(systemName: "gearshape")
                    .foregroundStyle(.secondary)
                    .help("\(title)の設定（1-13 以降で実装）")
            }
        }
    }
}

private struct EmptyGroupRow: View {
    let message: String
    var body: some View {
        Text(message)
            .font(.system(size: Tokens.fontSize.caption))
            .foregroundStyle(.secondary)
    }
}

/// ツリーの 1 行。実フォルダの子を遅延読み込みする再帰 View。
private struct FolderTreeRow: View {
    let node: FolderTreeNode
    @Binding var expandedIDs: Set<String>
    let selectedURL: URL?
    let onSelect: (URL) -> Void
    let onDropFailure: @MainActor @Sendable (String) -> Void

    @State private var children: [FolderTreeNode]?
    @State private var accessDenied = false
    @State private var isDropTargeted = false

    private var isSelected: Bool {
        selectedURL?.standardizedFileURL.path == node.url.standardizedFileURL.path
    }

    private var isExpanded: Binding<Bool> {
        Binding(
            get: { expandedIDs.contains(node.id) },
            set: { newValue in
                if newValue {
                    expandedIDs.insert(node.id)
                } else {
                    expandedIDs.remove(node.id)
                }
            }
        )
    }

    var body: some View {
        DisclosureGroup(isExpanded: node.isSymlink ? .constant(false) : isExpanded) {
            if accessDenied {
                AccessDeniedRow() // [SB-04][LP2-09]
            } else if let children {
                ForEach(children) { child in
                    FolderTreeRow(
                        node: child, expandedIDs: $expandedIDs, selectedURL: selectedURL, onSelect: onSelect,
                        onDropFailure: onDropFailure
                    )
                }
            } else {
                ProgressView()
                    .controlSize(.small)
            }
        } label: {
            Label(node.displayName, systemImage: node.isSymlink ? "arrow.turn.up.right" : "folder")
                .opacity(node.isOnline ? 1 : 0.4) // [LP-04]
                .fontWeight(isSelected ? .semibold : .regular)
                .padding(.horizontal, Tokens.spacing.xs)
                .padding(.vertical, 2)
                .background(isDropTargeted ? Tokens.Colors.accent.opacity(0.35) : (isSelected ? Tokens.Colors.accent.opacity(0.25) : Color.clear))
                .clipShape(RoundedRectangle(cornerRadius: Tokens.radius.s))
                .contentShape(Rectangle())
                .onTapGesture { onSelect(node.url) } // [LP-06]
                .dropDestination(for: URL.self) { items, _ in // [DD-05] ツリーへドロップで移動
                    DropHandling.performDrop(
                        items, into: node.url,
                        onComplete: {
                            if children != nil { loadChildren() }
                            // ウインドウ／ペインをまたいだ変更を拾う暫定策 [1-6 実機検証で発見]。
                            SessionState.shared.reloadToken += 1
                        },
                        onFailure: onDropFailure
                    )
                    return true
                } isTargeted: { isDropTargeted = $0 }
        }
        .disabled(node.isSymlink) // [SL-05]
        .onChange(of: isExpanded.wrappedValue, initial: true) { _, expanded in
            guard expanded, children == nil, !accessDenied else { return }
            loadChildren()
        }
    }

    private func loadChildren() {
        do {
            children = try FolderTreeNode.children(of: node)
        } catch {
            accessDenied = true
        }
    }
}

private struct AccessDeniedRow: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.spacing.xs) {
            Text("アクセス権がありません")
                .font(.system(size: Tokens.fontSize.caption))
                .foregroundStyle(Tokens.Colors.dangerText)
            Button("システム設定を開く") {
                // [B-20] フルディスクアクセスは entitlement では取得できない。
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                    NSWorkspace.shared.open(url)
                }
            }
            .font(.system(size: Tokens.fontSize.caption))
        }
    }
}
