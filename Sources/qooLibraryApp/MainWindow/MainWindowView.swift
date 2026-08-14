import QooApplication
import QooInfrastructure
import QooKit
import SwiftUI

/// メインウインドウ。3 ペイン + タブ [MW-01][UI-02]。
///
/// `windowState` はこの View インスタンスに `@State` で束縛されており、
/// ウインドウ（`WindowGroup` が作る各シーン）ごとに独立して生成される。
/// 複数ウインドウを開いても互いのタブ・選択・表示モードは影響しない [ST-20][ST-21]。
///
/// **`ThreePaneWindow`（`PaneWindows.swift`、`HSplitView` ベース）ではなく
/// `NavigationSplitView` + `.inspector()` を使う** [設計判断、CP-01 の例外、
/// ユーザー要望]。他の3ペイン画面は引き続き `ThreePaneWindow` を使う想定
/// （CP-01 の原則自体は変えていない）が、メインウインドウだけは戻る/進む/
/// 上の階層へ等の実ウインドウツールバー項目を「サイドバーの分割線を追跡して
/// 中央（detail）ペインの左端に揃える」必要があり、これは AppKit の
/// `NSTrackingSeparatorToolbarItem` に対応する SwiftUI の
/// `NavigationSplitView`/`.inspector()` を使ったときにのみ自動的に得られる
/// （`ControlGroup`/`Capsule`+`.regularMaterial` による自前チャーム、単なる
/// `.toolbar` 全般では得られないことを実機検証で確認済み）。詳細は
/// `docs/Specifications/13_UI_共通基盤.md` CP-01 の注記、`docs/Specifications/14_UI_メインウインドウ.md`
/// 参照。
struct MainWindowView: View {
    /// `String(localized:)` 等 `Text` の `LocalizedStringKey` 解決を経由しない
    /// 箇所向け [1-12 ローカライズ方針、CLAUDE.md 参照]。
    @Environment(\.locale) private var locale
    @State private var windowState: WindowState
    /// `⌘T` 新規タブ [KB-02 相当]。`FolderContentView` の他のショートカットと
    /// 同じく、可視要素を持たないボタンとして配線する。
    private let keyBindingStore: KeyBindingStore = UserDefaultsKeyBindingStore.shared
    /// コンテキストメニューの「新規ウインドウで開く」用 [`qooLibraryApp` の
    /// `WindowGroup(for: URL.self)` 参照]。
    @Environment(\.openWindow) private var openWindow
    /// 右ペイン（インスペクタ）をたたむ（隠す）[実機検証時のユーザー要望]。
    /// `@AppStorage` には意図的にしていない（タブバーの表示/非表示を同様の
    /// `if` 条件の中で `@AppStorage` を直接読む形にした際、SwiftUI の
    /// Observation が無限に再評価を繰り返しアプリがハングする不具合を実機検証で
    /// 確認したのと同じ危険なパターンを避けるため）。その代わり、初期値だけ
    /// `init` で `UserDefaults` から**素の値として**読み込み（リアクティブな
    /// 購読ではない）、トグル時に明示的に書き戻す [実機検証時のユーザー要望:
    /// 新規ウインドウを既存ウインドウの表示状態に揃えたい／再起動をまたいでも
    /// 保持したい、の両方に対応]。
    @State private var isRightPaneCollapsed: Bool
    private static let isRightPaneCollapsedKey = "qoo.mainWindow.isRightPaneCollapsed"
    /// 新規フォルダ作成ダイアログの状態。ボタン自体はウインドウの実ツールバーに
    /// あるが、`.alert` 本体は `FolderContentView` 側（`folder`/`CommandStack` を
    /// 参照できる場所）に置いたままにしたいため、ここへ持ち上げてバインディング
    /// で橋渡ししている [ユーザー要望: 戻る/進む/上の階層へ・表示切替・新規
    /// フォルダ・右ペイン折りたたみをすべて実ツールバーへ統合]。
    @State private var showingNewFolderPrompt = false
    @State private var newFolderName = String(localized: "action.newFolder", locale: AppLanguage.effectiveLocale)
    /// サイドバー（左ペイン）・インスペクタ（右ペイン）の幅 [UI-02 相当]。
    /// `NavigationSplitView`/`.inspector()` は `ideal:` を初期表示幅として
    /// 素直に尊重してくれる（`HSplitView` の `.frame(idealWidth:)` は無視される
    /// ことを 1-9 で実機検証済み、`PaneWindows.swift` 参照）ため、`ideal:` に
    /// 永続化した値を渡すだけで済み、`ThreePaneWindow` が使っていた
    /// `NSSplitView.setPosition` の自前ブリッジは不要になった。キー文字列は
    /// 旧 `ThreePaneWindow` 時代と同じものを使い、既存の保存値を引き継ぐ。
    @AppStorage("qoo.threePane.main.leftWidth") private var leftWidth: Double = 220
    @AppStorage("qoo.threePane.main.rightWidth") private var rightWidth: Double = 280
    /// 2本指の横スワイプを戻る/進むとして使うか、通常の横スクロールとして
    /// 使うか [ユーザー要望: どちらか一方しか選べないトレードオフを、ユーザー
    /// 自身に選ばせる]。環境設定「一般」タブ（`GeneralPreferencesTab.swift`）
    /// で切り替える。`false` を選んだ場合は3本指スワイプ（OS 側で
    /// 「ページ間をスワイプ」を3本指に設定する必要がある）が戻る/進むの手段になる。
    @AppStorage("qoo.twoFingerSwipeForNavigation") private var twoFingerSwipeForNavigation = true
    /// 戻る/進むのスワイプ方向を入れ替える [1-12 環境設定「一般」タブ、
    /// ユーザー要望]。
    @AppStorage("qoo.backForwardSwipeDirectionInverted") private var swipeDirectionInverted = false

