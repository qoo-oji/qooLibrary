import AppKit
import QooInfrastructure
import SwiftUI

/// アクティブなタブのフォルダ内容を一覧表示する最小実装。
///
/// これは 1-9（リスト表示・アイコン表示・サムネイル）の本実装ではなく、
/// タブ切替・複数ウインドウが実際に「別々の実フォルダ」を表示できることを
/// 検証するための最小限の中身。選択・ソート・サムネイルは 1-9 で作る。
///
/// コンテキストメニュー（名前変更・複製・ゴミ箱・新規フォルダ）はすべて
/// `FileOperationService` 経由でのみファイルシステムを変更する [FO-01][FO-02]。
/// 「Finder で表示」「パスをコピー」はファイルを変更しないため対象外 [FM-09][FM-10]。
struct FolderContentView: View {
    let folder: URL?
    @Binding var selection: Set<URL>
    let onNavigate: (URL) -> Void

    @State private var entries: [FolderEntry] = []
    @State private var loadError: String?
    @State private var actionError: String?
    @State private var renamingEntry: FolderEntry?
    @State private var renameText = ""
    @State private var showingNewFolderPrompt = false
    @State private var newFolderName = "新規フォルダ"
    @State private var isDropTargeted = false
    @FocusState private var isListFocused: Bool
    /// Shift クリックでの範囲選択の起点 [LV-06 相当]。
    @State private var selectionAnchor: URL?
    /// 複数選択された行を一度にドラッグするための `dragContainer` 系 API のスコープ
    /// [DD-02][設計判断: macOS 26 で追加された API、詳細は `.draggable(containerItemID:)` の
    /// 呼び出し箇所のコメント参照]。
    @Namespace private var dragNamespace

    private let fileOps = FileOperationService.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let folder {
                HStack {
                    Text(folder.path)
                        .font(.system(size: Tokens.fontSize.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                    Spacer()
                    Button {
                        newFolderName = "新規フォルダ"
                        showingNewFolderPrompt = true
                    } label: {
                        Image(systemName: "folder.badge.plus")
                    }
                    .buttonStyle(.borderless)
                    .help("新規フォルダを作成") // [FM-01]
                }
                .padding(.horizontal, Tokens.spacing.m)
                .padding(.vertical, Tokens.spacing.xs)
            }

            if let loadError {
                PlaceholderPane(title: "読み込みエラー", subtitle: loadError)
            } else if entries.isEmpty {
                PlaceholderPane(title: "空のフォルダ", subtitle: "")
            } else {
                List(entries, selection: $selection) { entry in
                    Label(entry.name, systemImage: entry.isDirectory ? "folder" : "doc")
                        .font(.system(size: Tokens.fontSize.body))
                        .tag(entry.url)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) {
                            if entry.isDirectory { onNavigate(entry.url) }
                        }
                        .onTapGesture(count: 1) {
                            // D&D 系のモディファイアを付けた行は List 標準のクリック選択が
                            // ハイライト込みで効かなくなることがあるため、明示的に選択する
                            // （Cmd でトグル・Shift で範囲選択、という Finder 流の規則も
                            // ここで手動で再現する）。
                            let flags = NSEvent.modifierFlags
                            if flags.contains(.command) {
                                if selection.contains(entry.url) {
                                    selection.remove(entry.url)
                                } else {
                                    selection.insert(entry.url)
                                }
                                selectionAnchor = entry.url
                            } else if flags.contains(.shift),
                                      let anchor = selectionAnchor,
                                      let anchorIndex = entries.firstIndex(where: { $0.url == anchor }),
                                      let clickedIndex = entries.firstIndex(where: { $0.url == entry.url }) {
                                let range = anchorIndex < clickedIndex ? anchorIndex...clickedIndex : clickedIndex...anchorIndex
                                selection = Set(entries[range].map(\.url))
                            } else {
                                // 既に複数選択の一部になっている行は潰さない
                                // （そうしないと複数選択した状態でドラッグを開始しても単一行しか
                                // ドラッグに含まれなくなる）。
                                if !selection.contains(entry.url) {
                                    selection = [entry.url]
                                }
                                selectionAnchor = entry.url
                            }
                            // List 標準のクリック選択は副作用としてリストへフォーカスも移すが、
                            // 手動での選択にはその副作用が無いため、選択がグレー（非フォーカス）
                            // 表示のままになる。明示的にフォーカスさせて青色のハイライトにする。
                            isListFocused = true
                        }
                        .contextMenu {
                            // 右クリックした行が現在の複数選択に含まれる場合は選択全体を対象にする
                            // （Finder と同じ規則）。「名前を変更」だけはバッチ名変更 UI が無いため
                            // 右クリックした 1 件のみを対象にする。
                            let targets = targetURLs(for: entry)
                            Button("Finder で表示") { NSWorkspace.shared.activateFileViewerSelecting(targets) } // [FM-09]
                            Button("パスをコピー") { copyPaths(targets) } // [FM-10]
                            Divider()
                            Button("複製") { duplicate(targets) } // [FM-02]
                            Button("名前を変更…") { beginRename(entry) } // [FM-05]
                            Divider()
                            Button("ゴミ箱に入れる", role: .destructive) { moveToTrash(targets) } // [FM-04]
                        }
                        // [DD-02] アプリ外（Finder 等）への実ファイル参照エクスポート。
                        // 旧来の `.onDrag`/`.draggable(_:)` は macOS の `List` で複数選択を
                        // まとめてドラッグできない未解決の既知バグがある（Apple Feedback
                        // FB10128110）。実測でも複数選択中に `.onDrag` が実際にドラッグされた
                        // 1行分しか呼ばれないことを確認した。macOS 26 で追加された
                        // `draggable(containerItemID:)` + `dragContainer` +
                        // `dragContainerSelection`（このファイル末尾の `List` に付与）の
                        // 組み合わせで、選択中の行から始めたドラッグに選択全体が含まれる。
                        .draggable(containerItemID: entry.url, containerNamespace: dragNamespace)
                        .modifier(DropIntoFolderModifier(
                            entry: entry,
                            reload: { reloadAndBroadcast() },
                            onFailure: { actionError = $0 }
                        ))
                }
                .focused($isListFocused)
                // [DD-02][設計判断] `URL` は既に `Transferable`。ドラッグされた行の
                // `containerItemID`（＝ URL 自身）の配列がそのままペイロードになる。
                .dragContainer(for: URL.self, itemID: \.self, in: dragNamespace) { draggedItemIDs in
                    draggedItemIDs
                }
                .dragContainerSelection(Array(selection), containerNamespace: dragNamespace)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: Tokens.radius.s)
                    .strokeBorder(Tokens.Colors.accent, lineWidth: 2)
                    .padding(2)
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { items, _ in // [DD-03] Finder・他アプリからの取り込み
            guard let folder else { return false }
            DropHandling.performDrop(items, into: folder, onComplete: { reloadAndBroadcast() }, onFailure: { actionError = $0 })
            return true
        } isTargeted: { isDropTargeted = $0 }
        .task(id: folder) {
            reload()
        }
        // ウインドウ／ペインをまたいだ変更を拾う暫定策 [1-6 実機検証で発見した
        // クロスウインドウの表示不整合対策、`SessionState.reloadToken` 参照]。
        .onChange(of: SessionState.shared.reloadToken) {
            reload()
        }
        .alert("名前を変更", isPresented: renamingBinding) {
            TextField("名前", text: $renameText)
            Button("変更") { commitRename() }
            Button("キャンセル", role: .cancel) {}
        }
        .alert("新規フォルダ", isPresented: $showingNewFolderPrompt) {
            TextField("フォルダ名", text: $newFolderName)
            Button("作成") { createNewFolder() }
            Button("キャンセル", role: .cancel) {}
        }
        .alert("操作に失敗しました", isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
            Button("OK") {}
        } message: {
            Text(actionError ?? "")
        }
    }

