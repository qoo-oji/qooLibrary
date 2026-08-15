import AppKit
import QooApplication
import QooInfrastructure
import QooKit
import SwiftUI

/// 左ペイン上半分: フォルダツリー [14章 §14.2]。
/// ボリューム／テンポラリフォルダ／ライブラリフォルダの 3 グループ [LP-01〜LP-08]。
///
/// テンポラリ・ライブラリフォルダの登録・削除は 1-13 で実装した
/// [RG-01〜RG-08、`RegisteredFolderStore` 参照]。
///
/// 各行の右クリックメニューは `FolderTreeContextMenu` が組み立てる
/// [ユーザー要望: 中央ペインのフォルダ用メニューに原則あわせつつ、
/// ボリューム／テンポラリ／ライブラリのどれに属する行かで項目を
/// 切り替えられる仕組みにする]。ファイル操作の実装自体は中央ペインと
/// 共通の `FolderOperations` に集約している。
struct FolderTreePane: View {
    /// `String(localized:)`/`NSOpenPanel`/`NotificationItem` 等 `Text` の
    /// `LocalizedStringKey` 解決を経由しない箇所向け [1-12 ローカライズ方針、
    /// CLAUDE.md 参照]。
    @Environment(\.locale) private var locale
    /// 中央ペインで現在表示中のフォルダ。一致するツリー行をハイライトする [LP-06]。
    let selectedURL: URL?
    /// `selectedURL` の入口 [`NavigationRoot` 参照]。実体として同じフォルダ
    /// でも、ボリューム経由か登録フォルダ経由かでツリーの自動展開先を分ける
    /// ために使う [ユーザー要望]。同じ仕組みは将来のラベルフィルタ
    /// （ライブラリ経由のときだけ適用）・テンポラリフォルダ専用の一括処理
    /// （テンポラリ経由のときだけ適用）にも使う想定の基盤 [ユーザー指摘、
    /// CLAUDE.md 参照]。
    let navigationRoot: NavigationRoot
    /// このペインが初めて現れた瞬間だけ、自動展開（`revealSelectionIfNeeded`）
    /// を1回スキップする [実機検証で発見・修正したバグ: 「アプリ起動時に
    /// 開くフォルダ」にテンポラリ／ライブラリフォルダを設定していても、
    /// 起動直後は一瞬だけ既定の仮想ホーム（`navigationRoot == .volume`）が
    /// 表示され、このペイン自身の `.task` がその一瞬の状態に対して
    /// `revealSelectionIfNeeded` を呼んでしまっていた。`expandedNodeIDs`/
    /// `volumesExpanded` は加算的にしか変化しない（`formUnion`、`= true`
    /// を戻す経路が無い）ため、直後に `MainWindowView` 側の別の `.task` が
    /// 正しい登録フォルダへ切り替えても、この一瞬の展開（Macintosh HD →
    /// ユーザーの実ホームフォルダまで）だけが取り消されずに残り続けていた
    /// ——ユーザー報告「テンポラリフォルダを指定しているのに、起動すると
    /// ボリュームのMacintosh HDがユーザーのホームフォルダまでツリー展開
    /// してしまう」。`MainWindowView.hasPendingStartupFolderOverride` が
    /// 「これから上書きされる見込みがあるか」を`.task`実行前に同期的に
    /// 判定し、上書きが見込まれる場合は初回の自動展開をスキップする——
    /// 実際に上書きが適用された後は `.onChange(of: selectedURL)` 経由で
    /// 改めて（今度は正しい `navigationRoot` で）自動展開される。
    let skipsInitialAutoExpand: Bool
    let onSelect: (URL, NavigationRoot) -> Void
    /// コンテキストメニューの「新規タブで開く」「新規ウインドウで開く」
    /// [ユーザー要望: 中央ペインのメニューに原則あわせる]。中央ペインと違い
    /// `NavigationRoot` も一緒に渡す——ライブラリ／テンポラリ配下の行から
    /// 開いた新規タブが、`.volume` に戻ってしまわないようにするため
    /// （「1階層上へ」の境界・ツリーの自動展開スコープに効く）。
    let onOpenInNewTab: (URL, NavigationRoot) -> Void
    let onOpenInNewWindow: (URL) -> Void

