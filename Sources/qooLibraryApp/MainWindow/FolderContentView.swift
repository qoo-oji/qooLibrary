import AppKit
import QooApplication
import QooInfrastructure
import QooKit
import SwiftUI
import UniformTypeIdentifiers

/// アクティブなタブのフォルダ内容を一覧表示する。
///
/// リスト表示（ソート可能なカラム、`Table`）とアイコン表示（サムネイル付き、
/// `IconGridView`）の両方に対応する [LV-01〜LV-03][IV-01/08/09]。
///
/// コンテキストメニュー（名前変更・複製・ゴミ箱・新規フォルダ）はすべて
/// `FileOperationService` 経由でのみファイルシステムを変更する [FO-01][FO-02]。
/// 「Finder で表示」「パスをコピー」はファイルを変更しないため対象外 [FM-09][FM-10]。
struct FolderContentView: View {
    let folder: URL?
    @Binding var selection: Set<URL>
    let onNavigate: (URL) -> Void
    /// Finder ツールバーの矢印ボタンと同等の戻る/進む [KB-02]。履歴自体は
    /// `WindowState`（タブごと）が保持し、このビューは通知を受けて呼ぶだけ。
    let onGoBack: () -> Void
    let onGoForward: () -> Void
    let canGoBack: Bool
    let canGoForward: Bool
    /// 1階層上へ [KB-02 相当]。`goBack`/`goForward` と同じ理由で `WindowState`
    /// 側のメソッドとして実装し、このビューは通知を受けて呼ぶだけにしている
    /// [実機検証で発見したバグの修正、`goToParent()` の旧実装のコメント参照]。
    let onGoToParent: () -> Void
    let canGoToParent: Bool
    /// コンテキストメニューの「新規タブで開く」「新規ウインドウで開く」
    /// [MW-01/MW-04 の周辺、要件定義書には無いがユーザー要望で追加]。
    let onOpenInNewTab: (URL) -> Void
    let onOpenInNewWindow: (URL) -> Void
    /// リスト/アイコン切替 [LV-04] とアイコンサイズ [IV-04]。`WindowState`
    /// （ウインドウ単位、タブをまたいで共有 [ST-22]）が保持する。
    @Binding var listStyle: ListStyle
    @Binding var iconSize: Double
    /// 新規フォルダ作成ダイアログの状態 [FM-01]。ボタン自体はウインドウの
    /// 実ツールバー（`MainWindowView`）に移したため、状態は上位で持ち上げ、
    /// このビューはダイアログ本体（`.alert`）と実際の作成処理のみを担う。
    @Binding var showingNewFolderPrompt: Bool
    @Binding var newFolderName: String

    @State private var entries: [FolderEntry] = []
    @State private var loadError: String?
    @State private var renamingEntry: FolderEntry?
    @State private var renameText = ""
    @FocusState private var isRenameFieldFocused: Bool
    /// Finder 流「選択済みの項目をもう一度クリックするとリネーム」の識別用
    /// [ユーザー要望]。クリックのたびに増分し、ダブルクリックや他の選択操作
    /// （＝別のクリック）が割り込んだら保留中のリネーム開始タイマーを
    /// 無効化する（`handleSingleClick`/`rowCell`/`IconGridView` 参照）。
    @State private var pendingRenameGeneration = 0
    @State private var isDropTargeted = false
    @FocusState private var isListFocused: Bool
    /// Shift クリックでの範囲選択の起点 [LV-06 相当]。
    @State private var selectionAnchor: URL?
    /// 複数選択された行を一度にドラッグするための `dragContainer` 系 API のスコープ
    /// [DD-02][設計判断: macOS 26 で追加された API、詳細は `.draggable(containerItemID:)` の
    /// 呼び出し箇所のコメント参照]。
    @Namespace private var dragNamespace
    /// 圧縮・展開など数秒かかることがある処理の実行中表示 [UI-09]。
    /// バイト単位の進捗（`ProgressReporter`）はまだ無いため不定進捗のみ。
    @State private var busyMessage: String?
    /// リスト表示の現在のソート順 [LV-01]。タブ切替をまたいで保持されて構わない
    /// 軽微な状態のため `WindowState`/`TabState` へは持ち上げず、他の一時的な
    /// `@State`（`selectionAnchor` 等）と同じくこのビュー内で完結させる。
    @State private var sortOrder: [FolderSortComparator] = [FolderSortComparator(key: .name)]
    /// カラムの表示/非表示 [LV-02] とフォルダをまとめる設定 [LV-03] は、
    /// 特定のウインドウやタブに紐づかないアプリ全体の表示設定。1-12（環境設定）
    /// の本実装が無いため、1-8 のキーバインド上書きと同じく `UserDefaults`
    /// （`@AppStorage`）に直接永続化する暫定形にしている。
    @AppStorage("qoo.folderList.showModificationDateColumn") private var showModificationDateColumn = true
    @AppStorage("qoo.folderList.showSizeColumn") private var showSizeColumn = true
    @AppStorage("qoo.folderList.showKindColumn") private var showKindColumn = true
    @AppStorage("qoo.folderList.groupFoldersAtTop") private var groupFoldersAtTop = true

