import QooApplication
import QooInfrastructure
import QooKit
import QooPersistence
import SwiftUI

/// アプリのエントリポイント。
///
/// `WindowGroup` は新規ウインドウ（⌘N）のたびに新しい `MainWindowView`
/// インスタンス（＝新しい `WindowState`）を作る。永続状態（DB）とセッション
/// 一時状態（`SessionState`）はまだフェーズ 1 の対象外の型に依存する部分
/// （ラベル・Undo 等）を除き、器だけをこの段階で用意している
/// [11章 §11.4 状態の 3 分類]。
@main
struct QooLibraryApp: App {
    /// [ユーザー要望、要件定義書には無い] 「すべてのウインドウが閉じたら終了」
    /// 環境設定（`GeneralPreferencesTab`）を実現するための橋渡し。詳細は
    /// `AppDelegate.swift` 参照。
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // フォルダツリー（`FolderTreePane`、`.listStyle(.sidebar)`）の行間を
        // 詰める [ユーザー要望]。**[調査の経緯]** `.sidebar` の実体である
        // `NSOutlineView`（`style = .sourceList`）は `rowHeight`/
        // `intercellSpacing` を実行時に直接代入しても内部的に約32ptへ強制
        // し戻すことを実機診断で確認済み（詳細は CLAUDE.md 参照）。一度は
        // `rowSizeStyle = .custom` を実行時に代入する方法も試したが、これは
        // SwiftUI が所有する `NSOutlineView` に対して AppKit 内部の
        // `_updateForSizeModeChange`（すべての可視行の再レイアウトを同期的に
        // 引き起こす）を発火させ、SwiftUI の AttributeGraph を再入させて
        // `SIGABRT` するクラッシュを引き起こした（クラッシュログで確認済み）。
        //
        // **`NSTableViewDefaultSizeMode`**（システム設定の「サイドバー
        // アイコンサイズ」＝Small/Medium/Large を裏で保持している
        // `UserDefaults` キー、値は 1/2/3）を使うと、`.sourceList` の行の
        // 高さは「実行時に既存のライブ NSOutlineView を書き換える」のでは
        // なく、AppKit 自身がテーブル構築時にこのキーを読んで最初から
        // 小さいプリセットで組み立てる——という安全な経路になることを実機
        // 診断で確認した（`rowSizeStyle` が自動的に medium(2)→small(1) に
        // なり、`rowHeight` は 32.0→24.0、実際の行の高さも 32.0→28.0 に
        // 縮小。クラッシュの原因だった実行時の直接代入は一切行っていない）。
        // `register(defaults:)` は最下位優先度の「登録ドメイン」に書き込む
        // ため、ユーザーが明示的にこのアプリ向けに別の値を設定していれば
        // 上書きしない。**サンドボックス下の `UserDefaults.standard` は
        // このアプリ専用のドメインであり、Finder 等の他アプリやシステム
        // 全体のこの設定には一切影響しない**（`defaults write -g` とは
        // 異なる。CLAUDE.md「設計の大原則」——固定値を強制するのではなく、
        // ここでは OS 自身が用意した「密度」プリセットに乗る形で解決した）。
        UserDefaults.standard.register(defaults: ["NSTableViewDefaultSizeMode": 1])
        // **macOS ネイティブのウインドウタブは無効にしない** [ユーザー判断、
        // 一度 `NSWindow.allowsAutomaticWindowTabbing = false` にして戻した経緯あり]。
        //
        // 1-16 の表示メニュー実装時に、AppKit が「表示」メニューへ自動で挿し込む
        // 「タブバーを表示」「すべてのタブを表示」が①本アプリ独自のタブ
        // （`TabBarView`/`TabState`）ではなくネイティブのウインドウタブを指していて
        // 紛らわしい②メニューの先頭を占めて表示モード（⌘1/⌘2）が Finder のように
        // 先頭に来ない、という理由で一度無効化した。**が、これはメニューの並びと
        // いう見た目のために「複数ウインドウを 1 つのタブ付きウインドウへ統合する」
        // という実機能を削る取引で、妥当ではなかった**（ユーザーが気づいて指摘）。
        //
        // 復活させたことで「表示」メニューの先頭は再びタブ関連の 2 項目になり、
        // 独自に足した表示モード等はその下に並ぶ。見た目の優先度を下げ、機能を
        // 優先する [ユーザー判断]。「アプリ独自のタブの中にネイティブのタブが
        // 入れ子になる」点は既知のトレードオフとして受け入れる。
        // 診断ログ [LG2-01〜LG2-08、1-15]。**他の起動処理より先に**行う —
        // 以降の初期化（ステージングの後始末、登録フォルダ／ボリューム許可の
        // 読み込み）で起きた事象も、正しいログレベルで記録されるようにする
        // ため。書き込み自体はバックグラウンドで行われるので起動は遅くならない
        // [CB-21]。
        Log.startSession()
        // 異常終了後に残ったステージングディレクトリを削除する
        // [RB-07][EX-03]。`Scene` は `.task` を持てないため `init()` から
        // 起動時に一度だけ実行する。
        Task {
            await SecureExtractor.cleanupResidualStaging()
        }
        // 登録済みライブラリ／テンポラリフォルダを読み込み、Security-Scoped
        // Bookmark へのアクセスをアプリ終了まで開始したままにする [1-13、
        // `RegisteredFolderStore.loadAndActivateAll()` のコメント参照]。
        Task {
            await RegisteredFolderStore.shared.loadAndActivateAll()
            // 「移動」メニューが同期的に読める形で登録フォルダを載せておく
            // [1-16、`RegisteredFolderIndex` のコメント参照]。以降の更新は
            // `FolderTreePane.reloadRegisteredFolders()` から取る。
            await RegisteredFolderIndex.shared.refresh()
        }
        // 環境設定「アクセス権」タブでユーザーが許可したボリューム／フォルダも
        // 同様に、アプリ終了までアクセスを開始したままにする
        // [ユーザー要望、`VolumeAccessStore` のコメント参照]。
        Task {
            await VolumeAccessStore.shared.loadAndActivateAll()
        }
        // Quick Look の独自カバープレビュー用に書き出したファイルは
        // セッション限りのキャッシュ [QL-03、`QuickLookCoverStore` のコメント
        // 参照]。ステージングと同じく、起動時に前回の残りを丸ごと片付ける。
        Task {
            await QuickLookCoverStore.shared.purgeAll()
        }
        // サムネイルキャッシュの鍵の形式が変わったときに残る、古い形式の
        // ファイルを捨てる [`DefaultCoverImageCache.purgeOutdatedVersions()`
        // 参照]。二度と引かれないものが上限 [IV-09] を圧迫し続けるのを防ぐ。
        Task {
            await DefaultCoverImageCache.shared.purgeOutdatedVersions()
        }
        // ライブラリ機能の合成根 [フェーズ 2 の結線、`LibraryServices` 参照]。
        // ストアを開き、リポジトリとスキャンエンジンを組み立てる。
        //
        // **開けなくてもアプリは起動し続ける**［設計判断］——qooLibrary は
        // フェーズ 1 の時点でファイルマネージャーとして完結しているので、
        // ライブラリ機能だけを畳んで残りを従来どおり使えるほうが害が小さい。
        // 失敗は `LibraryServices.startupFailure` に残り、有効化を試みた
        // ときに理由付きで提示される [ER-03]。
        //
        // **ここで走査は始めない。** 走査の対象になるのはユーザーが明示的に
        // ライブラリとして有効化した登録フォルダだけで、有効化は
        // `LibraryEnableAction` からしか起こらない。
        Task { @MainActor in
            await LibraryServices.shared.bootstrap()
            // **実体への追随を始める** [SY-01][VD-01]。ここまで来ると
            // FSEvents の監視とボリュームの着脱検知が動き出し、外部での変更が
            // 自動で DB へ反映される。
            //
            // `bootstrap()` の**後**に呼ぶ（リポジトリが揃っている必要がある）。
            // 登録フォルダの読み込みとの順序は気にしなくてよい——
            // `RegisteredFolderStore` の公開メソッドはどれも `ensureLoaded()`
            // から始まるので、先に来ても待ち合わせる。
            await LibraryServices.shared.startSync()
            // 参照されなくなったユーザー指定カバーの複製を捨てる [CV-06]。
            // **起動時に一度だけ**——差し替え・「既定に戻す」はその場では
            // 消さない（⌘Z で戻せる以上、消すと取り消した先に実体が無い）。
            // `CommandStack` はメモリのみで再起動をまたがないので、この時点で
            // 参照されていない複製はもう誰も戻せない
            // （`SecureExtractor.cleanupResidualStaging()` と同じ位置づけ）。
            await LibraryServices.shared.purgeUnreferencedUserCovers()
        }
        // [ER-01] エラー・通知の提示はこのコントローラ1箇所からのみ行う
        // （`NotificationRouterPresenterController` のコメント参照）。
        NotificationRouterPresenterController.shared.start()
        // 「置き換える」の途中で落ちた／切断された場合に残った退避を元へ戻す
        // [NV-92]。**提示を始めたあとに呼ぶ** — 戻せなかったことをユーザーへ
        // 伝える必要があり、それより前に走らせると通知の行き先が無い。
        Task {
            await ReplaceBackupRecovery.runAtStartup()
        }
        // 「移動」メニューの「最近使ったフォルダ」は同期的に読まれるので、
        // 実体の確認は起動時に済ませておく [NV6-02]。
        Task {
            await RecentFoldersStore.shared.refresh()
        }
        // 長時間処理の進捗は**別の小さなウインドウ**に出す［ユーザー要望］。
        // このコントローラがアプリ全体で 1 つの窓を出し入れする。
        OperationProgressWindowController.shared.start()
        // サムネイルの全体トグル [DS-01] とバックグラウンド動画サムネイル生成
        // [ユーザー要望、9.6 節] の接続。非表示にしたら掃引を止め、表示に
        // 戻したら再開する。起動時の最初の掃引は、上の Task の
        // `RegisteredFolderIndex.refresh()` が `restart()` を呼ぶことで始まる。
        ThumbnailVisibility.shared.onGlobalVisibilityChanged = { hidden in
            if hidden {
                BackgroundThumbnailWarmer.shared.stop()
            } else {
                BackgroundThumbnailWarmer.shared.restart()
            }
        }
    }

    var body: some Scene {
        // `for: TabTarget.self` にすることで、「新規タブ／ウインドウで開く」から
        // フォルダと入口（`NavigationRoot`）の両方を運べる（⌘N・Dock アイコン
        // からの起動など、値を指定しない経路は引き続き `nil` → 既定のホーム）。
        // **1 つのシーン ＝ 1 つのタブ**で、タブとして開くかウインドウとして
        // 開くかは `WindowTabJoiner` が決める [ネイティブタブ移行]。
        WindowGroup(for: TabTarget.self) { $target in
            MainWindowView(target: target)
                .appLanguageOverride() // [1-12 ローカライズ方針、CLAUDE.md 参照]
        }
        .windowResizability(.automatic)
        .defaultSize(width: 900, height: 560)
        // ゾンビウインドウ対策 [設計判断、qooViewer（姉妹プロジェクト）の実機
        // バグ報告を踏まえた予防的対応]。SwiftUI の `WindowGroup` 標準の状態
        // 復元（ウインドウが無い状態から再アクティブ化されたとき等に前回の
        // ウインドウを復元しようとする仕組み）が、閉じたはずの古い `NSWindow`
        // を再利用してしまい中身が正しく描画されない・`onAppear` が意図せず
        // 再発火するなどの不具合を招くことがあると報告されている。ウインドウの
        // 位置・サイズの記憶は `windowFrameAutosave`（自前の `UserDefaults`
        // ベースの仕組み）で行っており、この標準の状態復元には依存していない
        // ため、無効化しても既存機能に影響しない。
        .restorationBehavior(.disabled)
        .commands {
            CommandGroup(replacing: .appInfo) {
                AboutMenuButton()
            }
            CommandGroup(replacing: .appSettings) {
                PreferencesMenuButton()
            }
            // [Finder/Edit メニュー整備、要件定義書には無いユーザー要望への対応]
            // `.newItem`（既定の「新規ウインドウ」)の直後に追加する。個々の
            // ウインドウ・タブの状態は `FolderMenuActions`（`@FocusedValue`）
            // 経由で読む — 詳細はその型のコメント参照。
            CommandGroup(after: .newItem) {
                FileMenuCommands()
            }
            CommandGroup(replacing: .undoRedo) {
                UndoRedoMenuCommands()
            }
            // 標準の Cut/Copy/Paste/Delete/すべて選択は非活性のプレースホルダの
            // ままで実際には何も起きない（このアプリはテキスト編集ビューを
            // 持たず、AppKit 標準のレスポンダチェーン実装に乗っていないため）。
            // 独自実装（`FolderMenuActions` 経由）に丸ごと置き換える
            // [Finder/Edit メニュー整備]。
            CommandGroup(replacing: .pasteboard) {
                EditMenuCommands()
            }
            // [13章 §13.5 ヘルプメニュー、LG2-05] 標準の「qooLibrary ヘルプ」は
            // ヘルプブックを同梱していないため何も起きない項目のまま残る。
            // 実際に役立つ「診断ログを書き出す…」に置き換える。
            // 「README を開く」[HP-07] は今回の対象外。
            CommandGroup(replacing: .help) {
                DiagnosticExportMenuButton()
            }
            // [1-16 表示メニュー] **`CommandMenu` で新設しない** — SwiftUI は
            // 「表示」メニュー自体を標準で用意しており（タブバーを表示／すべての
            // タブを表示／フルスクリーンにする が既に入っている）、`CommandMenu`
            // を足すと同じ名前のメニューが 2 つ並ぶ。`.sidebar` 配置の手前へ
            // 挿し込むことで Finder と同じく表示モードが先頭に来る。
            CommandGroup(before: .sidebar) {
                ViewMenuCommands()
            }
            // [1-16 移動メニュー] Finder の「移動」メニュー相当。こちらは標準の
            // `CommandGroup` に対応する配置が無いため独立した `CommandMenu` に
            // する（SwiftUI は宣言順に Window メニューの手前へ挿入する）。
            CommandMenu("menu.go") {
                GoMenuCommands()
            }
        }

        Window("about.windowTitle", id: "about") {
            AboutView()
                .appLanguageOverride()
        }
        .windowResizability(.contentSize)

        // 環境設定 [15.10 節、1-12]。**`Settings` シーンではなく `About` と
        // 同じ普通の `Window(id:)` を使う** [設計判断、ユーザー要望による
        // 2ペイン化（`NavigationSplitView`）への変更時に実機検証で判明:
        // `Settings` シーンは `.principal` 配置のツールバー項目を「現在の
        // タブ」を示すピル（カプセル）状の背景付きで自動的に描画する仕様が
        // あり（Safari/Mail の環境設定のような、古い macOS の丸型タブに近い
        // 見た目を意図した挙動と考えられる）、これを SwiftUI の公開 API で
        // 取り除く方法が無かった。`Window(id:)` シーンにはこの自動装飾が
        // 無く、`⌘,`・メニュー項目は上の `CommandGroup(replacing: .appSettings)`
        // で手動配線する]。
        // ライブラリの設定 [LS-01〜LS-03][15.1 節]。**テンプレートは登録時に
        // 一度写されるだけの雛形** [LT-03] なので、写された設定を実際に
        // 調整できる場所がここになる。開くのはフォルダツリーの
        // 「ライブラリの設定…」から（`LibrarySettingsNavigation` が対象を渡す）。
        Window("librarySettings.windowTitle", id: "librarySettings") {
            LibrarySettingsWindow()
                .appLanguageOverride()
        }
        .defaultSize(width: 980, height: 620)

        // ラベルグループとラベルの編集 [LE-01〜LE-12][15.2 節]。開くのは
        // フォルダツリーの「ラベルを編集…」、ラベルフィルタと右ペインの
        // ラベルの右クリックから（`LabelEditorNavigation` が対象を渡す）。
        Window("labelEditor.windowTitle", id: "labelEditor") {
            LabelGroupEditorWindow()
                .appLanguageOverride()
        }
        .defaultSize(width: 1240, height: 680)

        // ラベル保管庫の整理 [LAW-01〜LAW-03][15.3 節]。開くのはフォルダツリーの
        // 「ラベルの保管庫…」と、ラベル編集ウインドウのフッターから
        // （`LabelVaultNavigation` が対象を渡す）。
        Window("labelVault.windowTitle", id: "labelVault") {
            LabelVaultWindow()
                .appLanguageOverride()
        }
        .defaultSize(width: 820, height: 560)

        // 孤立ファイルの整理 [OR-01〜OR-05][15.7 節]。開くのはフォルダツリーの
        // 「孤立ファイルを整理…」から（`OrphanCleanupNavigation` が対象を渡す）。
        // **登録ルート行は 2 種類ある**ので、通常の行と縮退した行の両方に
        // 配線してある。
        Window("orphanCleanup.windowTitle", id: "orphanCleanup") {
            OrphanCleanupWindow()
                .appLanguageOverride()
        }
        .defaultSize(width: 880, height: 560)

        Window("preferences.windowTitle", id: "preferences") {
            PreferencesView()
                .appLanguageOverride()
        }
        .windowResizability(.contentSize)
    }
}