    @State private var volumesExpanded = true
    @State private var temporaryExpanded = true
    @State private var libraryExpanded = true
    @State private var expandedNodeIDs: Set<String> = [] // [LP-05]
    /// 現在スクロール領域内に実際に描画されている行の ID（`FolderTreeNode.id`
    /// と同じ正規化パス文字列）。`List` は行を遅延生成するため、各
    /// `FolderTreeRow` の `.onAppear`/`.onDisappear` で増減させる
    /// [`revealSelectionIfNeeded` が「既に表示範囲内なら再スクロールしない」
    /// 判定に使う、ユーザー要望]。
    @State private var visibleNodeIDs: Set<String> = []
    @State private var volumes: [FolderTreeNode] = []
    @State private var libraryEntries: [RegisteredFolderEntry] = []
    @State private var temporaryEntries: [RegisteredFolderEntry] = []
    /// 表示中の入力ダイアログ [`FolderTreePrompt` 参照]。
    @State private var prompt: FolderTreePrompt?
    @State private var promptText = ""
    /// ファイル操作の共通レイヤ [`FolderOperations` 参照]。中央ペインと
    /// まったく同じ実装を共有する。実行中表示・パスワードシートの描画は
    /// `.folderOperationsHost(_:)` が担う。
    @State private var operations = FolderOperations()
    /// [ユーザー要望、環境設定「表示」タブ] 中央ペインでフォルダを移動した
    /// とき、現在のフォルダまでツリーを自動展開してスクロールする。
    @AppStorage("qoo.preferences.autoExpandTreeToCurrentFolder") private var autoExpandTreeToCurrentFolder = true

    var body: some View {
        ScrollViewReader { scrollProxy in
            List {
                Section {
                    if volumesExpanded {
                        ForEach(volumes) { node in
                            FolderTreeRow(
                                node: node, expandedIDs: $expandedNodeIDs, visibleIDs: $visibleNodeIDs, selectedURL: selectedURL,
                                branch: .volume, role: .volumeRoot, onSelect: onSelect,
                                onDropFailure: { presentFailureMessage($0) },
                                operations: operations, menuActions: menuActions
                            )
                        }
                    }
                } header: {
                    GroupHeader(title: String(localized: "folderTree.volumes", locale: locale), isExpanded: $volumesExpanded)
                }

                Section {
                    if temporaryExpanded {
                        registeredFolderRows(temporaryEntries, kind: .temporary)
                    }
                } header: {
                    GroupHeader(title: String(localized: "folderTree.temporaryFolders", locale: locale), isExpanded: $temporaryExpanded, showsAddButton: true) {
                        presentRegistrationPanel(kind: .temporary)
                    }
                }

                Section {
                    if libraryExpanded {
                        registeredFolderRows(libraryEntries, kind: .library)
                    }
                } header: {
                    GroupHeader(title: String(localized: "folderTree.libraryFolders", locale: locale), isExpanded: $libraryExpanded, showsAddButton: true) {
                        presentRegistrationPanel(kind: .library)
                    }
                }
            }
            .listStyle(.sidebar)
            .environment(\.defaultMinListRowHeight, 20) // 行間を少し詰める。可変にするのは 1-12（環境設定）で。
            .task {
                volumes = FolderTreeNode.mountedVolumes()
                await reloadRegisteredFolders()
                guard !skipsInitialAutoExpand else { return }
                revealSelectionIfNeeded(scrollProxy: scrollProxy)
            }
            // 入力を伴うダイアログは 3 種類（登録フォルダの表示名変更・実
            // フォルダ名の変更・新規フォルダ）あるが、**同じビューに複数の
            // `.alert` を重ねると表示が不安定になる**ため、`FolderTreePrompt`
            // という 1 つの状態にまとめて単一の `.alert` で扱う [設計判断]。
            .alert(promptTitle, isPresented: Binding(get: { prompt != nil }, set: { if !$0 { prompt = nil } })) {
                TextField(promptPlaceholder, text: $promptText)
                Button(promptConfirmTitle) { commitPrompt() }
                Button("common.cancel", role: .cancel) {}
            }
            .folderOperationsHost(operations)
            .onChange(of: selectedURL) { _, _ in
                revealSelectionIfNeeded(scrollProxy: scrollProxy)
            }
            // 登録ルート行の一覧は、このペインが `@State` に抱えている実体の
            // コピーなので、**このペイン以外が登録を変えたときには誰も
            // 読み直さない**。各行が監視している `SessionState.reloadToken`
            // （`FolderTreeRow` の `.onChange(of:)`）は行の中身を更新するだけで、
            // 一覧そのものには効かない。
            //
            // 中央ペインから登録フォルダを完全削除すると
            // `DeletePermanentlyCommand` が登録を強制解除する [FM-14] ため、
            // これが無いと「ストアからは消えているのに左ペインには残り続ける」
            // 状態になる（実機検証で発見）。登録の追加・解除・改名を伴う経路は
            // 他にもあり得るので、発生源ごとに手当てするのではなく、他の
            // ペインと同じ共通シグナルを見て読み直す。
            // **ボリューム一覧も同じ理由で読み直す** [1-16 のイジェクト実装時に
            // 実機検証で発見]。`volumes` も登録フォルダと同じくこのペインが
            // `@State` に抱えたコピーで、`.task` の初回しか読み込んでいなかった
            // ため、取り出したボリュームがツリーに残り続けていた。着脱の検知
            // （`NSWorkspace` のボリューム通知、VD-01〜06）は 2-2 の担当なので、
            // ここではアプリ内の操作を拾う共通シグナルに乗せるに留める
            // ——Finder 側で取り出した場合などはまだ追随しない [既知の限界]。
            .onChange(of: SessionState.shared.reloadToken) { _, _ in
                volumes = FolderTreeNode.mountedVolumes()
                Task { await reloadRegisteredFolders() }
            }
        }
    }