    /// キーバインド [13章 §13.6]。1-8 時点では開く・リネーム・ゴミ箱・
    /// 新規フォルダのみ実際に配線している（他の既定バインドは対応する
    /// 機能が実装され次第、各所で `keyBindingStore.binding(for:)` を参照する）。
    private let keyBindingStore: KeyBindingStore = UserDefaultsKeyBindingStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let loadError {
                PlaceholderPane(title: "読み込みエラー", subtitle: loadError)
            } else if listStyle == .icon {
                // アイコン表示 [IV-01/08/09、PF-10]。`Table` と違い選択・D&D・
                // コンテキストメニューの AppKit 標準機能が無いため、それぞれ
                // `IconGridView` 側で手動再現している（詳細はそのファイルの
                // コメント参照）。
                IconGridView(
                    entries: displayedEntries,
                    selection: $selection,
                    iconSize: iconSize,
                    dragNamespace: dragNamespace,
                    onNavigate: onNavigate,
                    onSingleClick: { handleSingleClick($0) },
                    onReload: { reloadAndBroadcast() },
                    onDropFailure: { presentFailureMessage($0) },
                    contextMenuContent: { urls in contextMenuContent(for: urls) },
                    renamingURL: renamingEntry?.url,
                    renameText: $renameText,
                    isRenameFieldFocused: $isRenameFieldFocused,
                    onCommitRename: { commitRename() },
                    onCancelRename: { cancelRename() },
                    isFocused: isListFocused
                )
                // `Table` は標準でキーボードフォーカスを受け取れるが、
                // `IconGridView`（`ScrollView`/`LazyVGrid`）はそうではないため
                // `.focusable()` が無いと `.focused($isListFocused)` が何にも
                // 結びつかず、Enter キーの `.onKeyPress` が発火しなかった
                // [実機検証で発見]。
                .focusable()
                .focused($isListFocused)
                .onKeyPress(keyBindingStore.binding(for: .open).combos.first?.swiftUIKeyEquivalent ?? .return) {
                    openSelection()
                    return .handled
                }
                .onKeyPress(.downArrow) {
                    selectFirstOrLastIfNoneSelected(first: true) ? .handled : .ignored
                }
                .onKeyPress(.upArrow) {
                    selectFirstOrLastIfNoneSelected(first: false) ? .handled : .ignored
                }
            } else {
                // カラムベースのリスト表示 [LV-01〜LV-03]。ソートは `sortOrder`
                // バインディングを通してヘッダクリックで切り替わる。実際の並べ替えは
                // `displayedEntries` がこの状態を見て計算する（`Table` 自身は
                // データを自動ソートしない）。
                Table(displayedEntries, selection: $selection, sortOrder: $sortOrder) {
                    TableColumn("名前", sortUsing: FolderSortComparator(key: .name)) { entry in
                        rowCell(entry, isRenaming: renamingEntry?.url == entry.url) {
                            // アイコンを固定幅の枠に収めて Finder のように先頭を揃える
                            // （実機検証で発覚: アイコンの実測幅がまちまちだと名前の
                            // 先頭位置がずれる）。Finder と同じアイコン [ユーザー要望、
                            // `FileIconProvider` 参照]。
                            HStack(spacing: Tokens.spacing.xs) {
                                Image(nsImage: FileIconProvider.shared.icon(for: entry.url))
                                    .resizable()
                                    .frame(width: 16, height: 16)
                                if renamingEntry?.url == entry.url {
                                    // Finder 流のインライン名前編集 [ユーザー要望]。
                                    TextField("名前", text: $renameText)
                                        .textFieldStyle(.plain)
                                        .focused($isRenameFieldFocused)
                                        .onSubmit { commitRename() }
                                        .onExitCommand { cancelRename() }
                                        .onAppear {
                                            isRenameFieldFocused = true
                                            // フィールドエディタが割り当てられた後で
                                            // ないと選択範囲を操作できないため
                                            // 1 サイクル遅らせる。
                                            DispatchQueue.main.async {
                                                InlineRenameSupport.selectBaseNameIfApplicable(for: entry)
                                            }
                                        }
                                        .onChange(of: isRenameFieldFocused) { _, focused in
                                            if !focused, renamingEntry?.url == entry.url {
                                                commitRename()
                                            }
                                        }
                                } else {
                                    Text(entry.name)
                                }
                            }
                            .font(.system(size: Tokens.fontSize.body))
                        }
                    }
                    .width(min: 160, ideal: 280)

                    if showModificationDateColumn {
                        TableColumn("更新日", sortUsing: FolderSortComparator(key: .modificationDate)) { entry in
                            rowCell(entry, isRenaming: renamingEntry?.url == entry.url) {
                                Text(entry.modificationDate.map { Self.dateFormatter.string(from: $0) } ?? "—")
                                    .font(.system(size: Tokens.fontSize.body))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .width(min: 110, ideal: 170)
                    }

                    if showSizeColumn {
                        TableColumn("サイズ", sortUsing: FolderSortComparator(key: .size)) { entry in
                            rowCell(entry, isRenaming: renamingEntry?.url == entry.url) {
                                Text(entry.isDirectory ? "—" : Self.sizeFormatter.string(fromByteCount: entry.fileSize ?? 0))
                                    .font(.system(size: Tokens.fontSize.body))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .width(min: 70, ideal: 90)
                    }

                    if showKindColumn {
                        TableColumn("種類", sortUsing: FolderSortComparator(key: .kind)) { entry in
                            rowCell(entry, isRenaming: renamingEntry?.url == entry.url) {
                                Text(entry.kindDescription)
                                    .font(.system(size: Tokens.fontSize.body))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .width(min: 90, ideal: 140)
                    }
                }
                .focused($isListFocused)
                // [DD-02][設計判断] `URL` は既に `Transferable`。ドラッグされた行の
                // `containerItemID`（＝ URL 自身）の配列がそのままペイロードになる。
                .dragContainer(for: URL.self, itemID: \.self, in: dragNamespace) { draggedItemIDs in
                    draggedItemIDs
                }
                .dragContainerSelection(Array(selection), containerNamespace: dragNamespace)
                // `Table`/`List` 専用の選択集合ベースのコンテキストメニュー
                // [実機検証時のユーザー指摘への対応]。行ごとに `.contextMenu` を
                // 付ける方式（以前の実装）だと、選択されていない行を右クリックした
                // ときに Finder のような青い枠線（「これから出るメニューの対象は
                // この行」の表示）が出なかった。この API は AppKit の
                // `NSTableView` の標準機能を直接使うため、右クリックした行が
                // 現在の選択に含まれなければ自動的にその1行だけを対象にし、
                // 枠線表示も標準で行われる（自前で追跡・実装する必要が無い）。
                // 何も選択されていない空きスペースを右クリックした場合は
                // `urls` が空集合になるので、それで空きスペース用メニューと
                // 行メニューを切り替える（以前は別々の `.contextMenu` だった）。
                .contextMenu(forSelectionType: URL.self) { urls in
                    contextMenuContent(for: urls)
                }
                // [KB-02] 選択中の項目を開く。ディレクトリはダブルクリックと同じ
                // ナビゲーション、ファイルは既定アプリで開く（Finder と同じ）。
                .onKeyPress(keyBindingStore.binding(for: .open).combos.first?.swiftUIKeyEquivalent ?? .return) {
                    openSelection()
                    return .handled
                }
                // Finder 流: 何も選択していない状態で↓/↑を押すと先頭/末尾を選択する
                // [実機検証時のユーザー要望]。何か選択済みなら `.ignored` を返し、
                // `Table` 標準の行選択移動（AppKit の既定キーハンドリング）に譲る。
                .onKeyPress(.downArrow) {
                    selectFirstOrLastIfNoneSelected(first: true) ? .handled : .ignored
                }
                .onKeyPress(.upArrow) {
                    selectFirstOrLastIfNoneSelected(first: false) ? .handled : .ignored
                }
            }

            if let folder {
                Divider()
                HStack(spacing: Tokens.spacing.s) {
                    PathBarView(folder: folder, onNavigate: onNavigate) // [ユーザー要望: Finder 流のパスバー]
                    // リスト/アイコン表示モード依存のコントロールをパスバーの右端に統一
                    // [ユーザー要望: 上段の行をリスト/アイコンどちらでも同じ配置にしたい
                    // ため、以前は上段に置いていたこの2つをここへ移動]。
                    if listStyle == .icon { // [IV-04]
                        Slider(value: $iconSize, in: Tokens.iconSize.min...Tokens.iconSize.max, step: Tokens.iconSize.step)
                            .frame(width: 100)
                            .help("アイコンサイズ")
                    } else {
                        Menu {
                            Toggle("更新日", isOn: $showModificationDateColumn)
                            Toggle("サイズ", isOn: $showSizeColumn)
                            Toggle("種類", isOn: $showKindColumn)
                            Divider()
                            Toggle("フォルダを上にまとめる", isOn: $groupFoldersAtTop) // [LV-03]
                        } label: {
                            Image(systemName: "line.3.horizontal.decrease.circle")
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .help("表示するカラム") // [LV-02]
                    }
                }
                .padding(.horizontal, Tokens.spacing.m)
                .padding(.vertical, Tokens.spacing.xs)
                .background(.thinMaterial)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            // リネーム・ゴミ箱・新規フォルダのキーボードショートカット
            // [KB-03][UI-09 相当]。可視要素を持たないボタンとして配線する
            // 標準的な SwiftUI のパターン。
            Group {
                KeyBindingButtons(action: .rename, store: keyBindingStore, isDisabled: selection.count != 1) {
                    beginRenameFromShortcut()
                }
                KeyBindingButtons(action: .moveToTrash, store: keyBindingStore, isDisabled: selection.isEmpty, role: .destructive) {
                    moveToTrash(Array(selection))
                }
                KeyBindingButtons(action: .newFolder, store: keyBindingStore, isDisabled: folder == nil) {
                    newFolderName = "新規フォルダ"
                    showingNewFolderPrompt = true
                }
                KeyBindingButtons(action: .goToParent, store: keyBindingStore, isDisabled: !canGoToParent) {
                    onGoToParent()
                }
                KeyBindingButtons(action: .goBack, store: keyBindingStore, isDisabled: !canGoBack) {
                    onGoBack()
                }
                KeyBindingButtons(action: .goForward, store: keyBindingStore, isDisabled: !canGoForward) {
                    onGoForward()
                }
                KeyBindingButtons(action: .copy, store: keyBindingStore, isDisabled: selection.isEmpty) {
                    copySelectionToPasteboard(Array(selection))
                }
                KeyBindingButtons(action: .paste, store: keyBindingStore, isDisabled: !canPaste || folder == nil) {
                    pasteFromPasteboard()
                }
            }
            .frame(width: 0, height: 0)
            .opacity(0)
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: Tokens.radius.s)
                    .strokeBorder(Tokens.Colors.accent, lineWidth: 2)
                    .padding(2)
                    .allowsHitTesting(false)
            }
        }
        .overlay {
            // 圧縮・展開は数秒かかることがあり、無表示だとアプリが固まった
            // ように見える。バイト単位の進捗が無いため不定進捗のみ表示する。
            if let busyMessage {
                ZStack {
                    Color.black.opacity(0.15)
                    QooProgressPresenter(title: busyMessage)
                        .background(.regularMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: Tokens.radius.m))
                }
                .ignoresSafeArea()
            }
        }
        .dropDestination(for: URL.self) { items, _ in // [DD-03] Finder・他アプリからの取り込み
            guard let folder else { return false }
            DropHandling.performDrop(items, into: folder, onComplete: { reloadAndBroadcast() }, onFailure: { presentFailureMessage($0) })
            return true
        } isTargeted: { isDropTargeted = $0 }
        .task(id: folder) {
            reload()
            // ⌘↑・戻る・進む・ツリークリック等、クリック以外の経路でナビゲート
            // した場合に一覧がキーボードフォーカスを失ったままになり、選択行が
            // 非フォーカス色（グレー）で表示され、矢印キーを押してもビープする
            // だけになる不具合があった [実機検証で発見]。フォルダそのものが
            // 変わったとき（＝実際のナビゲーション時）だけフォーカスを戻す
            // （`reloadToken` 経由の再読み込みではフォーカスを奪わないよう、
            // ここではなく `reload()` 呼び出し側で行う）。
            isListFocused = true
        }
        // ウインドウ／ペインをまたいだ変更を拾う暫定策 [1-6 実機検証で発見した
        // クロスウインドウの表示不整合対策、`SessionState.reloadToken` 参照]。
        .onChange(of: SessionState.shared.reloadToken) {
            reload()
        }
        .alert("新規フォルダ", isPresented: $showingNewFolderPrompt) {
            TextField("フォルダ名", text: $newFolderName)
            Button("作成") { createNewFolder() }
            Button("キャンセル", role: .cancel) {}
        }
    }

    private static let sizeFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    /// `entries` に現在のソート順 [LV-01] とフォルダをまとめる設定 [LV-03] を
    /// 適用した、実際に `Table` へ渡す並び。`filter` は相対順序を保つため、
    /// グルーピングを先にソートした結果へ適用しても各グループ内の順序は
    /// 崩れない。
    private var displayedEntries: [FolderEntry] {
        var result = entries
        result.sort(using: sortOrder)
        if groupFoldersAtTop {
            result = result.filter(\.isDirectory) + result.filter { !$0.isDirectory }
        }
        return result
    }

    /// 空きスペースの右クリックメニュー「並び替え」用 [LV-01]。`Table` のカラム
    /// ヘッダクリックと違い昇順/降順の切替は持たず、選択したキーで常に昇順に
    /// リセットする（Finder の「整頓順序」メニューと同じ割り切り）。
    private var sortKeyBinding: Binding<FolderSortComparator.Key> {
        Binding(
            get: { sortOrder.first?.key ?? .name },
            set: { sortOrder = [FolderSortComparator(key: $0)] }
        )
    }

    /// 各カラムのセルに共通の行操作（選択・ダブルクリック・コンテキストメニュー・
    /// ドラッグ＆ドロップ）をまとめて適用する。`Table` は `List` と違いカラムごとに
    /// 独立したセルなので、Finder と同じく行のどこをクリックしても同じ挙動に
    /// なるよう、すべてのカラムのセルに同一の modifier 一式を付与する。
    @ViewBuilder
    private func rowCell(_ entry: FolderEntry, isRenaming: Bool = false, @ViewBuilder content: () -> some View) -> some View {
        if isRenaming {
            // インライン編集中はこの行の選択・ダブルクリック・D&D 用ジェスチャを
            // すべて外す。`TextField` 自身のクリック（カーソル位置合わせ等）が
            // 誤って選択操作やリネームの再トリガーとして扱われるのを防ぐため
            // [ユーザー要望: Finder 流のインライン名前編集]。
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    pendingRenameGeneration += 1 // ダブルクリックなら保留中のリネームは取り消す
                    if entry.isDirectory { onNavigate(entry.url) }
                }
                // 単発クリックの選択は `.simultaneousGesture` にする。同じ view に
                // `.onTapGesture(count: 1)` と `.onTapGesture(count: 2)` を両方
                // つけると、SwiftUI は「本当に単発クリックか、ダブルクリックの
                // 1 回目か」を見極めるためシステムのダブルクリック間隔だけ単発側の
                // 発火を遅らせる（実機検証で Finder に対して選択ハイライトが
                // 遅く感じられる原因になっていた）。`.simultaneousGesture` は排他的な
                // 判定グループに入らないため、単発クリックで即座に発火する。
                .simultaneousGesture(TapGesture(count: 1).onEnded {
                    handleSingleClick(entry)
                })
                // [DD-02] アプリ外（Finder 等）への実ファイル参照エクスポート。
                // 旧来の `.onDrag`/`.draggable(_:)` は macOS の `List` で複数選択を
                // まとめてドラッグできない未解決の既知バグがある（Apple Feedback
                // FB10128110）。macOS 26 で追加された `draggable(containerItemID:)` +
                // `dragContainer` + `dragContainerSelection`（`Table` に付与、上記
                // 参照）の組み合わせで、選択中の行から始めたドラッグに選択全体が含まれる。
                .draggable(containerItemID: entry.url, containerNamespace: dragNamespace)
                .modifier(DropIntoFolderModifier(
                    entry: entry,
                    reload: { reloadAndBroadcast() },
                    onFailure: { presentFailureMessage($0) }
                ))
        }
    }

    /// D&D 系のモディファイアを付けた行は List/Table 標準のクリック選択が
    /// ハイライト込みで効かなくなることがあるため、明示的に選択する
    /// （Cmd でトグル・Shift で範囲選択、という Finder 流の規則もここで手動で
    /// 再現する）。範囲選択は画面表示順（`displayedEntries`）で計算する。
    ///
    /// **Finder 流のインライン名前編集の起点もここ**
    /// [ユーザー要望: 既に選択済みの項目をもう一度クリックするとその場で
    /// リネームできるようにしたい、リネーム用の別ウインドウは出したくない]。
    /// クリックの瞬間にダブルクリックの1回目かどうかは判定できないため、
    /// 「既にこの1件だけが選択されていた状態でのクリック」を検知したら
    /// 少し待ってから開始し、その間に別のクリック（ダブルクリックの2回目・
    /// 他の項目の選択・修飾キー付きクリック等）が起きたら
    /// `pendingRenameGeneration` の不一致で自動的にキャンセルされる。
    private func handleSingleClick(_ entry: FolderEntry) {
        if renamingEntry != nil {
            commitRename() // 別の行をクリックしたら進行中のインライン編集を確定する
        }
        pendingRenameGeneration += 1
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            if selection.contains(entry.url) {
                selection.remove(entry.url)
            } else {
                selection.insert(entry.url)
            }
            selectionAnchor = entry.url
        } else if flags.contains(.shift),
                  let anchor = selectionAnchor,
                  let anchorIndex = displayedEntries.firstIndex(where: { $0.url == anchor }),
                  let clickedIndex = displayedEntries.firstIndex(where: { $0.url == entry.url }) {
            let range = anchorIndex < clickedIndex ? anchorIndex...clickedIndex : clickedIndex...anchorIndex
            selection = Set(displayedEntries[range].map(\.url))
        } else {
            let wasAlreadySoleSelection = selection == [entry.url]
            // 既に複数選択の一部になっている行は潰さない
            // （そうしないと複数選択した状態でドラッグを開始しても単一行しか
            // ドラッグに含まれなくなる）。
            if !selection.contains(entry.url) {
                selection = [entry.url]
            }
            selectionAnchor = entry.url
            if wasAlreadySoleSelection {
                let generation = pendingRenameGeneration
                Task {
                    try? await Task.sleep(for: .milliseconds(400))
                    guard generation == pendingRenameGeneration, selection == [entry.url] else { return }
                    beginRename(entry)
                }
            }
        }
        // List/Table 標準のクリック選択は副作用としてリストへフォーカスも移すが、
        // 手動での選択にはその副作用が無いため、選択がグレー（非フォーカス）
        // 表示のままになる。明示的にフォーカスさせて青色のハイライトにする。
        isListFocused = true
    }

    /// Finder 流: 何も選択していない状態で↓/↑を押すと先頭/末尾の項目を選択する
    /// [実機検証時のユーザー要望、リスト・アイコン両表示で共通]。何かが既に
    /// 選択されている場合は何もしない（`false` を返し、呼び出し側は
    /// `.ignored` を返すことで `Table` 標準の行選択移動に処理を譲る）。
    private func selectFirstOrLastIfNoneSelected(first: Bool) -> Bool {
        guard selection.isEmpty, let target = first ? displayedEntries.first : displayedEntries.last else {
            return false
        }
        selection = [target.url]
        selectionAnchor = target.url
        isListFocused = true
        return true
    }

    /// `.contextMenu(forSelectionType:)` から呼ばれる。`urls` は AppKit が
    /// 解決済みの対象集合（右クリックした行が選択に含まれていればその選択全体、
    /// 含まれていなければその1行だけ、何もない場所なら空集合）[Finder と同じ規則、
    /// 実機検証時のユーザー指摘への対応]。
    ///
    /// 利用頻度が高いと想定される順に並べる [ユーザー指摘]。開く／移動系 →
    /// 編集系（名前変更・複製・コピー・ゴミ箱）→ 圧縮 → 展開 → 副次的な操作
    /// （表示・パス・共有・エイリアス）→ 付随情報（ロック・情報）の順。
    @ViewBuilder
    private func contextMenuContent(for urls: Set<URL>) -> some View {
        if urls.isEmpty {
            // 空きスペースの右クリック。表示切替・並び替えも Finder に揃える
            // [ユーザー要望、要件定義書には無い]。`Picker` を `Menu` の中で
            // `.pickerStyle(.inline)` にすると、サブメニューとして現在の
            // 選択にチェックマークが付く標準の見た目になる。
            Menu("表示") { // [LV-04]
                Picker("表示", selection: $listStyle) {
                    Label("リスト", systemImage: "list.bullet").tag(ListStyle.list)
                    Label("アイコン", systemImage: "square.grid.2x2").tag(ListStyle.icon)
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
            Menu("並び替え") { // [LV-01]
                Picker("並び替え", selection: sortKeyBinding) {
                    Text("名前").tag(FolderSortComparator.Key.name)
                    Text("更新日").tag(FolderSortComparator.Key.modificationDate)
                    Text("サイズ").tag(FolderSortComparator.Key.size)
                    Text("種類").tag(FolderSortComparator.Key.kind)
                }
                .pickerStyle(.inline)
                .labelsHidden()
                Divider()
                // アイコン表示にはこの設定への導線が無かったため、ここに置くことで
                // リスト・アイコン両方から到達できるようにした [LV-03 の導線拡張]。
                Toggle("フォルダを上にまとめる", isOn: $groupFoldersAtTop)
            }
            Divider()
            Button("新規フォルダ") {
                newFolderName = "新規フォルダ"
                showingNewFolderPrompt = true
            }
            Button("ペースト") { pasteFromPasteboard() }
                .disabled(!canPaste)
        } else {
            let targets = Array(urls)
            let targetEntries = entries.filter { urls.contains($0.url) }
            Button("開く") { openEntries(targetEntries) } // [KB-02 相当]
            if targetEntries.allSatisfy(\.isDirectory) {
                // 新規タブ/ウインドウで開くはフォルダのみ意味を持つ。Finder は
                // 複数選択なら選択したフォルダの数だけタブ/ウインドウを開く。
                Button(targets.count == 1 ? "新規タブで開く" : "新規タブでそれぞれ開く") {
                    targets.forEach(onOpenInNewTab)
                }
                Button(targets.count == 1 ? "新規ウインドウで開く" : "新規ウインドウでそれぞれ開く") {
                    targets.forEach(onOpenInNewWindow)
                }
            }
            Divider()
            // 名前を変更はバッチ名変更 UI が無いため単一対象時のみ。
            if targets.count == 1, let only = targetEntries.first {
                Button("名前を変更…") { beginRename(only) } // [FM-05]
            }
            Button("複製") { duplicate(targets) } // [FM-02]
            Button("コピー") { copySelectionToPasteboard(targets) } // [KB-02 相当、⌘C]
            Divider()
            Button("ゴミ箱に入れる", role: .destructive) { moveToTrash(targets) } // [FM-04]
            Divider()
            Button("ここに圧縮") { compressHere(targets) } // [AR-10]
            Button("圧縮…") { compressWithDialog(targets) } // [AR-11]
            if isExtractable(targets) {
                Divider()
                Button("ここに展開") { extractInPlace(targets) } // [AR-20]
                if targets.count == 1, let single = targets.first {
                    Button("「\(archiveBaseName(single))」に展開") { extractToNamedFolders(targets) } // [AR-21]
                } else {
                    Button("それぞれのフォルダに展開") { extractToNamedFolders(targets) } // [AR-23]
                }
                Button("展開…") { extractToChosenDestination(targets) } // [AR-22]
            }
            Divider()
            Button("Finder で表示") { NSWorkspace.shared.activateFileViewerSelecting(targets) } // [FM-09]
            Button("パスをコピー") { copyPaths(targets) } // [FM-10]
            ShareLink("共有…", items: targets) // [共有、既定ラベルが英語 "Share..." になるため明示的に指定]
            Button("エイリアスを作成") { createAliases(for: targets) }
            Divider()
            Button(targetEntries.allSatisfy(\.isLocked) ? "ロック解除" : "ロック") {
                toggleLock(targetEntries)
            }
            // 「情報を見る」の簡易シートは 1-10 で常設の右ペイン
            // インスペクタ（`InspectorPane`）に置き換えたため削除した。
        }
    }

    private func reload() {
        guard let folder else {
            entries = []
            loadError = nil
            return
        }
        do {
            let keys: Set<URLResourceKey> = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .isUserImmutableKey]
            let urls = try FileManager.default.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles]
            )
            entries = urls.map { url in
                let values = try? url.resourceValues(forKeys: keys)
                return FolderEntry(
                    url: url,
                    name: url.lastPathComponent,
                    isDirectory: values?.isDirectory ?? false,
                    fileSize: values?.fileSize.map(Int64.init),
                    modificationDate: values?.contentModificationDate,
                    isLocked: values?.isUserImmutable ?? false
                )
            }
            loadError = nil
        } catch {
            entries = []
            loadError = error.localizedDescription
        }
    }

