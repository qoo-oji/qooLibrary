import SwiftUI

/// File/Edit メニューバー（`qooLibraryApp.swift` の `.commands`）から、
/// 現在アクティブなウインドウの `FolderContentView` が持つファイル操作
/// アクションを呼び出すための橋渡し [Finder/Edit メニュー整備、要件定義書には
/// 無いユーザー要望への対応]。
///
/// メニューバーの `.commands` はシーン構築時に評価され、個々のウインドウ・
/// タブが持つ状態（現在のフォルダ・選択）を直接参照できない。`@FocusedValue`
/// はこの用途のための SwiftUI 標準機構で、キーウインドウのビュー階層に
/// 置かれた値を読み取れる。`CommandStack`（Undo/Redo）のようなアプリ全体で
/// 単一のシングルトンとは異なり、フォルダ・選択はウインドウ／タブごとに
/// 異なるため、この橋渡しが必要になる。
///
/// `.focusedValue`（キーボードフォーカスを持つ特定のコントロールのみに
/// 見える）ではなく `.focusedSceneValue`（そのウインドウのシーン全体で
/// 見える）を使う — ツールバーのボタンを操作した直後などフォーカスが
/// 一覧から外れている場面でも File/Edit メニューが機能する必要があるため。
struct FolderMenuActions {
    var canOpen = false
    var canQuickLook = false
    var canNewFolder = false
    var canNewFolderWithSelection = false
    var canRename = false
    var canDuplicate = false
    var canMakeAlias = false
    var canCompress = false
    /// Finder の「パスワード付きで圧縮」（「圧縮」の ⌥ 代替）[Finder 対比監査]。
    /// `canCompress`（選択があるか）に加えて、既定の圧縮形式が暗号化に対応して
    /// いるか（`FolderOperations.canCompressWithPassword`）にも依存する。
    /// メニューバーではこのフラグで項目を**無効化**する（項目自体を消さない
    /// 理由は `FileMenuCommands` のコメント参照）。
    var canCompressWithPassword = false
    var canMoveToTrash = false
    /// [FM-14] 完全削除。`canMoveToTrash` と条件は同じだが、意味が異なる
    /// （取り消せない操作）ため別のフラグとして持つ。
    var canDeletePermanently = false
    var canCopyPath = false
    var canCopy = false
    var canCut = false
    var canPaste = false
    var canSelectAll = false
    /// Finder の「すべてを選択解除」（「すべてを選択」の ⌥ 代替）[Finder 対比監査]。
    var canDeselectAll = false
    var canRevealInFinder = false
    /// ターミナルで開く [ユーザー要望]。選択が無ければ現在のフォルダが対象に
    /// なるため、フォルダを表示している限り常に有効。
    var canOpenInTerminal = false

    var open: () -> Void = {}
    var quickLook: () -> Void = {}
    var newFolder: () -> Void = {}
    var newFolderWithSelection: () -> Void = {}
    var rename: () -> Void = {}
    var duplicate: () -> Void = {}
    var makeAlias: () -> Void = {}
    var compress: () -> Void = {}
    var compressWithPassword: () -> Void = {}
    var moveToTrash: () -> Void = {}
    var deletePermanently: () -> Void = {}
    var copyPath: () -> Void = {}
    var copy: () -> Void = {}
    var cut: () -> Void = {}
    var paste: () -> Void = {}
    var moveItemsHere: () -> Void = {}
    var selectAll: () -> Void = {}
    var deselectAll: () -> Void = {}
    var revealInFinder: () -> Void = {}
    var openInTerminal: () -> Void = {}

    // MARK: - 表示メニュー [1-16]

    /// リスト表示の並び替え [LV-01]。中央ペインのカラムヘッダ・空きスペースの
    /// 右クリックメニューと同じ状態を、メニューバーからも操作できるようにする。
    var sortKey: FolderSortComparator.Key = .name
    var sortAscending = true
    var setSortKey: (FolderSortComparator.Key) -> Void = { _ in }
    var setSortAscending: (Bool) -> Void = { _ in }
    /// カラムの表示/非表示 [LV-02]。
    var visibleColumns: Set<FolderColumn> = []
    var setColumnVisible: (FolderColumn, Bool) -> Void = { _, _ in }
    /// フォルダを上にまとめる [LV-03]。
    var groupFoldersAtTop = false
    var setGroupFoldersAtTop: (Bool) -> Void = { _ in }
    /// 並び替え・カラムはリスト表示のときだけ意味を持つ。アイコン表示中は
    /// メニュー項目を無効化する（Finder も同様に、表示モードに応じて
    /// 「表示オプション」の中身が変わる）。
    var isListStyleActive = false
}

/// リスト表示のカラム [LV-02]。名前列は常に表示されるため含めない。
///
/// 中央ペインの漏斗アイコンメニュー・環境設定「表示」タブ・表示メニューの
/// 3 箇所が同じ `UserDefaults` キーを共有しており、この enum はそのキーを
/// 1 箇所にまとめて取り違えを防ぐためのもの [1-16]。
enum FolderColumn: String, CaseIterable, Identifiable, Sendable {
    case modificationDate, size, kind, creationDate, addedDate

    var id: String { rawValue }

    var storageKey: String {
        switch self {
        case .modificationDate: "qoo.folderList.showModificationDateColumn"
        case .size: "qoo.folderList.showSizeColumn"
        case .kind: "qoo.folderList.showKindColumn"
        case .creationDate: "qoo.folderList.showCreationDateColumn"
        case .addedDate: "qoo.folderList.showAddedDateColumn"
        }
    }

    /// 表示名は既存のカラムヘッダ・環境設定と同じローカライズキーを再利用する。
    var localizationKey: LocalizedStringKey {
        switch self {
        case .modificationDate: "column.modificationDate"
        case .size: "column.size"
        case .kind: "column.kind"
        case .creationDate: "column.creationDate"
        case .addedDate: "column.addedDate"
        }
    }
}

private struct FolderMenuActionsKey: FocusedValueKey {
    typealias Value = FolderMenuActions
}

extension FocusedValues {
    var folderMenuActions: FolderMenuActions? {
        get { self[FolderMenuActionsKey.self] }
        set { self[FolderMenuActionsKey.self] = newValue }
    }
}