    /// [ユーザー要望] `selectedURL` の祖先をすべて展開し、その行までスクロール
    /// する。`autoExpandTreeToCurrentFolder` が無効なら何もしない。
    ///
    /// **`navigationRoot` で反応するグループを厳密に1つに絞る**
    /// [ユーザー指摘: 実体として同じフォルダでも、ライブラリ経由でアクセス
    /// したときはボリューム側のツリーが反応してはならず、その逆（ボリューム
    /// 経由のときにライブラリ／テンポラリ側が反応する）もあってはならない。
    /// 当初は `selectedURL` のパスが登録フォルダの配下かどうかで判定していたが、
    /// これだと「実際にはどちらの入口から来たか」を区別できず、ボリューム
    /// ツリーを手で辿って登録フォルダと同じ実フォルダに到達した場合にも
    /// ライブラリ側が反応してしまっていた。`navigationRoot`（`WindowState` が
    /// 入口ごとに明示的に記録する）を直接見ることで、実体のパスに関わらず
    /// 「どちらから来たか」で厳密に分岐する]。
    private func revealSelectionIfNeeded(scrollProxy: ScrollViewProxy) {
        guard autoExpandTreeToCurrentFolder, let selectedURL else { return }

        switch navigationRoot {
        case .volume:
            volumesExpanded = true
            expandedNodeIDs.formUnion(Self.ancestorPaths(of: selectedURL, downTo: nil))
        case .registeredFolder(let id, let rootURL):
            if temporaryEntries.contains(where: { $0.folder.id == id }) {
                temporaryExpanded = true
            } else if libraryEntries.contains(where: { $0.folder.id == id }) {
                libraryExpanded = true
            }
            expandedNodeIDs.formUnion(Self.ancestorPaths(of: selectedURL, downTo: rootURL))
        }

        // ツリー行は遅延読み込み（`FolderTreeRow.loadChildren()`）のため、
        // 展開の反映（子の読み込み・行の生成）が実際に画面へ反映されるまで
        // 数フレームかかることがある。`PaneWindows.swift`/`WindowFrameAutosave.swift`
        // と同じ「1サイクル遅らせて適用する」パターンだが、階層が深い場合は
        // 複数段のカスケードになるため、経験的に十分な余裕を持たせている。
        let targetID = selectedURL.standardizedFileURL.path
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            // [ユーザー要望] ハイライトされた行が既に表示範囲内にあるなら
            // スクロールしない。`visibleNodeIDs` は各 `FolderTreeRow` の
            // `.onAppear`/`.onDisappear` で増減する（`List` の行virtualization
            // を利用した「実際に画面に描画されているか」の判定、`List` に
            // 標準の可視判定 API が無いための代替手段）。展開の反映を待つ
            // ため、この判定も同じ 0.3 秒遅延の後に行う。
            guard !visibleNodeIDs.contains(targetID) else { return }
            withAnimation {
                scrollProxy.scrollTo(targetID, anchor: .center)
            }
        }
    }

    /// `url` の祖先ディレクトリの正規化パス（`FolderTreeNode.id` と同じ形式）
    /// を返す。`downTo` を指定すると、その URL に到達した時点で打ち切る
    /// （`downTo` 自身は結果に含める）。`nil`（ボリューム経由）ならファイル
    /// システムルートまで遡る。
    ///
    /// [実機検証で発見した無限ループを修正] `URL.deletingLastPathComponent()`
    /// はルート `/` に対して呼んでも `/` 自身を返すとは限らない（Apple の
    /// ドキュメントに明記された既知の挙動、1-8 のパスバー実装時に一度踏んで
    /// CLAUDE.md に教訓として残していたのと同じ罠に、ここでも気づかずに
    /// 引っかかった）。「`parent == current` になったら止める」という終了判定
    /// では `current` が `/` に達した後も `deletingLastPathComponent()` を
    /// 呼び続けてしまい、CPU を 100% 消費するハングを引き起こした。
    /// **ループの先頭で `current.path == "/"` を確認し、`/` に達した時点で
    /// `deletingLastPathComponent()` を一切呼ばずに抜ける**よう修正した。
    ///
    /// [実機検証で発見した2件目のバグを修正] `url` が `floor` そのもの
    /// （登録フォルダの根を直接選択した場合）だと、`floor` との一致判定を
    /// 「`parent` を計算した後」にしか行っていなかったため、`floor` 自身は
    /// 一度も `parent` になる機会が無く（`parent` は常に `current` の1つ上を
    /// 指すため）、判定に一切引っかからないままファイルシステムルートまで
    /// 遡ってしまっていた（ライブラリフォルダの根を直接開くとボリューム
    /// ツリーまで反応する不具合として発覚）。**ループの先頭で「`current` が
    /// 既に `floor` そのもの」かを確認し、その時点で `parent` を計算せずに
    /// 抜ける**よう修正した。
    private static func ancestorPaths(of url: URL, downTo floor: URL?) -> Set<String> {
        var paths: Set<String> = []
        let floorPath = floor?.standardizedFileURL.path
        var current = url.standardizedFileURL
        while current.path != "/" && !current.path.isEmpty {
            if let floorPath, current.path == floorPath { break } // 既に根に達している
            let parent = current.deletingLastPathComponent().standardizedFileURL
            paths.insert(parent.path)
            if parent.path == current.path { break } // 保険: 万一進まなくなったら打ち切る
            current = parent
        }
        return paths
    }

    @ViewBuilder
    private func registeredFolderRows(_ entries: [RegisteredFolderEntry], kind: RegisteredFolderKind) -> some View {
        if entries.isEmpty {
            EmptyGroupRow(message: String(localized: "folderTree.noneRegistered", locale: locale))
        } else {
            ForEach(entries) { entry in
                if let node = entry.node {
                    FolderTreeRow(
                        node: node, expandedIDs: $expandedNodeIDs, visibleIDs: $visibleNodeIDs, selectedURL: selectedURL,
                        branch: .registered(kind: kind, id: entry.folder.id, rootURL: node.url),
                        role: .registeredRoot,
                        onSelect: onSelect,
                        onDropFailure: { presentFailureMessage($0) },
                        operations: operations, menuActions: menuActions,
                        registeredFolder: entry.folder
                    )
                } else {
                    // ブックマーク解決失敗（ボリューム未接続等）[SB-05]。
                    OfflineRegisteredFolderRow(displayName: entry.folder.displayName) {
                        unregisterFolder(entry.folder)
                    }
                }
            }
        }
    }

    // MARK: - コンテキストメニューの配線

    /// `FolderOperations` では完結しない項目（ナビゲーション・入力ダイアログ・
    /// 登録ストア操作）の橋渡し [`FolderTreeContextMenuActions` 参照]。
    private var menuActions: FolderTreeContextMenuActions {
        FolderTreeContextMenuActions(
            open: { onSelect($0.url, $0.navigationRoot) },
            openInNewTab: { onOpenInNewTab($0.url, $0.navigationRoot) },
            openInNewWindow: { onOpenInNewWindow($0.url) },
            beginRenameFolder: { context in
                prompt = .renameFolder(url: context.url)
                promptText = context.url.lastPathComponent
            },
            beginNewFolder: { context in
                prompt = .newFolder(parent: context.url)
                promptText = String(localized: "action.newFolder", locale: locale)
            },
            beginRenameDisplayName: { folder in
                prompt = .renameDisplayName(folder)
                promptText = folder.displayName
            },
            unregister: { unregisterFolder($0) }
        )
    }

    // MARK: - 入力ダイアログ（3 種類を単一の `.alert` で扱う）

    private var promptTitle: String {
        switch prompt {
        case .renameDisplayName: String(localized: "folderTree.renameDisplayName", locale: locale)
        case .renameFolder: String(localized: "folderTree.renameFolder", locale: locale)
        case .newFolder, .none: String(localized: "action.newFolder", locale: locale)
        }
    }

    private var promptPlaceholder: String {
        switch prompt {
        case .renameDisplayName: String(localized: "folderTree.displayName", locale: locale)
        case .renameFolder, .newFolder, .none: String(localized: "folder.namePlaceholder", locale: locale)
        }
    }

    private var promptConfirmTitle: String {
        switch prompt {
        case .renameDisplayName, .renameFolder: String(localized: "action.rename", locale: locale)
        case .newFolder, .none: String(localized: "common.create", locale: locale)
        }
    }

    private func commitPrompt() {
        guard let prompt else { return }
        let name = promptText
        self.prompt = nil
        switch prompt {
        case .renameDisplayName(let folder): // [RG-05]
            guard !name.isEmpty else { return }
            Task {
                try? await RegisteredFolderStore.shared.rename(folder.id, to: name)
                await reloadRegisteredFolders()
            }
        case .renameFolder(let url): // [FM-05]
            operations.rename(url, to: name) { reloadTreeAfterMutation() }
        case .newFolder(let parent): // [FM-01]
            operations.createFolder(named: name, in: parent) {
                // 作成先の行を開いておく——折りたたんだ行に対して実行した場合、
                // 開かないと「何も起きなかった」ように見えるため。既に展開済み
                // なら `SessionState.reloadToken` 側で、折りたたみ済みなら
                // 展開を検知した `FolderTreeRow` 側で、どちらも子が読み直される。
                expandedNodeIDs.insert(parent.standardizedFileURL.path)
                reloadTreeAfterMutation()
            }
        }
    }

    /// ツリー自身の表示更新は各行が `SessionState.reloadToken` を監視して行う
    /// （`FolderTreeRow` の `.onChange(of:)` 参照）。登録ルート行だけはこの
    /// ペインが直接保持しているため、こちらは明示的に読み直す。
    private func reloadTreeAfterMutation() {
        Task { await reloadRegisteredFolders() }
    }

    private func presentRegistrationPanel(kind: RegisteredFolderKind) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "folderTree.registerPanelPrompt", locale: locale)
        panel.message = kind == .library
            ? String(localized: "folderTree.chooseLibraryFolder", locale: locale)
            : String(localized: "folderTree.chooseTemporaryFolder", locale: locale)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                _ = try await RegisteredFolderStore.shared.register(url: url, kind: kind, displayName: nil)
                await reloadRegisteredFolders()
            } catch {
                await NotificationRouter.shared.present(NotificationItem(
                    category: .error, severity: .sheet,
                    title: String(localized: "folderTree.registrationFailedTitle", locale: locale), body: Self.errorMessage(for: error)
                ))
            }
        }
    }

    private func unregisterFolder(_ folder: RegisteredFolder) {
        Task {
            try? await RegisteredFolderStore.shared.unregister(folder.id)
            await reloadRegisteredFolders()
        }
    }

    /// [ER-01] エラー提示は必ず `NotificationRouter` 経由にする。
    private func presentFailureMessage(_ message: String) {
        Task {
            await NotificationRouter.shared.present(
                NotificationItem(category: .error, severity: .sheet, title: String(localized: "error.operationFailed", locale: locale), body: message)
            )
        }
    }

    private func reloadRegisteredFolders() async {
        async let libraries = RegisteredFolderStore.shared.folders(kind: .library)
        async let temporaries = RegisteredFolderStore.shared.folders(kind: .temporary)
        libraryEntries = await Self.entries(for: libraries, kind: .library)
        temporaryEntries = await Self.entries(for: temporaries, kind: .temporary)
        // 「移動」メニュー用のキャッシュも同じタイミングで更新する [1-16]。
        // 登録の追加・解除・表示名変更・`SessionState.reloadToken` の変化は
        // すべてこのメソッドを経由するため、更新経路をここ 1 本に集約できる
        // [`RegisteredFolderIndex` のコメント参照]。
        await RegisteredFolderIndex.shared.refresh()
    }

    private static func entries(for folders: [RegisteredFolder], kind: FolderTreeNode.Kind) async -> [RegisteredFolderEntry] {
        var result: [RegisteredFolderEntry] = []
        for folder in folders {
            let url = await RegisteredFolderStore.shared.resolvedURL(for: folder)
            let node = url.map { FolderTreeNode(url: $0, displayName: folder.displayName, kind: kind) }
            result.append(RegisteredFolderEntry(folder: folder, node: node))
        }
        return result
    }

    private static func errorMessage(for error: Error) -> String {
        let locale = AppLanguage.effectiveLocale
        switch error {
        case RegisteredFolderError.nestedRegistration:
            return String(localized: "folderTree.nestedRegistrationError", locale: locale)
        case RegisteredFolderError.unsupportedFileSystem(let reason):
            switch reason {
            case .noPersistentFileID(let fileSystem), .persistentIDNotPreserved(let fileSystem):
                return String(format: String(localized: "folderTree.unsupportedFileSystemError", locale: locale), fileSystem)
            }
        default:
            return error.localizedDescription
        }
    }
}