    /// 自分自身の再読み込みに加えて、他のウインドウ／ペインにも変更を知らせる
    /// [1-6 実機検証で発見: これが無いとウインドウをまたいだ D&D 等で表示が古いまま残る]。
    private func reloadAndBroadcast() {
        reload()
        SessionState.shared.reloadToken += 1
    }

    /// [ER-01] エラー提示は必ず `NotificationRouter` 経由にする。以前は
    /// `@State private var actionError: String?` + 専用の `.alert` を
    /// このビュー自身が持っていたが、それこそが ER-01 が禁じる「機能ごとに
    /// 独自の提示方法を作る」状態だったため、1-12b でここへ一本化した。
    private func presentError(_ error: Error, whatHappened: String) {
        Task { await NotificationRouter.shared.presentError(error, whatHappened: whatHappened) }
    }

    /// D&D 失敗など、`Error` ではなく素の `String` しか渡されてこない経路用。
    private func presentFailureMessage(_ message: String) {
        Task {
            await NotificationRouter.shared.present(
                NotificationItem(category: .error, severity: .sheet, title: "操作に失敗しました", body: message)
            )
        }
    }

    private func copyPaths(_ urls: [URL]) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
    }

    /// `⌘C`/コンテキストメニュー「コピー」。標準の `NSPasteboard` にファイル URL
    /// として書き込むため、Finder との相互運用（Finder へ貼り付け／Finder で
    /// コピーしたものをここへ貼り付け）が両方とも成立する。
    private func copySelectionToPasteboard(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects(urls as [NSURL])
    }

    /// `⌘V`/コンテキストメニュー「ペースト」。ペーストボード上のファイル URL を
    /// 現在のフォルダへコピーする（Finder の `⌘V` と同じ既定、移動ではない）。
    private func pasteFromPasteboard() {
        guard let folder,
              let urls = NSPasteboard.general.readObjects(forClasses: [NSURL.self]) as? [URL],
              !urls.isEmpty
        else { return }
        Task {
            do {
                _ = try await CommandStack.shared.run(CopyFilesCommand(items: urls, destination: folder))
                reloadAndBroadcast()
            } catch {
                presentError(error, whatHappened: "ペーストに失敗しました")
            }
        }
    }

    private var canPaste: Bool {
        NSPasteboard.general.canReadObject(forClasses: [NSURL.self], options: nil)
    }

    private func createAliases(for urls: [URL]) {
        guard let folder else { return }
        let children: [any Command] = urls.map { CreateAliasCommand(source: $0, destinationFolder: folder) }
        guard let command = Self.singleOrComposite(children, displayName: "エイリアスを作成") else { return }
        Task {
            do {
                _ = try await CommandStack.shared.run(command)
                reloadAndBroadcast()
            } catch {
                presentError(error, whatHappened: "エイリアスの作成に失敗しました")
            }
        }
    }

    /// 対象が全てロック済みなら解除、そうでなければロックする（Finder と同じ
    /// トグル規則）。
    private func toggleLock(_ targets: [FolderEntry]) {
        guard !targets.isEmpty else { return }
        let shouldLock = !targets.allSatisfy(\.isLocked)
        Task {
            do {
                _ = try await CommandStack.shared.run(SetLockedCommand(items: targets.map(\.url), locked: shouldLock))
                reloadAndBroadcast()
            } catch {
                presentError(error, whatHappened: shouldLock ? "ロックに失敗しました" : "ロック解除に失敗しました")
            }
        }
    }

    private func beginRename(_ entry: FolderEntry) {
        renamingEntry = entry
        renameText = entry.name
    }

    /// `⌘R` ショートカット用。バッチ名変更 UI が無いため単一選択時のみ動く
    /// [FM-05]。
    private func beginRenameFromShortcut() {
        guard selection.count == 1, let url = selection.first,
              let entry = entries.first(where: { $0.url == url })
        else { return }
        beginRename(entry)
    }

    /// `Enter`/`⌘↓` ショートカット用 [KB-02]。単一選択ならディレクトリは
    /// ナビゲーション、ファイルは既定アプリで開く。複数選択時はディレクトリへ
    /// 同時に移動できないため、ファイルだけを開く。
    private func openSelection() {
        guard !selection.isEmpty else { return }
        openEntries(entries.filter { selection.contains($0.url) })
    }

    /// コンテキストメニューの「開く」用 [KB-02 相当]。`openSelection()` と同じ
    /// 規則だが、右クリックした対象（必ずしも現在の選択と一致しない）を直接渡せる。
    private func openEntries(_ targets: [FolderEntry]) {
        if targets.count == 1, let only = targets.first {
            if only.isDirectory {
                onNavigate(only.url)
            } else {
                NSWorkspace.shared.open(only.url)
            }
            return
        }
        for target in targets where !target.isDirectory {
            NSWorkspace.shared.open(target.url)
        }
    }

    /// インライン編集中の `TextField` は即座に閉じる（`renamingEntry` を
    /// 同期的にクリアする）。実際のリネーム自体は非同期だが、UI 上の見た目は
    /// 楽観的に確定させる（Finder と同じ体感）。名前が変わっていなければ
    /// 何もしない（Undo スタックへの無意味な積み増しを避ける）。
    private func commitRename() {
        guard let entry = renamingEntry else { return }
        renamingEntry = nil
        guard !renameText.isEmpty, renameText != entry.name else { return }
        Task {
            do {
                _ = try await CommandStack.shared.run(RenameCommand(item: entry.url, newName: renameText))
                reloadAndBroadcast()
            } catch {
                presentError(error, whatHappened: "名前の変更に失敗しました")
            }
        }
    }

    private func cancelRename() {
        renamingEntry = nil
    }

    private func duplicate(_ urls: [URL]) {
        guard let folder else { return }
        Task {
            do {
                _ = try await CommandStack.shared.run(CopyFilesCommand(items: urls, destination: folder))
                reloadAndBroadcast()
            } catch {
                presentError(error, whatHappened: "複製に失敗しました")
            }
        }
    }

    private func moveToTrash(_ urls: [URL]) {
        Task {
            do {
                _ = try await CommandStack.shared.run(TrashCommand(items: urls))
                reloadAndBroadcast()
            } catch {
                presentError(error, whatHappened: "ゴミ箱への移動に失敗しました")
            }
        }
    }

    private func createNewFolder() {
        guard let folder, !newFolderName.isEmpty else { return }
        Task {
            do {
                _ = try await CommandStack.shared.run(CreateFolderCommand(url: folder.appendingPathComponent(newFolderName)))
                reloadAndBroadcast()
            } catch {
                presentError(error, whatHappened: "フォルダの作成に失敗しました")
            }
        }
    }

    // MARK: - 圧縮・展開 [9.4 節]

    /// 選択されたすべての項目が対応アーカイブ形式のファイルであること
    /// [AR-20〜AR-23]。フォルダが混じっている場合は展開メニューを出さない。
    private func isExtractable(_ urls: [URL]) -> Bool {
        guard !urls.isEmpty else { return false }
        let matching = entries.filter { urls.contains($0.url) }
        return matching.count == urls.count && matching.allSatisfy { $0.archiveFormat != nil }
    }

    /// `.tar.gz` のような複合拡張子も含めてアーカイブ名から拡張子を除いた
    /// ベース名を返す（展開先フォルダ名に使う）[AR-21]。
    private func archiveBaseName(_ url: URL) -> String {
        let name = url.lastPathComponent
        if name.lowercased().hasSuffix(".tar.gz") {
            return String(name.dropLast(".tar.gz".count))
        }
        return url.deletingPathExtension().lastPathComponent
    }

    /// 複数のコマンドを 1 回の操作として 1 つの Undo 単位にまとめる [UD-04]。
    /// 1 件ならそのまま返し、0 件なら `nil`（実行するものが無い）。
    private static func singleOrComposite(_ commands: [any Command], displayName: String) -> (any Command)? {
        if commands.isEmpty { return nil }
        if commands.count == 1 { return commands[0] }
        return CompositeCommand(displayName: displayName, children: commands)
    }

    /// 展開先フォルダを新規作成する場合は `CreateFolderCommand` + `ExtractCommand`
    /// を 1 つの Undo 単位にまとめる [UD-04]。複数アーカイブの一括展開も
    /// まとめて 1 単位にする（`MX2-08` の精神）。途中で失敗したら残りは中断する
    /// 暫定対応 [ER-20 の趣旨に近い、`BatchNotificationSession`〈結果サマリ・
    /// 部分失敗の集約〉はまだ実装していないため]。
    private func extractArchives(_ urls: [URL], destination: @escaping (URL) -> URL) {
        busyMessage = urls.count == 1 ? "展開しています…" : "展開しています…（\(urls.count) 件）"
        var children: [any Command] = []
        for url in urls {
            let target = destination(url)
            if !FileManager.default.fileExists(atPath: target.path) {
                children.append(CreateFolderCommand(url: target))
            }
            children.append(ExtractCommand(archiveURL: url, destination: target))
        }
        let name = urls.count == 1 ? "「\(urls[0].lastPathComponent)」を展開" : "\(urls.count) 件のアーカイブを展開"
        guard let command = Self.singleOrComposite(children, displayName: name) else {
            busyMessage = nil
            return
        }
        Task {
            defer { busyMessage = nil }
            do {
                _ = try await CommandStack.shared.run(command)
            } catch {
                presentError(error, whatHappened: "展開に失敗しました")
            }
            reloadAndBroadcast()
        }
    }

    private func extractInPlace(_ urls: [URL]) {
        guard let folder else { return }
        extractArchives(urls) { _ in folder } // [AR-20]
    }

    private func extractToNamedFolders(_ urls: [URL]) {
        guard let folder else { return }
        extractArchives(urls) { folder.appendingPathComponent(archiveBaseName($0)) } // [AR-21][AR-23]
    }

    private func extractToChosenDestination(_ urls: [URL]) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "展開"
        panel.message = "展開先のフォルダを選択してください"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        extractArchives(urls) { _ in destination } // [AR-22]
    }

    /// 単一選択時は項目名、複数選択時はカレントフォルダ名 [AR-10]。
    private func compressHere(_ urls: [URL]) {
        guard let folder, !urls.isEmpty else { return }
        let name = urls.count == 1 ? archiveBaseName(urls[0]) : folder.lastPathComponent
        busyMessage = "圧縮しています…"
        Task {
            defer { busyMessage = nil }
            do {
                _ = try await CommandStack.shared.run(
                    CompressCommand(items: urls, destinationName: name, destinationFolder: folder)
                )
                reloadAndBroadcast()
            } catch {
                presentError(error, whatHappened: "圧縮に失敗しました")
            }
        }
    }

    /// ファイル名・保存先を指定するダイアログ。既定値は `compressHere` と同じ
    /// [AR-11]。zip 以外の形式は対応しないため、形式選択は設けない。
    private func compressWithDialog(_ urls: [URL]) {
        guard let folder, !urls.isEmpty else { return }
        let defaultName = urls.count == 1 ? archiveBaseName(urls[0]) : folder.lastPathComponent
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(defaultName).zip"
        panel.allowedContentTypes = [.zip]
        panel.directoryURL = folder
        panel.prompt = "圧縮"
        panel.message = "保存先を選択してください"
        guard panel.runModal() == .OK, let destinationURL = panel.url else { return }
        let destinationFolder = destinationURL.deletingLastPathComponent()
        let name = destinationURL.deletingPathExtension().lastPathComponent
        busyMessage = "圧縮しています…"
        Task {
            defer { busyMessage = nil }
            do {
                // NSSavePanel は既存ファイルの上書き確認を既に行っているため、
                // ここでは `.keepBoth`（自動連番）ではなく `.replace` にする。
                _ = try await CommandStack.shared.run(
                    CompressCommand(
                        items: urls, destinationName: name, destinationFolder: destinationFolder, conflictPolicy: .replace
                    )
                )
                reloadAndBroadcast()
            } catch {
                presentError(error, whatHappened: "圧縮に失敗しました")
            }
        }
    }
}

