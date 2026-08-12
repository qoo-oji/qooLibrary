import AppKit
import QooInfrastructure
import SwiftUI

/// アイコン表示 [IV-01/08/09、PF-10]。`Table`/`List` と違い選択・ドラッグ＆
/// ドロップ・コンテキストメニューまわりの AppKit 標準機能が一切無いため、
/// このファイルで手動再現する。
///
/// 具体的に失っているもの・妥協した点:
/// - `.contextMenu(forSelectionType:)`（`FolderContentView` の `Table` が使う、
///   選択されていない行を右クリックしたときに Finder 流の青い枠線を自動描画
///   してくれる AppKit 標準 API）は `List`/`Table` 専用で、`LazyVGrid` には
///   使えない。そのため各セルへ個別に `.contextMenu` を付ける旧来方式に戻して
///   おり、非選択項目を右クリックしたときの枠線表示は無い
///   [既知の制限、必要になれば手動の枠線描画を追加検討]。
/// - 選択・ダブルクリック・D&D は `FolderContentView` の `rowCell`/
///   `handleSingleClick` と同じロジックをセル単位で再現している
///   （`onSingleClick` クロージャで実際の選択処理自体は `FolderContentView`
///   に委譲し、二重実装を避けている）。
struct IconGridView<MenuContent: View>: View {
    let entries: [FolderEntry]
    @Binding var selection: Set<URL>
    let iconSize: Double
    let dragNamespace: Namespace.ID
    let onNavigate: (URL) -> Void
    let onSingleClick: (FolderEntry) -> Void
    let onReload: () -> Void
    let onDropFailure: (String) -> Void
    /// 空きスペースの右クリック（`urls` が空集合）も同じクロージャで扱う
    /// （`FolderContentView.contextMenuContent(for:)` が既に空集合の場合の
    /// 「新規フォルダ」「ペースト」を用意しているため、ここで別途持つ必要が無い）。
    @ViewBuilder let contextMenuContent: (Set<URL>) -> MenuContent

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: iconSize + 32), spacing: Tokens.spacing.m)]
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: Tokens.spacing.l) { // [PF-10] 可視範囲のみ描画
                ForEach(entries) { entry in
                    cell(for: entry)
                }
            }
            .padding(Tokens.spacing.m)
        }
        .contentShape(Rectangle())
        // 行の `.contextMenu` がヒットしない空きスペースでの右クリック用
        // （`Table` 側の `.contextMenu(forSelectionType:)` が空集合のときと
        // 同じ役割）。
        .contextMenu {
            contextMenuContent([])
        }
        // [DD-02][設計判断] `URL` は既に `Transferable`。ドラッグされたセルの
        // `containerItemID`（＝ URL 自身）の配列がそのままペイロードになる。
        .dragContainer(for: URL.self, itemID: \.self, in: dragNamespace) { draggedItemIDs in
            draggedItemIDs
        }
        .dragContainerSelection(Array(selection), containerNamespace: dragNamespace)
    }

    @ViewBuilder
    private func cell(for entry: FolderEntry) -> some View {
        VStack(spacing: Tokens.spacing.xs) {
            ThumbnailImage(entry: entry, size: iconSize)
            Text(entry.name)
                .font(.system(size: Tokens.fontSize.caption))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(height: Tokens.fontSize.caption * 2.4)
        }
        .padding(Tokens.spacing.xs)
        .frame(width: iconSize + 32)
        .background(selection.contains(entry.url) ? Tokens.Colors.accent.opacity(0.18) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: Tokens.radius.s))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            if entry.isDirectory { onNavigate(entry.url) }
        }
        // `FolderContentView.rowCell` と同じ理由で `.simultaneousGesture` に
        // している（単発クリックの選択発火をダブルクリック判定の待ち時間から
        // 外し、即座に反応させる）。
        .simultaneousGesture(TapGesture(count: 1).onEnded {
            onSingleClick(entry)
        })
        .contextMenu {
            contextMenuContent(targets(for: entry))
        }
        .draggable(containerItemID: entry.url, containerNamespace: dragNamespace)
        .modifier(DropIntoFolderModifier(entry: entry, reload: onReload, onFailure: onDropFailure))
    }

    /// 右クリックした項目が現在の選択に含まれていれば選択全体、そうでなければ
    /// その1件だけを対象にする（Finder と同じ規則。`Table` 側は AppKit が
    /// 自動でやってくれるが、`LazyVGrid` では自前で判定する）。
    private func targets(for entry: FolderEntry) -> Set<URL> {
        selection.contains(entry.url) ? selection : [entry.url]
    }
}

/// 1セル分のサムネイル。生成中はプレースホルダ [IV-08]。`ThumbnailService`
/// が非同期に解決し、`.task(id:)` によりセルが再利用されて対象の `entry` が
/// 変わったら（`LazyVGrid` のスクロール外へ流れて別の項目に再利用されたら）
/// 自動的に前のタスクをキャンセルして再取得する。
private struct ThumbnailImage: View {
    let entry: FolderEntry
    let size: Double

    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: placeholderSystemImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .foregroundStyle(.secondary)
                    .padding(size * 0.18)
            }
        }
        .frame(width: size, height: size)
        .task(id: entry.url) {
            image = nil
            // 最大ピクセルサイズは表示サイズの2倍（Retina 相当）を目安にする。
            guard let cgImage = await ThumbnailService.shared.thumbnail(for: entry.url, maxPixelSize: Int(size * 2)) else {
                return
            }
            image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        }
    }

    private var placeholderSystemImage: String {
        if entry.isDirectory { return "folder.fill" }
        if entry.archiveFormat != nil { return "doc.zipper" }
        return "doc.fill"
    }
}