/// ツリーから開く入力ダイアログの種類。`.alert` を種類ごとに重ねると表示が
/// 不安定になるため、単一の `.alert` をこの状態で切り替える [設計判断]。
private enum FolderTreePrompt {
    /// 登録フォルダの表示名を変更する [RG-05]。実フォルダ名は変えない。
    case renameDisplayName(RegisteredFolder)
    /// 実フォルダの名前を変更する [FM-05]。中央ペインは Finder 流のインライン
    /// 編集だが、ツリーにはその基盤が無いためアラート方式にしている
    /// [ユーザー判断]。
    case renameFolder(url: URL)
    /// `parent` の中に新規フォルダを作る [FM-01]。
    case newFolder(parent: URL)
}

/// 登録済みフォルダ 1 件（表示名・Security-Scoped Bookmark）と、解決済みの
/// `FolderTreeNode`（オフラインなら `nil` [SB-05]）のペア。
private struct RegisteredFolderEntry: Identifiable {
    let folder: RegisteredFolder
    let node: FolderTreeNode?
    var id: UUID { folder.id }
}

private struct GroupHeader: View {
    @Environment(\.locale) private var locale
    let title: String
    @Binding var isExpanded: Bool
    var showsAddButton: Bool = false
    var onAdd: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: Tokens.spacing.xs) {
            // [ユーザー要望] 見出し左の開閉三角（chevron）を削除した。開閉
            // 状態を示す視覚的インジケータは無くなるが、見出しクリックでの
            // 開閉自体はこのボタンがそのまま担う（`isExpanded.toggle()`）。
            Button {
                isExpanded.toggle() // [LP-07] 各グループは折りたたみ可
            } label: {
                // [ユーザー指摘の修正] `.sidebar` 標準の見出し用スタイル
                // （グレーの小さい文字）はダークモードで読みづらく、
                // フォルダ行本体（`FolderTreeRow.rowLabel`）ともサイズが
                // 揃っていなかった。フォルダ行と同じ大きさ・色
                // （`Color.primary`、ライト/ダークとも自動追従）に統一する
                // [ユーザー指摘: フォルダの文字色に合わせてよい]。
                Text(title)
                    .font(.system(size: Tokens.fontSize.body))
                    .foregroundStyle(Color.primary)
                    .fontWeight(.bold) // [ユーザー要望] ライト/ダークとも太字にする。
            }
            .buttonStyle(.plain)
            Spacer()
            if showsAddButton {
                Button {
                    onAdd?()
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help(String(format: String(localized: "folderTree.registerGroup", locale: locale), title))
                Image(systemName: "gearshape")
                    .foregroundStyle(.secondary)
                    .help(String(format: String(localized: "folderTree.groupSettings", locale: locale), title))
            }
        }
    }
}

