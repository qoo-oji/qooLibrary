import Foundation

/// 修飾キーの組み合わせ。`SwiftUI.EventModifiers` に相当するが、`QooKit` は
/// Foundation 以外に依存できない [A-01] ため独自定義する。View 層でだけ
/// `SwiftUI.EventModifiers` に変換する。
public struct KeyModifiers: OptionSet, Sendable, Codable, Equatable, Hashable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let command = KeyModifiers(rawValue: 1 << 0)
    public static let shift = KeyModifiers(rawValue: 1 << 1)
    public static let option = KeyModifiers(rawValue: 1 << 2)
    public static let control = KeyModifiers(rawValue: 1 << 3)
}

/// キー1つ + 修飾キーの組み合わせ [13章 §13.6]。`key` は単一文字（"r" 等）
/// または記号キー名（"return"/"space"/"delete"/"up"/"down"/"left"/"right"/
/// "escape"/"tab"）のいずれか。`SwiftUI.KeyboardShortcut` への変換は
/// View 層（`qooLibraryApp`）でのみ行う [設計判断、A-01 との整合]。
public struct KeyCombo: Sendable, Codable, Equatable, Hashable {
    public let key: String
    public let modifiers: KeyModifiers

    public init(key: String, modifiers: KeyModifiers = []) {
        self.key = key
        self.modifiers = modifiers
    }
}

/// キーバインドを割り当てる対象の操作 [MX-08 の `ManualCommandID` とは別物、
/// 13章 §13.6 KB2-03 参照]。フェーズ 1-1〜1-7 で実装済みの操作と、
/// まだ実装されていない操作（今後のフェーズで機能が追加された時点で実際に
/// 配線する）の両方を含む。一覧を完全にしておくことで、未実装のうちから
/// 衝突検出・既定に戻す機能が意味を持つ。
public enum ActionID: String, Sendable, Codable, CaseIterable {
    case newTab
    case open
    /// Finder の「選択項目を開く」（⌘↓）[1-16 移動メニューの Finder 準拠]。
    /// `open`（Return）と同じ動作で、Finder に合わせたキーを別に持たせたもの。
    case openSelection
    case goToParent
    /// Finder の「内包しているフォルダを新規ウインドウで開く」（⌃⌘↑）。
    case goToParentInNewWindow
    /// Finder の「内包しているフォルダ」の ⌥ 代替（⌥⌘↑）。上の階層を新規
    /// ウインドウで開き、現在のウインドウを閉じる。
    case goToParentAndCloseWindow
    case goBack
    case goForward
    /// Finder の「フォルダへ移動…」（⇧⌘G）[1-16 移動メニュー]。パスを直接
    /// 入力して移動する。
    case goToFolder
    /// 標準の場所へ移動する [1-16 移動メニューの Finder 準拠]。キーはいずれも
    /// Finder と同一。実際の行き先とアクセス要件は `StandardLocation`
    /// （`Sources/qooLibraryApp/MainWindow/StandardLocations.swift`）が持つ。
    case goToHome
    case goToDocuments
    case goToDesktop
    case goToDownloads
    case goToLibrary
    case goToComputer
    case goToICloudDrive
    case goToShared
    case goToApplications
    case goToUtilities
    case rename
    case moveToTrash
    case deletePermanently
    case quickLook
    case toggleThumbnails
    case newFolder
    case copy
    /// Finder の「パス名をコピー」（「コピー」の ⌥ 代替、⌥⌘C）[FM-10]。
    case copyPath
    case paste
    /// Finder の「ここに項目を移動」（「ペースト」の ⌥ 代替、⌥⌘V）。
    case moveItemsHere
    case cut
    case focusSearch
    /// 表示モードの直接指定（⌘1 / ⌘2）[1-16 表示メニュー]。
    ///
    /// **旧 `toggleDisplayMode` を置き換えたもの。** Finder は表示モードを
    /// ⌘1〜⌘4 の直接指定で切り替え「トグル」の概念自体を持たないため、
    /// Finder 準拠のメニューを用意する段になって、トグル 1 個という設計
    /// そのものが合わないと判明した（旧ケースはどこからも呼ばれておらず
    /// 既定キーも空だった）。
    case displayAsIcons
    case displayAsList
    /// アイコンサイズの拡大・縮小（⌘+ / ⌘-）[IV-04][1-16 表示メニュー]。
    case increaseIconSize
    case decreaseIconSize
    /// ボリュームの取り出し [1-16]。`ejectAll` は Finder の「取り出す」の
    /// ⌥ 代替「すべてを取り出す」に対応し、Finder 自身と同じく既定キーは持たない。
    case eject
    case ejectAll
    /// ペイン・バーの表示切替 [1-16 表示メニュー]。いずれも Finder 標準キー。
    case toggleSidebar
    case toggleInspector
    case togglePathBar
    case toggleStatusBar
    case clearLabelFilter
    case moveToVault
    case undo
    case redo
    /// [1-12b フォローアップ] Finder/Edit メニュー整備の一環で追加。
    case selectAll
    /// Finder の「すべてを選択解除」（「すべてを選択」の ⌥ 代替、⌥⌘A）。
    case deselectAll
    case duplicate
    case makeAlias
    case compress
    /// Finder の「選択項目で新規フォルダを作成」（既定は ⌃⌘N、既定キーの
    /// 割り当ては本アプリでは行わない。File メニューからのみ呼べれば十分と
    /// 判断したため、`combos: []` にしている）。
    case newFolderWithSelection
}

