import AppKit
import SwiftUI

/// アプリ内タブバー。ネイティブ `NSWindow` のタブ機構には委ねず、タブごとの
/// `WindowState` をアプリ側で管理する [MW2-04 の設計判断]。
/// ドラッグでの並べ替え・別ウインドウへの移動（MW-03）は未実装 [フォローアップ]。
struct TabBarView: View {
    @Bindable var windowState: WindowState

    var body: some View {
        HStack(spacing: 2) {
            ForEach(windowState.tabs) { tab in
                TabChip(
                    tab: tab,
                    isSelected: tab.id == windowState.selectedTabID,
                    canClose: windowState.tabs.count > 1,
                    onSelect: { windowState.selectedTabID = tab.id },
                    onClose: { windowState.closeTab(tab.id) }
                )
            }
            Button {
                pickFolderAndOpenTab()
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, Tokens.spacing.xs)
            .help("新規タブ（フォルダを選択）")

            Spacer()
        }
        .padding(.horizontal, Tokens.spacing.s)
        .padding(.vertical, Tokens.spacing.xs)
        .background(Tokens.Colors.paneBackground)
    }

    private func pickFolderAndOpenTab() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "このフォルダをタブで開く"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        windowState.openTab(for: url)
    }
}

private struct TabChip: View {
    let tab: TabState
    let isSelected: Bool
    let canClose: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: Tokens.spacing.xs) {
            Text(tab.title)
                .font(.system(size: Tokens.fontSize.caption))
                .lineLimit(1)
            if canClose {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9))
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, Tokens.spacing.s)
        .padding(.vertical, Tokens.spacing.xs)
        .background(isSelected ? Tokens.Colors.accent.opacity(0.18) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: Tokens.radius.s))
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
    }
}