private struct EmptyGroupRow: View {
    let message: String
    var body: some View {
        Text(message)
            .font(.system(size: Tokens.fontSize.caption))
            .foregroundStyle(.secondary)
    }
}

/// [SB-05] ブックマーク解決に失敗した登録フォルダ（ボリューム未接続等）。
/// フェーズ1にはスキャン・DB が無いため「オフライン状態として保持」ではなく
/// 単純な表示のみだが、登録解除だけはここからもできるようにしている。
private struct OfflineRegisteredFolderRow: View {
    let displayName: String
    let onUnregister: () -> Void

    var body: some View {
        Label {
            Text(displayName)
        } icon: {
            Image(systemName: "questionmark.folder")
                .frame(width: 16, alignment: .center)
        }
        .opacity(0.4)
        .padding(.horizontal, Tokens.spacing.xs)
        .padding(.vertical, 2)
        .help("folderTree.notFoundHint")
        .contextMenu {
            Button("folderTree.unregister") { onUnregister() }
        }
    }
}

/// ツリーの 1 行。実フォルダの子を遅延読み込みする再帰 View。
private struct FolderTreeRow: View {
    let node: FolderTreeNode
    @Binding var expandedIDs: Set<String>
    /// 現在画面に描画されている行の ID 集合。`.onAppear`/`.onDisappear` で
    /// 自分自身の ID を増減させる [`FolderTreePane.visibleNodeIDs` 参照]。
    @Binding var visibleIDs: Set<String>
    let selectedURL: URL?
    /// この行（および再帰的に読み込まれる子孫すべて）が属するツリーの枝
    /// [`FolderTreeBranch` 参照]。`registeredFolder` と違い**子孫にもそのまま
    /// 伝播させる**（クリックした行がツリーのどの枝に属するかを常に正しく
    /// `onSelect` へ伝え、かつコンテキストメニューをグループごとに
    /// 出し分けるため）。
    let branch: FolderTreeBranch
    /// この行の役割 [`FolderTreeRowRole` 参照]。子孫は常に `.plainFolder`。
    let role: FolderTreeRowRole
    let onSelect: (URL, NavigationRoot) -> Void
    let onDropFailure: @MainActor @Sendable (String) -> Void
    /// ファイル操作の共通レイヤ。ペイン全体で 1 つを共有する。
    let operations: FolderOperations
    let menuActions: FolderTreeContextMenuActions
    /// ライブラリ／テンポラリの**登録ルート行**のときだけ渡される
    /// [RG-05][RG-06]。再帰的に読み込まれる子孫フォルダの行では `nil` の
    /// ままにし、登録解除・表示名変更のメニューが実フォルダの深い階層に
    /// 誤って出ないようにする。
    var registeredFolder: RegisteredFolder?

