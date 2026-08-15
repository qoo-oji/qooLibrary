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
        // [ER-01] エラー・通知の提示はこのコントローラ1箇所からのみ行う
        // （`NotificationRouterPresenterController` のコメント参照）。
        NotificationRouterPresenterController.shared.start()
    }

    var body: some Scene {
        // `for: URL.self` にすることで、右クリックの「新規ウインドウで開く」から
        // `openWindow(value: url)` で特定のフォルダを初期表示にした新規ウインドウを
        // 開ける（⌘N・Dock アイコンからの起動など、値を指定しない経路は
        // 引き続き `nil` → 既定の仮想ホームになる）。
        WindowGroup(for: URL.self) { $initialFolder in
            MainWindowView(initialFolder: initialFolder)
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
        Button("preferences.windowTitle") {
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
        Button("diagnostics.exportMenuItem") {
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

    var body: some View {
        Button("action.newFolder") { actions?.newFolder() }
            .disabled(actions?.canNewFolder != true)
        Button("action.newFolderWithSelection") { actions?.newFolderWithSelection() }
            .disabled(actions?.canNewFolderWithSelection != true)
        Divider()
        Button("action.open") { actions?.open() }
            .disabled(actions?.canOpen != true)
        Button("action.quickLook") { actions?.quickLook() } // [QL-01]
            .disabled(actions?.canQuickLook != true)
        Divider()
        Button("action.rename") { actions?.rename() }
            .disabled(actions?.canRename != true)
        Button("folder.duplicate") { actions?.duplicate() }
            .disabled(actions?.canDuplicate != true)
        Button("folder.createAlias") { actions?.makeAlias() }
            .disabled(actions?.canMakeAlias != true)
        Button("action.compress") { actions?.compress() }
            .disabled(actions?.canCompress != true)
            // Finder と同じく ⌥ で「パスワード付きで圧縮」に入れ替わる
            // [Finder 対比監査]。
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
            .modifierKeyAlternate(.option) {
                Button("folder.compressHereWithPassword") { actions?.compressWithPassword() }
                    .disabled(actions?.canCompressWithPassword != true)
            }
        Divider()
        Button("folder.revealInFinder") { actions?.revealInFinder() }
            .disabled(actions?.canRevealInFinder != true)
        Divider()
        Button("folder.moveToTrash", role: .destructive) { actions?.moveToTrash() }
            .disabled(actions?.canMoveToTrash != true)
            // Finder と同じく ⌥ で「すぐに削除…」に入れ替わる [FM-14]
            // [Finder 対比監査]。**ここでは `.keyboardShortcut` を付けない**
            // （このファイル冒頭の方針どおり）ため、⌥⌘⌫ のような既定の
            // キー割り当ては生えない — [FM-16]「完全削除に既定のキーバインドを
            // 割り当てない」と矛盾しないことを実測でも確認済み（代替項目の
            // キー等価は入力不能な U+0000 になる）。
            .modifierKeyAlternate(.option) {
                Button("folder.deletePermanentlyEllipsis", role: .destructive) { actions?.deletePermanently() }
                    .disabled(actions?.canDeletePermanently != true)
            }
        // 「パス名をコピー」はここに退避していた「その他」サブメニューではなく、
        // Finder と同じく Edit メニューの「コピー」の ⌥ 代替になった
        // （`EditMenuCommands` 参照）。
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
        Button("action.cut") { actions?.cut() }
            .disabled(actions?.canCut != true)
        Button("action.copy") { actions?.copy() }
            .disabled(actions?.canCopy != true)
            // 以下 3 つはいずれも Finder と同じ ⌥ 代替 [Finder 対比監査。
            // ⌥ 代替の一覧と、対応しなかった項目の理由は CLAUDE.md
            // 「Finder の ⌥ 代替項目」節を参照]。
            .modifierKeyAlternate(.option) {
                Button("folder.copyPath") { actions?.copyPath() } // [FM-10]
                    .disabled(actions?.canCopyPath != true)
            }
        Button("action.paste") { actions?.paste() }
            .disabled(actions?.canPaste != true)
            .modifierKeyAlternate(.option) {
                Button("folder.moveItemsHere") { actions?.moveItemsHere() }
                    .disabled(actions?.canPaste != true)
            }
        Divider()
        Button("action.selectAll") { actions?.selectAll() }
            .disabled(actions?.canSelectAll != true)
            .modifierKeyAlternate(.option) {
                Button("action.deselectAll") { actions?.deselectAll() }
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
        Button(undoTitle(stack.undoTitle)) {
            Task {
                await CommandStack.shared.undo()
                SessionState.shared.reloadToken += 1 // [実機検証で発見: 一覧再読み込みの伝達漏れ]
            }
        }
        .disabled(!stack.canUndo)

        Button(redoTitle(stack.redoTitle)) {
            Task {
                await CommandStack.shared.redo()
                SessionState.shared.reloadToken += 1
            }
        }
        .disabled(!stack.canRedo)
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