struct FolderEntry: Identifiable {
    var id: URL { url }
    let url: URL
    let name: String
    let isDirectory: Bool
    let fileSize: Int64?
    let modificationDate: Date?
    let isLocked: Bool

    /// zip/7z/rar/tar.gz（cbz/cb7/cbr のエイリアス含む）と認識できるファイル
    /// [AR-20〜AR-23]。フォルダは対象外。
    var archiveFormat: ArchiveFormat? {
        isDirectory ? nil : ArchiveFormat.from(filename: name)
    }

    /// Finder の「種類」列相当 [LV-01]。`UTType` の `localizedDescription` を使う。
    var kindDescription: String {
        if isDirectory { return "フォルダ" }
        let ext = url.pathExtension
        if !ext.isEmpty, let type = UTType(filenameExtension: ext), let description = type.localizedDescription {
            return description
        }
        return ext.isEmpty ? "書類" : "\(ext.uppercased()) ファイル"
    }
}

/// リスト表示の全カラム共通のソートキー [LV-01]。`Table` の `sortOrder` は
/// 単一のコンパレータ型の配列を要求するため、キーの種類を enum で切り替える
/// 1つの型にまとめている（各カラムがそれぞれ別のコンパレータ型を持つことはできない）。
private struct FolderSortComparator: SortComparator {
    enum Key: Hashable {
        case name, modificationDate, size, kind
    }

