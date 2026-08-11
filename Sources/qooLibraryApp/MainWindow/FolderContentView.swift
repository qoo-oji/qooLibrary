import AppKit
import QooInfrastructure
import QooKit
import SwiftUI
import UniformTypeIdentifiers

/// アクティブなタブのフォルダ内容を一覧表示する。
///
/// リスト表示（ソート可能なカラム）は 1-9 で実装済み [LV-01〜LV-03]。
/// アイコン表示・サムネイルは 1-9 の後続ステップで追加する。
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
            } else {
                // カラムベースのリスト表示 [LV-01〜LV-03]。ソートは `sortOrder`
                // バインディングを通してヘッダクリックで切り替わる。実際の並べ替えは
                // `displayedEntries` がこの状態を見て計算する（`Table` 自身は
                // データを自動ソートしない）。
                Table(displayedEntries, selection: $selection, sortOrder: $sortOrder) {
                    TableColumn("名前", sortUsing: FolderSortComparator(key: .name)) { entry in
                        rowCell(entry) {
                            // `Label` だと "folder"/"doc" の SF Symbol の実測幅の違いで
                            // 名前の先頭位置がフォルダとファイルでずれる（実機検証で発覚）。
                            // アイコンを固定幅の枠に収めて Finder のように先頭を揃える。
                            HStack(spacing: Tokens.spacing.xs) {
                                Image(systemName: entry.isDirectory ? "folder" : "doc")
                                    .frame(width: 16, alignment: .center)
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
                // [KB-02] 選択中の項目を開く。ディレクトリはダブルクリックと同じ
                // ナビゲーション、ファイルは既定アプリで開く（Finder と同じ）。
                .onKeyPress(keyBindingStore.binding(for: .open).combos.first?.swiftUIKeyEquivalent ?? .return) {
                    openSelection()
                    return .handled
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
                    goToParent()
                }
                KeyBindingButtons(action: .goBack, store: keyBindingStore, isDisabled: !canGoBack) {
                    onGoBack()
                }
                KeyBindingButtons(action: .goForward, store: keyBindingStore, isDisabled: !canGoForward) {
                    onGoForward()
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
            .contextMenu {
                rowContextMenu(for: entry)
            }
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

    @ViewBuilder
    private func rowContextMenu(for entry: FolderEntry) -> some View {
        // 右クリックした行が現在の複数選択に含まれる場合は選択全体を対象にする
        // （Finder と同じ規則）。「名前を変更」だけはバッチ名変更 UI が無いため
        // 右クリックした 1 件のみを対象にする。
        let targets = targetURLs(for: entry)
        Button("Finder で表示") { NSWorkspace.shared.activateFileViewerSelecting(targets) } // [FM-09]
        Button("パスをコピー") { copyPaths(targets) } // [FM-10]
        Divider()
        Button("複製") { duplicate(targets) } // [FM-02]
        Button("名前を変更…") { beginRename(entry) } // [FM-05]
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
        Button("ゴミ箱に入れる", role: .destructive) { moveToTrash(targets) } // [FM-04]
    }

    private func reload() {
        guard let folder else {
            entries = []
            loadError = nil
            return
        }
        do {
            let keys: Set<URLResourceKey> = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
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
                    modificationDate: values?.contentModificationDate
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

    /// 右クリックした行が現在の複数選択に含まれていれば選択全体を、そうでなければ
    /// その 1 件のみを対象にする（Finder のコンテキストメニューと同じ規則）。
    private func targetURLs(for entry: FolderEntry) -> [URL] {
        guard selection.contains(entry.url) else { return [entry.url] }
        return entries.filter { selection.contains($0.url) }.map(\.url)
    }

    private func copyPaths(_ urls: [URL]) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
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
        let targets = entries.filter { selection.contains($0.url) }
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

    /// サンドボックスの仮想ホーム（`~/Library/Containers/<bundle-id>/Data`、
    /// `FileManager.homeDirectoryForCurrentUser` が返す値 [1-3 の実機検証で
    /// 確認済み]）。この 1 つ上（コンテナ本体のルート）はアプリの内部実装領域で
    /// サンドボックスプロファイルが読み取りを許可しない
    /// [実機検証で発見: Documents から ⌘↑ を連打すると "permission to view it"
    /// エラーになっていた。コンテナルート自体は Unix パーミッション上は
    /// 読めても、サンドボックスは `Data` 配下だけをアプリに開放する]。
    private static let sandboxHomeDirectory = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL

    /// 仮想ホームより上には昇らない（昇っても読めない場所しかなく、
    /// ユーザーにとって意味のある行き先ではないため）。
    private var canGoToParent: Bool {
        guard let folder else { return false }
        return folder.standardizedFileURL != Self.sandboxHomeDirectory
    }

    /// `⌘↑` ショートカット用 [KB-02 相当]。ツリー・ダブルクリックと同じ
    /// `onNavigate` 経路を使う。
    private func goToParent() {
        guard canGoToParent, let folder else { return }
        onNavigate(folder.deletingLastPathComponent())
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

private struct FolderEntry: Identifiable {
    var id: URL { url }
    let url: URL
    let name: String
    let isDirectory: Bool
    let fileSize: Int64?
    let modificationDate: Date?

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
private struct DropIntoFolderModifier: ViewModifier {
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
