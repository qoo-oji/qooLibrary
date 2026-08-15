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
    case goToParent
    case goBack
    case goForward
    /// Finder の「フォルダへ移動…」（⇧⌘G）[1-16 移動メニュー]。パスを直接
    /// 入力して移動する。
    case goToFolder
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

    public init(id: ActionID, combos: [KeyCombo], isDestructive: Bool = false) {
        self.id = id
        self.combos = combos
        self.isDestructive = isDestructive
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
        KeyBinding(id: .goToParent, combos: [KeyCombo(key: "up", modifiers: .command)]),
        // 戻る/進む: Finder 流の ⌘[ / ⌘] に加えて、ブラウザ流の ⌘← / ⌘→ も
        // 併用したいという実運用上の要望により両方を既定にした
        // [実機検証: ⌘] が他アプリのショートカットと競合する環境があったため、
        // 同じ操作に複数のキーを割り当てられる余地が必要だと判明]。
        KeyBinding(id: .goBack, combos: [
            KeyCombo(key: "[", modifiers: .command),
            KeyCombo(key: "left", modifiers: .command),
        ]),
        KeyBinding(id: .goForward, combos: [
            KeyCombo(key: "]", modifiers: .command),
            KeyCombo(key: "right", modifiers: .command),
        ]),
        KeyBinding(id: .goToFolder, combos: [KeyCombo(key: "g", modifiers: [.command, .shift])]), // Finder 標準
        KeyBinding(id: .rename, combos: [KeyCombo(key: "r", modifiers: .command)]), // [KB-03]
        KeyBinding(id: .moveToTrash, combos: [KeyCombo(key: "delete", modifiers: .command)]),
        KeyBinding(id: .deletePermanently, combos: [], isDestructive: true), // [FM-16]
        KeyBinding(id: .quickLook, combos: [KeyCombo(key: "space")]), // [QL-01]
        KeyBinding(id: .toggleThumbnails, combos: [KeyCombo(key: "i", modifiers: [.command, .control])]), // [DS-02]
        KeyBinding(id: .newFolder, combos: [KeyCombo(key: "n", modifiers: [.command, .shift])]),
        KeyBinding(id: .copy, combos: [KeyCombo(key: "c", modifiers: .command)]),
        // ⌥ 代替 3 件はいずれも Finder 標準のキー [Finder 対比監査]。
        // メニュー項目側に `.keyboardShortcut` は付けない（`KeyBindingButtons`
        // をアプリ唯一の配線経路にする 1-8 以来の方針）。
        KeyBinding(id: .copyPath, combos: [KeyCombo(key: "c", modifiers: [.command, .option])]),
        KeyBinding(id: .paste, combos: [KeyCombo(key: "v", modifiers: .command)]),
        KeyBinding(id: .moveItemsHere, combos: [KeyCombo(key: "v", modifiers: [.command, .option])]),
        KeyBinding(id: .cut, combos: [KeyCombo(key: "x", modifiers: .command)]),
        KeyBinding(id: .focusSearch, combos: [KeyCombo(key: "f", modifiers: .command)]),
        // 表示メニュー [1-16]。いずれも Finder 標準のキーに合わせている
        // （⌘1/⌘2 は Finder のアイコン表示/リスト表示、本アプリはこの 2 種類
        // のみのため ⌘3/⌘4 に当たるものは無い）。
        KeyBinding(id: .displayAsIcons, combos: [KeyCombo(key: "1", modifiers: .command)]),
        KeyBinding(id: .displayAsList, combos: [KeyCombo(key: "2", modifiers: .command)]),
        KeyBinding(id: .increaseIconSize, combos: [KeyCombo(key: "+", modifiers: .command)]),
        KeyBinding(id: .decreaseIconSize, combos: [KeyCombo(key: "-", modifiers: .command)]),
        KeyBinding(id: .toggleSidebar, combos: [KeyCombo(key: "s", modifiers: [.command, .control])]),
        // Finder の「プレビューを隠す」（⇧⌘P）に相当。本アプリでは常設の
        // インスペクタ（右ペイン、1-10）がその役割。
        KeyBinding(id: .toggleInspector, combos: [KeyCombo(key: "p", modifiers: [.command, .shift])]),
        KeyBinding(id: .togglePathBar, combos: [KeyCombo(key: "p", modifiers: [.command, .option])]),
        KeyBinding(id: .toggleStatusBar, combos: [KeyCombo(key: "/", modifiers: .command)]),
        KeyBinding(id: .eject, combos: [KeyCombo(key: "e", modifiers: .command)]), // Finder 標準
        KeyBinding(id: .ejectAll, combos: []), // Finder も ⌥ 代替のみでキーは持たない
        KeyBinding(id: .clearLabelFilter, combos: [KeyCombo(key: "k", modifiers: [.command, .shift])]), // [LF-07]
        KeyBinding(id: .moveToVault, combos: [KeyCombo(key: "a", modifiers: [.command, .control])]),
        KeyBinding(id: .undo, combos: [KeyCombo(key: "z", modifiers: .command)]),
        KeyBinding(id: .redo, combos: [KeyCombo(key: "z", modifiers: [.command, .shift])]),
        KeyBinding(id: .selectAll, combos: [KeyCombo(key: "a", modifiers: .command)]), // Finder 標準
        KeyBinding(id: .deselectAll, combos: [KeyCombo(key: "a", modifiers: [.command, .option])]), // Finder 標準
        KeyBinding(id: .duplicate, combos: [KeyCombo(key: "d", modifiers: .command)]), // Finder 標準
        KeyBinding(id: .makeAlias, combos: [KeyCombo(key: "l", modifiers: .command)]), // Finder 標準
        KeyBinding(id: .compress, combos: []), // Finder 自身も既定キーを割り当てていない
        KeyBinding(id: .newFolderWithSelection, combos: []), // File メニューからのみ呼べれば十分
    ]

    public static func binding(for action: ActionID) -> KeyBinding {
        all.first { $0.id == action } ?? KeyBinding(id: action, combos: [])
    }
}