    var key: Key
    var order: SortOrder = .forward

    func compare(_ lhs: FolderEntry, _ rhs: FolderEntry) -> ComparisonResult {
        let result: ComparisonResult
        switch key {
        case .name:
            result = lhs.name.localizedStandardCompare(rhs.name) // [LV-01] Finder 流の自然順
        case .modificationDate:
            let l = lhs.modificationDate ?? .distantPast
            let r = rhs.modificationDate ?? .distantPast
            result = l == r ? .orderedSame : (l < r ? .orderedAscending : .orderedDescending)
        case .size:
            // フォルダはサイズを表示しない（Finder と同様）ため、常に先頭に来るよう
            // 最小値扱いにする。
            let l = lhs.isDirectory ? Int64.min : (lhs.fileSize ?? 0)
            let r = rhs.isDirectory ? Int64.min : (rhs.fileSize ?? 0)
            result = l == r ? .orderedSame : (l < r ? .orderedAscending : .orderedDescending)
        case .kind:
            result = lhs.kindDescription.localizedStandardCompare(rhs.kindDescription)
        }
        guard order == .reverse else { return result }
        switch result {
        case .orderedAscending: return .orderedDescending
        case .orderedDescending: return .orderedAscending
        case .orderedSame: return .orderedSame
        }
    }
}