private struct PreferencesMenuButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("preferences.windowTitle", systemImage: "gear") {
            openWindow(id: "preferences")
        }
        .keyboardShortcut(",", modifiers: .command)
    }
}

private struct AboutMenuButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("about.windowTitle") {
            openWindow(id: "about")
        }
    }
}

/// ヘルプメニューの「診断ログを書き出す…」[13章 §13.5、LG2-05]。
/// 実処理は環境設定「詳細」タブと共有する（`DiagnosticExportAction` 参照）。
private struct DiagnosticExportMenuButton: View {
    @Environment(\.locale) private var locale

    var body: some View {
        Button("diagnostics.exportMenuItem", systemImage: "stethoscope") {
            DiagnosticExportAction.run(locale: locale)
        }
    }
}

/// File メニュー本体 [Finder/Edit メニュー整備]。実際のキーボードショートカット
/// はここでは付けない — `KeyBindingButtons`（`FolderContentView` の
/// `.background` 参照）がアプリの唯一の配線経路になるようにするため
/// [設計判断、1-8 以来の他のショートカットと同じ仕組みに揃える。`UndoRedoMenuCommands`
/// と同じ理由]。フォーカス中のウインドウにアクティブなタブが無い場合
/// （`actions` が `nil`）はすべて無効化する。
private struct FileMenuCommands: View {
    @FocusedValue(\.folderMenuActions) private var actions
    /// 「取り出す」だけは `WindowMenuActions` 側から読む [1-16]。対象は選択でも
    /// 現在のフォルダでもなく「そのフォルダが乗っているボリューム」で、判定に
    /// 必要な `windowState` を持っているのが `MainWindowView` のため。
    @FocusedValue(\.windowMenuActions) private var window

