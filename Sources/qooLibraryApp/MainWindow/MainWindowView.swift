import QooInfrastructure
import QooKit
import SwiftUI

/// メインウインドウ。3 ペイン + タブ [MW-01][UI-02]。
///
/// `windowState` はこの View インスタンスに `@State` で束縛されており、
/// ウインドウ（`WindowGroup` が作る各シーン）ごとに独立して生成される。
/// 複数ウインドウを開いても互いのタブ・選択・表示モードは影響しない [ST-20][ST-21]。
struct MainWindowView: View {
    @State private var windowState: WindowState
    /// `⌘T` 新規タブ [KB-02 相当]。`FolderContentView` の他のショートカットと
    /// 同じく、可視要素を持たないボタンとして配線する。
    private let keyBindingStore: KeyBindingStore = UserDefaultsKeyBindingStore.shared
    /// コンテキストメニューの「新規ウインドウで開く」用 [`qooLibraryApp` の
    /// `WindowGroup(for: URL.self)` 参照]。
    @Environment(\.openWindow) private var openWindow
    /// 右ペインをたたむ（隠す）[実機検証時のユーザー要望]。`@AppStorage` には
    /// 意図的にしていない（`ThreePaneWindow.isRightPaneCollapsed` のコメント
    /// 参照、タブバーの表示/非表示で踏んだハング不具合と同じ危険なパターンを
    /// 避けるため）。再起動をまたいでは保持されないが、セッション中は保持される。
    @State private var isRightPaneCollapsed = false

    /// `initialFolder` は `WindowGroup(for: URL.self)` から渡される値。⌘N や
    /// Dock からの起動では `nil`（既定の仮想ホーム）、「新規ウインドウで開く」
    /// からは特定のフォルダになる。
    init(initialFolder: URL?) {
        _windowState = State(initialValue: initialFolder.map(WindowState.init(initialFolder:)) ?? WindowState())
    }

    var body: some View {
        VStack(spacing: 0) {
            // タブが2つ以上のときだけ自動表示する（Safari/Finder 流、ユーザー指摘）。
            // `@AppStorage` で「常に表示」に切り替えられるようにする案も試したが、
            // この `if` 条件の中で `@AppStorage` の値を読むと SwiftUI の
            // Observation が無限に再評価を繰り返しアプリがハングすることを
            // 実機検証で確認した（`windowState.tabs.count` 単独の条件に戻すと
            // 再現しない）。原因を安全に切り分けられる状況になかったため、
            // 「常に表示」トグルは見送り、この単純な条件のみにした
            // [フォローアップ: 原因調査、1-12 で改めて検討]。
            if windowState.tabs.count >= 2 {
                TabBarView(windowState: windowState)
                Divider()
            }
            ThreePaneWindow(id: "main", isRightPaneCollapsed: isRightPaneCollapsed) {
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
                        onNavigate: { windowState.navigateCurrentTab(to: $0) },
                        onGoBack: { windowState.goBack() },
                        onGoForward: { windowState.goForward() },
                        canGoBack: windowState.canGoBack,
                        canGoForward: windowState.canGoForward,
                        onOpenInNewTab: { windowState.openTab(for: $0) },
                        onOpenInNewWindow: { openWindow(value: $0) }
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
        .background {
            KeyBindingButtons(action: .newTab, store: keyBindingStore) {
                windowState.openDefaultTab()
            }
            .frame(width: 0, height: 0)
            .opacity(0)
        }
        .toolbar {
            ToolbarItem {
                Button {
                    isRightPaneCollapsed.toggle()
                } label: {
                    Image(systemName: "sidebar.trailing")
                }
                .help(isRightPaneCollapsed ? "詳細を表示" : "詳細を隠す")
            }
        }
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
