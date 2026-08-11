import SwiftUI

/// アプリ内タブバー。ネイティブ `NSWindow` のタブ機構には委ねず、タブごとの
/// `WindowState` をアプリ側で管理する [MW2-04 の設計判断]。
/// ドラッグでの並べ替え・別ウインドウへの移動（MW-03）は未実装 [フォローアップ]。
struct TabBarView: View {
    @Bindable var windowState: WindowState

    private static let barHeight: CGFloat = 30
    private static let addButtonWidth: CGFloat = 28
    private static let tabSpacing: CGFloat = 2
    private static let minTabWidth: CGFloat = 100

    var body: some View {
        // `GeometryReader` + 手計算の幅は実機検証で初回レイアウト時の
        // タイミング競合により表示が壊れる不具合を起こした
        // （タブバーが新規に挿入された直後、`geometry.size` が確定する前の
        // 値で `.frame(width:)` が適用され、黒塗りの崩れた表示になっていた）。
        // `.frame(maxWidth: .infinity)` を各タブに与えれば `HStack` が
        // 自然に均等分割してくれる（2つなら2分割、3つなら3分割
        // [ユーザー指摘]）ため、GeometryReader 自体が不要だと判明し撤去した。
        HStack(spacing: Self.tabSpacing) {
            ForEach(windowState.tabs) { tab in
                TabChip(
                    tab: tab,
                    isSelected: tab.id == windowState.selectedTabID,
                    canClose: windowState.tabs.count > 1,
                    onSelect: { windowState.selectedTabID = tab.id },
                    onClose: { windowState.closeTab(tab.id) },
                    onNewTab: { windowState.openDefaultTab() },
                    onCloseOthers: { windowState.closeOtherTabs(keeping: tab.id) }
                )
                .frame(minWidth: Self.minTabWidth, maxWidth: .infinity)
            }
            Button {
                windowState.openDefaultTab()
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .frame(width: Self.addButtonWidth)
            .help("新規タブ")
        }
        .frame(height: Self.barHeight)
        .padding(.horizontal, Tokens.spacing.s)
        .padding(.vertical, Tokens.spacing.xs)
        .background(Tokens.Colors.paneBackground)
    }
}

private struct TabChip: View {
    let tab: TabState
    let isSelected: Bool
    let canClose: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    let onNewTab: () -> Void
    let onCloseOthers: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: Tokens.spacing.xs) {
            // 閉じるボタンはタブの左端 [ユーザー指摘]。ホバー時のみ表示するが、
            // 表示/非表示でテキストの位置がずれないよう幅は常に確保し
            // 不透明度だけ切り替える。
            Group {
                if canClose {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 9))
                    }
                    .buttonStyle(.borderless)
                    .opacity(isHovering ? 1 : 0)
                }
            }
            .frame(width: 12)
            Text(tab.title)
                .font(.system(size: Tokens.fontSize.caption))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Tokens.spacing.s)
        .padding(.vertical, Tokens.spacing.xs)
        .background(isSelected ? Tokens.Colors.accent.opacity(0.18) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: Tokens.radius.s))
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("新規タブ") { onNewTab() }
            if canClose {
                Button("タブを閉じる") { onClose() }
                Button("他のタブを閉じる") { onCloseOthers() }
            }
        }
    }
}