    private var renamingBinding: Binding<Bool> {
        Binding(get: { renamingEntry != nil }, set: { if !$0 { renamingEntry = nil } })
    }

    private func reload() {
        guard let folder else {
            entries = []
            loadError = nil
            return
        }
        do {
            let urls = try FileManager.default.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
            entries = urls.map { url in
                let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                return FolderEntry(url: url, name: url.lastPathComponent, isDirectory: isDirectory)
            }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            loadError = nil
        } catch {
            entries = []
            loadError = error.localizedDescription
        }
    }

    /// 自分自身の再読み込みに加えて、他のウインドウ／ペインにも変更を知らせる
    /// [1-6 実機検証で発見: これが無いとウインドウをまたいだ D&D 等で表示が古いまま残る]。
    private func reloadAndBroadcast() {
        reload()
        SessionState.shared.reloadToken += 1
    }

    /// 右クリックした行が現在の複数選択に含まれていれば選択全体を、そうでなければ
    /// その 1 件のみを対象にする（Finder のコンテキストメニューと同じ規則）。
    private func targetURLs(for entry: FolderEntry) -> [URL] {
        guard selection.contains(entry.url) else { return [entry.url] }
        return entries.filter { selection.contains($0.url) }.map(\.url)
    }

    private func copyPaths(_ urls: [URL]) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
    }

    private func beginRename(_ entry: FolderEntry) {
        renamingEntry = entry
        renameText = entry.name
    }

    private func commitRename() {
        guard let entry = renamingEntry, !renameText.isEmpty else { return }
        Task {
            do {
                _ = try await fileOps.rename(entry.url, to: renameText)
                reloadAndBroadcast()
            } catch {
                actionError = error.localizedDescription
            }
        }
    }

    private func duplicate(_ urls: [URL]) {
        guard let folder else { return }
        Task {
            do {
                _ = try await fileOps.copy(urls, to: folder, options: OpOptions(conflictPolicy: .keepBoth))
                reloadAndBroadcast()
            } catch {
                actionError = error.localizedDescription
            }
        }
    }

    private func moveToTrash(_ urls: [URL]) {
        Task {
            do {
                _ = try await fileOps.trash(urls)
                reloadAndBroadcast()
            } catch {
                actionError = error.localizedDescription
            }
        }
    }

    private func createNewFolder() {
        guard let folder, !newFolderName.isEmpty else { return }
        Task {
            do {
                _ = try await fileOps.createDirectory(at: folder.appendingPathComponent(newFolderName))
                reloadAndBroadcast()
            } catch {
                actionError = error.localizedDescription
            }
        }
    }
}

private struct FolderEntry: Identifiable {
    var id: URL { url }
    let url: URL
    let name: String
    let isDirectory: Bool
}

/// フォルダ行にだけドロップ先を付与する（ファイル行に落としても意味がないため）[DD-05 相当]。
private struct DropIntoFolderModifier: ViewModifier {
    let entry: FolderEntry
    let reload: () -> Void
    let onFailure: @MainActor @Sendable (String) -> Void
    @State private var isTargeted = false

    func body(content: Content) -> some View {
        if entry.isDirectory {
            content
                .background(isTargeted ? Tokens.Colors.accent.opacity(0.15) : Color.clear)
                .dropDestination(for: URL.self) { items, _ in
                    DropHandling.performDrop(items, into: entry.url, onComplete: { reload() }, onFailure: onFailure)
                    return true
                } isTargeted: { isTargeted = $0 }
        } else {
            content
        }
    }
}