    @State private var children: [FolderTreeNode]?
    @State private var accessDenied = false
    @State private var isDropTargeted = false

    private var isSelected: Bool {
        selectedURL?.standardizedFileURL.path == node.url.standardizedFileURL.path
    }

    private var isExpanded: Binding<Bool> {
        Binding(
            get: { expandedIDs.contains(node.id) },
            set: { newValue in
                if newValue {
                    expandedIDs.insert(node.id)
                } else {
                    expandedIDs.remove(node.id)
                }
            }
        )
    }

    /// コンテキストメニューの出し分けに必要な情報一式
    /// [`FolderTreeRowContext` 参照]。
    private var menuContext: FolderTreeRowContext {
        FolderTreeRowContext(node: node, branch: branch, role: role, registeredFolder: registeredFolder)
    }

    @ViewBuilder
    private var rowLabel: some View {
        Label {
            Text(node.displayName)
        } icon: {
            // Finder と同じアイコン [ユーザー要望]。シンボリックリンクは
            // `NSWorkspace` が対象種別のアイコンにエイリアスの矢印バッジを
            // 重ねて返すため、以前のような専用の代用アイコンは不要になった。
            Image(nsImage: FileIconProvider.shared.icon(for: node.url))
                .resizable()
                .frame(width: 16, height: 16)
        }
        .opacity(node.isOnline ? 1 : 0.4) // [LP-04]
            // [実機検証で発見・修正したバグ] `NSTableViewDefaultSizeMode`
            // による行の高さ縮小（`QooLibraryApp.init()` 参照）は、Apple の
            // Small/Medium/Large プリセットとして「行の高さ・アイコン・
            // 文字サイズをまとめて一段階小さくする」設計になっており
            // [Finder 自身のサイドバーアイコンサイズ設定と同じ挙動]、
            // `.sidebar` の暗黙のフォントに任せていたこの行のテキストも
            // 一緒に縮んでしまっていた（ユーザー指摘）。中央ペイン
            // （`Table`）と大きさを揃えたいのはあくまで文字サイズだけの
            // 話であり、行の高さは意図して縮めているため、ここだけ明示的に
            // 中央ペインと同じサイズへ固定して暗黙の縮小から切り離す。
            .font(.system(size: Tokens.fontSize.body))
            .fontWeight(isSelected ? .semibold : .regular)
            // 濃い青の背景に対して黒文字だとコントラストが低いため、
            // Finder と同じく選択中は白文字にする。
            .foregroundStyle(isSelected ? Color(nsColor: .alternateSelectedControlTextColor) : Color.primary)
            // [ユーザー要望] ハイライトを中央ペイン（`Table`）と同じく行
            // 全体（アイコン＋名前の実幅だけでなく、ツリーの右端まで）に
            // 広げる。`Label` はそのままだと自身の内容幅にしか収まらない
            // ため、先に横幅いっぱいへ広げてから padding/background を
            // 適用する必要がある。
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Tokens.spacing.xs)
            .padding(.vertical, 2)
            // 選択のハイライトは AppKit のシステム標準色を使う
            // [実機検証時のユーザー指摘: 独自の半透明アクセントカラーだと
            // Finder のような青にならない]。`Table`/`List` の
            // `selection:` バインディングと違いこのツリーはフォーカスの
            // 概念を持たないため（クリックで中央ペインと同期するだけの
            // 表示専用の選択）、常に強調表示（青）にする。
            .background(isDropTargeted ? Tokens.Colors.accent.opacity(0.35) : (isSelected ? Color(nsColor: .selectedContentBackgroundColor) : Color.clear))
            .clipShape(RoundedRectangle(cornerRadius: Tokens.radius.s))
            .contentShape(Rectangle())
            .onTapGesture { onSelect(node.url, branch.navigationRoot) } // [LP-06]
            .dropDestination(for: URL.self) { items, _ in // [DD-05] ツリーへドロップで移動
                DropHandling.performDrop(
                    items, into: node.url,
                    onComplete: {
                        if children != nil { loadChildren() }
                        // ウインドウ／ペインをまたいだ変更を拾う暫定策 [1-6 実機検証で発見]。
                        SessionState.shared.reloadToken += 1
                    },
                    onFailure: onDropFailure
                )
                return true
            } isTargeted: { isDropTargeted = $0 }
    }

    var body: some View {
        DisclosureGroup(isExpanded: node.isSymlink ? .constant(false) : isExpanded) {
            if accessDenied {
                AccessDeniedRow() // [SB-04][LP2-09]
            } else if let children {
                ForEach(children) { child in
                    FolderTreeRow(
                        node: child, expandedIDs: $expandedIDs, visibleIDs: $visibleIDs, selectedURL: selectedURL,
                        branch: branch, role: .plainFolder, onSelect: onSelect,
                        onDropFailure: onDropFailure,
                        operations: operations, menuActions: menuActions
                    )
                }
            } else {
                ProgressView()
                    .controlSize(.small)
            }
        } label: {
            // 右クリックメニューは全行に付ける [ユーザー要望: 中央ペインの
            // フォルダ用メニューに原則あわせる]。以前は登録ルート行だけが
            // 「表示名を変更…」「登録解除」を持ち、それ以外の行は
            // 右クリックしても何も出なかった。項目の出し分けは
            // `FolderTreeContextMenu` が `branch`（グループ）と `role`
            // （ルートか通常フォルダか）から判断する。
            rowLabel.contextMenu {
                FolderTreeContextMenu(context: menuContext, operations: operations, actions: menuActions)
            }
        }
        .disabled(node.isSymlink) // [SL-05]
        // [ユーザー要望] `List` の行virtualizationを利用して「実際に画面へ
        // 描画されているか」を追跡する（`revealSelectionIfNeeded` の
        // 「既に表示範囲内ならスクロールしない」判定に使う）。
        .onAppear { visibleIDs.insert(node.id) }
        .onDisappear { visibleIDs.remove(node.id) }
        .onChange(of: isExpanded.wrappedValue, initial: true) { _, expanded in
            guard expanded, children == nil, !accessDenied else { return }
            loadChildren()
        }
        // [実機検証で発見・修正したバグ] 環境設定「アクセス権」タブでアクセスを
        // 取り消しても、既に読み込み済みのこの行の `children` はキャッシュされた
        // ままで、アプリを再起動するまで「アクセス権がありません」に戻らなかった。
        // 他ウインドウ／ペインをまたいだ変更の反映と同じ `SessionState.reloadToken`
        // 経由で、読み込み済み／アクセス拒否済みの行だけを再読み込みする。
        // コンテキストメニュー由来のファイル操作（新規フォルダ・複製・ゴミ箱
        // 等）の結果がツリーへ反映されるのも、この経路。
        .onChange(of: SessionState.shared.reloadToken) {
            guard children != nil || accessDenied else { return }
            accessDenied = false
            loadChildren()
        }
    }

    private func loadChildren() {
        do {
            children = try FolderTreeNode.children(of: node)
        } catch {
            children = nil
            accessDenied = true
        }
    }
}

