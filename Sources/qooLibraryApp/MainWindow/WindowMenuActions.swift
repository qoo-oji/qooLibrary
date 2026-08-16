import SwiftUI

/// 「移動」メニュー（`qooLibraryApp.swift` の `.commands`）から、現在アクティブな
/// ウインドウのナビゲーション操作を呼び出すための橋渡し [1-16 移動メニュー]。
///
/// `FolderMenuActions`（File/Edit メニュー用、`FolderContentView` が公開）と
/// 同じ `@FocusedValue` パターンだが、**公開するのは `MainWindowView`**。
/// 戻る/進む/上の階層への履歴と現在のタブは `WindowState`（ウインドウ単位）が
/// 持っており、`FolderContentView` は通知を受けて呼ぶだけの側だからで、
/// 状態を持っている場所から公開するほうが素直になる。
///
/// `.focusedValue` ではなく `.focusedSceneValue` を使う理由は
/// `FolderMenuActions` と同じ（ツールバー操作直後などフォーカスが一覧から
/// 外れている場面でもメニューが機能する必要があるため）。
struct WindowMenuActions {
    var canGoBack = false
    var canGoForward = false
    var canGoToParent = false

    var goBack: () -> Void = {}
    var goForward: () -> Void = {}
    var goToParent: () -> Void = {}
    var goHome: () -> Void = {}
    /// 「フォルダへ移動…」（⇧⌘G）のダイアログを開く [`GoToFolderDialog`]。
    var beginGoToFolder: () -> Void = {}
    /// 登録フォルダ・最近使ったフォルダなど、行き先が確定している移動。
    /// `root` を伴うのは、ライブラリ／テンポラリから入った場合に
    /// 「1階層上へ」の境界とフォルダツリーの自動展開スコープを正しく保つため
    /// [`NavigationRoot` 参照]。
    var navigate: (URL, NavigationRoot) -> Void = { _, _ in }

    // MARK: - ファイルメニュー [1-16 メニュー抜け監査]

    /// 新規タブ（⌘T）。1-8 で `ActionID.newTab` として登録し
    /// `KeyBindingButtons` で配線していたが、**メニューバーには項目が無く
    /// キーを知らないと辿り着けなかった** [ユーザー指摘]。Finder もファイル
    /// メニューに持っているため追加した。
    var newTab: () -> Void = {}
    /// 検索フィールドへフォーカス（⌘F）。`newTab` と同じ理由で追加
    /// [ユーザー指摘]。Finder のファイルメニュー「検索」に相当する。
    var focusSearch: () -> Void = {}

    // MARK: - 表示メニュー [1-16]

    /// 表示モードの直接指定 [LV-04]。Finder の ⌘1/⌘2 に合わせ、トグルでは
    /// なく「どちらにするか」を指定する（`ActionID.displayAsIcons`/`.displayAsList`）。
    var listStyle: ListStyle = .list
    var setListStyle: (ListStyle) -> Void = { _ in }
    /// アイコンサイズ [IV-04]。上限・下限に達したら該当の項目を無効化する。
    var canIncreaseIconSize = false
    var canDecreaseIconSize = false
    var increaseIconSize: () -> Void = {}
    var decreaseIconSize: () -> Void = {}
    /// ペイン・バーの表示状態。Finder に倣い、メニュー項目名を
    /// 「表示」/「隠す」で出し分けるために現在の状態も渡す。
    var isSidebarVisible = true
    var isInspectorVisible = true
    var isPathBarVisible = true
    var isStatusBarVisible = true
    var toggleSidebar: () -> Void = {}
    var toggleInspector: () -> Void = {}
    var togglePathBar: () -> Void = {}
    var toggleStatusBar: () -> Void = {}

    // MARK: - 取り出す [1-16]

    /// 現在表示中のフォルダが乗っているボリュームが取り出せるか。
    var canEject = false
    /// その相手がネットワーク越しか [NV-96]。**呼び名だけを変える**ために持つ
    /// ——Finder は SMB 等を「取り出す」ではなく「接続解除」と呼ぶ。
    var isEjectTargetNetworkVolume = false
    /// 取り出せるボリュームが 1 本でもマウントされているか
    /// （「すべてを取り出す」用。現在地とは無関係）。
    var canEjectAll = false
    var eject: () -> Void = {}
    var ejectAll: () -> Void = {}
}

private struct WindowMenuActionsKey: FocusedValueKey {
    typealias Value = WindowMenuActions
}

extension FocusedValues {
    var windowMenuActions: WindowMenuActions? {
        get { self[WindowMenuActionsKey.self] }
        set { self[WindowMenuActionsKey.self] = newValue }
    }
}
