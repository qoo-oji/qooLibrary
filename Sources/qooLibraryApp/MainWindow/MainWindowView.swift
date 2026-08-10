import SwiftUI

/// メインウインドウ。3 ペイン + タブ [MW-01][UI-02]。
///
/// `windowState` はこの View インスタンスに `@State` で束縛されており、
/// ウインドウ（`WindowGroup` が作る各シーン）ごとに独立して生成される。
/// 複数ウインドウを開いても互いのタブ・選択・表示モードは影響しない [ST-20][ST-21]。
struct MainWindowView: View {
    @State private var windowState = WindowState()

    var body: some View {
        VStack(spacing: 0) {
            TabBarView(windowState: windowState)
            Divider()
            ThreePaneWindow(id: "main") {
                VSplitView {
                    FolderTreePane(
                        selectedURL: windowState.currentTabIndex.flatMap { windowState.tabs[$0].folder },
                        onSelect: { windowState.navigateCurrentTab(to: $0) }
                    )
                    PlaceholderPane(title: "ラベルフィルタ", subtitle: "2-8 で実装")
                }
            } center: {
                if let index = windowState.currentTabIndex {
                    FolderContentView(
                        folder: windowState.tabs[index].folder,
                        selection: Binding(
                            get: { windowState.tabs[index].selection },
                            set: { windowState.tabs[index].selection = $0 }
                        ),
                        onNavigate: { windowState.navigateCurrentTab(to: $0) }
                    )
                } else {
                    PlaceholderPane(title: "タブがありません", subtitle: "")
                }
            } right: {
                // 1-10（詳細情報ペイン）の実装まで、1-2 の実機検証 UI を仮置きする。
                SandboxVerificationView()
            }
        }
        .frame(minWidth: 900, minHeight: 560)
    }
}

struct PlaceholderPane: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: Tokens.spacing.s) {
            Text(title)
                .font(.system(size: Tokens.fontSize.title1, weight: .semibold))
            if !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: Tokens.fontSize.body))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(Tokens.spacing.l)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