    /// `initialFolder` は `WindowGroup(for: URL.self)` から渡される値。⌘N や
    /// Dock からの起動では `nil`（既定の仮想ホーム）、「新規ウインドウで開く」
    /// からは特定のフォルダになる。
    ///
    /// `initialFolder == nil` の場合だけ「アプリ起動時に開くフォルダ」の環境
    /// 設定を適用する余地がある（`initialFolder` が明示的に指定されている
    /// 場合はそちらを優先する）。実際に適用するのは `hasAppliedStartupFolderThisLaunch`
    /// でさらに絞り込んだ、アプリ起動後最初の1本のウインドウだけ
    /// [`WindowFrameAutosaveView.hasRestoredPositionThisLaunch` と同じ
    /// パターン、⌘N で追加のウインドウを開くたびに起動時フォルダへ戻される
    /// のは望ましくないため]。
    private let wasLaunchedWithoutExplicitFolder: Bool
    nonisolated(unsafe) private static var hasAppliedStartupFolderThisLaunch = false

    init(initialFolder: URL?) {
        _windowState = State(initialValue: initialFolder.map(WindowState.init(initialFolder:)) ?? WindowState())
        _isRightPaneCollapsed = State(initialValue: UserDefaults.standard.bool(forKey: Self.isRightPaneCollapsedKey))
        wasLaunchedWithoutExplicitFolder = initialFolder == nil
    }

    /// これから「アプリ起動時に開くフォルダ」の `.task` がタブの `folder`/
    /// `navigationRoot` を書き換える見込みがあるかどうか。`.task` 内の適用
    /// ガード（`wasLaunchedWithoutExplicitFolder`/`hasAppliedStartupFolderThisLaunch`/
    /// `UserDefaults` の設定値）と全く同じ条件を、`.task` が実際に走る前に
    /// 同期的に判定できるようにしたもの [実機検証で発見したバグの修正、
    /// `FolderTreePane` の `skipsInitialAutoExpand` 引数のコメント参照]。
    private var hasPendingStartupFolderOverride: Bool {
        guard wasLaunchedWithoutExplicitFolder, !Self.hasAppliedStartupFolderThisLaunch else { return false }
        let kind = UserDefaults.standard.string(forKey: StartupFolderPreference.kindKey)
        return kind != nil && kind != StartupFolderKind.virtualHome.rawValue
    }

