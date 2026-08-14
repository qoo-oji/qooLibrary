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
    var canMoveToTrash = false
    var canCopy = false
    var canCut = false
    var canPaste = false
    var canSelectAll = false
    var canRevealInFinder = false

    var open: () -> Void = {}
    var quickLook: () -> Void = {}
    var newFolder: () -> Void = {}
    var newFolderWithSelection: () -> Void = {}
    var rename: () -> Void = {}
    var duplicate: () -> Void = {}
    var makeAlias: () -> Void = {}
    var compress: () -> Void = {}
    var moveToTrash: () -> Void = {}
    var copy: () -> Void = {}
    var cut: () -> Void = {}
    var paste: () -> Void = {}
    var selectAll: () -> Void = {}
    var revealInFinder: () -> Void = {}
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