    var body: some View {
        Button("action.newFolder", systemImage: "folder.badge.plus") { actions?.newFolder() }
            .disabled(actions?.canNewFolder != true)
            .fixedKeyboardShortcut(.newFolder)
        Button("action.newFolderWithSelection") { actions?.newFolderWithSelection() }
            .disabled(actions?.canNewFolderWithSelection != true)
        // 新規タブ [1-16 メニュー抜け監査]。⌘T として配線済みだったのにメニュー
        // バーに項目が無く、キーを知らないと辿り着けなかった [ユーザー指摘]。
        // 位置は Finder と同じ（新規フォルダ系の直後、「開く」の手前）。
        Button("action.newTab", systemImage: "plus.square.on.square") { window?.newTab() }
            .disabled(window == nil)
            .fixedKeyboardShortcut(.newTab)
        Divider()
        Button("action.open", systemImage: "arrow.up.forward.app") { actions?.open() }
            .disabled(actions?.canOpen != true)
            // Finder と同じく ⌥ で「新規ウインドウで開く」に入れ替わる
            // [1-16 メニュー抜け監査]。**「新規タブで開く」は Finder のファイル
            // メニューに存在しないためここには置かない**［ユーザー判断: 原則
            // Finder に揃える］。コンテキストメニューには従来どおりある。
            .modifierKeyAlternate(.option) {
                Button("folder.openInNewWindow", systemImage: "plus.rectangle") { actions?.openInNewWindow() }
                    .disabled(actions?.canOpenInNewWindow != true)
            }
        // このアプリケーションで開く [12章 §12.9]。Finder と同じく「開く」の
        // 直後。単一選択のときだけ対象が定まるため、それ以外は無効化する。
        OpenWithFileMenuItem(target: actions?.openWithTarget)
        Button("action.quickLook", systemImage: "eye") { actions?.quickLook() } // [QL-01]
            .disabled(actions?.canQuickLook != true)
        Divider()
        Button("action.rename", systemImage: "pencil") { actions?.rename() }
            .disabled(actions?.canRename != true)
        Button("folder.duplicate", systemImage: "plus.square.on.square") { actions?.duplicate() }
            .disabled(actions?.canDuplicate != true)
            .fixedKeyboardShortcut(.duplicate)
        Button("folder.createAlias", systemImage: "square.on.square.dashed") { actions?.makeAlias() }
            .disabled(actions?.canMakeAlias != true)
        // 圧縮／展開 [1-16 メニュー抜け監査]。**展開はコンテキストメニューに
        // しか無く、メニューバーには圧縮だけがある非対称な状態だった**
        // [ユーザー指摘]。コンテキストメニューと同じサブメニュー構成にまとめる
        // ［ユーザー判断: 展開は圧縮／展開のサブメニューで圧縮とまとめる］。
        //
        // **メニューバーでは「隠す」ではなく「無効にする」**。コンテキスト
        // メニュー側（`FolderContentView`／`FolderTreeContextMenu`）は
        // 項目自体を出さないが、ここで同じことをすると 2 つ問題がある:
        // ① 項目の有無を `@FocusedValue` に依存させると、フォーカス中の
        //    ウインドウがまだ値を公開していない起動直後などに項目が消える
        //    （実測: 起動直後のダンプで代替項目が生成されなかった）。
        // ② 代わりに `@AppStorage` を `if` 条件で読むのは、SwiftUI の
        //    Observation が無限に再評価してハングする既知の不具合を踏む
        //    パターンそのもの（CLAUDE.md「タブバー表示トグル」参照）。
        // メニューバーは項目が固定で有効/無効だけが変わるのが macOS の
        // 作法でもあるため、他の項目と同じ `.disabled` に揃える。
        Menu("folder.compressExtractSubmenu", systemImage: "zipper.page") {
            Button("folder.compressHere", systemImage: "zipper.page") { actions?.compress() } // [AR-10]
                .disabled(actions?.canCompress != true)
                // Finder と同じく ⌥ で「パスワード付きで圧縮」に入れ替わる
                // [Finder 対比監査]。
                .modifierKeyAlternate(.option) {
                    Button("folder.compressHereWithPassword", systemImage: "zipper.page") { actions?.compressWithPassword() }
                        .disabled(actions?.canCompressWithPassword != true)
                }
            Button("folder.compressEllipsis", systemImage: "zipper.page") { actions?.compressWithDialog() } // [AR-11]
                .disabled(actions?.canCompress != true)
            Divider()
            Button("folder.extractInPlace", systemImage: "shippingbox.and.arrow.backward") { actions?.extractInPlace() } // [AR-20]
                .disabled(actions?.canExtract != true)
            // 単一選択なら「（名前）に展開」[AR-21]、複数選択なら
            // 「それぞれのフォルダに展開」[AR-23]。コンテキストメニューと同じ。
            Button(extractToNamedTitle, systemImage: "shippingbox.and.arrow.backward") { actions?.extractToNamedFolders() }
                .disabled(actions?.canExtract != true)
            Button("folder.extractEllipsis", systemImage: "shippingbox.and.arrow.backward") { actions?.extractToChosenDestination() } // [AR-22]
                .disabled(actions?.canExtract != true)
        }
        .disabled(actions == nil)
        Divider()
        // 共有 [1-16 メニュー抜け監査]。コンテキストメニューにしか無かった。
        // Finder もファイルメニューに持っている。`ShareLink` はクロージャでは
        // なく実際の項目を要求するため、`FolderMenuActions.shareItems` から
        // 値そのものを受け取る。項目が空だと `ShareLink` 自体が機能しないので
        // その場合は無効化した見た目だけのボタンに差し替える。
        if let items = actions?.shareItems, !items.isEmpty {
            ShareLink(items: items) { Label("folder.shareEllipsis", systemImage: "square.and.arrow.up") }
        } else {
            Button("folder.shareEllipsis", systemImage: "square.and.arrow.up") {}
                .disabled(true)
        }
        Button("folder.revealInFinder", systemImage: "macwindow") { actions?.revealInFinder() }
            .disabled(actions?.canRevealInFinder != true)
        // ターミナルで開く [ユーザー要望]。選択が無ければ現在のフォルダが対象。
        Button("folder.openInTerminal", systemImage: "terminal") { actions?.openInTerminal() }
            .disabled(actions?.canOpenInTerminal != true)
        // 取り出す [1-16]。Finder と同じく ⌥ で「すべてを取り出す」に
        // 入れ替わる。既定キー ⌘E も Finder 標準（`ejectAll` 側は Finder 自身も
        // キーを割り当てていないため無し）。
        Button(
            window?.isEjectTargetNetworkVolume == true ? "action.disconnect" : "action.eject",
            systemImage: "eject"
        ) { window?.eject() }
            .disabled(window?.canEject != true)
            .fixedKeyboardShortcut(.eject)
            .modifierKeyAlternate(.option) {
                Button("action.ejectAll", systemImage: "eject") { window?.ejectAll() }
                    .disabled(window?.canEjectAll != true)
            }
        Divider()
        Button("folder.moveToTrash", systemImage: "trash", role: .destructive) { actions?.moveToTrash() }
            .disabled(actions?.canMoveToTrash != true)
            .fixedKeyboardShortcut(.moveToTrash)
            // Finder と同じく ⌥ で「すぐに削除…」に入れ替わる [FM-14]
            // [Finder 対比監査]。**ここでは `.keyboardShortcut` を付けない**
            // （このファイル冒頭の方針どおり）ため、⌥⌘⌫ のような既定の
            // キー割り当ては生えない — [FM-16]「完全削除に既定のキーバインドを
            // 割り当てない」と矛盾しないことを実測でも確認済み（代替項目の
            // キー等価は入力不能な U+0000 になる）。
            .modifierKeyAlternate(.option) {
                Button("folder.deletePermanentlyEllipsis", systemImage: "trash", role: .destructive) { actions?.deletePermanently() }
                    .disabled(actions?.canDeletePermanently != true)
            }
        // 「パス名をコピー」はここに退避していた「その他」サブメニューではなく、
        // Finder と同じく Edit メニューの「コピー」の ⌥ 代替になった
        // （`EditMenuCommands` 参照）。
        Divider()
        // 検索 [1-16 メニュー抜け監査]。⌘F とツールバーの虫めがねからしか
        // 辿れなかった [ユーザー指摘]。Finder もファイルメニューの末尾に置いている。
        Button("action.focusSearch", systemImage: "magnifyingglass") { window?.focusSearch() }
            .disabled(window == nil)
            .fixedKeyboardShortcut(.focusSearch)
    }

