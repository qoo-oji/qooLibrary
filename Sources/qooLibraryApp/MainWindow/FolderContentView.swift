import SwiftUI

/// アクティブなタブのフォルダ内容を一覧表示する最小実装。
///
/// これは 1-9（リスト表示・アイコン表示・サムネイル）の本実装ではなく、
/// タブ切替・複数ウインドウが実際に「別々の実フォルダ」を表示できることを
/// 検証するための最小限の中身。選択・ソート・サムネイルは 1-9 で作る。
struct FolderContentView: View {
    let folder: URL?
    @Binding var selection: Set<URL>
    let onNavigate: (URL) -> Void

    @State private var entries: [FolderEntry] = []
    @State private var loadError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let folder {
                Text(folder.path)
                    .font(.system(size: Tokens.fontSize.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
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
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: folder) {
            reload()
        }
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
}

private struct FolderEntry: Identifiable {
    var id: URL { url }
    let url: URL
    let name: String
    let isDirectory: Bool
}
