import AppKit
import QooInfrastructure
import SwiftUI

/// 左ペイン上半分: フォルダツリー [14章 §14.2]。
/// ボリューム／テンポラリフォルダ／ライブラリフォルダの 3 グループ [LP-01〜LP-08]。
///
/// テンポラリ・ライブラリフォルダの登録・削除は 1-13 で実装した
/// [RG-01〜RG-08、`RegisteredFolderStore` 参照]。
struct FolderTreePane: View {
    /// 中央ペインで現在表示中のフォルダ。一致するツリー行をハイライトする [LP-06]。
    let selectedURL: URL?
    let onSelect: (URL) -> Void

    @State private var volumesExpanded = true
    @State private var temporaryExpanded = true
    @State private var libraryExpanded = true
    @State private var expandedNodeIDs: Set<String> = [] // [LP-05]
    @State private var volumes: [FolderTreeNode] = []
    @State private var libraryEntries: [RegisteredFolderEntry] = []
    @State private var temporaryEntries: [RegisteredFolderEntry] = []
    @State private var dropError: String?
    @State private var registrationError: String?
    @State private var renamingFolder: RegisteredFolder?
    @State private var renameText = ""

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
                    registeredFolderRows(temporaryEntries)
                }
            } header: {
                GroupHeader(title: "テンポラリフォルダ", isExpanded: $temporaryExpanded, showsAddButton: true) {
                    presentRegistrationPanel(kind: .temporary)
                }
            }

            Section {
                if libraryExpanded {
                    registeredFolderRows(libraryEntries)
                }
            } header: {
                GroupHeader(title: "ライブラリフォルダ", isExpanded: $libraryExpanded, showsAddButton: true) {
                    presentRegistrationPanel(kind: .library)
                }
            }
        }
        .listStyle(.sidebar)
        .environment(\.defaultMinListRowHeight, 20) // 行間を少し詰める。可変にするのは 1-12（環境設定）で。
        .task {
            volumes = FolderTreeNode.mountedVolumes()
            await reloadRegisteredFolders()
        }
        .alert("操作に失敗しました", isPresented: Binding(get: { dropError != nil }, set: { if !$0 { dropError = nil } })) {
            Button("OK") {}
        } message: {
            Text(dropError ?? "")
        }
        .alert("登録できませんでした", isPresented: Binding(get: { registrationError != nil }, set: { if !$0 { registrationError = nil } })) {
            Button("OK") {}
        } message: {
            Text(registrationError ?? "")
        }
        .alert("表示名を変更", isPresented: Binding(get: { renamingFolder != nil }, set: { if !$0 { renamingFolder = nil } })) {
            TextField("表示名", text: $renameText)
            Button("変更") { commitRenameRegisteredFolder() }
            Button("キャンセル", role: .cancel) {}
        }
    }

    @ViewBuilder
    private func registeredFolderRows(_ entries: [RegisteredFolderEntry]) -> some View {
        if entries.isEmpty {
            EmptyGroupRow(message: "登録なし")
        } else {
            ForEach(entries) { entry in
                if let node = entry.node {
                    FolderTreeRow(
                        node: node, expandedIDs: $expandedNodeIDs, selectedURL: selectedURL, onSelect: onSelect,
                        onDropFailure: { dropError = $0 },
                        registeredFolder: entry.folder,
                        onRename: { beginRenameRegisteredFolder(entry.folder) },
                        onUnregister: { unregisterFolder(entry.folder) }
                    )
                } else {
                    // ブックマーク解決失敗（ボリューム未接続等）[SB-05]。
                    OfflineRegisteredFolderRow(displayName: entry.folder.displayName) {
                        unregisterFolder(entry.folder)
                    }
                }
            }
        }
    }

    private func presentRegistrationPanel(kind: RegisteredFolderKind) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "登録"
        panel.message = kind == .library
            ? "ライブラリフォルダとして登録するフォルダを選択してください"
            : "テンポラリフォルダとして登録するフォルダを選択してください"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                _ = try await RegisteredFolderStore.shared.register(url: url, kind: kind, displayName: nil)
                await reloadRegisteredFolders()
            } catch {
                registrationError = Self.errorMessage(for: error)
            }
        }
    }

    private func unregisterFolder(_ folder: RegisteredFolder) {
        Task {
            try? await RegisteredFolderStore.shared.unregister(folder.id)
            await reloadRegisteredFolders()
        }
    }

    private func beginRenameRegisteredFolder(_ folder: RegisteredFolder) {
        renamingFolder = folder
        renameText = folder.displayName
    }

    private func commitRenameRegisteredFolder() {
        guard let folder = renamingFolder, !renameText.isEmpty else { return }
        Task {
            try? await RegisteredFolderStore.shared.rename(folder.id, to: renameText)
            await reloadRegisteredFolders()
        }
    }

    private func reloadRegisteredFolders() async {
        async let libraries = RegisteredFolderStore.shared.folders(kind: .library)
        async let temporaries = RegisteredFolderStore.shared.folders(kind: .temporary)
        libraryEntries = await Self.entries(for: libraries, kind: .library)
        temporaryEntries = await Self.entries(for: temporaries, kind: .temporary)
    }

    private static func entries(for folders: [RegisteredFolder], kind: FolderTreeNode.Kind) async -> [RegisteredFolderEntry] {
        var result: [RegisteredFolderEntry] = []
        for folder in folders {
            let url = await RegisteredFolderStore.shared.resolvedURL(for: folder)
            let node = url.map { FolderTreeNode(url: $0, displayName: folder.displayName, kind: kind) }
            result.append(RegisteredFolderEntry(folder: folder, node: node))
        }
        return result
    }

    private static func errorMessage(for error: Error) -> String {
        switch error {
        case RegisteredFolderError.nestedRegistration:
            return "このフォルダは既に登録済みのフォルダと親子関係にあります。ライブラリ・テンポラリフォルダ同士は入れ子にできません。"
        case RegisteredFolderError.unsupportedFileSystem(let reason):
            switch reason {
            case .noPersistentFileID(let fileSystem), .persistentIDNotPreserved(let fileSystem):
                return "このフォルダのファイルシステム（\(fileSystem)）は永続的なファイル ID に対応していないため登録できません（exFAT・FAT32 の外部ボリューム等は非対応です）。"
            }
        default:
            return error.localizedDescription
        }
    }
}