    /// 単一選択なら「（名前）に展開」[AR-21]、そうでなければ
    /// 「それぞれのフォルダに展開」[AR-23]。
    private var extractToNamedTitle: LocalizedStringKey {
        guard let name = actions?.extractNamedTitle else { return "folder.extractEachToOwnFolder" }
        // `String(localized:)` は `@Environment(\.locale)` を見ないうえ、
        // メニューバーの `.commands` はシーンルートの `.appLanguageOverride()` の
        // 外側にあるため、`AppLanguage.effectiveLocale` を明示的に渡す
        // [CLAUDE.md「表示言語」節の方針]。
        let format = String(localized: "folder.extractToNamed", locale: AppLanguage.effectiveLocale)
        return LocalizedStringKey(String(format: format, name))
    }
}

/// ファイルメニューの「このアプリケーションで開く」[12章 §12.9]。
///
/// コンテキストメニューの `OpenWithMenu` は対象が確定しているときだけ描画される
/// が、**メニューバーでは項目を消さず無効化する**（`FileMenuCommands` の
/// コメント参照）。そのため対象が無い場合は空の無効なサブメニューを出す。
private struct OpenWithFileMenuItem: View {
    let target: (url: URL, isDirectory: Bool)?

    var body: some View {
        if let target {
            OpenWithMenu(url: target.url, isDirectory: target.isDirectory)
        } else {
            Menu("folder.openWithSubmenu") { EmptyView() }
                .disabled(true)
        }
    }
}

