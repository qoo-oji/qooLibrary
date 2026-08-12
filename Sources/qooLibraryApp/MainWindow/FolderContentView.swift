import AppKit
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

    @State private var entries: [FolderEntry] = []
    @State private var loadError: String?
    @State private var actionError: String?
    @State private var renamingEntry: FolderEntry?
    @State private var renameText = ""
    @State private var showingNewFolderPrompt = false
    @State private var newFolderName = "新規フォルダ"
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
    /// 「情報を見る」で表示する対象。1-10（右ペイン詳細情報）の本実装までの
    /// 暫定的な簡易シート。
    @State private var infoTargets: [FolderEntry]?
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

    private let fileOps = FileOperationService.shared
    /// キーバインド [13章 §13.6]。1-8 時点では開く・リネーム・ゴミ箱・
    /// 新規フォルダのみ実際に配線している（他の既定バインドは対応する
    /// 機能が実装され次第、各所で `keyBindingStore.binding(for:)` を参照する）。
    private let keyBindingStore: KeyBindingStore = UserDefaultsKeyBindingStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let folder {
                HStack {
                    Text(folder.path)
                        .font(.system(size: Tokens.fontSize.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                    Spacer()
                    if listStyle == .icon { // [IV-04]
                        Slider(value: $iconSize, in: Tokens.iconSize.min...Tokens.iconSize.max, step: Tokens.iconSize.step)
                            .frame(width: 100)
                            .help("アイコンサイズ")
                    }
                    Picker("表示", selection: $listStyle) { // [TB-04][LV-04]
                        Image(systemName: "list.bullet").tag(ListStyle.list)
                        Image(systemName: "square.grid.2x2").tag(ListStyle.icon)
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                    .labelsHidden()
                    if listStyle == .list {
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
                    Button {
                        newFolderName = "新規フォルダ"
                        showingNewFolderPrompt = true
                    } label: {
                        Image(systemName: "folder.badge.plus")
                    }
                    .buttonStyle(.borderless)
                    .help("新規フォルダを作成") // [FM-01]
                }
                .padding(.horizontal, Tokens.spacing.m)
                .padding(.vertical, Tokens.spacing.xs)
            }

            if let loadError {
                PlaceholderPane(title: "読み込みエラー", subtitle: loadError)
            } else if entries.isEmpty {
                PlaceholderPane(title: "空のフォルダ", subtitle: "")
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
                    onDropFailure: { actionError = $0 },
                    contextMenuContent: { urls in contextMenuContent(for: urls) }
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
                        rowCell(entry) {
                            // アイコンを固定幅の枠に収めて Finder のように先頭を揃える
                            // （実機検証で発覚: アイコンの実測幅がまちまちだと名前の
                            // 先頭位置がずれる）。Finder と同じアイコン [ユーザー要望、
                            // `FileIconProvider` 参照]。
                            HStack(spacing: Tokens.spacing.xs) {
                                Image(nsImage: FileIconProvider.shared.icon(for: entry.url))
                                    .resizable()
                                    .frame(width: 16, height: 16)
                                Text(entry.name)
                            }
                            .font(.system(size: Tokens.fontSize.body))
                        }
                    }
                    .width(min: 160, ideal: 280)

                    if showModificationDateColumn {
                        TableColumn("更新日", sortUsing: FolderSortComparator(key: .modificationDate)) { entry in
                            rowCell(entry) {
                                Text(entry.modificationDate.map { Self.dateFormatter.string(from: $0) } ?? "—")
                                    .font(.system(size: Tokens.fontSize.body))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .width(min: 110, ideal: 170)
                    }

                    if showSizeColumn {
                        TableColumn("サイズ", sortUsing: FolderSortComparator(key: .size)) { entry in
                            rowCell(entry) {
                                Text(entry.isDirectory ? "—" : Self.sizeFormatter.string(fromByteCount: entry.fileSize ?? 0))
                                    .font(.system(size: Tokens.fontSize.body))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .width(min: 70, ideal: 90)
                    }

                    if showKindColumn {
                        TableColumn("種類", sortUsing: FolderSortComparator(key: .kind)) { entry in
                            rowCell(entry) {
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
            DropHandling.performDrop(items, into: folder, onComplete: { reloadAndBroadcast() }, onFailure: { actionError = $0 })
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
        .alert("名前を変更", isPresented: renamingBinding) {
            TextField("名前", text: $renameText)
            Button("変更") { commitRename() }
            Button("キャンセル", role: .cancel) {}
        }
        .alert("新規フォルダ", isPresented: $showingNewFolderPrompt) {
            TextField("フォルダ名", text: $newFolderName)
            Button("作成") { createNewFolder() }
            Button("キャンセル", role: .cancel) {}
        }
        .alert("操作に失敗しました", isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
            Button("OK") {}
        } message: {
            Text(actionError ?? "")
        }
        .sheet(isPresented: Binding(get: { infoTargets != nil }, set: { if !$0 { infoTargets = nil } })) {
            if let infoTargets {
                FileInfoSheet(entries: infoTargets, sizeFormatter: Self.sizeFormatter, dateFormatter: Self.dateFormatter)
            }
        }
    }

    private var renamingBinding: Binding<Bool> {
        Binding(get: { renamingEntry != nil }, set: { if !$0 { renamingEntry = nil } })
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

    /// 各カラムのセルに共通の行操作（選択・ダブルクリック・コンテキストメニュー・
    /// ドラッグ＆ドロップ）をまとめて適用する。`Table` は `List` と違いカラムごとに
    /// 独立したセルなので、Finder と同じく行のどこをクリックしても同じ挙動に
    /// なるよう、すべてのカラムのセルに同一の modifier 一式を付与する。
    @ViewBuilder
    private func rowCell(_ entry: FolderEntry, @ViewBuilder content: () -> some View) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
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
                onFailure: { actionError = $0 }
            ))
    }

    /// D&D 系のモディファイアを付けた行は List/Table 標準のクリック選択が
    /// ハイライト込みで効かなくなることがあるため、明示的に選択する
    /// （Cmd でトグル・Shift で範囲選択、という Finder 流の規則もここで手動で
    /// 再現する）。範囲選択は画面表示順（`displayedEntries`）で計算する。
    private func handleSingleClick(_ entry: FolderEntry) {
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
            // 既に複数選択の一部になっている行は潰さない
            // （そうしないと複数選択した状態でドラッグを開始しても単一行しか
            // ドラッグに含まれなくなる）。
            if !selection.contains(entry.url) {
                selection = [entry.url]
            }
            selectionAnchor = entry.url
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
            // 空きスペースの右クリック。
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
            Button("情報を見る") { infoTargets = targetEntries } // [簡易版、1-10 で本実装]
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
                _ = try await fileOps.copy(urls, to: folder, options: OpOptions(conflictPolicy: .keepBoth))
                reloadAndBroadcast()
            } catch {
                actionError = error.localizedDescription
            }
        }
    }

    private var canPaste: Bool {
        NSPasteboard.general.canReadObject(forClasses: [NSURL.self], options: nil)
    }

    private func createAliases(for urls: [URL]) {
        guard let folder else { return }
        Task {
            do {
                for url in urls {
                    _ = try await fileOps.createAlias(for: url, in: folder)
                }
                reloadAndBroadcast()
            } catch {
                actionError = error.localizedDescription
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
                _ = try await fileOps.setLocked(targets.map(\.url), locked: shouldLock)
                reloadAndBroadcast()
            } catch {
                actionError = error.localizedDescription
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

    private func commitRename() {
        guard let entry = renamingEntry, !renameText.isEmpty else { return }
        Task {
            do {
                _ = try await fileOps.rename(entry.url, to: renameText)
                reloadAndBroadcast()
            } catch {
                actionError = error.localizedDescription
            }
        }
    }

    private func duplicate(_ urls: [URL]) {
        guard let folder else { return }
        Task {
            do {
                _ = try await fileOps.copy(urls, to: folder, options: OpOptions(conflictPolicy: .keepBoth))
                reloadAndBroadcast()
            } catch {
                actionError = error.localizedDescription
            }
        }
    }

    private func moveToTrash(_ urls: [URL]) {
        Task {
            do {
                _ = try await fileOps.trash(urls)
                reloadAndBroadcast()
            } catch {
                actionError = error.localizedDescription
            }
        }
    }

    private func createNewFolder() {
        guard let folder, !newFolderName.isEmpty else { return }
        Task {
            do {
                _ = try await fileOps.createDirectory(at: folder.appendingPathComponent(newFolderName))
                reloadAndBroadcast()
            } catch {
                actionError = error.localizedDescription
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

    /// 複数選択時、途中で失敗したら残りは中断する（1-12b の通知基盤が無く
    /// 個別エラーをまとめて出せないための暫定対応 [ER-20 の趣旨に近い]）。
    private func extractArchives(_ urls: [URL], destination: @escaping (URL) -> URL) {
        busyMessage = urls.count == 1 ? "展開しています…" : "展開しています…（\(urls.count) 件）"
        Task {
            defer { busyMessage = nil }
            for url in urls {
                let target = destination(url)
                do {
                    if !FileManager.default.fileExists(atPath: target.path) {
                        _ = try await fileOps.createDirectory(at: target)
                    }
                    _ = try await SecureExtractor.shared.extract(url, options: ExtractOptions(destination: target))
                } catch {
                    actionError = error.localizedDescription
                    break
                }
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
                _ = try await ArchiveCompressor.shared.compress(urls, destinationName: name, in: folder)
                reloadAndBroadcast()
            } catch {
                actionError = error.localizedDescription
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
                _ = try await ArchiveCompressor.shared.compress(
                    urls, destinationName: name, in: destinationFolder, conflictPolicy: .replace
                )
                reloadAndBroadcast()
            } catch {
                actionError = error.localizedDescription
            }
        }
    }
}

/// 「情報を見る」の簡易表示。1-10（右ペイン詳細情報の本実装、カバー画像・
/// ラベル・評価を含む）ができるまでの暫定版で、基本的なファイル情報のみ。
private struct FileInfoSheet: View {
    let entries: [FolderEntry]
    let sizeFormatter: ByteCountFormatter
    let dateFormatter: DateFormatter
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.spacing.m) {
            if entries.count == 1, let entry = entries.first {
                Text(entry.name)
                    .font(.system(size: Tokens.fontSize.title2, weight: .semibold))
                Divider()
                LabeledContent("種類", value: entry.kindDescription)
                LabeledContent("サイズ", value: entry.isDirectory ? "—" : sizeFormatter.string(fromByteCount: entry.fileSize ?? 0))
                LabeledContent("変更日", value: entry.modificationDate.map { dateFormatter.string(from: $0) } ?? "—")
                LabeledContent("場所", value: entry.url.deletingLastPathComponent().path)
                LabeledContent("ロック", value: entry.isLocked ? "はい" : "いいえ")
            } else {
                Text("\(entries.count) 項目")
                    .font(.system(size: Tokens.fontSize.title2, weight: .semibold))
                Divider()
                let totalSize = entries.filter { !$0.isDirectory }.reduce(Int64(0)) { $0 + ($1.fileSize ?? 0) }
                LabeledContent("合計サイズ", value: sizeFormatter.string(fromByteCount: totalSize))
            }
            Spacer()
            HStack {
                Spacer()
                Button("閉じる") { dismiss() }
            }
        }
        .padding(Tokens.spacing.l)
        .frame(minWidth: 320, minHeight: 200)
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