/// 登録済みフォルダ 1 件（表示名・Security-Scoped Bookmark）と、解決済みの
/// `FolderTreeNode`（オフラインなら `nil` [SB-05]）のペア。
private struct RegisteredFolderEntry: Identifiable {
    let folder: RegisteredFolder
    let node: FolderTreeNode?
    var id: UUID { folder.id }
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
                .help("\(title)を登録")
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

/// [SB-05] ブックマーク解決に失敗した登録フォルダ（ボリューム未接続等）。
/// フェーズ1にはスキャン・DB が無いため「オフライン状態として保持」ではなく
/// 単純な表示のみだが、登録解除だけはここからもできるようにしている。
private struct OfflineRegisteredFolderRow: View {
    let displayName: String
    let onUnregister: () -> Void

    var body: some View {
        Label {
            Text(displayName)
        } icon: {
            Image(systemName: "questionmark.folder")
                .frame(width: 16, alignment: .center)
        }
        .opacity(0.4)
        .padding(.horizontal, Tokens.spacing.xs)
        .padding(.vertical, 2)
        .help("見つかりません（ボリュームが接続されていない可能性があります）")
        .contextMenu {
            Button("登録解除") { onUnregister() }
        }
    }
}

/// ツリーの 1 行。実フォルダの子を遅延読み込みする再帰 View。
private struct FolderTreeRow: View {
    let node: FolderTreeNode
    @Binding var expandedIDs: Set<String>
    let selectedURL: URL?
    let onSelect: (URL) -> Void
    let onDropFailure: @MainActor @Sendable (String) -> Void
    /// ライブラリ／テンポラリの**登録ルート行**のときだけ渡される
    /// [RG-05][RG-06]。再帰的に読み込まれる子孫フォルダの行では `nil` の
    /// ままにし、登録解除・表示名変更のメニューが実フォルダの深い階層に
    /// 誤って出ないようにする。
    var registeredFolder: RegisteredFolder?
    var onRename: (() -> Void)?
    var onUnregister: (() -> Void)?

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

    @ViewBuilder
    private var rowLabel: some View {
        Label {
            Text(node.displayName)
        } icon: {
            // Finder と同じアイコン [ユーザー要望]。シンボリックリンクは
            // `NSWorkspace` が対象種別のアイコンにエイリアスの矢印バッジを
            // 重ねて返すため、以前のような専用の代用アイコンは不要になった。
            Image(nsImage: FileIconProvider.shared.icon(for: node.url))
                .resizable()
                .frame(width: 16, height: 16)
        }
        .opacity(node.isOnline ? 1 : 0.4) // [LP-04]
            .fontWeight(isSelected ? .semibold : .regular)
            // 濃い青の背景に対して黒文字だとコントラストが低いため、
            // Finder と同じく選択中は白文字にする。
            .foregroundStyle(isSelected ? Color(nsColor: .alternateSelectedControlTextColor) : Color.primary)
            .padding(.horizontal, Tokens.spacing.xs)
            .padding(.vertical, 2)
            // 選択のハイライトは AppKit のシステム標準色を使う
            // [実機検証時のユーザー指摘: 独自の半透明アクセントカラーだと
            // Finder のような青にならない]。`Table`/`List` の
            // `selection:` バインディングと違いこのツリーはフォーカスの
            // 概念を持たないため（クリックで中央ペインと同期するだけの
            // 表示専用の選択）、常に強調表示（青）にする。
            .background(isDropTargeted ? Tokens.Colors.accent.opacity(0.35) : (isSelected ? Color(nsColor: .selectedContentBackgroundColor) : Color.clear))
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
            // 登録ルート行のときだけ右クリックメニューを付ける。空の
            // `.contextMenu` を全行に付けると、登録フォルダでない行を
            // 右クリックしたときに空のメニューが出てしまうため、
            // `registeredFolder` の有無で分岐して回避する。
            if registeredFolder != nil {
                rowLabel.contextMenu {
                    if let onRename {
                        Button("表示名を変更…") { onRename() } // [RG-05]
                    }
                    if let onUnregister {
                        Button("登録解除") { onUnregister() } // [RG-06 の簡易版]
                    }
                }
            } else {
                rowLabel
            }
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