public struct KeyBinding: Sendable, Codable, Identifiable, Equatable {
    public let id: ActionID
    /// この操作に割り当てられたキーの組み合わせ。1つの操作に複数のキーを
    /// 割り当てられる（例: 戻る = ⌘[ と ⌘← の両方、Finder は ⌘[ のみだが
    /// ブラウザ流の ⌘← も併用したいという実運用上の要望から追加）。
    /// 空配列は「未割り当て」。
    public var combos: [KeyCombo]
    public let isDestructive: Bool
    /// ユーザーが環境設定「キーボード」タブで変更できるか [ユーザー判断]。
    ///
    /// `false` は **Finder と同じキーに揃えてある操作**。これらは対応する
    /// メニュー項目自身が `.keyboardShortcut` を持ち、**メニューにキーが
    /// 表示される**（`KeyBindingButtons` の不可視ボタン経由では表示されない）。
    /// 同じキーを二重に登録しないため、変更可能なものと違って
    /// `KeyBindingButtons` は使わない（複数キーを持つ `goBack`/`goForward` の
    /// 2 つ目以降だけは例外、`KeyBindingButtons.skipsPrimaryCombo` 参照）。
    ///
    /// 変更できなくても `DefaultKeyBindings.all` には載せたままにする —
    /// キーの定義を 1 箇所に保ち、変更可能な操作との衝突検出
    /// （`KeyBindingStore.conflicts(of:)`）も効かせるため。
    public let isCustomizable: Bool

    public init(
        id: ActionID, combos: [KeyCombo],
        isDestructive: Bool = false, isCustomizable: Bool = true
    ) {
        self.id = id
        self.combos = combos
        self.isDestructive = isDestructive
        self.isCustomizable = isCustomizable
    }
}

public protocol KeyBindingStore: Sendable {
    func binding(for action: ActionID) -> KeyBinding
    func setBinding(_ combos: [KeyCombo], for action: ActionID) throws // [KB-01]
    func conflicts(of combo: KeyCombo) -> [ActionID] // [KB-04]
    func resetToDefaults() // [KB-05]
}

public enum KeyBindingError: Error, Sendable, Equatable {
    /// 完全削除など、破壊的操作へキーバインドを割り当てようとした
    /// （既定で未割り当てにする方針、FM-16）。呼び出し側が明示的に許可
    /// しない限り拒否する余地を残すためのエラーだが、現状はどの操作も
    /// 割り当て自体は禁止していない。将来の UI（1-12）向けの土台。
    case destructiveActionRequiresConfirmation(ActionID)
}