/// 「表示」メニューへ足す項目 [1-16]。SwiftUI 標準の「表示」メニューの先頭
/// （`.sidebar` 配置の手前）へ挿し込む。
///
/// 状態は 2 つの `@FocusedValue` から読む: 表示モード・アイコンサイズ・ペイン
/// とバーの表示は `WindowMenuActions`（`MainWindowView` が公開）、並び替えと
/// カラムは `FolderMenuActions`（`FolderContentView` が公開）——それぞれ状態を
/// 実際に持っている側から公開するほうが素直なため。
///
/// **`@AppStorage` をこのビューで直接読まない**（カラムの実体は `@AppStorage`
/// だが、必ず `FolderMenuActions` のクロージャ越しに触る）。メニューバーの
/// `Toggle` を `@AppStorage` に束縛し、かつ同じキーをビュー構造を決める `if`
/// で読むと SwiftUI の Observation が無限に再評価してハングする既知の不具合を
/// 踏むため [CLAUDE.md「タブバー表示トグル」参照]。
///
/// 表示/非表示の項目は Finder に倣い、チェックマークではなく「〜を表示」/
/// 「〜を隠す」の動的なタイトルで出す。
private struct ViewMenuCommands: View {
    @FocusedValue(\.windowMenuActions) private var window
    @FocusedValue(\.folderMenuActions) private var folder