/// フォルダ行にだけドロップ先を付与する（ファイル行に落としても意味がないため）[DD-05 相当]。
struct DropIntoFolderModifier: ViewModifier {
    let entry: FolderEntry
    let reload: () -> Void
    let onFailure: @MainActor @Sendable (String) -> Void
    @State private var isTargeted = false

    func body(content: Content) -> some View {
        if entry.isDirectory {
            content
                .background(isTargeted ? Tokens.Colors.accent.opacity(0.15) : Color.clear)
                .dropDestination(for: URL.self) { items, _ in
                    DropHandling.performDrop(items, into: entry.url, onComplete: { reload() }, onFailure: onFailure)
                    return true
                } isTargeted: { isTargeted = $0 }
        } else {
            content
        }
    }
}

/// Finder の「パスバー」相当。ウインドウ下端に現在のフォルダまでの各階層を
/// ボタンとして並べ、任意の階層をクリックすると直接その階層へジャンプできる
/// [ユーザー要望、要件定義書には無い]。長いパスは折り返さず横スクロールする
/// （Finder は収まりきらない中間階層を省略記号にまとめるが、そこまでは
/// 踏み込まない単純化）。
struct PathBarView: View {
    let folder: URL
    let onNavigate: (URL) -> Void

    /// ルート（ボリューム）から `folder` までの各階層。`deletingLastPathComponent()`
    /// を繰り返す実装を最初に試したが、**ルート `/` に対して呼ぶと `/` 自身では
    /// なく `/..` を返す**という `Foundation` の既知の挙動
    /// （[Apple 公式ドキュメント](https://developer.apple.com/documentation/foundation/url/1780471-deletinglastpathcomponent)
    /// に「削除できる要素が無い場合は `/..` を追加することがある」旨の記載あり、
    /// 実機検証でも `/` → `/..` → `/../..` → … と際限なく伸び続けることを
    /// 確認した）により、`parent.path == current.path` での終了判定が
    /// 一度も成立せず無限ループしてしまっていた（アプリ起動直後にウインドウが
    /// 表示されず CPU 100% に張り付く不具合として発見）。`pathComponents`
    /// （`["/", "Users", "name", ...]` の配列）から先頭を起点に1つずつ
    /// 積み上げる実装に変更し、この不具合ごと回避している。
    private var pathComponents: [URL] {
        let components = folder.standardizedFileURL.pathComponents
        guard let first = components.first else { return [folder] }
        var current = URL(fileURLWithPath: first)
        var result = [current]
        for component in components.dropFirst() {
            current = current.appendingPathComponent(component)
            result.append(current)
        }
        return result
    }

    var body: some View {
        let components = pathComponents
        HStack(spacing: 2) {
            ForEach(Array(components.enumerated()), id: \.element) { index, url in
                if index > 0 {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                Button {
                    onNavigate(url)
                } label: {
                    HStack(spacing: 4) {
                        Image(nsImage: FileIconProvider.shared.icon(for: url))
                            .resizable()
                            .frame(width: 14, height: 14)
                        // Finder 準拠のローカライズされた表示名(ルートはボリューム名になる)
                        // [`FileIconProvider` と同じ設計判断: 追加の entitlement 不要]。
                        Text(FileManager.default.displayName(atPath: url.path))
                            .font(.system(size: Tokens.fontSize.caption))
                            .fontWeight(url == components.last ? .semibold : .regular)
                            .lineLimit(1)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        // 余白・背景は呼び出し側（`FolderContentView`）が行全体（この breadcrumb +
        // 右端のモード依存コントロール）へまとめて適用するため、ここでは持たない
        // [ユーザー要望: モード依存コントロールをパスバー行の右端へ統合]。
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
    }
}