/// 既定キーバインド一覧 [13章 §13.6「既定キーバインド」]。実際に配線済みの
/// 操作は 1-8 時点で `open`/`rename`/`moveToTrash`/`newFolder` のみ
/// （`Sources/qooLibraryApp/MainWindow/FolderContentView.swift` 参照）。
/// 他は対応する機能（検索・表示モード・ラベルフィルタ・保管庫・Undo・
/// Quick Look・サムネイル等）が実装されるフェーズで実際に配線する。
public enum DefaultKeyBindings {
    public static let all: [KeyBinding] = [
        // タブバーは既定で1タブ時に非表示のため、新規タブを開く手段が
        // ショートカット以外に無くならないよう用意する
        // [MW2-04 の設計判断、タブバー auto-hide 対応時に追加]。
        KeyBinding(id: .newTab, combos: [KeyCombo(key: "t", modifiers: .command)]),
        KeyBinding(id: .open, combos: [KeyCombo(key: "return")]), // [KB-02]
        KeyBinding(id: .openSelection, combos: [KeyCombo(key: "down", modifiers: .command)], isCustomizable: false),
        KeyBinding(id: .goToParent, combos: [KeyCombo(key: "up", modifiers: .command)]),
        KeyBinding(
            id: .goToParentInNewWindow,
            combos: [KeyCombo(key: "up", modifiers: [.command, .control])], isCustomizable: false
        ),
        KeyBinding(
            id: .goToParentAndCloseWindow,
            combos: [KeyCombo(key: "up", modifiers: [.command, .option])], isCustomizable: false
        ),
        // 戻る/進む: Finder 流の ⌘[ / ⌘] に加えて、ブラウザ流の ⌘← / ⌘→ も
        // 併用したいという実運用上の要望により両方を既定にした
        // [実機検証: ⌘] が他アプリのショートカットと競合する環境があったため、
        // 同じ操作に複数のキーを割り当てられる余地が必要だと判明]。
        // **2 つ目の ⌘←/⌘→ だけは `KeyBindingButtons` が配線する**
        // （メニュー項目が持てる `.keyboardShortcut` は 1 つだけのため、
        // メニューには 1 つ目の ⌘[/⌘] が表示される）。
        KeyBinding(id: .goBack, combos: [
            KeyCombo(key: "[", modifiers: .command),
            KeyCombo(key: "left", modifiers: .command),
        ], isCustomizable: false),
        KeyBinding(id: .goForward, combos: [
            KeyCombo(key: "]", modifiers: .command),
            KeyCombo(key: "right", modifiers: .command),
        ], isCustomizable: false),
        KeyBinding(id: .goToFolder, combos: [KeyCombo(key: "g", modifiers: [.command, .shift])], isCustomizable: false),
        // 標準の場所 [1-16 移動メニューの Finder 準拠]。キーはすべて Finder と
        // 同一のため変更不可（メニューにそのまま表示される）。
        KeyBinding(id: .goToHome, combos: [KeyCombo(key: "h", modifiers: [.command, .shift])], isCustomizable: false),
        KeyBinding(id: .goToDocuments, combos: [KeyCombo(key: "o", modifiers: [.command, .shift])], isCustomizable: false),
        KeyBinding(id: .goToDesktop, combos: [KeyCombo(key: "d", modifiers: [.command, .shift])], isCustomizable: false),
        KeyBinding(id: .goToDownloads, combos: [KeyCombo(key: "l", modifiers: [.command, .option])], isCustomizable: false),
        // **ライブラリだけは「ホーム + ⌥」でなければならない**（⇧⌘L ではない）。
        //
        // これは代替項目の成立条件そのもの [実測]。**代替は「基底と同じキー等価を
        // 持ち、修飾マスクだけが違う」ときにだけ現れる。** ⇧⌘L を付けると
        // キー等価が `L` になって基底（ホーム = ⇧⌘H）と組にならず、⌥ を押しても
        // 一生出てこない（実機で踏んだ）。同じ理由で「内包しているフォルダ」の
        // 2 つの代替は動く——あちらは 3 つとも ↑ を共有している。
        //
        // なお **Finder 自身のライブラリはキーを持たない**（実行時メニューを AX で
        // 採取して確認: `AXMenuItemCmdChar` が空、修飾マスクは「⌥ のみ・⌘ を
        // 含まない」）。⇧⌘L だと思い込んでいたのは古い macOS の記憶だった。
        // SwiftUI の `modifierKeyAlternate` は基底のキー等価を引き継ぐため
        // 「キー無し」にはできず、⌥⇧⌘H が実際に効く。ここを空にすると
        // 環境設定の一覧だけが「未割り当て」と嘘をつくので、実態に合わせる。
        KeyBinding(
            id: .goToLibrary,
            combos: [KeyCombo(key: "h", modifiers: [.command, .shift, .option])], isCustomizable: false
        ),
        KeyBinding(id: .goToComputer, combos: [KeyCombo(key: "c", modifiers: [.command, .shift])], isCustomizable: false),
        KeyBinding(id: .goToICloudDrive, combos: [KeyCombo(key: "i", modifiers: [.command, .shift])], isCustomizable: false),
        KeyBinding(id: .goToShared, combos: [KeyCombo(key: "s", modifiers: [.command, .shift])], isCustomizable: false),
        KeyBinding(id: .goToApplications, combos: [KeyCombo(key: "a", modifiers: [.command, .shift])], isCustomizable: false),
        KeyBinding(id: .goToUtilities, combos: [KeyCombo(key: "u", modifiers: [.command, .shift])], isCustomizable: false),
        // **Finder の「名前を変更」にキーは無い**（⌘R は「オリジナルを表示」）。
        // ⌘R は本アプリ独自の割り当てなので変更可能なまま残す。
        KeyBinding(id: .rename, combos: [KeyCombo(key: "r", modifiers: .command)]), // [KB-03]
        KeyBinding(id: .moveToTrash, combos: [KeyCombo(key: "delete", modifiers: .command)], isCustomizable: false),
        KeyBinding(id: .deletePermanently, combos: [], isDestructive: true), // [FM-16]
        // Finder のメニューは ⌘Y だが、本アプリは Space（Finder の実挙動と同じ）
        // を既定にしている。メニュー表示できる形ではないため変更可能なまま。
        KeyBinding(id: .quickLook, combos: [KeyCombo(key: "space")]), // [QL-01]
        KeyBinding(id: .toggleThumbnails, combos: [KeyCombo(key: "i", modifiers: [.command, .control])]), // [DS-02]
        KeyBinding(id: .newFolder, combos: [KeyCombo(key: "n", modifiers: [.command, .shift])], isCustomizable: false),
        KeyBinding(id: .copy, combos: [KeyCombo(key: "c", modifiers: .command)], isCustomizable: false),
        // ⌥ 代替 3 件はいずれも Finder 標準のキー [Finder 対比監査]。⌥ 代替の
        // メニュー項目でも `.keyboardShortcut` は機能する（実測で確認済み）。
        KeyBinding(id: .copyPath, combos: [KeyCombo(key: "c", modifiers: [.command, .option])], isCustomizable: false),
        KeyBinding(id: .paste, combos: [KeyCombo(key: "v", modifiers: .command)], isCustomizable: false),
        KeyBinding(id: .moveItemsHere, combos: [KeyCombo(key: "v", modifiers: [.command, .option])], isCustomizable: false),
        KeyBinding(id: .cut, combos: [KeyCombo(key: "x", modifiers: .command)], isCustomizable: false),
        KeyBinding(id: .focusSearch, combos: [KeyCombo(key: "f", modifiers: .command)], isCustomizable: false),
        // 表示メニュー [1-16]。いずれも Finder 標準のキーに合わせている
        // （⌘1/⌘2 は Finder のアイコン表示/リスト表示、本アプリはこの 2 種類
        // のみのため ⌘3/⌘4 に当たるものは無い）。
        KeyBinding(id: .displayAsIcons, combos: [KeyCombo(key: "1", modifiers: .command)], isCustomizable: false),
        KeyBinding(id: .displayAsList, combos: [KeyCombo(key: "2", modifiers: .command)], isCustomizable: false),
        KeyBinding(id: .increaseIconSize, combos: [KeyCombo(key: "+", modifiers: .command)], isCustomizable: false),
        KeyBinding(id: .decreaseIconSize, combos: [KeyCombo(key: "-", modifiers: .command)], isCustomizable: false),
        KeyBinding(id: .toggleSidebar, combos: [KeyCombo(key: "s", modifiers: [.command, .control])], isCustomizable: false),
        // Finder の「プレビューを隠す」（⇧⌘P）に相当。本アプリでは常設の
        // インスペクタ（右ペイン、1-10）がその役割。
        KeyBinding(id: .toggleInspector, combos: [KeyCombo(key: "p", modifiers: [.command, .shift])], isCustomizable: false),
        KeyBinding(id: .togglePathBar, combos: [KeyCombo(key: "p", modifiers: [.command, .option])], isCustomizable: false),
        KeyBinding(id: .toggleStatusBar, combos: [KeyCombo(key: "/", modifiers: .command)], isCustomizable: false),
        KeyBinding(id: .eject, combos: [KeyCombo(key: "e", modifiers: .command)], isCustomizable: false),
        KeyBinding(id: .ejectAll, combos: []), // Finder も ⌥ 代替のみでキーは持たない
        KeyBinding(id: .clearLabelFilter, combos: [KeyCombo(key: "k", modifiers: [.command, .shift])]), // [LF-07]
        KeyBinding(id: .moveToVault, combos: [KeyCombo(key: "a", modifiers: [.command, .control])]),
        KeyBinding(id: .undo, combos: [KeyCombo(key: "z", modifiers: .command)], isCustomizable: false),
        KeyBinding(id: .redo, combos: [KeyCombo(key: "z", modifiers: [.command, .shift])], isCustomizable: false),
        KeyBinding(id: .selectAll, combos: [KeyCombo(key: "a", modifiers: .command)], isCustomizable: false),
        KeyBinding(id: .deselectAll, combos: [KeyCombo(key: "a", modifiers: [.command, .option])], isCustomizable: false),
        KeyBinding(id: .duplicate, combos: [KeyCombo(key: "d", modifiers: .command)], isCustomizable: false),
        // **[訂正] Finder の「エイリアスを作成」は ⌃⌘A であって ⌘L ではない**
        // （⌘L は古い macOS の Finder。macOS 26 の `MenuBar.nib` を実際に読んで
        // 確認した）。⌘L は本アプリ独自の割り当てとして残し、変更可能にしておく
        // —— Finder に合わせて ⌃⌘A へ変えると未実装の `moveToVault`（⌃⌘A）と
        // 衝突するため、機能追加のタイミングで併せて判断する。
        KeyBinding(id: .makeAlias, combos: [KeyCombo(key: "l", modifiers: .command)]),
        KeyBinding(id: .compress, combos: []), // Finder 自身も既定キーを割り当てていない
        KeyBinding(id: .newFolderWithSelection, combos: []), // File メニューからのみ呼べれば十分
    ]

    /// メニュー項目に `.keyboardShortcut` を付ける対象（＝変更不可のもの）。
    public static func isFixed(_ action: ActionID) -> Bool {
        !binding(for: action).isCustomizable
    }

    public static func binding(for action: ActionID) -> KeyBinding {
        all.first { $0.id == action } ?? KeyBinding(id: action, combos: [])
    }
}
