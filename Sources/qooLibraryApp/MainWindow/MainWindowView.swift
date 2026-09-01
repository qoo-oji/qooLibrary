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
    /// Quick Look [QL-01]。`QLPreviewPanel` はアプリ全体で共有だが「何を
    /// プレビューするか」はウインドウごとに違うため、このウインドウの
    /// `windowState` と 1 対 1 で生成する（`QuickLookController` のコメント参照）。
    @State private var quickLook: QuickLookController
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
    /// パスバー・ステータスバーの表示 [1-16 表示メニュー]。**`isRightPaneCollapsed`
    /// と全く同じ扱いにしている** — `init` で `UserDefaults` から素の値として
    /// 一度だけ読み（リアクティブな購読ではない）、切り替え時に明示的に書き戻す。
    /// `@AppStorage` にしてビュー構造を決める `if` 条件で読むと SwiftUI の
    /// Observation が無限に再評価してハングする既知の不具合があるため
    /// （CLAUDE.md「タブバー表示トグル」参照）、そのパターンを踏まない。
    @State private var isPathBarVisible: Bool
    /// File メニューの「取り出す」の判定の控え [NV6-02]。詳細は
    /// `EjectMenuState` のコメント参照。
    @State private var ejectState = EjectMenuState()
    @State private var isStatusBarVisible: Bool
    private static let isPathBarVisibleKey = "qoo.mainWindow.isPathBarVisible"
    private static let isStatusBarVisibleKey = "qoo.mainWindow.isStatusBarVisible"
    /// サイドバー（左ペイン）の表示 [1-16 表示メニュー、Finder の ⌃⌘S 相当]。
    /// `NavigationSplitView` 自身が持つ表示状態なので、こちらは永続化せず
    /// `@State` のみ（ウインドウを開き直せば既定に戻る）。
    @State private var sidebarVisibility: NavigationSplitViewVisibility = .all
    /// ツールバーの「新規フォルダ」ボタンから中央ペインへ送る合図
    /// [ユーザー要望: 戻る/進む/上の階層へ・表示切替・新規フォルダ・右ペイン
    /// 折りたたみをすべて実ツールバーへ統合]。
    ///
    /// ダイアログ自体は、対象フォルダと作成後の再読み込みを知っている
    /// `FolderContentView` が出す [`NameInputDialog`]。**増分するだけの合図**に
    /// しているのは、`SessionState.reloadToken` と同じ理由 — 真偽値を上げ下げ
    /// する形にすると「まだ下げていない」状態が残って次の要求が落ちる。
    @State private var newFolderRequests = 0
    /// サイドバー（左ペイン）・インスペクタ（右ペイン）の幅 [UI-02 相当]。
    /// `NavigationSplitView`/`.inspector()` は `ideal:` を初期表示幅として
    /// 素直に尊重してくれる（`HSplitView` の `.frame(idealWidth:)` は無視される
    /// ことを 1-9 で実機検証済み、`PaneWindows.swift` 参照）ため、`ideal:` に
    /// 永続化した値を渡すだけで済み、`ThreePaneWindow` が使っていた
    /// `NSSplitView.setPosition` の自前ブリッジは不要になった。キー文字列は
    /// 旧 `ThreePaneWindow` 時代と同じものを使い、既存の保存値を引き継ぐ。
    @AppStorage("qoo.threePane.main.leftWidth") private var leftWidth: Double = 220
    @AppStorage("qoo.threePane.main.rightWidth") private var rightWidth: Double = 280
    /// 左サイドバーの中の上下分割（フォルダツリー／ラベルフィルタ）の位置
    /// ［ユーザー要望: ドラッグで変えても再起動すると忘れてしまう］。
    /// 覚えるのは**上側（フォルダツリー）の高さ**。
    @AppStorage("qoo.mainWindow.folderTreeHeight") private var folderTreeHeight: Double = 420
    /// 2本指の横スワイプを戻る/進むとして使うか、通常の横スクロールとして
    /// 使うか [ユーザー要望: どちらか一方しか選べないトレードオフを、ユーザー
    /// 自身に選ばせる]。環境設定「一般」タブ（`GeneralPreferencesTab.swift`）
    /// で切り替える。`false` を選んだ場合は3本指スワイプ（OS 側で
    /// 「ページ間をスワイプ」を3本指に設定する必要がある）が戻る/進むの手段になる。
    @AppStorage("qoo.twoFingerSwipeForNavigation") private var twoFingerSwipeForNavigation = true
    /// 戻る/進むのスワイプ方向を入れ替える [1-12 環境設定「一般」タブ、
    /// ユーザー要望]。
    @AppStorage("qoo.backForwardSwipeDirectionInverted") private var swipeDirectionInverted = false

    /// `target` は `WindowGroup(for: TabTarget.self)` から渡される値。⌘N や
    /// Dock からの起動では `nil`（既定の仮想ホーム）、「新規タブ／ウインドウで
    /// 開く」からは特定のフォルダと入口（`NavigationRoot`）になる
    /// [ネイティブタブ移行で `URL` から `TabTarget` へ拡張した]。
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

    init(target: TabTarget?) {
        let state = WindowState(target: target ?? .home)
        _windowState = State(initialValue: state)
        _quickLook = State(initialValue: QuickLookController(windowState: state))
        _isRightPaneCollapsed = State(initialValue: UserDefaults.standard.bool(forKey: Self.isRightPaneCollapsedKey))
        // パスバー・ステータスバーはどちらも既定で表示する。`bool(forKey:)` は
        // 未設定のとき `false` を返してしまうため、`object(forKey:)` で
        // 「設定されているか」を先に見る（`isRightPaneCollapsed` は既定 `false`
        // ＝表示なのでこの区別が要らなかった）。
        _isPathBarVisible = State(initialValue: Self.storedFlag(Self.isPathBarVisibleKey, default: true))
        _isStatusBarVisible = State(initialValue: Self.storedFlag(Self.isStatusBarVisibleKey, default: true))
        wasLaunchedWithoutExplicitFolder = target == nil
    }

    private static func storedFlag(_ key: String, default defaultValue: Bool) -> Bool {
        guard UserDefaults.standard.object(forKey: key) != nil else { return defaultValue }
        return UserDefaults.standard.bool(forKey: key)
    }

    /// 「アプリ起動時に開くフォルダ」の解決が終わったか。
    ///
    /// **フォルダツリーの自動展開はこれが `true` になるまで待つ。** 待たないと、
    /// 解決前の暫定の行き先（`TabTarget.home`）に対して一度展開が走り、
    /// `expandedNodeIDs` は減らないのでその展開が残り続ける
    /// ——ユーザー報告「テンポラリフォルダを指定しているのに、起動すると
    /// ボリュームの Macintosh HD がホームフォルダまで展開される」がこれ。
    ///
    /// 以前は「上書きの見込みがあるか」を `UserDefaults` から**事前に**
    /// 推測していたが、`.home` を除外していたため、
    /// **起動時フォルダを「ホーム」にすると仮想ホーム（`Data`）が開いていた**
    /// [実機検証で発見]。`TabTarget.home` は `WindowState.init` で評価され、
    /// その時点では `VolumeAccessStore.loadAndActivateAll()` がまだ終わって
    /// いないので `defaultHome` が「実ホームを読めない」と判断してしまう。
    /// **解決を必ず通す**ようにして直した（`StartupFolderPreference.resolve()`
    /// は許可の有効化を待ってから判定する）。
    @State private var startupFolderResolved = false

    /// ウインドウタイトル [ユーザー要望]。タブが無い/フォルダが無い場合のみ
    /// アプリ名にフォールバックする。
    ///
    /// `displayName(atPath:)` を直接呼ばない [NV6-02] — ここは `body` から
    /// 評価されるため、応答しない共有で描画のたびにメインスレッドが止まる
    /// （`DisplayNameCache` のコメント参照）。
    private var currentFolderTitle: String {
        guard let folder = windowState.folder else { return "qooLibrary" }
        return DisplayNameCache.shared.name(for: folder)
    }

    /// 「移動」メニューへ公開するナビゲーション操作 [1-16]。
    /// [TB-01] フォルダ表示モード／ライブラリ表示モードのシーソー。
    /// **ライブラリを開いているときだけ有効**——ボリューム・テンポラリでは
    /// `managedFile` の行が無く、空の一覧しか出せない。無効時はツールチップで
    /// 理由を示す [MX-04]。**必ず `setDisplayMode` を通す**——ライブラリ →
    /// フォルダの切替では、選んでいた本のフォルダへ移動する必要がある
    /// [VM-20〜VM-23]。素の束縛にすると素通りする。
    private var displayModeSeesaw: some View {
        Picker("mainWindow.displayMode", selection: Binding(
            get: { windowState.displayMode },
            set: { windowState.setDisplayMode($0) }
        )) {
            Image(systemName: "folder").tag(DisplayMode.folder)
            Image(systemName: "books.vertical").tag(DisplayMode.library)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .disabled(!windowState.canUseLibraryDisplayMode)
        .help(windowState.canUseLibraryDisplayMode
              ? "mainWindow.displayModeHelp"
              : "mainWindow.displayModeUnavailable")
    }

    private var currentWindowMenuActions: WindowMenuActions {
        WindowMenuActions(
            currentLibrary: windowState.currentLibrary,
            canSaveShelf: windowState.displayMode == .library
                && windowState.currentShelfCondition?.isActive == true,
            saveShelf: { presentSaveShelfDialog() },
            canGoBack: windowState.canGoBack,
            canGoForward: windowState.canGoForward,
            canGoToParent: windowState.canGoToParent,
            goBack: { windowState.goBack() },
            goForward: { windowState.goForward() },
            goToParent: { windowState.goToParent() },
            goToParentInNewWindow: {
                guard let target = windowState.parentTarget else { return }
                openAsWindow(target)
            },
            // Finder の ⌥⌘↑ は「上の階層を新規ウインドウで開き、現在のウインドウ
            // を閉じる」[nib のセレクタと実挙動で確認]。**閉じる対象は開く前に
            // 掴んでおく** — `openWindow` の後では `NSApp.keyWindow` が新しい
            // ウインドウを指す。実際に閉じるのは 1 サイクル遅らせる（新しい
            // ウインドウが出る前に閉じると、最後の 1 枚だった場合に一瞬
            // ウインドウが 0 枚になる）。
            goToParentAndCloseWindow: {
                guard let target = windowState.parentTarget else { return }
                let current = NSApp.keyWindow
                openAsWindow(target)
                DispatchQueue.main.async { current?.close() }
            },
            goToStandardLocation: { location in
                StandardLocationOpener.open(location, locale: locale) { url in
                    // 入口は場所ごとに決まる [`StandardLocation.navigationRoot`]。
                    // ホームグループに並ぶ場所（ホーム・書類・ダウンロード…）は
                    // `.home` になり、メニューから行ってもツリーのホームグループ
                    // 側がフォーカスされる——**同じ場所へ行く経路が複数あっても、
                    // 行き先の見え方は 1 つに揃える。**
                    windowState.navigate(to: url, root: location.navigationRoot)
                }
            },
            beginGoToFolder: { presentGoToFolderDialog() },
            navigate: { url, root in windowState.navigate(to: url, root: root) },
            // ファイルメニュー [1-16 メニュー抜け監査]。どちらも ⌘T/⌘F として
            // 配線済みだったがメニューバーからは辿れなかった。実体は下の
            // `keyBindingButtons` と同じものを呼ぶ。
            newTab: { openAsTab(.home) },
            focusSearch: { expandSearchField() },
            // 表示メニュー [1-16]。
            listStyle: windowState.listStyle,
            setListStyle: { windowState.listStyle = $0 },
            canIncreaseIconSize: windowState.listStyle == .icon && windowState.iconSize < Tokens.iconSize.max,
            canDecreaseIconSize: windowState.listStyle == .icon && windowState.iconSize > Tokens.iconSize.min,
            increaseIconSize: { adjustIconSize(by: Tokens.iconSize.step) },
            decreaseIconSize: { adjustIconSize(by: -Tokens.iconSize.step) },
            isSidebarVisible: sidebarVisibility != .detailOnly,
            isInspectorVisible: !isRightPaneCollapsed,
            isPathBarVisible: isPathBarVisible,
            isStatusBarVisible: isStatusBarVisible,
            toggleSidebar: { sidebarVisibility = sidebarVisibility == .detailOnly ? .all : .detailOnly },
            toggleInspector: { setRightPaneCollapsed(!isRightPaneCollapsed) },
            togglePathBar: {
                isPathBarVisible.toggle()
                UserDefaults.standard.set(isPathBarVisible, forKey: Self.isPathBarVisibleKey)
            },
            toggleStatusBar: {
                isStatusBarVisible.toggle()
                UserDefaults.standard.set(isStatusBarVisible, forKey: Self.isStatusBarVisibleKey)
            },
            // 取り出す [1-16]。Finder と同じく「今表示しているものが乗っている
            // ボリューム」が対象。
            canEject: ejectState.target != nil,
            isEjectTargetNetworkVolume: ejectState.targetIsNetwork,
            canEjectAll: ejectState.hasAny,
            eject: {
                guard let volume = ejectState.target else { return }
                Task { await VolumeEjectAction.eject(volume) }
            },
            ejectAll: { Task { await VolumeEjectAction.ejectAll() } }
        )
    }

    /// メニューバーからのシェルフ保存 [SH-01]。実装は左ペインの「＋」と共有
    /// （`ShelfDialogs`）。
    private func presentSaveShelfDialog() {
        guard let library = windowState.currentLibrary,
              let condition = windowState.currentShelfCondition else { return }
        ShelfDialogs.presentSave(libraryID: library.id, condition: condition,
                                 services: LibraryServices.shared, locale: locale)
    }

    /// File メニューの「取り出す」に必要な判定の控え。
    ///
    /// **毎回その場で調べてはいけない** [NV6-02]。`currentWindowMenuActions` は
    /// `body` が評価されるたびに組み立てられるので、そこでボリュームを列挙して
    /// `resourceValues` を読むと、**アイコンサイズのスライダーを動かしている間
    /// ずっとマウント中の全ボリュームへ問い合わせる**ことになる。ネットワーク
    /// 共有が 1 つ混じっていればそのたびに往復が走る。
    struct EjectMenuState: Equatable {
        var target: URL?
        var targetIsNetwork = false
        var hasAny = false
    }

    /// 現在地とマウント状態が変わったときだけ調べ直す。
    private func refreshEjectState() async {
        let folder = windowState.folder
        ejectState = await FileIO.perform {
            let target = VolumeEjectAction.ejectableVolume(containing: folder)
            return EjectMenuState(
                target: target,
                targetIsNetwork: target.map { VolumeEjector.isNetworkVolume($0) } ?? false,
                hasAny: !VolumeEjector.ejectableVolumes().isEmpty
            )
        }
    }

    /// アイコンサイズを 1 段階動かす [IV-04]。中央ペインのスライダーと同じ
    /// 範囲・刻みに収める。
    private func adjustIconSize(by delta: Double) {
        windowState.iconSize = min(max(windowState.iconSize + delta, Tokens.iconSize.min), Tokens.iconSize.max)
    }

    /// 右ペインの表示状態を変える唯一の経路（ツールバーのボタン・`.inspector` の
    /// バインディング・表示メニューがいずれもここを通る）。永続化の書き戻しを
    /// 1 箇所に集約するため。
    private func setRightPaneCollapsed(_ collapsed: Bool) {
        isRightPaneCollapsed = collapsed
        UserDefaults.standard.set(collapsed, forKey: Self.isRightPaneCollapsedKey)
    }

    /// 新しいタブとして開く [ネイティブタブ移行]。`WindowTabJoiner` に合流先を
    /// 予約してから `openWindow` するのが要点——予約が無いと macOS の設定次第で
    /// 別ウインドウとして開いてしまう（`WindowTabJoiner` のコメント参照）。
    private func openAsTab(_ target: TabTarget) {
        WindowTabJoiner.shared.prepareToOpenAsTab(from: NSApp.keyWindow)
        openWindow(value: target)
    }

    /// 独立した新規ウインドウとして開く。直前のタブ操作の予約が残っていても
    /// 巻き込まれないよう、明示的に予約を捨ててから開く。
    private func openAsWindow(_ target: TabTarget) {
        WindowTabJoiner.shared.prepareToOpenAsWindow()
        openWindow(value: target)
    }

    /// 「フォルダへ移動…」（⇧⌘G）[1-16 移動メニュー]。Finder の `GotoWindow` と
    /// 同じく独立したウインドウとして出す（`DialogWindowPresenter` 参照）。
    private func presentGoToFolderDialog() {
        DialogWindowPresenter.shared.present(
            title: String(localized: "goToFolder.title", locale: locale)
        ) { _ in
            GoToFolderDialog { url in
                // 入口は「ボリューム」扱いにする — 入力されたパスが結果的に
                // 登録フォルダの中を指していても、ユーザーはツリーの登録
                // フォルダ行から入ったわけではないため [`NavigationRoot` の
                // 「URL から逆算しない」方針に従う]。
                windowState.navigate(to: url, root: .volume)
            }
        }
    }


    /// 検索フィールドを開いているか [ユーザー要望: Finder と同じく、普段は
    /// 虫めがねボタンで、クリックすると検索欄になる]。
    ///
    /// **SwiftUI の `.searchable` は使えない** [SDK を直接確認]。macOS 26 で
    /// 追加された `searchToolbarBehavior(.minimize)`（まさにこの「普段はボタン」
    /// の挙動）は `SearchToolbarBehavior.minimize` が
    /// `@available(macOS, unavailable)` で **iOS/visionOS 専用**。加えて
    /// `.searchable` が挿し込むツールバー項目は位置を選べず、「表示切替の左」
    /// という配置指定も満たせない。そのため自前のコントロールにしている。
    @State private var isSearchFieldExpanded = false

    /// 虫めがねボタン ⇄ 検索欄。
    ///
    /// 開閉の規則は Finder に合わせる:
    /// - ボタンを押す / ⌘F → 開いてフォーカス
    /// - Esc → 内容を消して閉じる
    /// - フォーカスを失ったとき、**入力が空なら**閉じる（入力が残っていれば
    ///   開いたまま——絞り込みが効いていることが見えなくなるため）
    @ViewBuilder
    private var searchControl: some View {
        if isSearchFieldExpanded {
            ToolbarSearchField(
                text: $windowState.searchText,
                placeholder: String(localized: "folder.searchPrompt", locale: locale),
                onCancel: { collapseSearchField(clearingText: true) },
                onEndEditingWhileEmpty: { collapseSearchField(clearingText: false) }
            )
            .frame(width: 180)
        } else {
            Button { expandSearchField() } label: {
                Image(systemName: "magnifyingglass")
            }
            // ツールチップもプレースホルダと同じ「検索」でよい [ユーザー判断]。
            .help("folder.searchPrompt")
        }
    }

    /// 開くだけ。フォーカスは `ToolbarSearchField` 自身が生成時に取る。
    private func expandSearchField() {
        isSearchFieldExpanded = true
    }

    private func collapseSearchField(clearingText: Bool) {
        if clearingText { windowState.searchText = "" }
        isSearchFieldExpanded = false
    }

    /// ウインドウのツールバー。**`body` から切り出している** — 独自タブバーを
    /// 外して `body` の構造が変わった際に「型検査に時間がかかりすぎる」という
    /// コンパイルエラーになったため（`FolderContentView.bottomBars` と同じ理由。
    /// SwiftUI のビルダーは 1 つの式が大きくなるほど推論が急激に重くなる）。
    @ToolbarContentBuilder
    private var mainToolbar: some ToolbarContent {
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
                    // シーソー [TB-01] はサイドバー側のツールバーへ移した
                    // [ユーザー要望]。ここには置かない（同じ操作を 2 か所に
                    // 出さない）。

                    // 検索 [1-16]。**表示切替の左**に置く [ユーザー要望]。
                    searchControl

                    Picker("common.view", selection: $windowState.listStyle) { // [TB-04][LV-04]
                        Image(systemName: "list.bullet").tag(ListStyle.list)
                        Image(systemName: "square.grid.2x2").tag(ListStyle.icon)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    Button {
                        newFolderRequests += 1
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
                        setRightPaneCollapsed(!isRightPaneCollapsed)
                    } label: {
                        Image(systemName: "sidebar.trailing")
                    }
                    .help(isRightPaneCollapsed ? "mainWindow.showInspector" : "mainWindow.hideInspector")
                }
    }


    /// 中央ペイン＋インスペクタ。`mainToolbar` と同じ理由で `body` から
    /// 切り出している（型検査の負荷を分割するため）。
    @ViewBuilder
    private var detailPane: some View {
                Group {
                    FolderContentView(
                            folder: windowState.folder,
                            currentFolder: { windowState.folder },
                            // [VM-02] ラベルフィルタで残す子の名前。左ペインを
                            // 畳んでいても効く（駆動しているのは `.task`）。
                            allowedChildNames: windowState.labelFilter.allowedChildNames,
                            // [LF-14] 検索結果は名前では絞れないので、1 件ずつ
                            // DB へ問い合わせる経路を渡す。
                            filterDeepResults: { urls in
                                guard case .registeredFolder(_, let rootURL)
                                        = windowState.navigationRoot else { return nil }
                                return await windowState.labelFilter.deepMatches(
                                    urls,
                                    libraryRootPath: rootURL.standardizedFileURL.path,
                                    services: LibraryServices.shared)
                            },
                            labelFilterRevision: windowState.labelFilter.revision,
                            selection: $windowState.selection,
                            pendingRevealURL: $windowState.pendingRevealURL,
                            navigationCameFromTree: windowState.navigationCameFromTree,
                            onNavigate: { windowState.navigate(to: $0) },
                            onGoBack: { windowState.goBack() },
                            onGoForward: { windowState.goForward() },
                            canGoBack: windowState.canGoBack,
                            canGoForward: windowState.canGoForward,
                            onGoToParent: { windowState.goToParent() },
                            canGoToParent: windowState.canGoToParent,
                            relocateIfFolderVanished: { await windowState.relocateIfFolderVanished() },
                            // 現在のタブの `NavigationRoot` を新しいタブへ
                            // 引き継ぐ [フェーズ1完了前監査で記録した
                            // 「登録フォルダ配下のサブフォルダを新規タブで
                            // 開くと `.volume` に戻る」抜け穴の修正]。
                            onOpenInNewTab: { openAsTab(windowState.target(for: $0)) },
                            onOpenInNewWindow: { openAsWindow(windowState.target(for: $0)) },
                            quickLook: quickLook,
                            listStyle: $windowState.listStyle,
                            iconSize: $windowState.iconSize,
                            newFolderRequests: $newFolderRequests,
                            isPathBarVisible: isPathBarVisible,
                            isStatusBarVisible: isStatusBarVisible,
                            thumbnailHiddenReason: windowState.thumbnailHiddenReason, // [DS-01][DS-07]
                            onToggleThumbnails: { ThumbnailVisibility.shared.toggleGlobal() },
                            searchText: $windowState.searchText,
                            // [TB-01][VM-10〜VM-16] ライブラリ表示モード。
                            displayMode: windowState.displayMode,
                            // [IF-17][IF-18] フォルダ表示モードでのブックフォルダ。
                            bookFolderNames: windowState.bookFolders.names,
                            opensBookFolderWithApp: windowState.bookFolders.opensWithApp,
                            libraryContent: windowState.libraryContent,
                            library: windowState.currentLibrary,   // [FA-01][LF-01]
                            labelMenu: windowState.labelMenu,      // [RL3-01〜RL3-03]
                            unresolvedRescue: windowState.unresolvedRescue, // [UR3-03]
                            onExitUnresolvedView: { windowState.toggleUnresolvedFiles() },
                            onSetUnresolvedIncludesIgnored: {
                                windowState.setUnresolvedIncludesIgnored($0)
                            },
                            onLoadMoreLibraryRows: {
                                guard let library = windowState.currentLibrary else { return }
                                Task {
                                    await windowState.libraryContent.loadNextPage(
                                        library: library, services: LibraryServices.shared)
                                }
                            },
                            loadLibraryRows: { sort in
                                windowState.libraryContent.setSort(sort)
                                // モードがフォルダ側なら `library: nil` になり、
                                // モデルは一覧を捨てて `.inactive` へ戻る。
                                await windowState.libraryContent.load(
                                    library: windowState.displayMode == .library
                                        ? windowState.currentLibrary : nil,
                                    relativePath: windowState.libraryRelativePath,
                                    labelSelection: windowState.labelFilter.selection,
                                    ratingFilter: windowState.labelFilter.ratingFilter,
                                    searchText: windowState.searchText,
                                    services: LibraryServices.shared)
                            },
                            onLibrarySortChanged: { windowState.currentLibrarySort = $0 },
                            pendingLibrarySort: $windowState.pendingLibrarySort
                        )
                }
                .inspector(isPresented: Binding(
                    get: { !isRightPaneCollapsed },
                    set: { setRightPaneCollapsed(!$0) }
                )) {
                    InspectorPane(
                        folder: windowState.folder,
                        selection: windowState.selection,
                        thumbnailsHidden: windowState.areThumbnailsHidden, // [DS-06][CV2-01]
                        // ラベルフィルタと同じ解決経路 [RA-01][LF-01]。
                        // 入口が登録フォルダのときだけライブラリが決まる。
                        library: windowState.navigationRoot.registrationUUID
                            .flatMap { LibraryServices.shared.library(registrationUUID: $0) }
                    )
                    .inspectorColumnWidth(min: 220, ideal: rightWidth, max: 420)
                    .modifier(PaneWidthPersisting(storedWidth: $rightWidth))
                }
    }


    /// ブックフォルダの一覧を読み直す条件 [IF-17][IF-18]。
    ///
    /// `contentRevision` を含めるのは、走査が `isBookFolder` を書き換えたとき
    /// （画像フォルダにサブフォルダができて 1 冊扱いが解除された [IF-05] 等）に
    /// 印を消すため——実体の変更を見る `DirectoryObservation` では足りない。
    private struct BookFolderLoadKey: Hashable {
        let mode: DisplayMode
        let root: NavigationRoot
        let relativePath: String?
        let contentRevision: Int
        let settingsRevisions: [Int]
    }

    private var bookFolderLoadKey: BookFolderLoadKey {
        BookFolderLoadKey(
            mode: windowState.displayMode,
            root: windowState.navigationRoot,
            relativePath: windowState.libraryRelativePath,
            contentRevision: LibraryServices.shared.contentRevision,
            // 設定ウインドウで [IF-18] を切り替えたら、その場で効く。
            settingsRevisions: LibraryServices.shared.libraries.map(\.settingsRevision))
    }

    /// ラベルメニューの事前読み込みを読み直す条件 [RL3-01]。
    ///
    /// `bookFolderLoadKey` の条件に加えて `historyCount`（⌘Z・インスペクタでの
    /// 付け外しが紐づけを変える）と `libraryRowCount`（ライブラリ表示モードの
    /// 追加読み込みで対象が増える [FI-05]）にも乗る。
    private struct LabelMenuLoadKey: Hashable {
        let mode: DisplayMode
        let root: NavigationRoot
        let relativePath: String?
        let contentRevision: Int
        let historyCount: Int
        let libraryRowCount: Int
        let settingsRevisions: [Int]
    }

    private var labelMenuLoadKey: LabelMenuLoadKey {
        LabelMenuLoadKey(
            mode: windowState.displayMode,
            root: windowState.navigationRoot,
            relativePath: windowState.libraryRelativePath,
            contentRevision: LibraryServices.shared.contentRevision,
            historyCount: CommandStack.shared.operationHistory.count,
            libraryRowCount: windowState.libraryContent.rows.count,
            settingsRevisions: LibraryServices.shared.libraries.map(\.settingsRevision))
    }

    /// 未整理ビューの索引を読み直す条件 [UR3-03]。**未整理ビューを見ている
    /// 間だけ読む**——普段の一覧では要らない問い合わせなので、入ってから
    /// 読み、出たら捨てる。
    private var unresolvedRescueKey: UnresolvedRescueKey {
        UnresolvedRescueKey(
            libraryID: windowState.showsUnresolvedFiles ? windowState.currentLibrary?.id : nil,
            contentRevision: LibraryServices.shared.contentRevision,
            operationCount: CommandStack.shared.operationHistory.count)
    }

    private var labelFilterLoadKey: LabelFilterLoadKey {
        LabelFilterLoadKey(
            root: windowState.navigationRoot,
            libraries: LibraryServices.shared.libraries.map {
                "\($0.id.rawValue):\($0.settingsRevision)"
            },
            contentRevision: LibraryServices.shared.contentRevision,
            operationCount: CommandStack.shared.operationHistory.count)
    }

    private var labelFilterResultKey: LabelFilterResultKey {
        LabelFilterResultKey(
            libraryID: windowState.labelFilter.library?.id,
            relativePath: windowState.libraryRelativePath,
            revision: windowState.labelFilter.revision)
    }

    /// キーボードショートカットの配線（可視要素を持たない不可視ボタン群）。
    /// `mainToolbar`/`detailPane` と同じ理由で `body` から切り出している。
    ///
    /// **Finder と同じキーに揃えてある操作はここに無い** [ユーザー要望]。
    /// それらはメニュー項目自身が `.fixedKeyboardShortcut(_:)` でショートカットを
    /// 持ち、**メニューにキーが表示される**（不可視ボタン経由では表示されず、
    /// キーを知っている人にしか機能の存在が分からなかった）。同じキーの二重
    /// 登録を避けるため、ここからは外してある — 新規タブ・フォルダへ移動・
    /// 検索・表示モード・アイコンサイズ・各ペイン/バーの表示切替・取り出す・
    /// Undo/Redo がそれに当たる。残っているのは**変更可能な操作**だけ。
    @ViewBuilder
    private var keyBindingButtons: some View {
            Group {
                // サムネイル表示の一括切替（既定 ⌃⌘I）[DS-01][DS-02]。
                // 1-8 で `ActionID.toggleThumbnails` として登録だけしてあった
                // ものを、ここで初めて実際に配線した。**アプリ全体の状態**を
                // 反転するので、どのウインドウから押しても同じ [DS-03]。
                // ライブラリ側の強制非表示 [DS-04] が効いている場面でも
                // 無効化しない——これは全体設定の変更であり、その場の見た目が
                // 変わらないことを理由に設定操作自体を塞ぐのは行き過ぎのため
                // （ステータスバーのボタンだけは、押しても見た目が変わらない
                // ので無効化している。役割の違いは `StatusBarView` のコメント参照）。
                KeyBindingButtons(action: .toggleThumbnails, store: keyBindingStore) {
                    ThumbnailVisibility.shared.toggleGlobal()
                }
                // 「すべてを取り出す」は Finder 同様に既定キーを持たないため、
                // `KeyBindingButtons` はボタンを 1 つも生成しない（環境設定で
                // 割り当てたときだけ効く）。「取り出す」（⌘E）はファイルメニュー側。
                KeyBindingButtons(action: .ejectAll, store: keyBindingStore) {
                    Task { await VolumeEjectAction.ejectAll() }
                }
                // ラベルフィルタの一括 OFF（既定 ⇧⌘K）[LF-07]。1-8 で
                // `ActionID.clearLabelFilter` として登録だけしてあったものを、
                // ここで初めて配線した。**ウインドウ固有の状態**なので、
                // 押したウインドウの絞り込みだけが解ける [ST-21][LF-06]。
                KeyBindingButtons(action: .clearLabelFilter, store: keyBindingStore) {
                    windowState.labelFilter.clearAll()
                }
            }
            .frame(width: 0, height: 0)
            .opacity(0)
    }

    var body: some View {
        Group {
            NavigationSplitView(columnVisibility: $sidebarVisibility) {
                VStack(spacing: 0) {
                VSplitView {
                    // 分割位置の記憶 [UI-02、ユーザー要望]。`VSplitView` には
                    // `ideal` に相当する指定が無く、SwiftUI 側から初期位置を
                    // 渡す手段が無いため、`HSplitView` のときと同じく
                    // `NSSplitView.setPosition` を直接呼ぶ。**観測も同じ
                    // AppKit 側で行う** — SwiftUI の `GeometryReader` で測ると
                    // 単位が食い違い、起動のたびに縮んでいく（`SplitPositionApplier`
                    // の `onDividerMoved` のコメント参照）。
                    FolderTreePane(
                        selectedURL: windowState.folder,
                        navigationRoot: windowState.navigationRoot,
                        startupFolderResolved: startupFolderResolved,
                        onSelect: { url, root in windowState.navigate(to: url, root: root, fromTree: true) },
                        // ツリーのコンテキストメニュー「新規タブ／ウインドウで
                        // 開く」[ユーザー要望]。**タブ・ウインドウのどちらも
                        // `NavigationRoot` を引き継ぐ** — `WindowGroup` の値型を
                        // `URL` から `TabTarget` へ拡張したため、以前「新規
                        // ウインドウで開くだけは引き継げない」として記録して
                        // いた既知の制限は解消した [ネイティブタブ移行]。
                        onOpenInNewTab: { url, root in openAsTab(TabTarget(url: url, navigationRoot: root)) },
                        onOpenInNewWindow: { openAsWindow(windowState.target(for: $0)) }
                    )
                    .frame(minHeight: 120)
                    .background(SplitPositionApplier(
                        dividerIndex: 0, targetSize: folderTreeHeight, axis: .vertical,
                        onDividerMoved: { folderTreeHeight = $0 }
                    ))
                    // ラベルフィルタ [LF-01〜LF-14]。読み込みと再計算は下の
                    // `.task` が駆動する——**左ペインと中央ペインの両方**が
                    // 同じ結果を見る必要があり、この View に持たせると
                    // 左ペインを畳んだときに中央の絞り込みが止まる。
                    LabelFilterPane(model: windowState.labelFilter,
                                    services: LibraryServices.shared,
                                    isShowingUnresolved: windowState.showsUnresolvedFiles,
                                    onToggleUnresolved: { windowState.toggleUnresolvedFiles() },
                                    shelves: windowState.shelves,
                                    isLibraryDisplayMode: windowState.displayMode == .library,
                                    currentShelfCondition: windowState.currentShelfCondition,
                                    onApplyShelf: { windowState.applyShelf($0) })
                        .frame(minHeight: 80)
                }
                }
                .navigationSplitViewColumnWidth(min: 180, ideal: leftWidth, max: 400)
                .modifier(PaneWidthPersisting(storedWidth: $leftWidth))
                // フォルダ／ライブラリのシーソーを**サイドバー側のツールバー領域**へ
                // 置く [ユーザー要望: 左ペインをたたむボタンの隣に]。サイドバー列の
                // 中で宣言したツールバー項目は、追跡区切りの左（サイドバーの上）に
                // 並ぶ——一番大きく変化が見えるのが左ペインなので、切替もそこに。
                .toolbar {
                    ToolbarItem(placement: .automatic) {
                        displayModeSeesaw
                    }
                }
            } detail: {
                detailPane
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
            .toolbar { mainToolbar }
        }
        .frame(minWidth: 900, minHeight: 560)
        .windowFrameAutosave("qoo.MainWindow") // [実機検証時のユーザー要望]
        // 新しく開いたウインドウをネイティブのタブグループへ合流させる
        // [ネイティブタブ移行、`WindowTabJoiner` のコメント参照]。
        .windowTabJoiner()
        // 「移動」メニューへナビゲーション操作を公開する [1-16、
        // `WindowMenuActions` のコメント参照]。戻る/進むの履歴と現在のタブは
        // `windowState`（ウインドウ単位）が持つため、`FolderContentView` では
        // なくここから公開する。
        .focusedSceneValue(\.windowMenuActions, currentWindowMenuActions)
        // 「取り出す」の判定は現在地とマウント状態でしか変わらないので、
        // その 2 つが動いたときだけ調べ直す [NV6-02]。
        .task(id: windowState.folder) { await refreshEjectState() }
        // ラベルフィルタのグループとラベルを読む [LF-01][LF-02]。
        //
        // **一覧の変化にも乗せる**——`LibraryServices.libraries` は起動直後に
        // 非同期で埋まるので、「開いたとき 1 回」だけ読む造りにすると空の
        // 一覧を見て確定してしまう（ライブラリ設定ウインドウで実際に踏んだ
        // 競合と同じ形）。有効化・無効化・設定変更もここで拾える。
        .task(id: labelFilterLoadKey) {
            await windowState.labelFilter.load(
                registrationUUID: windowState.navigationRoot.registrationUUID,
                services: LibraryServices.shared)
        }
        // 保存した絞り込みを読む [SH-01]。**ラベルフィルタと同じ鍵で駆動する**
        // ——どちらも「表示中のライブラリについて左ペインが出すもの」で、
        // `operationHistory.count` を含んでいるので ⌘Z にも追随する。
        .task(id: labelFilterLoadKey) {
            await windowState.shelves.load(library: windowState.currentLibrary,
                                           services: LibraryServices.shared)
        }
        // 件数と、中央ペインが残す子の名前を数え直す [LF-11][VM-02]。
        .task(id: labelFilterResultKey) {
            await windowState.labelFilter.refreshResults(
                folderRelativePath: windowState.libraryRelativePath,
                services: LibraryServices.shared)
        }
        // フォルダ表示モードでブックフォルダに印を出す [IF-17]、および
        // 「開く」の既定 [IF-18]。**ライブラリ表示モードでは読まない**
        // ——あちらでは既に 1 冊として 1 行に出ており、印の出番が無い。
        .task(id: bookFolderLoadKey) {
            guard windowState.displayMode == .folder else {
                windowState.bookFolders.clear()
                return
            }
            await windowState.bookFolders.load(
                library: windowState.currentLibrary,
                relativePath: windowState.libraryRelativePath,
                services: LibraryServices.shared)
        }
        // 中央ペインのラベルメニューの事前読み込み [RL3-01〜RL3-03]。
        // メニューは遅延構築で非同期の後追い更新が効かないため、右クリックの
        // 前に読めている必要がある（`bookFolders` と同じ形）。
        .task(id: labelMenuLoadKey) {
            await windowState.labelMenu.load(
                library: windowState.currentLibrary,
                relativePath: windowState.libraryRelativePath,
                libraryRows: windowState.displayMode == .library
                    ? windowState.libraryContent.rows.map(\.file) : [],
                services: LibraryServices.shared)
        }
        // 未整理ビューの救済アクションが使う索引 [UR3-03]。
        .task(id: unresolvedRescueKey) {
            guard let libraryID = unresolvedRescueKey.libraryID else { return }
            // **索引としての入口を通す**（無視したものも読む）。一覧を絞るのは
            // `libraryContent.unresolvedFilter` の役目で、こちらではない。
            await windowState.unresolvedRescue.prepareAsIndex(
                services: LibraryServices.shared, libraryID: libraryID)
        }
        // 走査結果・通知履歴から未整理ビューへ [UR3-01][UR2-02]。
        // **最初に気づいたウインドウが引き受ける**（受け皿のコメント参照）。
        .onChange(of: UnresolvedViewNavigation.shared.pendingLibraryID) { _, _ in
            // **`onChange` が渡す新しい値ではなく、共有の値を読み直す**
            // ［code-review の指摘］。メインウインドウは複数開ける [MW-01] ので、
            // 引数を見ると**開いている枚数だけ**未整理ビューへ切り替わる
            // ——1 枚目が `nil` に戻しても、2 枚目のクロージャは自分が受け取った
            // 非 `nil` の値を見てしまう。読み直せば 2 枚目は `nil` で降りる。
            guard let pending = UnresolvedViewNavigation.shared.pendingLibraryID,
                  let library = LibraryServices.shared.libraries.first(where: { $0.id == pending })
            else { return }
            UnresolvedViewNavigation.shared.pendingLibraryID = nil
            windowState.showUnresolvedFiles(in: library)
        }
        .onChange(of: SessionState.shared.reloadToken) {
            Task { await refreshEjectState() }
        }
        // フォルダを移動すると `WindowState.navigate` が絞り込みを解除する。
        // その結果として空になったときは、検索欄も畳んでボタンへ戻す
        // （入力中＝フォーカスがある間は畳まない）。
        // フォルダを移動すると `WindowState.navigate` が絞り込みを解除する。
        // 入力中に畳んでしまわないよう、**入力欄がキーボードフォーカスを
        // 持っていないときだけ**畳む（判定は `NSSearchField` の実体に対して
        // 行う——`@FocusState` はツールバー内では機能しないため）。
        .onChange(of: windowState.searchText) { _, newValue in
            guard newValue.isEmpty, isSearchFieldExpanded else { return }
            guard !(NSApp.keyWindow?.firstResponder is NSText) else { return }
            collapseSearchField(clearingText: false)
        }
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
        // `QLPreviewPanel` の制御権をこのウインドウの `quickLook` へ渡すための
        // レスポンダ差し込み [QL-01、`QuickLookPanelInstaller` のコメント参照]。
        .background(QuickLookPanelInstaller(controller: quickLook))
        .background { keyBindingButtons }
        // アプリ起動時に開くフォルダ [ユーザー要望、環境設定「一般」タブ]。
        // アプリ起動後、最初に開く（＝明示的なフォルダ指定を受けていない）
        // ウインドウにだけ適用する [`hasAppliedStartupFolderThisLaunch` の
        // コメント参照]。既定（仮想ホーム）のときは何もしない（不要な非同期
        // 処理・チラつきを避ける）。
        .task {
            // 明示的な行き先で開いたウインドウ（新規タブ／ウインドウで開く）と、
            // 起動後 2 本目以降は解決しない。ツリーには「もう待たなくてよい」
            // ことだけ伝える。
            guard wasLaunchedWithoutExplicitFolder, !Self.hasAppliedStartupFolderThisLaunch else {
                startupFolderResolved = true
                return
            }
            Self.hasAppliedStartupFolderThisLaunch = true
            // **「ホーム」も含めて必ず解決する**（`startupFolderResolved` の
            // コメント参照）。`resolve()` はボリューム許可の有効化を待つので、
            // ここで初めて実ホームかどうかを正しく判定できる。
            let (url, root) = await StartupFolderPreference.resolve()
            windowState.folder = url
            windowState.navigationRoot = root
            // メインスレッドで FS を待たない [NV6-02]。
            windowState.title = await FileIO.perform { FileManager.default.displayName(atPath: url.path) }
            startupFolderResolved = true
            // 登録済みだが未有効のライブラリがあれば、ウィザードをステップ 3
            // から再開して有効化まで導く [§19.10 ステージ 2]。起動につき 1 回。
            LibrarySetupPrompt.runOnce(locale: locale, openWindow: openWindow)
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

/// ラベルフィルタの読み込みを走らせ直す条件。
///
/// `libraries` の要約まで含めるのは、**有効化・無効化・設定変更に追随する**ため。
/// `settingsRevision` が変わるとラベルグループの名前や並びも変わり得る [VT-02]。
private struct UnresolvedRescueKey: Hashable {
    /// `nil` なら未整理ビューを見ていない（読まない）。
    let libraryID: LibraryID?
    let contentRevision: Int
    let operationCount: Int
}

private struct LabelFilterLoadKey: Hashable {
    let root: NavigationRoot
    let libraries: [String]
    /// 走査が DB を書き換えるたびに増える [`LibraryServices.contentRevision`]。
    ///
    /// **これが無いとラベルが一覧に出ない**［2-9 の実機検証で発見］。有効化と
    /// 初回走査は同時に走るので、`libraries` が空 → 1 件に変わった時点で
    /// 一度読み込まれ、そのときはまだラベルが 1 件も無い。走査が終わっても
    /// `settingsRevision` は変わらないため鍵が動かず、**アプリを再起動する
    /// まで「このライブラリにはまだラベルがありません」のまま**だった。
    let contentRevision: Int
    /// DB を触る操作（⌘Z を含む）のたびに増える [`CommandStack` 参照]。
    ///
    /// **未整理の件数 [UR3-01] がこれを要る。**「以後無視する」[AL-33] は
    /// `CommandStack` 経由の取り消せる操作で、走査ではないので
    /// `contentRevision` は動かない——含めないと、無視した直後も ⌘Z で戻した
    /// 直後も左ペインの件数が古いままになる。
    let operationCount: Int
}

/// 件数と絞り込み結果を数え直す条件。
///
/// **選択そのものを鍵にしない**——辞書の中身が同じでも別インスタンスになった
/// 瞬間に再計算が走る。`revision` は選択・評価が実際に変わったときだけ増える。
private struct LabelFilterResultKey: Hashable {
    let libraryID: LibraryID?
    let relativePath: String?
    let revision: Int
}

struct PlaceholderPane: View {
    let title: String
    let subtitle: String
    /// 次に何ができるかを 1 つだけ添える [ER-03 の三要素のうち三つ目]。
    /// 現状の唯一の利用者は「アクセス権がありません」に添える
    /// 「アクセスを許可…」（`FolderContentView`）。
    var action: Action?

    struct Action {
        let title: String
        let perform: () -> Void
    }

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
            if let action {
                Button(action.title, action: action.perform)
                    .padding(.top, Tokens.spacing.xs)
            }
        }
        .padding(Tokens.spacing.l)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
