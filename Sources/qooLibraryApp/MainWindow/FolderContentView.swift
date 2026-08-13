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
    /// `String(localized:)`/`NotificationItem` 等 `Text` の `LocalizedStringKey`
    /// 解決を経由しない箇所向け [1-12 ローカライズ方針、CLAUDE.md 参照]。
    @Environment(\.locale) private var locale
    let folder: URL?
    /// `folder` の「実行時点で常に最新」版 [実機検証で発見したバグの修正、
    /// `onGoToParent` のコメントと同種の問題]。`folder`（`let` で受け取った
    /// 値）を直接読むアクション（ペースト・圧縮・新規フォルダ等、キーボード
    /// ショートカット経由で `KeyBindingButtons` の非表示ボタンから呼ばれる
    /// もの）は、ナビゲーション直後にキー入力すると SwiftUI が古い世代の
    /// `FolderContentView` インスタンス（＝古い `folder` の値）をまだ保持して
    /// いることがあり、1段階古いフォルダを対象に実行されてしまうことがあった
    /// （実機検証: Documents で ⌘X → Documents/Dummy へ移動して ⌘V すると
    /// Documents 側にペーストされる、という形で発覚）。`WindowState` は
    /// クラス（参照型）のため、その場で読み直せば常に最新の値が得られる。
    /// このクロージャは呼び出しのたびに `windowState.tabs[index].folder` を
    /// 読み直す（`MainWindowView` 側の配線を参照）。
    let currentFolder: () -> URL?
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
    /// 特定のウインドウやタブに紐づかないアプリ全体の表示設定。1-12 環境設定
    /// （`DisplayPreferencesTab.swift`/`GeneralPreferencesTab.swift`）が
    /// 同じ `UserDefaults` キーを共有しており、そちらからも変更できる。
    /// ここでは中央ペイン漏斗アイコンメニューの quick access のために
    /// `@AppStorage` で直接参照し続けている。
    @AppStorage("qoo.folderList.showModificationDateColumn") private var showModificationDateColumn = true
    @AppStorage("qoo.folderList.showSizeColumn") private var showSizeColumn = true
    @AppStorage("qoo.folderList.showKindColumn") private var showKindColumn = true
    /// Finder の列選択に合わせて追加した2列 [ユーザー要望: 「現在表示できる
    /// 情報だけでは少ない」]。新規に増やした列のため、既存ユーザーの表示が
    /// 急に増えて煩雑にならないよう既定は非表示にしている（他の3列は
    /// 元から既定 true）。
    @AppStorage("qoo.folderList.showCreationDateColumn") private var showCreationDateColumn = false
    @AppStorage("qoo.folderList.showAddedDateColumn") private var showAddedDateColumn = false
    @AppStorage("qoo.folderList.groupFoldersAtTop") private var groupFoldersAtTop = true
    /// 圧縮・展開の既定値 [環境設定「圧縮／展開」タブ、`CompressionPreferencesTab`
    /// と同じ `UserDefaults` キーを共有]。
    @AppStorage("qoo.preferences.compression.format") private var compressionFormat: CompressibleFormat = .zip
    @AppStorage("qoo.preferences.compression.zipLevel") private var compressionZipLevel: ZipCompressionLevel = .normal
    @AppStorage("qoo.preferences.compression.sevenZipCodec") private var compressionSevenZipCodec: SevenZipCodec = .ppmd
    @AppStorage("qoo.preferences.compression.encryption") private var compressionEncryption: ArchiveEncryptionMethod = .none
    @AppStorage("qoo.preferences.extraction.maxUncompressedGB") private var extractionMaxUncompressedGB: Double = Double(AppLimits.Extraction.defaultMaxUncompressedBytes) / 1_000_000_000
    @AppStorage("qoo.preferences.extraction.maxEntries") private var extractionMaxEntries: Double = Double(AppLimits.Extraction.defaultMaxEntries)
    @AppStorage("qoo.preferences.extraction.ratioWarn") private var extractionRatioWarn: Double = AppLimits.Extraction.defaultRatioWarn
    @AppStorage("qoo.preferences.extraction.ratioAbort") private var extractionRatioAbort: Double = AppLimits.Extraction.defaultRatioAbort
    /// 単一アーカイブ展開でパスワードが必要だった場合の再試行状態
    /// [環境設定「圧縮／展開」タブ]。複数選択の一括展開では対話的な
    /// パスワード再試行を提供しない（`extractArchives` のコメント参照、
    /// スコープを絞った設計判断）。
    @State private var pendingExtractionPassword: PendingExtractionPassword?
    /// 圧縮時にパスワードを尋ねている状態。
    @State private var pendingCompression: PendingCompression?
    /// 非 `nil` の間だけ、その URL までスクロールする [`.onChange(of: pendingScrollTarget)`
    /// 参照]。ユーザー自身のクリックによる選択ではスクロールしないよう、
    /// プログラム的に選択を変える呼び出し元（`runCompress` 等）だけが設定する。
    @State private var pendingScrollTarget: URL?
    /// キーバインド [13章 §13.6]。1-8 時点では開く・リネーム・ゴミ箱・
    /// 新規フォルダのみ実際に配線している（他の既定バインドは対応する
    /// 機能が実装され次第、各所で `keyBindingStore.binding(for:)` を参照する）。
    private let keyBindingStore: KeyBindingStore = UserDefaultsKeyBindingStore.shared
    /// アプリ関連付け [12章 §12.9]。`openEntries`/`OpenWithMenu` から使う。
    private let appAssociationService: AppAssociationService = AppAssociationStore.shared

    var body: some View {
        // 選択がプログラム的に変わったとき（例: 「ここに圧縮」完了後に
        // 作成したアーカイブを選択する）に中央ペインをその項目までスクロール
        // させるための `ScrollViewReader`（`Table`/`IconGridView` 双方の
        // スクロール領域を包む）[ユーザー要望]。
        ScrollViewReader { scrollProxy in
        VStack(alignment: .leading, spacing: 0) {
            if let loadError {
                PlaceholderPane(title: String(localized: "folder.loadError", locale: locale), subtitle: loadError)
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
                    onOpenEntry: { openEntries([$0]) },
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
                    TableColumn("column.name", sortUsing: FolderSortComparator(key: .name)) { entry in
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
                                    TextField("column.name", text: $renameText)
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
                        TableColumn("column.modificationDate", sortUsing: FolderSortComparator(key: .modificationDate)) { entry in
                            rowCell(entry, isRenaming: renamingEntry?.url == entry.url) {
                                Text(entry.modificationDate.map { Self.dateFormatter.string(from: $0) } ?? "—")
                                    .font(.system(size: Tokens.fontSize.body))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .width(min: 110, ideal: 170)
                    }

                    if showSizeColumn {
                        TableColumn("column.size", sortUsing: FolderSortComparator(key: .size)) { entry in
                            rowCell(entry, isRenaming: renamingEntry?.url == entry.url) {
                                Text(entry.isDirectory ? "—" : Self.sizeFormatter.string(fromByteCount: entry.fileSize ?? 0))
                                    .font(.system(size: Tokens.fontSize.body))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .width(min: 70, ideal: 90)
                    }

                    if showKindColumn {
                        TableColumn("column.kind", sortUsing: FolderSortComparator(key: .kind)) { entry in
                            rowCell(entry, isRenaming: renamingEntry?.url == entry.url) {
                                Text(entry.kindDescription)
                                    .font(.system(size: Tokens.fontSize.body))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .width(min: 90, ideal: 140)
                    }

                    if showCreationDateColumn { // [ユーザー要望: Finder に合わせてカラムを増やす]
                        TableColumn("column.creationDate", sortUsing: FolderSortComparator(key: .creationDate)) { entry in
                            rowCell(entry, isRenaming: renamingEntry?.url == entry.url) {
                                Text(entry.creationDate.map { Self.dateFormatter.string(from: $0) } ?? "—")
                                    .font(.system(size: Tokens.fontSize.body))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .width(min: 110, ideal: 170)
                    }

                    if showAddedDateColumn {
                        TableColumn("column.addedDate", sortUsing: FolderSortComparator(key: .addedDate)) { entry in
                            rowCell(entry, isRenaming: renamingEntry?.url == entry.url) {
                                Text(entry.addedDate.map { Self.dateFormatter.string(from: $0) } ?? "—")
                                    .font(.system(size: Tokens.fontSize.body))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .width(min: 110, ideal: 170)
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
                .background(TableHorizontalScrollDisabler())
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
                            .help("folder.iconSize")
                    } else {
                        Menu {
                            Toggle("column.modificationDate", isOn: $showModificationDateColumn)
                            Toggle("column.size", isOn: $showSizeColumn)
                            Toggle("column.kind", isOn: $showKindColumn)
                            Toggle("column.creationDate", isOn: $showCreationDateColumn)
                            Toggle("column.addedDate", isOn: $showAddedDateColumn)
                            Divider()
                            Toggle("preferences.general.groupFoldersAtTop", isOn: $groupFoldersAtTop) // [LV-03]
                        } label: {
                            Image(systemName: "line.3.horizontal.decrease.circle")
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .help("folder.visibleColumns") // [LV-02]
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
                    newFolderName = String(localized: "action.newFolder", locale: locale)
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
                KeyBindingButtons(action: .cut, store: keyBindingStore, isDisabled: selection.isEmpty) {
                    cutSelectionToPasteboard(Array(selection))
                }
                KeyBindingButtons(action: .paste, store: keyBindingStore, isDisabled: !canPaste || folder == nil) {
                    pasteFromPasteboard()
                }
                KeyBindingButtons(action: .selectAll, store: keyBindingStore, isDisabled: entries.isEmpty) {
                    selectAllInCurrentFolder()
                }
                KeyBindingButtons(action: .duplicate, store: keyBindingStore, isDisabled: selection.isEmpty) {
                    duplicate(Array(selection))
                }
                KeyBindingButtons(action: .makeAlias, store: keyBindingStore, isDisabled: selection.isEmpty) {
                    createAliases(for: Array(selection))
                }
                KeyBindingButtons(action: .compress, store: keyBindingStore, isDisabled: selection.isEmpty) {
                    compressHere(Array(selection))
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
        // File/Edit メニューバーへの橋渡し [`FolderMenuActions` 参照]。
        .focusedSceneValue(\.folderMenuActions, currentFolderMenuActions)
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
        .alert("action.newFolder", isPresented: $showingNewFolderPrompt) {
            TextField("folder.namePlaceholder", text: $newFolderName)
            Button("common.create") { createNewFolder() }
            Button("common.cancel", role: .cancel) {}
        }
        // 圧縮時のパスワード設定 [環境設定「圧縮／展開」タブ]。
        .sheet(item: $pendingCompression) { pending in
            ArchivePasswordSheet(mode: .setPassword) { password in
                runCompress(
                    pending.items, destinationName: pending.destinationName, destinationFolder: pending.destinationFolder,
                    options: pending.options, passphrase: password, conflictPolicy: pending.conflictPolicy
                )
            }
        }
        // 展開時のパスワード入力・誤りパスワードの再試行 [同上]。
        .sheet(item: $pendingExtractionPassword) { pending in
            ArchivePasswordSheet(mode: .unlock(retryErrorMessage: pending.retryErrorMessage)) { password in
                extractArchives([pending.archiveURL], destination: { _ in pending.target }, passphrase: password)
            }
        }
        // `pendingScrollTarget` が設定されたときだけスクロールする
        // [実機検証で発見したバグの修正: 以前は `.onChange(of: selection)` で
        // あらゆる選択変更のたびにスクロールしていたため、ユーザーが中央
        // ペイン内の既に見えている項目をクリックしただけで画面が中央寄せに
        // ジャンプしてしまっていた。「ここに圧縮」後に作成したファイルまで
        // スクロールしたいのはプログラム的に選択を変えたときだけであり、
        // ユーザー自身のクリックによる選択ではスクロールすべきではない
        // （ユーザー指摘）。`runCompress` など、明示的にスクロールが必要な
        // 呼び出し元だけが `pendingScrollTarget` を設定する]。
        .onChange(of: pendingScrollTarget) { _, newValue in
            guard let target = newValue else { return }
            withAnimation {
                scrollProxy.scrollTo(target, anchor: .center)
            }
            pendingScrollTarget = nil
        }
        }
    }

    /// `FolderMenuActions` の値。File/Edit メニューの各項目はこの値を通じて
    /// 現在のフォルダ・選択に対して動作する [`.focusedSceneValue` の呼び出し
    /// 箇所参照]。
    private var currentFolderMenuActions: FolderMenuActions {
        let selected = Array(selection)
        var actions = FolderMenuActions()
        actions.canOpen = !selection.isEmpty
        actions.canNewFolder = folder != nil
        actions.canNewFolderWithSelection = folder != nil && !selection.isEmpty
        actions.canRename = selection.count == 1
        actions.canDuplicate = !selection.isEmpty
        actions.canMakeAlias = !selection.isEmpty
        actions.canCompress = !selection.isEmpty
        actions.canMoveToTrash = !selection.isEmpty
        actions.canCopy = !selection.isEmpty
        actions.canCut = !selection.isEmpty
        actions.canPaste = canPaste && folder != nil
        actions.canSelectAll = !entries.isEmpty
        actions.canRevealInFinder = !selection.isEmpty

        actions.open = { openSelection() }
        actions.newFolder = {
            newFolderName = String(localized: "action.newFolder", locale: locale)
            showingNewFolderPrompt = true
        }
        actions.newFolderWithSelection = { newFolderWithSelection(selected) }
        actions.rename = { beginRenameFromShortcut() }
        actions.duplicate = { duplicate(selected) }
        actions.makeAlias = { createAliases(for: selected) }
        actions.compress = { compressHere(selected) }
        actions.moveToTrash = { moveToTrash(selected) }
        actions.copy = { copySelectionToPasteboard(selected) }
        actions.cut = { cutSelectionToPasteboard(selected) }
        actions.paste = { pasteFromPasteboard() }
        actions.selectAll = { selectAllInCurrentFolder() }
        actions.revealInFinder = { NSWorkspace.shared.activateFileViewerSelecting(selected) }
        return actions
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
                    // [実機検証で発見したバグの修正] 以前はフォルダのときだけ
                    // `onNavigate` を呼んでおり、ファイルのダブルクリックが
                    // 何も起きなかった（環境設定「関連付け」タブで既定アプリを
                    // 設定しても反映されない、という報告の真因だった）。
                    // `openEntries` はフォルダ/ファイルの判定を内部で行う。
                    openEntries([entry])
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
            Menu("common.view") { // [LV-04]
                Picker("common.view", selection: $listStyle) {
                    Label("common.list", systemImage: "list.bullet").tag(ListStyle.list)
                    Label("common.icon", systemImage: "square.grid.2x2").tag(ListStyle.icon)
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
            Menu("common.sortBy") { // [LV-01]
                Picker("common.sortBy", selection: sortKeyBinding) {
                    Text("column.name").tag(FolderSortComparator.Key.name)
                    Text("column.modificationDate").tag(FolderSortComparator.Key.modificationDate)
                    Text("column.size").tag(FolderSortComparator.Key.size)
                    Text("column.kind").tag(FolderSortComparator.Key.kind)
                    Text("column.creationDate").tag(FolderSortComparator.Key.creationDate)
                    Text("column.addedDate").tag(FolderSortComparator.Key.addedDate)
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
            Divider()
            Button("action.newFolder") {
                newFolderName = String(localized: "action.newFolder", locale: locale)
                showingNewFolderPrompt = true
            }
            Button("action.paste") { pasteFromPasteboard() }
                .disabled(!canPaste)
            // Finder は空きスペースの右クリックにも「すべて選択」を出す
            // [Finder/Edit メニュー整備の一環で追加]。
            Button("action.selectAll") { selectAllInCurrentFolder() }
                .disabled(entries.isEmpty)
        } else {
            let targets = Array(urls)
            let targetEntries = entries.filter { urls.contains($0.url) }
            Button("action.open") { openEntries(targetEntries) } // [KB-02 相当]
            // 「アプリケーションで開く」[12章 §12.9、単一選択のファイルのみ。
            // フォルダは拡張子を持たず `candidates(for:)` の対象にならない
            // ため対象外にしている]。
            if targets.count == 1, let only = targetEntries.first, !only.isDirectory {
                OpenWithMenu(url: only.url)
            }
            if targetEntries.allSatisfy(\.isDirectory) {
                // 新規タブ/ウインドウで開くはフォルダのみ意味を持つ。Finder は
                // 複数選択なら選択したフォルダの数だけタブ/ウインドウを開く。
                Button(targets.count == 1 ? "folder.openInNewTab" : "folder.openEachInNewTab") {
                    targets.forEach(onOpenInNewTab)
                }
                Button(targets.count == 1 ? "folder.openInNewWindow" : "folder.openEachInNewWindow") {
                    targets.forEach(onOpenInNewWindow)
                }
            }
            Divider()
            // 名前を変更はバッチ名変更 UI が無いため単一対象時のみ。
            if targets.count == 1, let only = targetEntries.first {
                Button("folder.renameEllipsis") { beginRename(only) } // [FM-05]
            }
            Button("folder.duplicate") { duplicate(targets) } // [FM-02]
            Button("action.copy") { copySelectionToPasteboard(targets) } // [KB-02 相当、⌘C]
            Button("action.cut") { cutSelectionToPasteboard(targets) } // [Finder/Edit メニュー整備、⌘X]
            // Finder の「選択項目で新規フォルダを作成」[Finder/Edit メニュー整備]。
            // 移動先を作る操作のため、フォルダ自身が対象に混ざっていても
            // Finder と同じく無条件に出す。
            Button("action.newFolderWithSelection") { newFolderWithSelection(targets) }
            Divider()
            Button("folder.moveToTrash", role: .destructive) { moveToTrash(targets) } // [FM-04]
            Divider()
            // 圧縮・展開関連をサブメニューにまとめる [ユーザー要望]。
            Menu("folder.compressExtractSubmenu") {
                Button("folder.compressHere") { compressHere(targets) } // [AR-10]
                Button("folder.compressEllipsis") { compressWithDialog(targets) } // [AR-11]
                if isExtractable(targets) {
                    Divider()
                    Button("folder.extractInPlace") { extractInPlace(targets) } // [AR-20]
                    if targets.count == 1, let single = targets.first {
                        Button(String(format: String(localized: "folder.extractToNamed", locale: locale), archiveBaseName(single))) { extractToNamedFolders(targets) } // [AR-21]
                    } else {
                        Button("folder.extractEachToOwnFolder") { extractToNamedFolders(targets) } // [AR-23]
                    }
                    Button("folder.extractEllipsis") { extractToChosenDestination(targets) } // [AR-22]
                }
            }
            Divider()
            Button("folder.revealInFinder") { NSWorkspace.shared.activateFileViewerSelecting(targets) } // [FM-09]
            Button("folder.copyPath") { copyPaths(targets) } // [FM-10]
            ShareLink("folder.shareEllipsis", items: targets) // [共有、既定ラベルが英語 "Share..." になるため明示的に指定]
            Button("folder.createAlias") { createAliases(for: targets) }
            Divider()
            Button(targetEntries.allSatisfy(\.isLocked) ? "folder.unlock" : "folder.lock") {
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
            let keys: Set<URLResourceKey> = [
                .isDirectoryKey, .fileSizeKey, .contentModificationDateKey,
                .creationDateKey, .addedToDirectoryDateKey, .isUserImmutableKey,
            ]
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
                    creationDate: values?.creationDate,
                    addedDate: values?.addedToDirectoryDate,
                    isLocked: values?.isUserImmutable ?? false
                )
            }
            loadError = nil
            // ゴミ箱・移動等で消えた項目を選択から取り除く [実機検証で発見:
            // ファイルをゴミ箱に入れても `selection` に URL が残ったままになり、
            // 右ペインのインスペクタ（`InspectorPane`）が `.task(id: url)` の
            // id（＝ URL 自体）が変わらないため削除前の情報を表示し続けて
            // いた]。選択が空になれば `InspectorPane` は現在のフォルダ自身の
            // 情報表示にフォールバックする（既存の設計）。
            let currentURLs = Set(entries.map(\.url))
            selection.formIntersection(currentURLs)
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
                NotificationItem(category: .error, severity: .sheet, title: String(localized: "error.operationFailed", locale: locale), body: message)
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
        // 素のコピーはカット状態を打ち消す（さもないと直前のカットが
        // 後続のペーストで誤って移動として処理されてしまう）。
        SessionState.shared.cutURLs = []
    }

    /// `⌘X`/コンテキストメニュー「カット」[Finder/Edit メニュー整備の一環で追加]。
    /// Finder 自身のカット判定はプライベート API 頼りで他アプリと相互運用
    /// できないため、`SessionState.cutURLs`（アプリ内で完結する簡易な独自実装、
    /// 型のコメント参照）で「次のペーストは移動にする」ことだけを覚えておく。
    /// ペーストボードへの書き込み自体は `copySelectionToPasteboard` と同じ
    /// （Finder への貼り付け自体はコピーとして成立する。カットの伝搬は
    /// アプリ内ペースト時のみ有効）。
    private func cutSelectionToPasteboard(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects(urls as [NSURL])
        SessionState.shared.cutURLs = Set(urls.map { $0.standardizedFileURL.path })
    }

    /// `⌘V`/コンテキストメニュー「ペースト」。ペーストボード上のファイル URL が
    /// 直前にカットされた集合と一致すれば移動、そうでなければコピー
    /// （Finder の `⌘V` と同じ既定）。**パス文字列（`standardizedFileURL.path`）で
    /// 比較する** — 生の `URL` 同士の `==` はペーストボード往復後の表現差異
    /// （末尾スラッシュ等）で一致しないことがあった [実機検証で発見、
    /// `SessionState.cutURLs` のコメント参照]。
    private func pasteFromPasteboard() {
        guard let folder = currentFolder(),
              let urls = NSPasteboard.general.readObjects(forClasses: [NSURL.self]) as? [URL],
              !urls.isEmpty
        else { return }
        let isCutPaste = !SessionState.shared.cutURLs.isEmpty
            && Set(urls.map { $0.standardizedFileURL.path }) == SessionState.shared.cutURLs
        Task {
            do {
                if isCutPaste {
                    _ = try await CommandStack.shared.run(MoveFilesCommand(items: urls, destination: folder))
                    SessionState.shared.cutURLs = []
                } else {
                    _ = try await CommandStack.shared.run(CopyFilesCommand(items: urls, destination: folder))
                }
                reloadAndBroadcast()
            } catch {
                presentError(error, whatHappened: String(localized: "error.pasteFailed", locale: locale))
            }
        }
    }

    private var canPaste: Bool {
        NSPasteboard.general.canReadObject(forClasses: [NSURL.self], options: nil)
    }

    /// `⌘A`/空きスペースの右クリック「すべて選択」[Finder/Edit メニュー整備]。
    private func selectAllInCurrentFolder() {
        guard !entries.isEmpty else { return }
        selection = Set(entries.map(\.url))
    }

    /// Finder の「選択項目で新規フォルダを作成」[Finder/Edit メニュー整備]。
    /// 新規フォルダの作成と選択項目の移動を 1 つの Undo 単位にまとめる [UD-04]。
    /// 衝突時にコマンド自体が失敗しないよう、事前にフォルダ名の空きを探す
    /// （Finder の「新規フォルダ」「新規フォルダ 2」…と同じ体裁）。
    private func newFolderWithSelection(_ urls: [URL]) {
        guard let folder = currentFolder(), !urls.isEmpty else { return }
        let baseName = String(localized: "action.newFolderWithSelection.baseName", locale: locale)
        var candidate = folder.appendingPathComponent(baseName)
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(baseName) \(suffix)")
            suffix += 1
        }
        let children: [any Command] = [
            CreateFolderCommand(url: candidate),
            MoveFilesCommand(items: urls, destination: candidate),
        ]
        guard let command = Self.singleOrComposite(children, displayName: String(localized: "action.newFolderWithSelection", locale: locale)) else { return }
        Task {
            do {
                _ = try await CommandStack.shared.run(command)
                selection = [candidate]
                reloadAndBroadcast()
            } catch {
                presentError(error, whatHappened: String(localized: "error.newFolderWithSelectionFailed", locale: locale))
            }
        }
    }

    private func createAliases(for urls: [URL]) {
        guard let folder = currentFolder() else { return }
        let children: [any Command] = urls.map { CreateAliasCommand(source: $0, destinationFolder: folder) }
        guard let command = Self.singleOrComposite(children, displayName: String(localized: "folder.createAlias", locale: locale)) else { return }
        Task {
            do {
                _ = try await CommandStack.shared.run(command)
                reloadAndBroadcast()
            } catch {
                presentError(error, whatHappened: String(localized: "error.createAliasFailed", locale: locale))
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
                presentError(error, whatHappened: String(localized: shouldLock ? "error.lockFailed" : "error.unlockFailed", locale: locale))
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
    ///
    /// [実機検証で発見: 環境設定「関連付け」タブで既定アプリを設定しても
    /// ダブルクリックで反映されなかったバグの修正] ファイルは
    /// `AppAssociationService.open(_:with: nil)` 経由で開く — `nil` を渡すと
    /// 内部で qooLibrary の関連付け設定（`primary(for:)`）→ 無ければシステムの
    /// 既定アプリの順にフォールバックする（`AppAssociationStore.open(_:with:)`
    /// 参照）。以前は `NSWorkspace.shared.open(url)` を直に呼んでおり、
    /// 常にシステムの既定アプリで開いてしまっていた。
    private func openEntries(_ targets: [FolderEntry]) {
        if targets.count == 1, let only = targets.first {
            if only.isDirectory {
                onNavigate(only.url)
            } else {
                openWithAssociation(only.url)
            }
            return
        }
        for target in targets where !target.isDirectory {
            openWithAssociation(target.url)
        }
    }

    /// [ER-01] 開くのに失敗した場合もエラーを握りつぶさず提示する。
    private func openWithAssociation(_ url: URL) {
        Task {
            do {
                try await appAssociationService.open([url], with: nil)
            } catch {
                presentError(error, whatHappened: String(localized: "error.openFailed", locale: locale))
            }
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
                presentError(error, whatHappened: String(localized: "error.renameFailed", locale: locale))
            }
        }
    }

    private func cancelRename() {
        renamingEntry = nil
    }

    private func duplicate(_ urls: [URL]) {
        guard let folder = currentFolder() else { return }
        Task {
            do {
                _ = try await CommandStack.shared.run(CopyFilesCommand(items: urls, destination: folder))
                reloadAndBroadcast()
            } catch {
                presentError(error, whatHappened: String(localized: "error.duplicateFailed", locale: locale))
            }
        }
    }

    private func moveToTrash(_ urls: [URL]) {
        Task {
            do {
                _ = try await CommandStack.shared.run(TrashCommand(items: urls))
                reloadAndBroadcast()
            } catch {
                presentError(error, whatHappened: String(localized: "error.trashFailed", locale: locale))
            }
        }
    }

    private func createNewFolder() {
        guard let folder = currentFolder(), !newFolderName.isEmpty else { return }
        Task {
            do {
                _ = try await CommandStack.shared.run(CreateFolderCommand(url: folder.appendingPathComponent(newFolderName)))
                reloadAndBroadcast()
            } catch {
                presentError(error, whatHappened: String(localized: "error.createFolderFailed", locale: locale))
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

    /// 展開時の安全上限 [環境設定「圧縮／展開」タブ]。GB 単位で保存している
    /// ため `ExtractLimits.maxUncompressedBytes`（バイト単位）へ変換する。
    private var currentExtractLimits: ExtractLimits {
        ExtractLimits(
            maxUncompressedBytes: Int64(extractionMaxUncompressedGB * 1_000_000_000),
            maxEntries: Int(extractionMaxEntries),
            ratioWarn: extractionRatioWarn,
            ratioAbort: extractionRatioAbort
        )
    }

    /// 展開先フォルダを新規作成する場合は `CreateFolderCommand` + `ExtractCommand`
    /// を 1 つの Undo 単位にまとめる [UD-04]。複数アーカイブの一括展開も
    /// まとめて 1 単位にする（`MX2-08` の精神）。途中で失敗したら残りは中断する
    /// 暫定対応 [ER-20 の趣旨に近い、`BatchNotificationSession`〈結果サマリ・
    /// 部分失敗の集約〉はまだ実装していないため]。
    ///
    /// **パスワードの対話的な再試行は単一アーカイブ展開時のみ提供する**
    /// [環境設定「圧縮／展開」タブ、設計判断]。複数選択の一括展開中に
    /// パスワード保護されたアーカイブに遭遇した場合、どれが原因か・途中まで
    /// 成功した分をどう扱うかの UX が複雑になるため、通常のエラー表示に
    /// 留める（対話的な再試行は行わない）。
    private func extractArchives(_ urls: [URL], destination: @escaping (URL) -> URL, passphrase: String? = nil) {
        busyMessage = urls.count == 1
            ? String(localized: "folder.extractingOne", locale: locale)
            : String(format: String(localized: "folder.extractingCount", locale: locale), urls.count)
        let limits = currentExtractLimits
        var children: [any Command] = []
        for url in urls {
            let target = destination(url)
            if !FileManager.default.fileExists(atPath: target.path) {
                children.append(CreateFolderCommand(url: target))
            }
            let entryPassphrase = urls.count == 1 ? passphrase : nil
            children.append(ExtractCommand(archiveURL: url, destination: target, limits: limits, passphrase: entryPassphrase))
        }
        let name = urls.count == 1
            ? String(format: String(localized: "folder.extractCommandName", locale: locale), urls[0].lastPathComponent)
            : String(format: String(localized: "folder.extractCommandNameCount", locale: locale), urls.count)
        guard let command = Self.singleOrComposite(children, displayName: name) else {
            busyMessage = nil
            return
        }
        Task {
            defer { busyMessage = nil }
            do {
                _ = try await CommandStack.shared.run(command)
                reloadAndBroadcast()
            } catch let error as ExtractError where urls.count == 1 && (error == .passwordProtected || error == .incorrectPassphrase) {
                let retryMessage = error == .incorrectPassphrase ? String(localized: "error.incorrectPassphrase", locale: locale) : nil
                pendingExtractionPassword = PendingExtractionPassword(
                    archiveURL: urls[0], target: destination(urls[0]), retryErrorMessage: retryMessage
                )
            } catch {
                presentError(error, whatHappened: String(localized: "error.extractFailed", locale: locale))
                reloadAndBroadcast()
            }
        }
    }

    private func extractInPlace(_ urls: [URL]) {
        guard let folder = currentFolder() else { return }
        extractArchives(urls) { _ in folder } // [AR-20]
    }

    private func extractToNamedFolders(_ urls: [URL]) {
        guard let folder = currentFolder() else { return }
        extractArchives(urls) { folder.appendingPathComponent(archiveBaseName($0)) } // [AR-21][AR-23]
    }

    private func extractToChosenDestination(_ urls: [URL]) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "folder.extractPanelPrompt", locale: locale)
        panel.message = String(localized: "folder.chooseExtractDestination", locale: locale)
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        extractArchives(urls) { _ in destination } // [AR-22]
    }

    /// 現在の環境設定から `CompressionOptions` を組み立てる
    /// [環境設定「圧縮／展開」タブ]。
    private var currentCompressionOptions: CompressionOptions {
        CompressionOptions(
            format: compressionFormat, zipLevel: compressionZipLevel,
            sevenZipCodec: compressionSevenZipCodec, encryption: compressionEncryption
        )
    }

    /// 単一選択時は項目名、複数選択時はカレントフォルダ名 [AR-10]。暗号化が
    /// 有効な場合はパスワードシートを挟んでから実行する
    /// [環境設定「圧縮／展開」タブ]。
    private func compressHere(_ urls: [URL]) {
        guard let folder = currentFolder(), !urls.isEmpty else { return }
        let name = urls.count == 1 ? archiveBaseName(urls[0]) : folder.lastPathComponent
        let options = currentCompressionOptions
        guard options.encryption != .none else {
            runCompress(urls, destinationName: name, destinationFolder: folder, options: options, passphrase: nil)
            return
        }
        pendingCompression = PendingCompression(items: urls, destinationName: name, destinationFolder: folder, options: options, conflictPolicy: .keepBoth)
    }

    /// ファイル名・保存先を指定するダイアログ。zip/7z は環境設定の既定形式に
    /// 従う [AR-11]。
    private func compressWithDialog(_ urls: [URL]) {
        guard let folder = currentFolder(), !urls.isEmpty else { return }
        let options = currentCompressionOptions
        let ext = options.format == .zip ? "zip" : "7z"
        let defaultName = urls.count == 1 ? archiveBaseName(urls[0]) : folder.lastPathComponent
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(defaultName).\(ext)"
        panel.allowedContentTypes = options.format == .zip ? [.zip] : []
        panel.directoryURL = folder
        panel.prompt = String(localized: "folder.compressPanelPrompt", locale: locale)
        panel.message = String(localized: "folder.chooseSaveDestination", locale: locale)
        guard panel.runModal() == .OK, let destinationURL = panel.url else { return }
        let destinationFolder = destinationURL.deletingLastPathComponent()
        let name = destinationURL.deletingPathExtension().lastPathComponent
        // NSSavePanel は既存ファイルの上書き確認を既に行っているため、
        // ここでは `.keepBoth`（自動連番）ではなく `.replace` にする。
        guard options.encryption != .none else {
            runCompress(urls, destinationName: name, destinationFolder: destinationFolder, options: options, passphrase: nil, conflictPolicy: .replace)
            return
        }
        pendingCompression = PendingCompression(items: urls, destinationName: name, destinationFolder: destinationFolder, options: options, conflictPolicy: .replace)
    }

    private func runCompress(
        _ items: [URL], destinationName: String, destinationFolder: URL,
        options: CompressionOptions, passphrase: String?, conflictPolicy: ConflictPolicy = .keepBoth
    ) {
        busyMessage = String(localized: "folder.compressing", locale: locale)
        Task {
            defer { busyMessage = nil }
            do {
                // 完了後に作成したアーカイブを選択状態にするため、`CommandStack`
                // に渡す前に具体的な型のまま変数へ保持しておく（`CompressCommand`
                // は `final class` のため、`run(_:)` 実行後も同じインスタンスの
                // `resultURL` を読める）[ユーザー要望]。
                let command = CompressCommand(
                    items: items, destinationName: destinationName, destinationFolder: destinationFolder,
                    options: options, passphrase: passphrase, conflictPolicy: conflictPolicy
                )
                _ = try await CommandStack.shared.run(command)
                reloadAndBroadcast()
                if let resultURL = command.resultURL {
                    selection = [resultURL]
                    pendingScrollTarget = resultURL
                }
            } catch {
                presentError(error, whatHappened: String(localized: "error.compressFailed", locale: locale))
            }
        }
    }
}

/// 圧縮時にパスワードシートを表示するための保留状態
/// [環境設定「圧縮／展開」タブ]。
private struct PendingCompression: Identifiable {
    let id = UUID()
    let items: [URL]
    let destinationName: String
    let destinationFolder: URL
    let options: CompressionOptions
    let conflictPolicy: ConflictPolicy
}

/// 単一アーカイブ展開でパスワードが必要だった場合の再試行状態
/// [環境設定「圧縮／展開」タブ]。
private struct PendingExtractionPassword: Identifiable {
    let id = UUID()
    let archiveURL: URL
    let target: URL
    let retryErrorMessage: String?
}

/// 「アプリケーションで開く」サブメニュー [12章 §12.9、ユーザー要望]。
/// `AppAssociationService.candidates(for:)` を非同期で読み込んで列挙する。
/// `.task(id: url)` は `Menu` の中身として組み立てられた時点（右クリックで
/// コンテキストメニューを開いた時点）で発火するため、候補アプリの探索は
/// サブメニューへ実際にカーソルを合わせる前から先行して始まる。
private struct OpenWithMenu: View {
    @Environment(\.locale) private var locale
    let url: URL

    private let service: AppAssociationService = AppAssociationStore.shared
    @State private var candidates: [AppCandidate] = []

    var body: some View {
        Menu("folder.openWithSubmenu") {
            ForEach(candidates) { candidate in
                Button {
                    Task { try? await service.open([url], with: candidate.bundleID) }
                } label: {
                    Label {
                        Text(candidate.name)
                    } icon: {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: candidate.url.path))
                    }
                }
            }
            if !candidates.isEmpty {
                Divider()
            }
            Button("folder.openWithOtherEllipsis") { chooseOtherApplication() }
        }
        .task(id: url) {
            candidates = await service.candidates(for: url.pathExtension)
        }
    }

    /// Finder の「Open With > その他…」相当。選んだアプリはこの1回だけ使う
    /// （既定アプリとして保存するかどうかは環境設定「関連付け」タブの役割）。
    private func chooseOtherApplication() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = String(localized: "folder.openWithChoosePrompt", locale: locale)
        guard panel.runModal() == .OK, let appURL = panel.url,
              let bundle = Bundle(url: appURL), let bundleID = bundle.bundleIdentifier
        else { return }
        Task { try? await service.open([url], with: bundleID) }
    }
}

struct FolderEntry: Identifiable {
    var id: URL { url }
    let url: URL
    let name: String
    let isDirectory: Bool
    let fileSize: Int64?
    let modificationDate: Date?
    /// Finder の「作成日」列相当 [ユーザー要望: Finder に合わせてカラムを増やす]。
    let creationDate: Date?
    /// Finder の「追加日」列相当（このフォルダへ作成/移動/リネームされた日時）。
    let addedDate: Date?
    let isLocked: Bool

    /// zip/7z/rar/tar.gz（cbz/cb7/cbr のエイリアス含む）と認識できるファイル
    /// [AR-20〜AR-23]。フォルダは対象外。
    var archiveFormat: ArchiveFormat? {
        isDirectory ? nil : ArchiveFormat.from(filename: name)
    }

    /// Finder の「種類」列相当 [LV-01]。`UTType` の `localizedDescription` を使う。
    var kindDescription: String {
        // `FolderEntry` は View ではないため `@Environment(\.locale)` を
        // 持てず、`AppLanguage.effectiveLocale` を使う
        // [1-12 ローカライズ方針、CLAUDE.md 参照]。
        let locale = AppLanguage.effectiveLocale
        if isDirectory { return String(localized: "kind.folder", locale: locale) }
        let ext = url.pathExtension
        if !ext.isEmpty, let type = UTType(filenameExtension: ext), let description = type.localizedDescription {
            return description
        }
        guard !ext.isEmpty else { return String(localized: "kind.document", locale: locale) }
        return String(format: String(localized: "kind.extensionFile", locale: locale), ext.uppercased())
    }
}

/// リスト表示の全カラム共通のソートキー [LV-01]。`Table` の `sortOrder` は
/// 単一のコンパレータ型の配列を要求するため、キーの種類を enum で切り替える
/// 1つの型にまとめている（各カラムがそれぞれ別のコンパレータ型を持つことはできない）。
private struct FolderSortComparator: SortComparator {
    enum Key: Hashable {
        case name, modificationDate, size, kind, creationDate, addedDate
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
        case .creationDate:
            let l = lhs.creationDate ?? .distantPast
            let r = rhs.creationDate ?? .distantPast
            result = l == r ? .orderedSame : (l < r ? .orderedAscending : .orderedDescending)
        case .addedDate:
            let l = lhs.addedDate ?? .distantPast
            let r = rhs.addedDate ?? .distantPast
            result = l == r ? .orderedSame : (l < r ? .orderedAscending : .orderedDescending)
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

/// `Table`（`NSTableView`/`NSScrollView` 内包）の水平方向のスクロールバー・
/// 端でのバウンスを見た目だけ抑える [マウス・トラックパッドでの戻る/進む機能
/// `BackForwardGestureSupport` 実装時に追加]。`Table` の4カラムがウインドウ幅を
/// 超えるとカラムが見切れるが、ウインドウ幅を広げる／カラムを非表示にする
/// （LV-02）ことで対処できるため、このトレードオフを許容する。
///
/// **実際に横スワイプのジェスチャーを `Table` に渡さないようにする本体の対処は
/// ここではなく `BackForwardGestureSupport.swift` 側で行っている**（横方向優位の
/// `.scrollWheel` イベントをグローバルモニタの段階で `nil` を返して握りつぶし、
/// `Table` を含め以降どの view にも配送されないようにする）。当初はここで
/// `Table` の内部 `NSScrollView`（実体は `ListCoreScrollView`、SwiftUI 内部の
/// private なサブクラス）を実行時に isa 差し替え（`object_setClass`）して
/// `scrollWheel(with:)` を上書きする方式を試したが、`ListCoreScrollView` 独自の
/// 描画・挙動（実機のビュー階層ダンプで確認した `NSScrollPocket`/`BackdropView`
/// 等の視覚効果）を丸ごと破壊するリスクがあり、かつ `.background()` で配置した
/// このビューは `Table` の内部スクロールビューの子孫ではなく共通の祖先を持つ
/// 「兄弟」だったため `enclosingScrollView`（祖先方向のみ探索）では見つけられ
/// ないことも判明した。イベント配送そのものを止める方が対象の型に依存せず
/// 安全なため、そちらへ切り替えた。
private struct TableHorizontalScrollDisabler: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        TableHorizontalScrollDisablerView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class TableHorizontalScrollDisablerView: NSView {
    private var hasApplied = false

    override var intrinsicContentSize: NSSize { NSSize(width: 0, height: 0) }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyIfNeeded()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        applyIfNeeded()
    }

    private func applyIfNeeded() {
        guard !hasApplied, let scrollView = enclosingScrollView else { return }
        hasApplied = true
        scrollView.hasHorizontalScroller = false
        scrollView.horizontalScrollElasticity = .none
    }
}
