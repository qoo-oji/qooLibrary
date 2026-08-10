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
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) {
                            if entry.isDirectory { onNavigate(entry.url) }
                        }
                        .contextMenu {
                            Button("Finder で表示") { NSWorkspace.shared.activateFileViewerSelecting([entry.url]) } // [FM-09]
                            Button("パスをコピー") { copyPath(entry.url) } // [FM-10]
                            Divider()
                            Button("複製") { duplicate(entry) } // [FM-02]
                            Button("名前を変更…") { beginRename(entry) } // [FM-05]
                            Divider()
                            Button("ゴミ箱に入れる", role: .destructive) { moveToTrash(entry) } // [FM-04]
                        }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: folder) {
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

    private func copyPath(_ url: URL) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.path, forType: .string)
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
                reload()
            } catch {
                actionError = error.localizedDescription
            }
        }
    }

    private func duplicate(_ entry: FolderEntry) {
        guard let folder else { return }
        Task {
            do {
                _ = try await fileOps.copy([entry.url], to: folder, options: OpOptions(conflictPolicy: .keepBoth))
                reload()
            } catch {
                actionError = error.localizedDescription
            }
        }
    }

    private func moveToTrash(_ entry: FolderEntry) {
        Task {
            do {
                _ = try await fileOps.trash([entry.url])
                reload()
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
                reload()
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