    var body: some View {
        // 表示モードの直接指定（⌘1/⌘2）[LV-04]。Finder と同じく現在のモードに
        // チェックマークが付くよう `Picker` + `.pickerStyle(.inline)` にする。
        Picker("common.view", selection: listStyleBinding) {
            Label("common.icon", systemImage: "square.grid.2x2").tag(ListStyle.icon)
                .fixedKeyboardShortcut(.displayAsIcons)
            Label("common.list", systemImage: "list.bullet").tag(ListStyle.list)
                .fixedKeyboardShortcut(.displayAsList)
        }
        .pickerStyle(.inline)
        .labelsHidden()
        .disabled(window == nil)
        // `.pickerStyle(.inline)` は自身の前後に区切り線を作るため、ここで
        // `Divider()` を足すと二重線になる（実アプリのメニューをダンプして確認）。
        //
        // サムネイル表示の一括切替 [DS-01][DS-02]。仕様書 13章 §13.7 の表示
        // メニュー順（表示モード → サムネイル → 並び替え → …）に合わせてここへ置く。
        //
        // **`@FocusedValue` を経由せず `ThumbnailVisibility` を直接読む。**
        // これはウインドウごとの設定ではなくアプリ全体の状態 [DS-03] なので、
        // フォーカス中のウインドウの有無で使えなくなるのはおかしい
        // （他の項目が `.disabled(window == nil)` なのは、いずれも対象の
        // ウインドウが要る操作だから）。`@Observable` なのでメニューの
        // タイトルは状態の変化に追従する。
        //
        // **タイトルは実効値ではなく「全体トグルの状態」を出す** — ライブラリ側の
        // 強制非表示 [DS-04] は全体設定を変えないため、実効値で出すと
        // 「表示」を選んでも何も起きないように見えてしまう。その場で何が
        // 起きているかはステータスバー側が理由付きで示す [DS-07]。
        Button(thumbnailsGloballyHidden ? "view.showThumbnails" : "view.hideThumbnails", systemImage: "photo") {
            ThumbnailVisibility.shared.toggleGlobal()
        }
        Divider()
        Menu("common.sortBy", systemImage: "arrow.up.arrow.down") { // [LV-01]
            Picker("common.sortBy", selection: sortKeyBinding) {
                ForEach(folder?.availableSortKeys
                        ?? FolderSortComparator.Key.allCases.filter(\.isAvailableInFolderMode),
                        id: \.self) { key in
                    Text(key.localizationKey).tag(key)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
            // ここも `Divider()` は足さない（インラインの `Picker` が前後に
            // 区切り線を作るため、入れると三重線になる）。
            Picker("common.sortBy", selection: sortAscendingBinding) {
                Text("sort.ascending").tag(true)
                Text("sort.descending").tag(false)
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
        .disabled(folder == nil)
        Menu("folder.visibleColumns", systemImage: "tablecells") { // [LV-02]
            // [LV-04][VM-15] 表示モードで選べる列だけを並べる。
            ForEach(folder?.availableColumns ?? FolderColumn.allCases.filter(\.isAvailableInFolderMode)) { column in
                Toggle(column.localizationKey, isOn: columnBinding(column))
            }
            Divider()
            Toggle("preferences.general.groupFoldersAtTop", isOn: groupFoldersBinding) // [LV-03]
        }
        // カラムはリスト表示のときだけ意味を持つ（Finder も表示モードに応じて
        // 「表示オプション」の中身が変わる）。
        .disabled(folder?.isListStyleActive != true)
        Divider()
        Button("action.increaseIconSize", systemImage: "plus.magnifyingglass") { window?.increaseIconSize() } // [IV-04]
            .disabled(window?.canIncreaseIconSize != true)
            .fixedKeyboardShortcut(.increaseIconSize)
        Button("action.decreaseIconSize", systemImage: "minus.magnifyingglass") { window?.decreaseIconSize() }
            .disabled(window?.canDecreaseIconSize != true)
            .fixedKeyboardShortcut(.decreaseIconSize)
        Divider()
        Button(window?.isSidebarVisible == false ? "view.showSidebar" : "view.hideSidebar", systemImage: "sidebar.leading") {
            window?.toggleSidebar()
        }
        .fixedKeyboardShortcut(.toggleSidebar)
        .disabled(window == nil)
        Button(window?.isInspectorVisible == false ? "view.showInspector" : "view.hideInspector", systemImage: "sidebar.trailing") {
            window?.toggleInspector()
        }
        .fixedKeyboardShortcut(.toggleInspector)
        .disabled(window == nil)
        Button(window?.isPathBarVisible == false ? "view.showPathBar" : "view.hidePathBar") {
            window?.togglePathBar()
        }
        .fixedKeyboardShortcut(.togglePathBar)
        .disabled(window == nil)
        Button(window?.isStatusBarVisible == false ? "view.showStatusBar" : "view.hideStatusBar") {
            window?.toggleStatusBar()
        }
        .fixedKeyboardShortcut(.toggleStatusBar)
        .disabled(window == nil)
    }

    /// `@Observable` を `body` から読むことで、トグルの変化がメニュー項目の
    /// タイトルに反映される（メニューバーは「開いた」だけでは再評価されないが、
    /// `@Observable` な状態の変化では再評価される。`GoMenuCommands` のコメント参照）。
    private var thumbnailsGloballyHidden: Bool {
        ThumbnailVisibility.shared.isGloballyHidden
    }

    // `@FocusedValue` は読み取り専用なので、`Picker`/`Toggle` に渡す
    // `Binding` はここで get/set のペアとして組み立てる。値が来ていない
    // （フォーカス中のウインドウが無い）ときは無害な既定値を返し、set は
    // 何もしない — 項目自体は `.disabled` で押せない状態になっている。

    private var listStyleBinding: Binding<ListStyle> {
        Binding(
            get: { window?.listStyle ?? .list },
            set: { window?.setListStyle($0) }
        )
    }

    private var sortKeyBinding: Binding<FolderSortComparator.Key> {
        Binding(
            get: { folder?.sortKey ?? .name },
            set: { folder?.setSortKey($0) }
        )
    }

    private var sortAscendingBinding: Binding<Bool> {
        Binding(
            get: { folder?.sortAscending ?? true },
            set: { folder?.setSortAscending($0) }
        )
    }

    private func columnBinding(_ column: FolderColumn) -> Binding<Bool> {
        Binding(
            get: { folder?.visibleColumns.contains(column) ?? false },
            set: { folder?.setColumnVisible(column, $0) }
        )
    }

    private var groupFoldersBinding: Binding<Bool> {
        Binding(
            get: { folder?.groupFoldersAtTop ?? false },
            set: { folder?.setGroupFoldersAtTop($0) }
        )
    }
}

/// 「移動」メニュー本体 [1-16]。File/Edit メニューと同じく、実際のキーボード
/// ショートカットはここでは付けない（`KeyBindingButtons` がアプリ唯一の配線
/// 経路、`FileMenuCommands` 冒頭のコメント参照）。
///
/// **登録フォルダ・最近使ったフォルダは `@Observable` なシングルトンから
/// 同期的に読む**。メニューバーのメニューはアプリ起動時に構築され「開いた」
/// だけでは再評価されない（1-14 の ⌥ 代替調査で実測）が、`@Observable` な
/// 状態の変化による再評価は起きる（Undo メニューの動的タイトルが既存の実例）
/// ため、非同期に解決した結果をあらかじめ載せておく設計にしている
/// [`RegisteredFolderIndex` のコメント参照]。
private struct GoMenuCommands: View {
    @FocusedValue(\.windowMenuActions) private var actions
    /// 「選択項目を開く」（⌘↓）だけは選択の状態を知っている側が要る。
    @FocusedValue(\.folderMenuActions) private var folderActions
    /// `@Observable` なので、参照した `library`/`temporary`/`paths` が変われば
    /// このビューは再評価される。
    private var registeredFolders: RegisteredFolderIndex { .shared }
    private var recentFolders: RecentFoldersStore { .shared }

    var body: some View {
        Button("action.goBack", systemImage: "chevron.backward") { actions?.goBack() }
            .disabled(actions?.canGoBack != true)
            .fixedKeyboardShortcut(.goBack)
        Button("action.goForward", systemImage: "chevron.forward") { actions?.goForward() }
            .disabled(actions?.canGoForward != true)
            .fixedKeyboardShortcut(.goForward)
        // Finder は「内包しているフォルダ」に ⌥ と ⌃ の 2 つの代替を持たせて
        // いる（`MenuBar.nib` を実体化して確認）。同じ構成にする。
        // ⇧⌘↑「デスクトップの起動ディスクを選択」だけはデスクトップの概念が
        // 無いため対象外。
        Button("action.goToParent", systemImage: "arrow.up.folder") { actions?.goToParent() }
            .fixedKeyboardShortcut(.goToParent)
            .disabled(actions?.canGoToParent != true)
            .modifierKeyAlternate(.option) {
                Button("action.goToParent", systemImage: "arrow.up.folder") {
                    actions?.goToParentAndCloseWindow()
                }
                .fixedKeyboardShortcut(.goToParentAndCloseWindow)
                .disabled(actions?.canGoToParent != true)
            }
            .modifierKeyAlternate(.control) {
                Button("menu.go.parentInNewWindow", systemImage: "arrow.up.folder") {
                    actions?.goToParentInNewWindow()
                }
                .fixedKeyboardShortcut(.goToParentInNewWindow)
                .disabled(actions?.canGoToParent != true)
            }
        // Finder の「選択項目を開く」（⌘↓）。実体は File メニューの「開く」
        // （Return）と同じで、Finder に合わせたキーを別に持たせたもの
        // [ユーザー判断]。選択の有無を知っているのは `FolderMenuActions` 側。
        Button("menu.go.openSelection") { folderActions?.open() }
            .fixedKeyboardShortcut(.openSelection)
            .disabled(folderActions?.canOpen != true)
        Divider()
        // Finder と同じ標準の場所 [ユーザー判断、1-16 移動メニューの Finder
        // 準拠]。行き先・アイコン・キー・アクセス要件はすべて
        // `StandardLocation` が持つ。**未許可ならその場でパネルを出して 1 回
        // だけ許可を求める**ので、ここは呼ぶだけでよい。
        //
        // Finder にあってここに無いもの（最近の項目・AirDrop・ネットワーク等）
        // と、その理由は `StandardLocation` の doc コメントにまとめてある。
        standardLocationItem(.documents)
        standardLocationItem(.desktop)
        standardLocationItem(.downloads)
        // Finder は「ライブラリ」を「ホーム」の ⌥ 代替として隠している。
        standardLocationItem(.home)
            .modifierKeyAlternate(.option) { standardLocationItem(.library) }
        standardLocationItem(.computer)
        standardLocationItem(.iCloudDrive)
        standardLocationItem(.shared)
        standardLocationItem(.applications)
        standardLocationItem(.utilities)
        Divider()
        // ここから下は qooLibrary 独自。Finder のサイドバー相当にあたるのが
        // 登録済みのライブラリ／テンポラリフォルダで、1 件も登録が無い
        // グループはサブメニュー自体を出さない。
        if !registeredFolders.library.isEmpty {
            Menu("folderTree.libraryFolders", systemImage: "books.vertical") {
                registeredFolderButtons(registeredFolders.library)
            }
        }
        if !registeredFolders.temporary.isEmpty {
            Menu("folderTree.temporaryFolders", systemImage: "tray") {
                registeredFolderButtons(registeredFolders.temporary)
            }
        }
        Divider()
        Menu("menu.go.recentFolders", systemImage: "clock") {
            let recents = recentFolders.existingFolders
            if recents.isEmpty {
                Button("menu.go.noRecentFolders") {}
                    .disabled(true)
            } else {
                ForEach(recents) { entry in
                    Button(entry.displayName) {
                        actions?.navigate(entry.url, .volume)
                    }
                    .disabled(actions == nil)
                }
                Divider()
                Button("menu.go.clearRecentFolders") { recentFolders.clear() }
            }
        }
        Divider()
        Button("goToFolder.menuItem", systemImage: "arrow.forward.folder") { actions?.beginGoToFolder() }
            .fixedKeyboardShortcut(.goToFolder)
            .disabled(actions == nil)
    }

    /// 標準の場所 1 件。Finder と同じアイコン・同じキーを持つ。
    private func standardLocationItem(_ location: StandardLocation) -> some View {
        Button(location.titleKey, systemImage: location.systemImage) {
            actions?.goToStandardLocation(location)
        }
        .fixedKeyboardShortcut(location.action)
        .disabled(actions == nil)
    }

    @ViewBuilder
    private func registeredFolderButtons(_ entries: [RegisteredFolderIndex.Entry]) -> some View {
        ForEach(entries) { entry in
            Button(entry.displayName) {
                actions?.navigate(entry.url, .registeredFolder(id: entry.id, rootURL: entry.url))
            }
            .disabled(actions == nil)
        }
    }
}

/// Edit メニューの Cut/Copy/Paste/すべて選択 [Finder/Edit メニュー整備]。
/// 標準の `.pasteboard` プレースホルダを丸ごと置き換える（`.commands` 呼び出し
/// 箇所のコメント参照）。Undo/Redo は別グループ（`UndoRedoMenuCommands`）の
/// ままにしている（`CommandStack` はアプリ全体で単一のシングルトンのため
/// `FocusedValue` を経由する必要が無く、置き換える理由も無い）。
private struct EditMenuCommands: View {
    @FocusedValue(\.folderMenuActions) private var actions

    var body: some View {
        Button("action.cut", systemImage: "scissors") {
            // 入力中なら文字を切り取る［ユーザー指定、`TextEditingKeyRouting` 参照］。
            guard !TextEditingKeyRouting.handledCut() else { return }
            actions?.cut()
        }
            .disabled(actions?.canCut != true)
            .fixedKeyboardShortcut(.cut)
        Button("action.copy", systemImage: "document.on.document") {
            guard !TextEditingKeyRouting.handledCopy() else { return }
            actions?.copy()
        }
            .disabled(actions?.canCopy != true)
            .fixedKeyboardShortcut(.copy)
            // 以下 3 つはいずれも Finder と同じ ⌥ 代替 [Finder 対比監査。
            // ⌥ 代替の一覧と、対応しなかった項目の理由は CLAUDE.md
            // 「Finder の ⌥ 代替項目」節を参照]。
            .modifierKeyAlternate(.option) {
                Button("folder.copyPath", systemImage: "document.on.document") { actions?.copyPath() } // [FM-10]
                    .fixedKeyboardShortcut(.copyPath)
                    .disabled(actions?.canCopyPath != true)
            }
        Button("action.paste", systemImage: "document.on.clipboard") {
            guard !TextEditingKeyRouting.handledPaste() else { return }
            actions?.paste()
        }
            .disabled(actions?.canPaste != true)
            .fixedKeyboardShortcut(.paste)
            .modifierKeyAlternate(.option) {
                Button("folder.moveItemsHere", systemImage: "folder") { actions?.moveItemsHere() }
                    .fixedKeyboardShortcut(.moveItemsHere)
                    .disabled(actions?.canPaste != true)
            }
        Divider()
        Button("action.selectAll", systemImage: "character.textbox") {
            guard !TextEditingKeyRouting.handledSelectAll() else { return }
            actions?.selectAll()
        }
            .disabled(actions?.canSelectAll != true)
            .fixedKeyboardShortcut(.selectAll)
            .modifierKeyAlternate(.option) {
                Button("action.deselectAll", systemImage: "character.textbox") { actions?.deselectAll() }
                    .fixedKeyboardShortcut(.deselectAll)
                    .disabled(actions?.canDeselectAll != true)
            }
    }
}

/// Edit メニューの「取り消す」/「やり直す」[UD-06]。実際のキーボード
/// ショートカット（⌘Z/⇧⌘Z）はここでは付けない
/// — `DefaultKeyBindings`/`KeyBindingButtons`（`MainWindowView` の
/// `.background` 参照）がアプリの唯一の配線経路になるようにするため
/// [設計判断、1-8 以来の他のショートカットと同じ仕組みに揃える]。ここは
/// 動的なタイトルを出す発見可能なメニュー項目としての役割のみを持つ。
private struct UndoRedoMenuCommands: View {
    // `Command.displayName`（`QooApplication`）は現状 UI 文字列扱いで日本語
    // 固定のまま。ここではその前後に付く助詞部分だけをローカライズする
    // [1-12 ローカライズ方針の適用範囲外、CLAUDE.md「既知の未対応範囲」参照]。
    @Environment(\.locale) private var locale

    var body: some View {
        let stack = CommandStack.shared
        Button(undoTitle(stack.undoTitle), systemImage: "arrow.uturn.backward") {
            // 一覧への反映は `FileOperationService` が
            // `DirectoryChangeHub` へ伝える [10章 §10.0]。取り消しも
            // 結局そのサービスを通ってファイルを動かすため、ここで
            // 別途知らせる必要は無い。
            Task { await Self.present(await CommandStack.shared.undo(), isUndo: true) }
        }
        .fixedKeyboardShortcut(.undo)
        .disabled(!stack.canUndo)

        Button(redoTitle(stack.redoTitle), systemImage: "arrow.uturn.forward") {
            Task { await Self.present(await CommandStack.shared.redo(), isUndo: false) }
        }
        .fixedKeyboardShortcut(.redo)
        .disabled(!stack.canRedo)
    }

    /// **取り消し・やり直しの失敗をユーザーに見せる** [ER-01]［監査で発見］。
    ///
    /// 以前は `CommandStack` がログと操作履歴に書くだけで、⌘Z が失敗しても
    /// **画面には何も出なかった**（操作履歴には閲覧 UI が無い）。
    /// ユーザーには「取り消したはずのファイルが戻っていない」という結果だけが
    /// 残る。取り消しは「やり直しがきく」という前提を支える機能なので、
    /// その前提が崩れたことこそ真っ先に伝えなければならない。
    ///
    /// 提示を `CommandStack` の中で行わないのは、そこが `NotificationRouter`
    /// を待つとテストで永久に返らないため（`CommandStack.undo()` のコメント参照）。
    @MainActor
    private static func present(_ outcome: UndoOutcome, isUndo: Bool) async {
        guard outcome.needsAttention else { return }
        let locale = AppLanguage.effectiveLocale
        let title = String(
            localized: isUndo ? "error.undoFailed" : "error.redoFailed", locale: locale
        )
        let body: String
        switch outcome {
        case let .partial(operationName, succeeded, failed):
            var lines = [operationName, ""]
            lines.append(String(
                format: String(localized: "error.partialCounts", locale: locale), succeeded, failed.count
            ))
            for item in failed.prefix(5) { lines.append("• \(item.item): \(item.reason)") }
            if failed.count > 5 {
                lines.append(String(
                    format: String(localized: "error.partialMore", locale: locale), failed.count - 5
                ))
            }
            body = lines.joined(separator: "\n")
        case let .failed(operationName, reason):
            body = "\(operationName)\n\n\(reason)"
        case .complete, .nothingToDo:
            return
        }
        await NotificationRouter.shared.present(NotificationItem(
            category: .error, severity: .sheet, title: title, body: body
        ))
    }

    private func undoTitle(_ operationName: String?) -> String {
        guard let operationName else { return String(localized: "action.undo", locale: locale) }
        let template = String(localized: "menu.undoWithName", locale: locale)
        return String(format: template, operationName)
    }

    private func redoTitle(_ operationName: String?) -> String {
        guard let operationName else { return String(localized: "action.redo", locale: locale) }
        let template = String(localized: "menu.redoWithName", locale: locale)
        return String(format: template, operationName)
    }
}