/// [SB-04][LP2-09] **フルディスクアクセスへ誘導していた旧実装は撤去した**
/// ——実機検証の結果、フルディスクアクセスは App Sandbox のカーネルレベルの
/// ファイル読み取り制限を回避しないと判明したため（CLAUDE.md 1-4 節「将来
/// 検討」の訂正参照）。**その場で `NSOpenPanel` を開く実装も一度作ったが、
/// ユーザー要望で環境設定「アクセス権」タブへの遷移に置き換えた**
/// （複数箇所に許可 UI が分散するより、一箇所に集約する方が分かりやすい
/// という判断）。許可自体は `AccessPreferencesTab` の「追加…」から行う
/// （既定でルート/Macintosh HD を指した状態で開く）。許可されると
/// `SessionState.reloadToken` 経由でこの行も自動的に再読み込みされる
/// （`FolderTreeRow` の `.onChange(of: SessionState.shared.reloadToken)` 参照）。
private struct AccessDeniedRow: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.spacing.xs) {
            Text("folderTree.accessDenied")
                .font(.system(size: Tokens.fontSize.caption))
                .foregroundStyle(Tokens.Colors.dangerText)
            Button("folderTree.grantAccessEllipsis") {
                PreferencesNavigation.shared.pendingCategory = .access
                openWindow(id: "preferences")
            }
            .font(.system(size: Tokens.fontSize.caption))
        }
    }
}