    /// ウインドウタイトル [ユーザー要望]。タブが無い/フォルダが無い場合のみ
    /// アプリ名にフォールバックする。
    private var currentFolderTitle: String {
        guard let index = windowState.currentTabIndex, let folder = windowState.tabs[index].folder else {
            return "qooLibrary"
        }
        return FileManager.default.displayName(atPath: folder.path)
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
            NavigationSplitView {
                VSplitView {
                    FolderTreePane(
                        selectedURL: windowState.currentTabIndex.flatMap { windowState.tabs[$0].folder },
                        navigationRoot: windowState.currentTabIndex.map { windowState.tabs[$0].navigationRoot } ?? .volume,
                        skipsInitialAutoExpand: hasPendingStartupFolderOverride,
                        onSelect: { url, root in windowState.navigateCurrentTab(to: url, root: root) }
                    )
                    PlaceholderPane(
                        title: String(localized: "mainWindow.labelFilter", locale: locale),
                        subtitle: String(localized: "mainWindow.implementedIn28", locale: locale)
                    )
                }
                .navigationSplitViewColumnWidth(min: 180, ideal: leftWidth, max: 400)
                .modifier(PaneWidthPersisting(storedWidth: $leftWidth))
            } detail: {
                Group {
                    if let index = windowState.currentTabIndex {
                        FolderContentView(
                            folder: windowState.tabs[index].folder,
                            currentFolder: { windowState.tabs[index].folder },
                            selection: Binding(
                                get: { windowState.tabs[index].selection },
                                set: { windowState.tabs[index].selection = $0 }
                            ),
                            pendingRevealURL: Binding(
                                get: { windowState.tabs[index].pendingRevealURL },
                                set: { windowState.tabs[index].pendingRevealURL = $0 }
                            ),
                            onNavigate: { windowState.navigateCurrentTab(to: $0) },
                            onGoBack: { windowState.goBack() },
                            onGoForward: { windowState.goForward() },
                            canGoBack: windowState.canGoBack,
                            canGoForward: windowState.canGoForward,
                            onGoToParent: { windowState.goToParent() },
                            canGoToParent: windowState.canGoToParent,
                            onOpenInNewTab: { windowState.openTab(for: $0) },
                            onOpenInNewWindow: { openWindow(value: $0) },
                            listStyle: $windowState.listStyle,
                            iconSize: $windowState.iconSize,
                            showingNewFolderPrompt: $showingNewFolderPrompt,
                            newFolderName: $newFolderName
                        )
                    } else {
                        PlaceholderPane(title: String(localized: "mainWindow.noTabs", locale: locale), subtitle: "")
                    }
                }
                .inspector(isPresented: Binding(
                    get: { !isRightPaneCollapsed },
                    set: { isPresented in
                        isRightPaneCollapsed = !isPresented
                        UserDefaults.standard.set(isRightPaneCollapsed, forKey: Self.isRightPaneCollapsedKey)
                    }
                )) {
                    InspectorPane(
                        folder: windowState.currentTabIndex.flatMap { windowState.tabs[$0].folder },
                        selection: windowState.currentTabIndex.map { windowState.tabs[$0].selection } ?? []
                    )
                    .inspectorColumnWidth(min: 220, ideal: rightWidth, max: 420)
                    .modifier(PaneWidthPersisting(storedWidth: $rightWidth))
                }
            }
            // ウインドウタイトルをカレントフォルダ名にする [ユーザー要望:
            // ツールバーの戻る/進む/上の階層への右に並ぶタイトルが常に
            // アプリ名「qooLibrary」のままだったのを、Finder と同じくカレント
            // フォルダ名にしたい]。Finder 準拠のローカライズされた表示名
            // （`PathBarView`/`FileIconProvider` と同じ設計判断）を使う。
            .navigationTitle(currentFolderTitle)
            // 戻る・進む・上の階層へを実ウインドウツールバーに置く [ユーザー要望]。
            // `NavigationSplitView` に直接付けることで、`.navigation` 配置の
            // 項目がサイドバーの分割線を追跡し、detail（中央）ペインの左端に
            // 揃う（`NSTrackingSeparatorToolbarItem` 相当、実機検証で確認）。
            .toolbar {
                // 戻る・進む・上の階層への3つを1つの `ToolbarItemGroup(placement: .navigation)`
                // にまとめている。`ControlGroup`（戻る/進むだけを丸皮でグループ化する案）を
                // 併用すると、実機検証で `ControlGroup` の中身だけが `.navigation`
                // （先頭側）ではなく末尾側に配置されてしまう現象を確認した（`Button`
                // 単体は正しく先頭に来ていたため、`ControlGroup` だけがグループの
                // `placement` を継承していないように見える）。`ControlGroup` をやめ、
                // 3つとも同じ `ToolbarItemGroup` 内の素の `Button` にすることで解消した
                // （なお macOS 側が `.navigation` 内の連続したボタン列を自動的に丸皮風の
                // 見た目にまとめてくれるため、視覚的なグループ化自体は失われていない）。
                ToolbarItemGroup(placement: .navigation) {
                    Button {
                        windowState.goBack()
                    } label: {
                        Image(systemName: "chevron.backward")
                    }
                    .disabled(!windowState.canGoBack)
                    .help("action.goBack")

                    Button {
                        windowState.goForward()
                    } label: {
                        Image(systemName: "chevron.forward")
                    }
                    .disabled(!windowState.canGoForward)
                    .help("action.goForward")

                    Button {
                        windowState.goToParent()
                    } label: {
                        Image(systemName: "arrow.up")
                    }
                    .disabled(!windowState.canGoToParent)
                    .help("action.goToParent")
                }
                // 表示切替（リスト/アイコン）・新規フォルダ [ユーザー要望:
                // 戻る/進むと同じ高さの実ツールバーに置く]。`.navigation` には
                // サイドバー側の分割線を追跡する専用の仕組みがあるが、それに
                // 対応する「インスペクタ側の分割線を追跡する」配置は存在しない
                // ようで、右ペイン（インスペクタ）を開くとこれらの項目もインスペクタ
                // 側の分割線を追跡してインスペクタの上に来てしまう（中央ペインの
                // 範囲外に出る）。既定配置（`.automatic`）・明示的な `.primaryAction`・
                // `.toolbar` の付け替え（`NavigationSplitView` 側/`.inspector` の
                // 中身側）のいずれを試しても同じ結果だった。Apple Developer
                // Forums でも同種の報告があり、macOS バージョンをまたいで挙動が
                // 変わる、SwiftUI 側の未整備な領域と判断した。中央ペインの範囲内に
                // 収めることより実ツールバーとしての見た目・高さを優先する
                // [ユーザー判断、既知のトレードオフとして受け入れ]。
                ToolbarItemGroup(placement: .primaryAction) {
                    Picker("common.view", selection: $windowState.listStyle) { // [TB-04][LV-04]
                        Image(systemName: "list.bullet").tag(ListStyle.list)
                        Image(systemName: "square.grid.2x2").tag(ListStyle.icon)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    Button {
                        newFolderName = String(localized: "action.newFolder", locale: locale)
                        showingNewFolderPrompt = true
                    } label: {
                        Image(systemName: "folder.badge.plus")
                    }
                    .help("mainWindow.createNewFolder") // [FM-01]
                }
                // 右ペイン（インスペクタ）の表示/非表示。常にツールバー末尾
                // （インスペクタが開いていればその上、閉じていればウインドウ右端）
                // に来る。**新規フォルダボタンと視覚的に別グループへ分離したい
                // という要望は、実機検証の結果、実現できなかった** [既知の限界]。
                // 試したがすべて失敗した方法:
                // 1. `ToolbarSpacer(.fixed, placement: .primaryAction)` を新規
                //    フォルダボタンとこのボタンの間に挟む。
                // 2. 同じく `ToolbarSpacer(.flexible, ...)`。
                // 3. このボタンの `placement` を `.secondaryAction` に変更
                //    → 分離はされたが、末尾ではなくツールバー中央（タイトル付近）
                //    という全く別の場所に移動してしまった。
                // 4. `Picker`＋新規フォルダ側を明示的な `ToolbarItemGroup` でまとめ、
                //    このボタンを独立した `ToolbarItem` にする。
                // 5. さらにこのボタン側も独立した `ToolbarItemGroup` にする
                //    （現在のコード、4と揃えただけで見た目は変わらない）。
                // いずれも、末尾の「新規フォルダ」ボタンとこのボタンという
                // **隣接する2つの単独アイコンボタン**は常に1つの角丸グループへ
                // 自動的に吸収されてしまい、分離できなかった。macOS 26 の新しい
                // ツールバー描画（Liquid Glass）側の挙動と考えられ、SwiftUI の
                // 公開 API では制御できないと判断した [既知の制限として記録]。
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        isRightPaneCollapsed.toggle()
                        UserDefaults.standard.set(isRightPaneCollapsed, forKey: Self.isRightPaneCollapsedKey)
                    } label: {
                        Image(systemName: "sidebar.trailing")
                    }
                    .help(isRightPaneCollapsed ? "mainWindow.showInspector" : "mainWindow.hideInspector")
                }
            }
        }
        .frame(minWidth: 900, minHeight: 560)
        .windowFrameAutosave("qoo.MainWindow") // [実機検証時のユーザー要望]
        // マウスのサイドボタン・トラックパッドのスワイプでの戻る/進む
        // [ユーザー要望、13章 §13.6「将来検討」に記録していたものを実装]。
        // ウインドウ直下（`MainWindowView`）に1回だけ適用する
        // [`BackForwardGestureSupport.swift` のコメント参照: タブごとに
        // 再生成されうる `FolderContentView` に付けるとジェスチャー途中で
        // モニタが再設置され、イベントストリームが途切れることを実機検証で
        // 確認した]。
        .backForwardGestureSupport(
            onGoBack: { windowState.goBack() },
            onGoForward: { windowState.goForward() },
            twoFingerSwipeForNavigation: twoFingerSwipeForNavigation,
            swipeDirectionInverted: swipeDirectionInverted
        )
        .background {
            Group {
                KeyBindingButtons(action: .newTab, store: keyBindingStore) {
                    windowState.openDefaultTab()
                }
                // [UD-02] Undo/Redo はウインドウ単位ではなくアプリ全体で単一の
                // `CommandStack.shared` を操作するため、特定のタブ/フォルダに
                // 依存せずここ（ウインドウ直下）に配線する。
                KeyBindingButtons(action: .undo, store: keyBindingStore, isDisabled: !CommandStack.shared.canUndo) {
                    Task {
                        await CommandStack.shared.undo()
                        // ファイル操作系の他の経路と同じく、Undo 後も一覧の再読み込みを
                        // 明示的に伝える必要がある [実機検証で発見: 忘れていたため
                        // Undo 自体は成功していても画面が古いままだった]。
                        SessionState.shared.reloadToken += 1
                    }
                }
                KeyBindingButtons(action: .redo, store: keyBindingStore, isDisabled: !CommandStack.shared.canRedo) {
                    Task {
                        await CommandStack.shared.redo()
                        SessionState.shared.reloadToken += 1
                    }
                }
            }
            .frame(width: 0, height: 0)
            .opacity(0)
        }
        // アプリ起動時に開くフォルダ [ユーザー要望、環境設定「一般」タブ]。
        // アプリ起動後、最初に開く（＝明示的なフォルダ指定を受けていない）
        // ウインドウにだけ適用する [`hasAppliedStartupFolderThisLaunch` の
        // コメント参照]。既定（仮想ホーム）のときは何もしない（不要な非同期
        // 処理・チラつきを避ける）。
        .task {
            guard wasLaunchedWithoutExplicitFolder, !Self.hasAppliedStartupFolderThisLaunch else { return }
            Self.hasAppliedStartupFolderThisLaunch = true
            guard UserDefaults.standard.string(forKey: StartupFolderPreference.kindKey) != nil,
                  UserDefaults.standard.string(forKey: StartupFolderPreference.kindKey) != StartupFolderKind.virtualHome.rawValue
            else { return }
            let (url, root) = await StartupFolderPreference.resolve()
            guard let index = windowState.currentTabIndex else { return }
            windowState.tabs[index].folder = url
            windowState.tabs[index].navigationRoot = root
            windowState.tabs[index].title = FileManager.default.displayName(atPath: url.path)
        }
    }
}

/// ペインの実測幅を `GeometryReader` で観測し `UserDefaults`（`@AppStorage`）へ
/// 書き戻す。`PaneWindows.swift` の `WidthPersistingModifier` と同じ役割・同じ
/// 実装だが、`NavigationSplitView`/`.inspector()` 用にこのファイル内へ複製して
/// いる（`ThreePaneWindow` 側の型は `private` で共有できないため）。書き込みの
/// みを担当し、初期表示への反映は `ideal:` パラメータ自体が行う（`HSplitView`
/// と違い `NavigationSplitView`/`.inspector()` は `ideal:` を実際に尊重するため、
/// `ThreePaneWindow` が必要としていた `NSSplitView.setPosition` の自前適用は
/// 不要）。
private struct PaneWidthPersisting: ViewModifier {
    @Binding var storedWidth: Double

    func body(content: Content) -> some View {
        content.background {
            GeometryReader { geometry in
                Color.clear
                    .onChange(of: geometry.size.width) { _, newValue in
                        if newValue > 0 {
                            storedWidth = newValue
                        }
                    }
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
