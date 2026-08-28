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
    @Environment(\.openWindow) private var openWindow
    /// 中央ペインで現在表示中のフォルダ。一致するツリー行をハイライトする [LP-06]。
    let selectedURL: URL?
    /// `selectedURL` の入口 [`NavigationRoot` 参照]。実体として同じフォルダ
    /// でも、ボリューム経由か登録フォルダ経由かでツリーの自動展開先を分ける
    /// ために使う [ユーザー要望]。同じ仕組みは将来のラベルフィルタ
    /// （ライブラリ経由のときだけ適用）・テンポラリフォルダ専用の一括処理
    /// （テンポラリ経由のときだけ適用）にも使う想定の基盤 [ユーザー指摘、
    /// CLAUDE.md 参照]。
    let navigationRoot: NavigationRoot
    /// 「アプリ起動時に開くフォルダ」の解決が終わったか
    /// [`MainWindowView.startupFolderResolved` 参照]。
    ///
    /// **自動展開はこれと「一覧の読み込み完了」の両方が揃うまで待つ。**
    /// 解決前の暫定の行き先に対して一度でも展開が走ると、`expandedNodeIDs` は
    /// 減らないので**その展開が残り続ける**——ユーザー報告「テンポラリ
    /// フォルダを指定しているのに、起動するとボリュームの Macintosh HD が
    /// ホームフォルダまで展開される」がこの形だった。
    ///
    /// 以前は「初回だけスキップする」真偽値を受け取っていたが、それだと
    /// **上書きが結局起きなかった場合に一度も展開されない**（`.home` を選んで
    /// いて既に実ホームが開いている場合など）。両者が揃った時点で 1 回走る
    /// 形にすると、`.task` とこの値のどちらが先に確定しても正しく動く。
    let startupFolderResolved: Bool
    let onSelect: (URL, NavigationRoot) -> Void
    /// コンテキストメニューの「新規タブで開く」「新規ウインドウで開く」
    /// [ユーザー要望: 中央ペインのメニューに原則あわせる]。中央ペインと違い
    /// `NavigationRoot` も一緒に渡す——ライブラリ／テンポラリ配下の行から
    /// 開いた新規タブが、`.volume` に戻ってしまわないようにするため
    /// （「1階層上へ」の境界・ツリーの自動展開スコープに効く）。
    let onOpenInNewTab: (URL, NavigationRoot) -> Void
    let onOpenInNewWindow: (URL) -> Void

    /// ボリューム・ホーム・登録フォルダの一覧を読み終えたか。
    /// 起動直後の自動展開は、これと `startupFolderResolved` が揃ってから走る。
    @State private var treeDataLoaded = false
    @State private var didRevealInitialSelection = false

    // グループの開閉は再起動をまたいで覚える [ユーザー判断]。**グループが
    // 4 つになり、左ペインの高さによってはテンポラリ・ライブラリが
    // スクロールしないと見えなくなる**ため、使わないグループを畳んだら
    // その状態が残るようにする。
    //
    // **`@AppStorage` を使ってはいけない。** 下の `body` はこれらを
    // 「行を描くかどうか」の `if` 条件に使っており、`@AppStorage` をその形で
    // 読むと SwiftUI の Observation が無限に再評価してアプリがハングする
    // [1-9 のタブバー表示トグルで実際に踏んだ]。`isRightPaneCollapsed` と
    // 同じく、**初期値だけ `UserDefaults` から素の値として読み、変更時に
    // 明示的に書き戻す**一方向の同期にしてある。
    @State private var volumesExpanded = FolderTreePane.storedExpansion(.volumes)
    @State private var favoritesExpanded = FolderTreePane.storedExpansion(.favorites)
    @State private var temporaryExpanded = FolderTreePane.storedExpansion(.temporary)
    @State private var libraryExpanded = FolderTreePane.storedExpansion(.library)
    @State private var expandedNodeIDs: Set<FolderTreeSelection> = [] // [LP-05]
    /// 現在スクロール領域内に実際に描画されている行の ID（`FolderTreeNode.id`
    /// と同じ正規化パス文字列）。`List` は行を遅延生成するため、各
    /// `FolderTreeRow` の `.onAppear`/`.onDisappear` で増減させる
    /// [`revealSelectionIfNeeded` が「既に表示範囲内なら再スクロールしない」
    /// 判定に使う、ユーザー要望]。
    @State private var visibleNodeIDs: Set<FolderTreeSelection> = []
    /// `List` 自身に持たせる選択 [ユーザー要望: ツリーをキーボードで辿りたい]。
    ///
    /// **上下移動も ← → の開閉も `List`／`DisclosureGroup` が既に持っている。**
    /// 自分でキーを捌こうとすると届かない（`NSOutlineView` が先に食べる）が、
    /// 選択を束ねてやれば AppKit の実装がそのまま働く。こちらは「選択が
    /// 変わったら、そこへ移動する」だけを担う。
    ///
    /// 選択の値に URL と枝の両方を持たせているので、変化を受け取った時点で
    /// 行を引き当て直す必要が無い（どの枝から来たかは `NavigationRoot` に
    /// 要る [`FolderTreeBranch` 参照]）。
    @State private var listSelection: FolderTreeSelection?
    @State private var volumes: [FolderTreeNode] = []
    /// 「よく使う項目」グループの行 [ユーザー要望]。何を並べるかは環境設定
    /// （`FavoriteLocations`）が決めるので登録フォルダのような永続化は無く、
    /// 存在確認と「直下にサブフォルダがあるか」を測り直すだけで再構築できる。
    @State private var favoriteItems: [FavoriteItem] = []
    /// 外付けディスク・ディスクイメージ・ネットワークボリュームのマウント
    /// ポイントが並ぶ場所。起動ボリューム（`/`）はここには現れないが、
    /// 取り外されることも無いので見張る必要が無い。
    private static let volumesDirectory = URL(fileURLWithPath: "/Volumes", isDirectory: true)
    @State private var volumesWatch = DirectoryObservation()
    @State private var libraryEntries: [RegisteredFolderEntry] = []
    @State private var temporaryEntries: [RegisteredFolderEntry] = []
    /// 登録ルートの**親フォルダ**を見張る [1-17][RG3-07]。キーは親のパス。
    ///
    /// ## なぜ親なのか
    /// 縮退へ落ちる引き金は 2 つある。ボリュームの着脱は `volumesWatch`
    /// （`/Volumes`）が拾うが、**登録ルート自身がゴミ箱へ移された・消された・
    /// 改名された**場合は、その変更が現れるのは**親フォルダ**である。
    /// 登録ルート自身を見張っても、中身が変わらない限り届かない。
    ///
    /// これが無いと、Finder で登録ライブラリをゴミ箱へ入れても、ツリーは
    /// 「正常」のまま残り続ける——実機検証で実際にそうなった。1-17 が塞ごうと
    /// している「気づかないままゴミ箱の中へ書き続ける」状態がそのまま残る。
    /// アプリ内でゴミ箱へ入れた場合は `SessionState.reloadToken` が動くので
    /// 拾えていたが、**アプリ外からの操作だけが漏れていた。**
    ///
    /// 親は重複しやすい（ライブラリを同じボリューム直下にまとめている等）ので
    /// パスで畳んで、実際の見張りは重複なく 1 つずつにする。
    @State private var registrationParentWatches: [String: DirectoryObservation] = [:]
    /// ファイル操作の共通レイヤ [`FolderOperations` 参照]。中央ペインと
    /// まったく同じ実装を共有する。操作の途中で判断を仰ぐシートの描画は
    /// `.folderOperationsHost(_:)` が担う。
    @State private var operations = FolderOperations()
    /// [ユーザー要望、環境設定「表示」タブ] 中央ペインでフォルダを移動した
    /// とき、現在のフォルダまでツリーを自動展開してスクロールする。
    @AppStorage("qoo.preferences.autoExpandTreeToCurrentFolder") private var autoExpandTreeToCurrentFolder = true

    var body: some View {
        ScrollViewReader { scrollProxy in
            List(selection: $listSelection) {
                Section {
                    if volumesExpanded {
                        ForEach(volumes) { node in
                            FolderTreeRow(
                                node: node, expandedIDs: $expandedNodeIDs, visibleIDs: $visibleNodeIDs,
                                selection: listSelection,
                                branch: .volume, role: .volumeRoot, onSelect: onSelect,
                                onDropFailure: { presentFailureMessage($0) },
                                operations: operations, menuActions: menuActions
                            )
                        }
                    }
                } header: {
                    GroupHeader(
                        title: String(localized: "folderTree.volumes", locale: locale),
                        isExpanded: persistedExpansion(.volumes, $volumesExpanded))
                }

                // ボリュームとテンポラリの間 [ユーザー指定の位置]。Finder の
                // 「よく使う項目」にあたるグループで、並べる場所は環境設定で
                // 選べる [`FavoriteLocations`]。
                Section {
                    if favoritesExpanded {
                        ForEach(favoriteItems) { item in
                            FolderTreeRow(
                                node: item.node, expandedIDs: $expandedNodeIDs, visibleIDs: $visibleNodeIDs,
                                selection: listSelection,
                                branch: .favorites, role: .favoriteRoot, onSelect: onSelect,
                                onDropFailure: { presentFailureMessage($0) },
                                operations: operations, menuActions: menuActions,
                                // 表示名は文字列カタログから引く [ユーザー要望:
                                // 表示名は Finder に揃える]。`localizedName` /
                                // `displayName(atPath:)` でも Finder と同じ訳語は
                                // 得られるが、あれは `Bundle.main.preferredLocalizations`
                                // に固定されるため**アプリ内の言語切替に追従しない**
                                // [実測]。訳語そのものは Apple の一次情報
                                // （`SystemFolderLocalizations`）から写してある。
                                displayNameKey: item.location.titleKey
                            )
                        }
                    }
                } header: {
                    GroupHeader(
                        title: String(localized: "folderTree.favorites", locale: locale),
                        isExpanded: persistedExpansion(.favorites, $favoritesExpanded))
                }

                Section {
                    if temporaryExpanded {
                        registeredFolderRows(temporaryEntries, kind: .temporary)
                    }
                } header: {
                    GroupHeader(
                        title: String(localized: "folderTree.temporaryFolders", locale: locale),
                        isExpanded: persistedExpansion(.temporary, $temporaryExpanded),
                        showsAddButton: true
                    ) {
                        presentRegistrationPanel(kind: .temporary)
                    }
                }

                Section {
                    if libraryExpanded {
                        registeredFolderRows(libraryEntries, kind: .library)
                    }
                } header: {
                    GroupHeader(
                        title: String(localized: "folderTree.libraryFolders", locale: locale),
                        isExpanded: persistedExpansion(.library, $libraryExpanded),
                        showsAddButton: true
                    ) {
                        presentRegistrationPanel(kind: .library)
                    }
                }
            }
            // 選択が動いたら（クリックでも ↑ ↓ でも）そこへ移動する。
            .onChange(of: listSelection) { _, newValue in
                guard let newValue,
                      newValue.url.standardizedFileURL != selectedURL?.standardizedFileURL
                else { return }
                navigateToSelection(newValue)
            }
            // 中央ペインなど外からフォルダが変わったときは選択も合わせておく。
            // そうしないと、次に ↑ ↓ を押したとき前にいた場所から動き出す。
            .onChange(of: selectedURL, initial: true) { _, newValue in
                syncListSelection(to: newValue)
            }
            .listStyle(.sidebar)
            .environment(\.defaultMinListRowHeight, 20) // 行間を少し詰める。可変にするのは 1-12（環境設定）で。
            // ボリュームの着脱に追随する [WA-07][VD-07]。`/Volumes` を見張ると
            // FSEvents が `Mount`/`Unmount` を届けてくれることを実測で確認して
            // いる。**仕様 10.2 節の `VolumeMonitor`（VD-01〜06 の状態遷移）とは
            // 別物**で、ここでやるのは「ツリーのボリューム一覧を実体に合わせる」
            // だけ。2-2 で `VolumeMonitor` が入っても、こちらは表示の追随として
            // そのまま残せる。
            // 登録ルートがアプリの外でゴミ箱へ移された・消された・改名された
            // ときに追随する [1-17]。変更が現れるのは**親フォルダ**なので、
            // そちらを見張っている（`registrationParentWatches` 参照）。
            .onChange(of: registrationParentGeneration) {
                Task { await reloadRegisteredFolders() }
            }
            .onChange(of: volumesWatch.generation) {
                Task {
                    await reloadVolumes()
                    // **登録フォルダの状態も一緒に取り直す** [RG3-07、1-17]。
                    // ボリュームの着脱こそが `.online` ⇄ `.offline` を動かす
                    // 主たる引き金で、ここで取り直さないと、外付けを抜いても
                    // 登録フォルダは「正常」のまま残り続ける（`reloadToken` が
                    // たまたま動くまで気づけない）。
                    //
                    // フェーズ1の判定は受動的でよい [RG3-07] が、**受け取れる
                    // 信号は取りこぼさない**——2-2 で `NSWorkspace` のボリューム
                    // 通知（VD-01〜06）に置き換わっても、状態モデルと判定順序は
                    // そのままで駆動方法だけが替わる。
                    await reloadRegisteredFolders()
                }
            }
            .task {
                volumesWatch.watch(Self.volumesDirectory, scope: .shallow)
                await reloadVolumes()
                await reloadFavorites()
                await reloadRegisteredFolders()
                treeDataLoaded = true
                revealInitialSelectionIfReady(scrollProxy: scrollProxy)
            }
            // 起動時フォルダの解決と一覧の読み込みは、どちらが先に終わるか
            // 決まっていない。**両方揃った時点で 1 回だけ**自動展開する。
            .onChange(of: startupFolderResolved) { _, _ in
                revealInitialSelectionIfReady(scrollProxy: scrollProxy)
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
                Task {
                    await reloadVolumes()
                    // アクセス許可の増減や、環境設定での表示項目の変更で
                    // 「よく使う項目」の見え方が変わる（許可した瞬間に
                    // 「直下にサブフォルダがあるか」を測れるようになり、三角の
                    // 有無が確定する）。どちらもこの共通シグナルを動かす。
                    await reloadFavorites()
                    await reloadRegisteredFolders()
                }
            }
        }
    }

    /// 開閉を覚えるグループ。
    enum TreeGroup: String {
        case volumes, favorites, temporary, library
        var storageKey: String { "qoo.folderTree.expanded.\(rawValue)" }
    }

    /// 既定はすべて開いた状態。`bool(forKey:)` は未設定でも `false` を返すので、
    /// 「設定されているか」を先に見る [`MainWindowView.storedFlag` と同じ形]。
    static func storedExpansion(_ group: TreeGroup) -> Bool {
        guard UserDefaults.standard.object(forKey: group.storageKey) != nil else { return true }
        return UserDefaults.standard.bool(forKey: group.storageKey)
    }

    /// 見出しのクリックで開閉したときに書き戻す `Binding`。
    ///
    /// **`revealSelectionIfNeeded` の自動展開はここを通さない**（`@State` を
    /// 直接動かす）。自動で開いたものまで覚えると、利用者が畳んだ意図を
    /// アプリ側が黙って上書きすることになる——覚えるのは明示的な操作だけ。
    private func persistedExpansion(_ group: TreeGroup, _ state: Binding<Bool>) -> Binding<Bool> {
        Binding(
            get: { state.wrappedValue },
            set: { newValue in
                state.wrappedValue = newValue
                UserDefaults.standard.set(newValue, forKey: group.storageKey)
            }
        )
    }

    /// 起動直後の自動展開。**材料と行き先の両方が揃ってから、1 回だけ**走る。
    ///
    /// 以降の移動は `.onChange(of: selectedURL)` が拾う。
    private func revealInitialSelectionIfReady(scrollProxy: ScrollViewProxy) {
        guard treeDataLoaded, startupFolderResolved, !didRevealInitialSelection else { return }
        didRevealInitialSelection = true
        revealSelectionIfNeeded(scrollProxy: scrollProxy)
    }

    /// 外からフォルダが変わったときに `List` の選択を合わせる。
    ///
    /// 枝は現在の `navigationRoot` から復元する。登録フォルダ経由の場合、
    /// `NavigationRoot` は種別（テンポラリ／ライブラリ）を持たないので、
    /// 登録一覧から引き当てる。
    private func syncListSelection(to url: URL?) {
        listSelection = rowID(for: url)
    }

    /// `selectedURL` と `navigationRoot` から行の識別子を組み立てる。
    ///
    /// `List` の選択とツリーの自動展開・スクロールが**同じ導出**を使う
    /// ——別々に書くと、選択している行とスクロール先が食い違う。
    private func rowID(for url: URL?) -> FolderTreeSelection? {
        guard let url else { return nil }
        let branch: FolderTreeBranch
        switch navigationRoot {
        case .volume:
            branch = .volume
        case .favorites:
            branch = .favorites
        case .registeredFolder(let id, let rootURL):
            if temporaryEntries.contains(where: { $0.folder.id == id }) {
                branch = .temporary(id: id, rootURL: rootURL)
            } else {
                branch = .library(id: id, rootURL: rootURL)
            }
        }
        return FolderTreeSelection(url: url, branch: branch)
    }

    /// 祖先のパス集合を、その枝の行の識別子へ変換する。
    private static func rowIDs(_ paths: Set<String>, branch: FolderTreeBranch) -> Set<FolderTreeSelection> {
        Set(paths.map { FolderTreeSelection(path: $0, branch: branch) })
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
            // **そのボリュームのマウントポイントで打ち切る** [実機検証で発見・
            // 修正したバグ、ユーザー報告: 「外部ボリュームを選択すると、なぜか
            // Macintosh HD のツリーが展開する」]。ツリーはボリュームごとに
            // 独立した最上位の行を持つが、**パスの上では外部ボリュームも
            // `/Volumes/…` ＝起動ボリュームの配下**にある。祖先をルートまで
            // 遡ると `/Volumes` と `/` が展開対象に入り、`/` は Macintosh HD の
            // 行 ID そのものなので、選んでもいない Macintosh HD が開いていた。
            // マウントポイントより上は「別の行」なので遡ってはいけない。
            //
            // 起動ボリューム自身（マウントポイントが `/`）を選んだ場合は
            // `floor == "/"` となり、ループの終了条件と一致するため従来どおり
            // 動く（仮想ホームのように `/` 配下の深い場所も正しく展開される）。
            expandedNodeIDs.formUnion(
                Self.rowIDs(Self.ancestorPaths(of: selectedURL, downTo: volumeRoot(containing: selectedURL)), branch: .volume)
            )
        case .favorites:
            favoritesExpanded = true
            // **一番深く一致する行で打ち切る。** `~/Downloads/foo` はホーム行
            // にも一致するが、開きたいのは「ダウンロード」行の下だけ——上まで
            // 開くと、ホーム行が展開されて同じフォルダが 2 か所に見えることになる。
            //
            // **一致する行が無ければ何も展開しない。** `.favorites` を名乗り
            // ながらどの行の配下でもない状態は `WindowState.normalizedRoot` が
            // 潰しているので通常は起こらないが、ここで無条件に遡ると `/`（＝
            // Macintosh HD の行 ID）まで開いてしまう——選んでもいない
            // ボリュームのツリーが展開される、という 3 度目の同じ壊れ方に
            // なるので、砦を 2 枚にしておく。
            if let floor = favoriteRoot(containing: selectedURL) {
                expandedNodeIDs.formUnion(
                    Self.rowIDs(Self.ancestorPaths(of: selectedURL, downTo: floor), branch: .favorites)
                )
            }
        case .registeredFolder(let id, let rootURL):
            if temporaryEntries.contains(where: { $0.folder.id == id }) {
                temporaryExpanded = true
            } else if libraryEntries.contains(where: { $0.folder.id == id }) {
                libraryExpanded = true
            }
            let branch: FolderTreeBranch = temporaryEntries.contains(where: { $0.folder.id == id })
                ? .temporary(id: id, rootURL: rootURL)
                : .library(id: id, rootURL: rootURL)
            expandedNodeIDs.formUnion(
                Self.rowIDs(Self.ancestorPaths(of: selectedURL, downTo: rootURL), branch: branch)
            )
        }

        // ツリー行は遅延読み込み（`FolderTreeRow.loadChildren()`）のため、
        // 展開の反映（子の読み込み・行の生成）が実際に画面へ反映されるまで
        // 数フレームかかることがある。`PaneWindows.swift`/`WindowFrameAutosave.swift`
        // と同じ「1サイクル遅らせて適用する」パターンだが、階層が深い場合は
        // 複数段のカスケードになるため、経験的に十分な余裕を持たせている。
        // スクロール先も枝で絞る [`FolderTreeSelection`]。同じ実フォルダが
        // 2 つの枝に現れるので、パスだけで探すと選んでいない側の行へ飛ぶ。
        guard let targetID = rowID(for: selectedURL) else { return }
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
    /// `url` を含むボリュームのマウントポイント（このツリーが最上位の行として
    /// 表示しているもの）。
    ///
    /// **`.volumeURLKey` は使わない** — サンドボックス配下の経路で解決に失敗する
    /// ことがある（1-6 の D&D で実際に踏み、`.volumeUUIDStringKey` へ切り替えた
    /// のと同じ罠）。ここでは既に手元にある `volumes`（＝ツリーが実際に表示して
    /// いる行）から最長一致で引き当てるので、「ツリーの行として存在するもの」と
    /// 必ず一致するという利点もある。
    private func volumeRoot(containing url: URL) -> URL? {
        let path = url.standardizedFileURL.path
        return volumes
            .map(\.url)
            .filter { path == $0.standardizedFileURL.path || path.hasPrefix($0.standardizedFileURL.path + "/") }
            // `/` と `/Volumes/X` は両方とも前方一致するので、より深い方を選ぶ。
            .max { $0.standardizedFileURL.path.count < $1.standardizedFileURL.path.count }
    }

    /// `url` を含む「よく使う項目」の行のうち、**一番深いもの**。無ければ
    /// `nil` ——呼び出し側はそのとき**何も展開しない**（上のコメント参照）。
    ///
    /// `volumeRoot(containing:)` と同じ最長一致。判定そのものは
    /// `FavoriteLocations.root(containing:in:)` に純粋関数として置いてある
    /// （引数だけで振る舞いが決まるので、実アプリを起動せず境界条件を
    /// 確かめられる）。**表示中の行そのもの**から探すので、環境設定で項目を
    /// 隠した直後でも食い違わない。
    private func favoriteRoot(containing url: URL) -> URL? {
        FavoriteLocations.root(containing: url, in: favoriteItems.map(\.node.url))
    }

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
            registeredRowsForEach(entries, kind: kind)
                // D&D で並べ替えられる [RG3-33]。順序はストアに保存され、
                // 全ウインドウ・「移動」メニューで共有する（`reorder` 参照）。
                .onMove { from, to in
                    moveRegisteredFolders(kind, from: from, to: to)
                }
        }
    }

    /// 登録ルート行の `ForEach` 本体。`.onMove` [RG3-33] を付けるために
    /// `if/else` の外へ切り出してある（`onMove` は `ForEach` 自身にしか
    /// 付けられない）。
    private func registeredRowsForEach(_ entries: [RegisteredFolderEntry],
                                       kind: RegisteredFolderKind) -> some DynamicViewContent {
        ForEach(entries) { entry in
                if let node = entry.node {
                    FolderTreeRow(
                        node: node, expandedIDs: $expandedNodeIDs, visibleIDs: $visibleNodeIDs,
                        selection: listSelection,
                        branch: .registered(kind: kind, id: entry.folder.id, rootURL: node.url),
                        role: .registeredRoot,
                        onSelect: onSelect,
                        onDropFailure: { presentFailureMessage($0) },
                        operations: operations, menuActions: menuActions,
                        registeredFolder: entry.folder,
                        annotation: entry.annotation,
                        allowsWriting: entry.state.status.allowsWriting
                    )
                } else {
                    // 入って辿れない縮退状態 [1-17]。**行を出し続けるのが要点**
                    // ——登録レコードは決して自動削除しない [RG3-04][SB-05] ので、
                    // 状態を見せて次の一手を示す。
                    DegradedRegisteredFolderRow(
                        state: entry.state,
                        onRelocate: { presentRelocatePanel(for: entry.folder) },
                        onRevealInFinder: { operations.revealInFinder([$0]) },
                        onUnregister: { unregisterFolder(entry.folder) },
                        isLibraryEnabled: LibraryServices.shared
                            .isEnabled(registrationUUID: entry.folder.id),
                        onDisableLibrary: { disableLibrary(entry.folder) },
                        onOpenLibrarySettings: { openLibrarySettings(entry.folder) },
                        onOpenLabelEditor: { openLabelEditor(entry.folder) },
                        onOpenLabelVault: { openLabelVault(entry.folder) },
                        onOpenFileVault: { openFileVault(entry.folder) },
                        onOpenOrphanCleanup: { openOrphanCleanup(entry.folder) },
                        onOpenUnresolvedFiles: { openUnresolvedFiles(entry.folder) }
                    )
                }
            }
    }

    /// フォルダツリーの D&D 並べ替え [RG3-33]。
    ///
    /// **先にローカルの並びを動かしてからストアへ書く**——ストアの保存を
    /// 待ってから描き直すと、ドロップの瞬間に一度元の位置へ戻って見える。
    /// 保存後の `reloadToken` で他のウインドウとメニューが追随する。
    private func moveRegisteredFolders(_ kind: RegisteredFolderKind,
                                       from: IndexSet, to: Int) {
        var entries = kind == .library ? libraryEntries : temporaryEntries
        entries.move(fromOffsets: from, toOffset: to)
        if kind == .library { libraryEntries = entries } else { temporaryEntries = entries }
        let ids = entries.map(\.folder.id)
        Task {
            await RegisteredFolderStore.shared.reorder(ids: ids, kind: kind)
            SessionState.shared.reloadToken += 1
        }
    }

    /// 実体を見失った登録に、新しい場所を割り当て直す [1-17、`.missing` の
    /// 「場所を選び直す…」]。
    ///
    /// **登録解除して登録し直すのとは違う。** 登録 ID が保たれるので、それに
    /// 紐づくもの（フェーズ1ではサムネイル非表示設定、フェーズ2ではラベル・
    /// 評価・カバー画像）がそのまま生き残る。
    private func presentRelocatePanel(for folder: RegisteredFolder) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "folderTree.relocatePanelPrompt", locale: locale)
        panel.message = String(
            format: String(localized: "folderTree.relocatePanelMessage", locale: locale), folder.displayName
        )
        // **最後に分かっている場所の「親」から開く** [1-17]。当のフォルダ自身は
        // もう無いので、そこを指しても Finder 側で無視される。
        if let last = folder.lastKnownPath {
            panel.directoryURL = URL(fileURLWithPath: last).deletingLastPathComponent()
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }

        Task {
            do {
                let result = try await RegisteredFolderStore.shared.relocate(folder.id, to: url)
                await reloadRegisteredFolders()
                // ツリーだけでなく、この登録フォルダを表示していた他のペインも
                // 読み直させる（登録の増減と同じ共通シグナル）。
                SessionState.shared.reloadToken += 1
                // **新規登録と同じ警告を出す** [FS-06][NV-87][NV8-04、レビューで
                // 発見]。ネットワーク共有やクラウドへ移し替えたのに何も言わない
                // のでは、登録経路との食い違いになる。
                if !result.warnings.isEmpty {
                    await NotificationRouter.shared.present(NotificationItem(
                        category: .warning, severity: .transient,
                        title: String(localized: "folderTree.registeredWithWarningTitle", locale: locale),
                        body: result.warnings.map(Self.description(for:)).joined(separator: "\n")
                    ))
                }
            } catch {
                await NotificationRouter.shared.presentError(
                    error, whatHappened: String(localized: "folderTree.relocateFailedTitle", locale: locale)
                )
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
            beginRenameFolder: { presentRenameFolderDialog($0.url) },
            beginNewFolder: { presentNewFolderDialog(in: $0.url, branch: $0.branch) },
            beginRenameDisplayName: { presentRenameDisplayNameDialog($0) },
            unregister: { unregisterFolder($0) },
            // [DS-04] 状態はメインアクタ上のキャッシュから同期的に読み、
            // 書き込みだけ非同期でストアへ送ってからキャッシュを取り直す。
            isThumbnailsAlwaysHidden: { RegisteredFolderIndex.shared.hidesThumbnails(registeredFolderID: $0.id) },
            setThumbnailsAlwaysHidden: { setThumbnailsAlwaysHidden($0, hidden: $1) },
            // [フェーズ 2 の結線] ライブラリ機能。実処理は `LibraryEnableAction`
            // に集約してある——フォルダツリーとメニューバーの両方から同じ実装を
            // 呼ぶため（同じに見える操作に独立した経路を作ると、片方だけ直して
            // 取り残す。1-12 のアプリ関連付けで実際に踏んだ形）。
            isLibraryEnabled: { LibraryServices.shared.isEnabled(registrationUUID: $0.id) },
            enableLibrary: { LibraryEnableAction.begin(folder: $0, url: $1, locale: locale,
                                                      openWindow: openWindow) },
            rescanLibrary: { LibraryEnableAction.rescan(folder: $0, url: $1, locale: locale,
                                                       openWindow: openWindow) },
            disableLibrary: { LibraryEnableAction.disable(folder: $0) },
            openLibrarySettings: { openLibrarySettings($0) },
            openLabelEditor: { openLabelEditor($0) },
            openLabelVault: { openLabelVault($0) },
            openFileVault: { openFileVault($0) },
            openOrphanCleanup: { openOrphanCleanup($0) },
            openUnresolvedFiles: { openUnresolvedFiles($0) },
            // [FDA-03] ライブラリ配下のフォルダを丸ごと保管庫へ。
            libraryForRow: { context in
                guard case .registeredFolder(let id, _) = context.navigationRoot,
                      let library = LibraryServices.shared.library(registrationUUID: id),
                      library.isOnline else { return nil }
                return library
            },
            archiveFolderToVault: { context, library in
                operations.archiveFolder(context.url, library: library)
            }
        )
    }

    // MARK: - 入力ダイアログ
    //
    // いずれも `NameInputDialog` を独立したモーダルウインドウとして出す
    // （`DialogWindowPresenter` 参照）。中央ペインのファイル名変更は従来どおり
    // Finder 流のインライン編集で、この経路は通らない。

    /// 実フォルダの名前を変更する [FM-05]。
    private func presentRenameFolderDialog(_ url: URL) {
        DialogWindowPresenter.shared.present(
            title: String(localized: "folderTree.renameFolder", locale: locale)
        ) { _ in
            NameInputDialog(
                placeholder: String(localized: "folder.namePlaceholder", locale: locale),
                confirmTitle: String(localized: "action.rename", locale: locale),
                initialName: url.lastPathComponent
            ) { name in
                operations.rename(url, to: name) { reloadTreeAfterMutation() }
            }
        }
    }

    /// `parent` の中に新規フォルダを作る [FM-01]。
    private func presentNewFolderDialog(in parent: URL, branch: FolderTreeBranch) {
        DialogWindowPresenter.shared.present(
            title: String(localized: "action.newFolder", locale: locale)
        ) { _ in
            NameInputDialog(
                placeholder: String(localized: "folder.namePlaceholder", locale: locale),
                confirmTitle: String(localized: "common.create", locale: locale),
                initialName: String(localized: "action.newFolder", locale: locale)
            ) { name in
                operations.createFolder(named: name, in: parent) {
                    // 作成先の行を開いておく——折りたたんだ行に対して実行した場合、
                    // 開かないと「何も起きなかった」ように見えるため。既に展開済み
                    // なら `SessionState.reloadToken` 側で、折りたたみ済みなら
                    // 展開を検知した `FolderTreeRow` 側で、どちらも子が読み直される。
                    expandedNodeIDs.insert(FolderTreeSelection(url: parent, branch: branch))
                    reloadTreeAfterMutation()
                }
            }
        }
    }

    /// 登録フォルダの表示名を変更する [RG-05]。実フォルダ名は変えない。
    private func presentRenameDisplayNameDialog(_ folder: RegisteredFolder) {
        DialogWindowPresenter.shared.present(
            title: String(localized: "folderTree.renameDisplayName", locale: locale)
        ) { _ in
            NameInputDialog(
                placeholder: String(localized: "folderTree.displayName", locale: locale),
                confirmTitle: String(localized: "action.rename", locale: locale),
                initialName: folder.displayName
            ) { name in
                Task {
                    do {
                        try await RegisteredFolderStore.shared.rename(folder.id, to: name)
                    } catch {
                        // 保存失敗を握りつぶさない [ER-01、2026-08 既知の不具合の
                        // 一掃] — 以前は `try?` で、次回起動時に変更が消えていても
                        // 気づく手段が無かった。
                        await NotificationRouter.shared.presentError(
                            error, whatHappened: String(localized: "error.operationFailed", locale: locale)
                        )
                    }
                    await reloadRegisteredFolders()
                }
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
        // ライブラリフォルダは登録ウィザードで [RG3-20]。フォルダの選択から
        // テンプレート・確認までを 1 本の導線にする（登録＝ライブラリ化）。
        // テンポラリは従来どおりパネルだけ（フェーズ 3 の対象）。
        if kind == .library {
            LibraryRegistrationWizard.begin(locale: locale, openWindow: openWindow)
            return
        }
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
                let result = try await RegisteredFolderStore.shared.register(
                    url: url, kind: kind, displayName: nil
                )
                await reloadRegisteredFolders()
                // **登録は通ったが知らせるべきこと** [FS-06][NV-87]。
                // 以前はここまで届く口が無く、生成された警告がそのまま
                // 捨てられていた。判断は要らないので一時通知にとどめる [ER-02]。
                if !result.warnings.isEmpty {
                    await NotificationRouter.shared.present(NotificationItem(
                        category: .warning, severity: .transient,
                        title: String(localized: "folderTree.registeredWithWarningTitle", locale: locale),
                        body: result.warnings.map(Self.description(for:))
                            .joined(separator: "\n")
                    ))
                }
            } catch {
                await NotificationRouter.shared.present(NotificationItem(
                    category: .error, severity: .sheet,
                    title: String(localized: "folderTree.registrationFailedTitle", locale: locale), body: Self.errorMessage(for: error)
                ))
            }
        }
    }

    /// 登録時の警告 [FS-06][NV8-04] の文言は `LibraryEnableAction` に一本化
    /// されている（登録の経路が 2 つあるため。片方だけ直る事故を防ぐ）。
    private static func description(for warning: RegistrationWarning) -> String {
        LibraryEnableAction.registrationWarningDescription(
            warning, locale: AppLanguage.effectiveLocale)
    }

    /// この登録フォルダでサムネイルを常に非表示にするか [DS-04]。
    ///
    /// **`unregisterFolder` と同じく View のメソッドとして持つ**（コンテキスト
    /// メニューの `FolderTreeContextMenuActions` へ直接書かない）。あちらは
    /// 一行のクロージャを並べた対応表として読めるようにしておきたいため。
    private func setThumbnailsAlwaysHidden(_ folder: RegisteredFolder, hidden: Bool) {
        Task {
            do {
                try await RegisteredFolderStore.shared.setThumbnailsAlwaysHidden(hidden, for: folder.id)
            } catch {
                await NotificationRouter.shared.presentError(
                    error,
                    whatHappened: String(localized: "folderTree.thumbnailSettingFailed", locale: locale)
                )
                return
            }
            // `RegisteredFolderIndex` を取り直すと、この設定を見ているすべての
            // ウインドウが `@Observable` 経由で追従する [DS-03 と同じ即時反映]。
            // ツリーの行そのものは変わらないので `SessionState.reloadToken` は
            // 増やさない（フォルダ一覧の再読み込みまで巻き込む必要が無い）。
            await RegisteredFolderIndex.shared.refresh()
        }
    }

    /// 登録解除 [RG-06 の簡易版]。
    ///
    /// **ライブラリとして有効なら、DB のライブラリ行も一緒に消す。**
    /// 片方だけ消すと、登録は無いのにライブラリ行と数万件のレコードが
    /// DB に取り残される——誰も片付けられず、同じフォルダを再登録すると
    /// 新しい UUID で 2 件目ができて古い行が永久に残る。
    ///
    /// **消える前に必ず尋ねる。** `LibraryRepository.unregister` は
    /// `keepLabels` をまだ見ずに連鎖削除するので、**手で付けた評価やラベルが
    /// 黙って失われる**。ラベル保管庫 [RG-06][2-11] が入るまでは、せめて
    /// 何が失われるかを伝えてから消す。
    private func unregisterFolder(_ folder: RegisteredFolder) {
        guard LibraryServices.shared.isEnabled(registrationUUID: folder.id) else {
            performUnregister(folder)
            return
        }
        DialogWindowPresenter.shared.present(
            title: String(localized: "folderTree.unregister", locale: locale)
        ) { dismiss in
            LibraryUnregisterConfirmationDialog(folderName: folder.displayName) {
                dismiss()
                performUnregister(folder, disablingLibrary: true)
            }
        }
    }

    /// ライブラリの設定ウインドウを開く [LS-01〜LS-03]。
    ///
    /// `Window(id:)` は同じ id で再度開いてもビューを作り直さないので、
    /// 「どのライブラリを見せるか」は受け皿（`LibrarySettingsNavigation`）へ
    /// 先に置いてから開く——`PreferencesNavigation` と同じ形。
    private func openLibrarySettings(_ folder: RegisteredFolder) {
        guard let summary = LibraryServices.shared.library(registrationUUID: folder.id) else { return }
        LibrarySettingsNavigation.shared.pendingLibraryID = summary.id
        openWindow(id: "librarySettings")
    }

    /// ラベルグループ編集ウインドウを開く [LE-01〜LE-12][15.2 節]。
    ///
    /// **登録ルート行は 2 つある**（通常の `FolderTreeContextMenu` と、縮退した
    /// `DegradedRegisteredFolderRow`）。配線は別々なので、項目を足すときは
    /// 両方に要る——片方だけ配線して取り残した前例がある。
    private func openLabelEditor(_ folder: RegisteredFolder) {
        guard let summary = LibraryServices.shared.library(registrationUUID: folder.id) else { return }
        LabelEditorNavigation.shared.pendingLibraryID = summary.id
        openWindow(id: "labelEditor")
    }

    /// ラベル保管庫の整理ウインドウを開く [LAW-01〜LAW-03][15.3 節]。
    ///
    /// `openLabelEditor` と同じく、**登録ルート行が 2 つある**ことに注意
    /// （通常の `FolderTreeContextMenu` と縮退した
    /// `DegradedRegisteredFolderRow`）。配線は別々なので両方に要る。
    private func openLabelVault(_ folder: RegisteredFolder) {
        guard let summary = LibraryServices.shared.library(registrationUUID: folder.id) else { return }
        // **受け皿へ置く順序をここで書き直さない** [CP-02]。写すと、入口が
        // 増えたときに片方だけ直して取り残す（このリポジトリで 3 度起きた形）。
        LabelVaultNavigation.open(libraryID: summary.id, openWindow: openWindow)
    }

    /// ファイル保管庫の整理ウインドウを開く [FAW-01〜FAW-05][15.4 節]。
    private func openFileVault(_ folder: RegisteredFolder) {
        guard let summary = LibraryServices.shared.library(registrationUUID: folder.id) else { return }
        // **受け皿へ置く順序をここで書き直さない** [CP-02]。
        FileVaultNavigation.open(libraryID: summary.id, openWindow: openWindow)
    }

    /// 孤立ファイルの整理ウインドウを開く [OR-01〜OR-05][15.7 節]。
    ///
    /// `openLabelVault` と同じく、**登録ルート行が 2 つある**ことに注意
    /// （通常の `FolderTreeContextMenu` と縮退した
    /// `DegradedRegisteredFolderRow`）。配線は別々なので両方に要る。
    private func openOrphanCleanup(_ folder: RegisteredFolder) {
        guard let summary = LibraryServices.shared.library(registrationUUID: folder.id) else { return }
        // **受け皿へ置く順序をここで書き直さない** [CP-02]。
        OrphanCleanupNavigation.open(libraryID: summary.id, openWindow: openWindow)
    }

    /// 未解決ファイルの整理ウインドウを開く [UR-01〜UR-06][15.6 節]。
    ///
    /// 孤立側と同じく、**登録ルート行が 2 つある**ことに注意（通常の
    /// `FolderTreeContextMenu` と縮退した `DegradedRegisteredFolderRow`）。
    /// 配線は別々なので両方に要る。
    private func openUnresolvedFiles(_ folder: RegisteredFolder) {
        guard let summary = LibraryServices.shared.library(registrationUUID: folder.id) else { return }
        // **受け皿へ置く順序をここで書き直さない** [CP-02]。
        UnresolvedFilesNavigation.open(libraryID: summary.id, openWindow: openWindow)
    }

    /// ライブラリ機能だけを無効にする（登録フォルダは残す）。
    private func disableLibrary(_ folder: RegisteredFolder) {
        Task {
            do {
                try await LibraryServices.shared.disable(registrationUUID: folder.id)
            } catch {
                await NotificationRouter.shared.presentError(
                    error, whatHappened: String(localized: "library.disable.failed", locale: locale)
                )
            }
            await reloadRegisteredFolders()
        }
    }

    private func performUnregister(_ folder: RegisteredFolder, disablingLibrary: Bool = false) {
        Task {
            do {
                // **ライブラリを先に、登録解除を後に。** 逆にすると、
                // 解除でセキュリティスコープが閉じたあとに DB を触ることになり、
                // 失敗したときに「登録は消えたがライブラリ行は残る」という
                // 一番片付けにくい状態を作る。
                if disablingLibrary {
                    try await LibraryServices.shared.disable(registrationUUID: folder.id)
                }
                try await RegisteredFolderStore.shared.unregister(folder.id)
            } catch {
                // 保存失敗を握りつぶさない [ER-01、2026-08 既知の不具合の一掃]。
                await NotificationRouter.shared.presentError(
                    error, whatHappened: String(localized: "error.operationFailed", locale: locale)
                )
            }
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

    /// ボリューム一覧を読み直す。
    ///
    /// **メインスレッドで読まない** [NV6-02]。マウント表の読み出し自体は速い
    /// が、そのあと各ボリュームへ `volumeLocalizedName` などを尋ねるので、
    /// 応答しないネットワーク共有が 1 つ混じっていると、そこで止まる。
    /// ボリューム一覧はアプリ起動時とマウント／アンマウントのたびに読むため、
    /// 止まるとツリー全体が描画されない。
    private func reloadVolumes() async {
        volumes = await FileIO.perform { FolderTreeNode.mountedVolumes() }
    }

    private func reloadFavorites() async {
        // 何を並べるかはメインアクタ側で決め（`UserDefaults` を読むだけ）、
        // 実 I/O を伴う行の組み立てだけを外へ出す [NV6-02]。
        let locations = FavoriteLocations.visible
        favoriteItems = await FileIO.perform { FavoriteLocations.load(locations) }
    }

    /// ツリーの選択が動いたときの移動 [LP-06]。
    ///
    /// **よく使う項目の行だけ、未許可ならその場で許可パネルを挟む**
    /// ［ユーザー判断: 未許可の項目も普通に並べ、押したらパネルを出す］。
    /// デスクトップ・書類は TCC 保護でそのパスへの許可が要り、ホーム自身も
    /// 許可が要る [実測、`StandardLocation.accessRequirement`]——ここで
    /// 求めないと、「アクセス権がありません」に突き当たるまで理由が分からない。
    ///
    /// 判定と許可の求め方は「移動」メニューと同じ `StandardLocationOpener`
    /// に委ねる。同じ場所へ行く経路が 2 つあって振る舞いが違う、という形を
    /// 作らないため [1-12 のアプリ関連付けで踏んだ「複数の到達経路」の教訓]。
    private func navigateToSelection(_ selection: FolderTreeSelection) {
        let root = selection.branch.navigationRoot
        guard case .favorites = selection.branch,
              let location = FavoriteLocations.visible.first(where: {
                  $0.url.standardizedFileURL == selection.url.standardizedFileURL
              })
        else {
            onSelect(selection.url, root)
            return
        }
        StandardLocationOpener.open(
            location, locale: locale,
            // パネルを閉じられたら選択を戻す。押した瞬間に `List` の選択は
            // 動いてしまうので、移動しなかったのに選択だけ進んだ状態を残すと、
            // 次の ↑ ↓ が居ない場所から動き出す。
            onCancel: { syncListSelection(to: selectedURL) },
            navigate: { onSelect($0, root) }
        )
    }

    private func reloadRegisteredFolders() async {
        // **状態を 1 回でまとめて解決する** [1-17]。以前は登録ごとに
        // `resolvedURL(for:)` を逐次呼んでいたが、`states()` はマウント表を
        // 1 回だけ写し、残りの解決と実体確認を並行に行う——応答しない
        // ボリュームがあっても待ちは上限 1 回分で収まる。
        let states = await RegisteredFolderStore.shared.states()
        // **`entries` はメインアクタの外で組み立てる** [NV6-02]。行の材料を
        // 作るだけだった以前と違い、いまは登録ルートの直下も 1 回読む
        // （三角マークの出し分け、`FolderTreeNode.hasSubfolders` 参照）。
        let built = await FileIO.perform {
            (
                library: Self.entries(from: states, kind: .library),
                temporary: Self.entries(from: states, kind: .temporary)
            )
        }
        libraryEntries = built.library
        temporaryEntries = built.temporary
        // **ここで `syncListSelection` を呼んではいけない** [実機検証で発見]。
        // このメソッドは `await` を挟むので、そのあと読む `selectedURL` は
        // **1 世代古い View インスタンスの値**になり得る（このコードベースが
        // 繰り返し踏んでいる罠）。古い値で `listSelection` を書き換えると
        // `.onChange(of: listSelection)` がユーザー操作と区別できずに発火し、
        // **起動時フォルダを開いた直後に、それを捨てて古い場所へ戻してしまう。**
        //
        // 枝の取り違え（一覧が空のときテンポラリをライブラリと判定する）は、
        // `FolderTreeBranch.identityKey` が種別を畳むことで無害になっている。
        syncRegistrationParentWatches(states)
        // 「移動」メニュー用のキャッシュも同じタイミングで更新する [1-16]。
        // 登録の追加・解除・表示名変更・`SessionState.reloadToken` の変化は
        // すべてこのメソッドを経由するため、更新経路をここ 1 本に集約できる
        // [`RegisteredFolderIndex` のコメント参照]。
        await RegisteredFolderIndex.shared.refresh()
        // フォルダ名＝表示名 [RG3-31]。`states()` がストア側の表示名を実名へ
        // 追随させたので、DB 側（設定ウインドウの一覧・通知・@libraryname）も
        // 揃える。リネームの検知（RG3-07 の親の見張り）はこのメソッドへ
        // 合流するので、呼び出しはここ 1 本で足りる。
        await LibraryServices.shared.syncLibraryDisplayNames()
    }

    /// 登録ルートの親フォルダの見張りを、いまの登録内容に合わせる [1-17]。
    ///
    /// **場所が分かっているものだけ**が対象。オフラインの登録は親も
    /// 未接続のボリューム上にあり、見張っても届かない（届くようになるのは
    /// 接続されたときで、それは `volumesWatch` が拾う）。
    private func syncRegistrationParentWatches(_ states: [RegisteredFolderState]) {
        let parents = Set(
            states.compactMap { state -> String? in
                guard let url = state.status.resolvedURL else { return nil }
                return url.deletingLastPathComponent().standardizedFileURL.path
            }
        )
        // 要らなくなったものを解く。`DirectoryObservation` は解放時に自分で
        // 登録を解くので、辞書から外すだけでよい。
        for key in registrationParentWatches.keys where !parents.contains(key) {
            registrationParentWatches.removeValue(forKey: key)
        }
        for parent in parents where registrationParentWatches[parent] == nil {
            let observation = DirectoryObservation()
            observation.watch(URL(fileURLWithPath: parent), scope: .shallow)
            registrationParentWatches[parent] = observation
        }
    }

    /// 見張っている親フォルダの世代の合計。**`body` から読むことが購読になる**
    /// ので、`.onChange` の比較対象にそのまま使う（`DirectoryObservation` は
    /// `@Observable`）。個々の値が要るわけではなく、「どれかが動いた」ことだけ
    /// 分かればよい。
    private var registrationParentGeneration: Int {
        registrationParentWatches.values.reduce(0) { $0 &+ $1.generation }
    }

    /// 状態一覧から、片方のグループぶんの行の材料を組み立てる。
    ///
    /// **`node` を作るのは「入って辿れる」状態のときだけ** [RG3-06]。
    /// オフラインで作ってしまうと、行を展開しただけで未接続のボリュームを
    /// 読みに行く——ネットワーク越しならそこで接続タイムアウト分ブロックする。
    /// **`nonisolated` であること。** `FileIO.perform` の閉包から呼ぶので、
    /// `View` から受け継いだ `@MainActor` のままだと隔離検査の表明が破れて
    /// **起動直後に即死する**（`dispatch_assert_queue_fail` →
    /// `EXC_BREAKPOINT`。実際に踏んだ。コンパイラは警告を出すので、
    /// アプリ層の警告を放置しないこと）。
    private nonisolated static func entries(
        from states: [RegisteredFolderState], kind: RegisteredFolderKind
    ) -> [RegisteredFolderEntry] {
        let nodeKind: FolderTreeNode.Kind = kind == .library ? .library : .temporary
        // 並びは保存順（`states()` が `folders` の配列順で返す）[RG3-33]。
        return states
            .filter { $0.folder.kind == kind }
            .map { state in
                let node = state.status.allowsNavigation
                    ? state.status.resolvedURL.map { url in
                        FolderTreeNode(
                            url: url, displayName: state.folder.displayName, kind: nodeKind,
                            // 登録ルートも三角マークの出し分けの対象
                            // [ユーザー報告: 直下にファイルしか無いのに三角が出る]。
                            // ネットワーク越しは調べない（`children(of:)` と同じ判断）。
                            hasSubfolders: MountTable.current().isRemote(url)
                                ? nil : DirectoryProbe.hasSubdirectory(at: url, countingPackages: false)
                        )
                    }
                    : nil
                return RegisteredFolderEntry(state: state, node: node)
            }
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

/// 登録済みフォルダ 1 件（表示名・Security-Scoped Bookmark）と、解決済みの
/// `FolderTreeNode`（オフラインなら `nil` [SB-05]）のペア。
/// ツリーの行を一意に指す識別子。選択・展開・可視判定・スクロールの
/// **すべてがこれを鍵にする。**
///
/// **URL と枝の両方**を持つ — 枝が無いと、同じ実フォルダでもボリューム経由か
/// ライブラリ経由かを区別できず、`NavigationRoot` を正しく決められない
/// [`FolderTreeBranch` 参照]。
///
/// ## なぜパスだけでは足りないのか
///
/// **同じ実フォルダが 2 つの枝に同時に現れる。** `~/Downloads` はホーム
/// グループの行であると同時に、Macintosh HD → Users → … と辿った先にも
/// ある。以前はパス文字列だけを鍵にしていたため、
///
/// - 片方を展開するともう片方も開き、
/// - 選択のハイライトが 2 か所に出て、
/// - `scrollTo` がどちらへ飛ぶか決まらなかった
///
/// ——最後のものは「起動時にホームグループの行をフォーカスする」[ユーザー要望]
/// を直接壊す（ボリューム側の行へスクロールしうる）。ホームグループを
/// 追加して確実に起こるようになったが、**登録フォルダでも同じ形が元から
/// あった**（登録したフォルダはボリュームを辿っても到達できる）。
///
/// ## 同一性は正規化パスで決める（`URL` の `==` ではない）
///
/// `URL` の等価判定は末尾スラッシュや `isDirectory` フラグの違いまで見るため、
/// `contentsOfDirectory` が返した URL と、祖先のパスから組み立てた URL が
/// 一致しない。正規化は `init` で 1 回だけ行う——`Set` の出入りは行の
/// 表示・非表示のたびに起きるので、`hash` のたびに正規化し直さない。
struct FolderTreeSelection: Hashable {
    let url: URL
    let branch: FolderTreeBranch
    private let normalizedPath: String

    init(url: URL, branch: FolderTreeBranch) {
        self.url = url
        self.branch = branch
        self.normalizedPath = url.standardizedFileURL.path
    }

    /// 祖先のパス文字列（`FolderTreePane.ancestorPaths`）から作る。
    init(path: String, branch: FolderTreeBranch) {
        self.init(url: URL(fileURLWithPath: path, isDirectory: true), branch: branch)
    }

    /// 枝は `identityKey` で比べる——`rootURL` の表現差を持ち込まないため
    /// [`FolderTreeBranch.identityKey` 参照]。
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.branch.identityKey == rhs.branch.identityKey && lhs.normalizedPath == rhs.normalizedPath
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(branch.identityKey)
        hasher.combine(normalizedPath)
    }
}

/// 登録済みフォルダ 1 件の、ツリーが描くのに必要な材料 [1-17]。
///
/// `node` は**入って辿れる状態のときだけ**作る（`.online` と
/// `.unsupportedFileSystem`）。オフライン・ゴミ箱・消失では `nil` にして
/// `DegradedRegisteredFolderRow` へ回す——`FolderTreeRow` を作ってしまうと、
/// 行を展開しただけで未接続のボリュームを読みに行く [RG3-06]。
private struct RegisteredFolderEntry: Identifiable {
    let state: RegisteredFolderState
    let node: FolderTreeNode?

    var folder: RegisteredFolder { state.folder }
    var id: UUID { folder.id }

    /// 行に添える注記。正常かつ入れ子でもなければ `nil`（何も足さない）。
    var annotation: RegisteredRootAnnotation? {
        guard state.status.isDegraded || state.isNested else { return nil }
        return RegisteredRootAnnotation(status: state.status, isNested: state.isNested)
    }
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
        // ＋/歯車をボリューム行の取り出しボタンと同じ大きさに揃える
        // [ユーザー要望]。サイズ未指定だと既定で描かれ、実測でグリフが
        // 12pt ＝ 取り出しボタン（10pt）より一回り大きかった。見出しの
        // タイトルは自前で `.font` を指定しているので影響を受けない。
        .font(.system(size: Tokens.fontSize.caption))
        // 見出しの ＋/歯車を、ボリューム行の取り出しボタンと同じ右端に揃える
        // [ユーザー要望]。**`List` はセクション見出しと（`DisclosureGroup` を
        // 挟む）通常行とで異なるトレーリングインセットを与える**ため、素のままだと
        // 見出し側だけが右へはみ出す。差分は AppKit 側の実装依存で計算では
        // 求まらないので、実際に描画された画面のピクセルを測って決めた
        // （取り出しボタンの右端 253pt に対し歯車は 268pt ＝ 15pt 外側）。
        // 最も近いトークン値を使う（1pt の差は表示上わからない）。
        .padding(.trailing, Tokens.spacing.l)
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

/// 入って辿れない縮退状態の登録フォルダ [1-17、8章 §8.7.1]。
///
/// 1-13 以来ここは「ブックマークを解決できなかった行」1 種類しかなく、
/// 未接続も削除もゴミ箱も同じグレーの行に潰れていた。**性質が違えば
/// 次の一手も違う**ので、状態ごとに見た目と操作を変える:
///
/// | 状態 | 見た目 | 出す操作 | 復帰 |
/// |---|---|---|---|
/// | `.offline` | グレーアウト | 登録解除 | 接続すれば自動 [VD-03] |
/// | `.inTrash` | 警告色 | Finder で表示・登録解除 | ゴミ箱から戻せば自動 |
/// | `.missing` | 通常色＋疑問符 | 場所を選び直す…・登録解除 | 手動 |
///
/// **どの状態でも登録解除を出す**が、それはユーザーが選んだときだけ効く
/// ——アプリが勝手に消すことは無い [RG3-04][SB-05]。
private struct DegradedRegisteredFolderRow: View {
    @Environment(\.locale) private var locale
    let state: RegisteredFolderState
    let onRelocate: () -> Void
    let onRevealInFinder: (URL) -> Void
    let onUnregister: () -> Void
    /// この登録がライブラリとして有効か [フェーズ 2 の結線]。
    ///
    /// **縮退した行にも無効化を出すために要る。** この行型は
    /// `FolderTreeContextMenu` を通らない別経路なので、出し分けの方針
    /// （`LibraryMenuVisibility`）を共有しないと 2 つの行で食い違う
    /// ——実機検証で「ボリュームを失うと無効化の手段が消える」形で実際に踏んだ。
    let isLibraryEnabled: Bool
    let onDisableLibrary: () -> Void
    /// 設定は DB しか触らないので、縮退状態でも開ける [LS-01]。
    let onOpenLibrarySettings: () -> Void
    /// ラベルグループ編集ウインドウ [LE-01〜LE-12]。**縮退状態でこそ要る**
    /// ——外付けが無い間に表記ゆれを片付けられる（DB しか触らない）。
    let onOpenLabelEditor: () -> Void
    let onOpenLabelVault: () -> Void
    let onOpenFileVault: () -> Void
    /// 孤立ファイルの整理ウインドウ [OR-01〜OR-05]。**縮退状態でこそ開きたい**
    /// ——「孤立していないか」を確かめられる（オフラインの間は判定しない
    /// [OR2-06][ID-08] ことが、開けば読み取れる）。
    let onOpenOrphanCleanup: () -> Void
    /// 未解決ファイルの整理ウインドウ [UR-01〜UR-06]。**縮退状態でも開ける**
    /// ——照合の結果しか見ないので、実体が無くても一覧は正しい。
    let onOpenUnresolvedFiles: () -> Void

    /// `.offline` だけ薄くする。ゴミ箱・消失は「気づいてほしい」状態なので
    /// 薄めない——未接続は待てば戻る日常的な状態で、そちらこそ目立たない
    /// ほうがよい。
    private var opacity: Double {
        if case .offline = state.status { return 0.4 }
        return 1
    }

    private var iconName: String {
        switch state.status {
        case .offline: "externaldrive.badge.xmark"
        case .inTrash: "trash"
        case .missing: "questionmark.folder"
        // 入って辿れる状態はこの行を使わない（`FolderTreeRow` が描く）。
        case .online, .unsupportedFileSystem: "folder"
        }
    }

    private var iconColor: Color {
        switch state.status {
        case .inTrash, .missing: Tokens.Colors.dangerText
        case .offline, .online, .unsupportedFileSystem: .secondary
        }
    }

    /// ツールチップに出す説明。**「何が起きたか」と「次に何ができるか」を
    /// 併せて言う** [ER-03 の考え方をこの行にも当てる]。
    private var hint: String {
        let key: String.LocalizationValue = switch state.status {
        case .offline: "folderTree.status.offlineHint"
        case .inTrash: "folderTree.status.inTrashHint"
        case .missing: "folderTree.status.missingHint"
        case .online, .unsupportedFileSystem: "folderTree.status.missingHint"
        }
        let message = String(localized: key, locale: locale)
        // 最後に分かっている場所を添える。「どのボリュームを繋げばよいか」が
        // 分からないと、オフラインの行は手の打ちようが無い。
        guard let path = state.status.lastKnownPath else { return message }
        return "\(message)\n\(path)"
    }

    var body: some View {
        Label {
            Text(state.folder.displayName)
                .font(.system(size: Tokens.fontSize.body))
        } icon: {
            Image(systemName: iconName)
                .foregroundStyle(iconColor)
                .frame(width: 16, alignment: .center)
        }
        .opacity(opacity)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Tokens.spacing.xs)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .help(hint)
        .contextMenu {
            // ゴミ箱の中は中身を確かめたくなるので Finder への導線を出す
            // [8章 §8.7.1 の「許可する操作」]。qooLibrary 自身では中へ
            // 入らせない——入れなければ中で書くこともできない［ユーザー判断］。
            if case .inTrash(let url) = state.status {
                Button("folder.revealInFinder", systemImage: "macwindow") { onRevealInFinder(url) }
                Divider()
            }
            if case .missing = state.status {
                Button("folderTree.relocateEllipsis", systemImage: "arrow.forward.folder") { onRelocate() }
                Divider()
            }
            // 縮退した行は定義上オンラインではないので `isOnline: false`。
            // 方針は `FolderTreeContextMenu` と同じ関数から引く。
            let libraryItems = LibraryMenuVisibility.items(isEnabled: isLibraryEnabled,
                                                           isOnline: false)
            if libraryItems.contains(.settings) {
                Button("library.settings.menuItem", systemImage: "gearshape") {
                    onOpenLibrarySettings()
                }
            }
            if libraryItems.contains(.labels) {
                Button("library.labels.menuItem", systemImage: "tag") { onOpenLabelEditor() }
            }
            if libraryItems.contains(.labelVault) {
                Button("library.labelVault.menuItem", systemImage: "archivebox") {
                    onOpenLabelVault()
                }
            }
            if libraryItems.contains(.fileVault) {
                Button("library.fileVault.menuItem", systemImage: "archivebox.fill") {
                    onOpenFileVault()
                }
            }
            if libraryItems.contains(.orphanCleanup) {
                Button("library.orphanCleanup.menuItem", systemImage: "questionmark.folder") {
                    onOpenOrphanCleanup()
                }
            }
            if libraryItems.contains(.unresolvedFiles) {
                Button("library.unresolvedFiles.menuItem",
                       systemImage: "questionmark.square.dashed") {
                    onOpenUnresolvedFiles()
                }
            }
            if libraryItems.contains(.disable) {
                Button("library.disable.menuItem", systemImage: "books.vertical.circle") {
                    onDisableLibrary()
                }
            }
            if !libraryItems.isEmpty { Divider() }
            Button("folderTree.unregister", systemImage: "minus.circle") { onUnregister() }
        }
    }
}

/// ツリーの 1 行。実フォルダの子を遅延読み込みする再帰 View。
private struct FolderTreeRow: View {
    let node: FolderTreeNode
    @Binding var expandedIDs: Set<FolderTreeSelection>
    /// 現在画面に描画されている行の ID 集合。`.onAppear`/`.onDisappear` で
    /// 自分自身の ID を増減させる [`FolderTreePane.visibleNodeIDs` 参照]。
    @Binding var visibleIDs: Set<FolderTreeSelection>
    /// いま選ばれている行 [`FolderTreeSelection`]。**枝まで含めて比べる**
    /// ——同じ実フォルダがボリューム側とホームグループ側の両方にあるので、
    /// パスだけで比べると青いハイライトが 2 か所に出る。
    let selection: FolderTreeSelection?
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
    /// 実フォルダ名の代わりに使う表示名 [ユーザー要望: 表示名は Finder に
    /// 揃える]。ホームグループの行だけが渡す（`~/Downloads` を「ダウンロード」
    /// と描く）。
    ///
    /// **`String` ではなく `LocalizedStringKey` で受ける**のが要点。
    /// `Text(LocalizedStringKey)` は `.environment(\.locale)` を自動で見るので、
    /// アプリ内の表示言語切替にそのまま追従する——`localizedName` /
    /// `displayName(atPath:)` は `Bundle.main.preferredLocalizations` に固定
    /// されるため追従しない [実測]。**子孫には渡さない**: その先は実フォルダで、
    /// 名前はユーザーが付けたものである。
    var displayNameKey: LocalizedStringKey?
    /// 登録ルート行が縮退しているときの注記 [1-17]。`registeredFolder` と同じく
    /// **子孫には伝播させない**——`.unsupportedFileSystem` はボリューム全体の
    /// 性質なので配下にも当てはまるが、警告を全行に重ねて出しても読みづらく
    /// なるだけで、登録ルートに 1 つ出れば伝わる。
    var annotation: RegisteredRootAnnotation?
    /// この行の配下へ書き込んでよいか [1-17]。**警告の表示と違い、これは
    /// 子孫へそのまま伝播させる**［レビューで発見］。
    ///
    /// `.unsupportedFileSystem` はボリューム全体の性質なので、登録ルートだけを
    /// 塞いでも**1 つ開いて中の行を右クリックすれば素通りできた**（子孫の
    /// `role` は `.plainFolder` なので、むしろ複製・圧縮・ゴミ箱まで開く）。
    /// 見た目は根に 1 つで足りるが、禁止は配下すべてに効かなければ意味が無い。
    var allowsWriting: Bool = true

    /// 縮退の警告文言を組み立てるのに要る [1-17]。`Text` のリテラルと違い
    /// `String(localized:)` は環境のロケールを自動では見ないため、明示的に
    /// 読んで渡す必要がある [CLAUDE.md「表示言語」節の区別]。
    @Environment(\.locale) private var locale

    @State private var children: [FolderTreeNode]?
    @State private var accessDenied = false
    /// ボリュームが取り外されている [1-17]。`accessDenied` とは案内が違う。
    @State private var volumeNotMounted = false
    /// 展開している間、このフォルダの直下を見張る [10章 §10.0]。
    @State private var watch = DirectoryObservation()
    @State private var isDropTargeted = false

    /// この行の識別子。選択・展開・可視判定・スクロールのすべてがこれを使う。
    private var rowID: FolderTreeSelection {
        FolderTreeSelection(url: node.url, branch: branch)
    }

    private var isSelected: Bool { selection == rowID }

    private var isExpanded: Binding<Bool> {
        Binding(
            get: { expandedIDs.contains(rowID) },
            set: { newValue in
                if newValue {
                    expandedIDs.insert(rowID)
                } else {
                    expandedIDs.remove(rowID)
                }
            }
        )
    }

    /// コンテキストメニューの出し分けに必要な情報一式
    /// [`FolderTreeRowContext` 参照]。
    private var menuContext: FolderTreeRowContext {
        FolderTreeRowContext(
            node: node, branch: branch, role: role, registeredFolder: registeredFolder,
            annotation: annotation, allowsWriting: allowsWriting
        )
    }

    /// 展開しようとして「アクセス権がありません」になったとき、その場で許可を
    /// 求める経路 [ユーザー判断: ホームグループは押したらパネル]。
    ///
    /// **よく使う項目の行にだけ返す。** それ以外は従来どおり環境設定
    /// 「アクセス権」タブへ誘導する——許可 UI を一箇所に集約するという既存の
    /// 判断はそのままで、ここだけ例外にするのは「書類を開きたい」という
    /// 明示的な操作の直後だから（移動メニューが同じ理由でその場パネルを
    /// 出しているのと揃える）。
    ///
    /// 許可されると `requestAccess` が `SessionState.reloadToken` を進め、
    /// この行の `.onChange` が読み直す——ここで明示的に読み直す必要は無い。
    private var grantAccessInPlace: (() -> Void)? {
        guard case .favorites = branch else { return nil }
        let url = node.url
        let locale = locale
        return {
            Task { _ = await StandardLocationOpener.requestAccess(to: url, locale: locale) }
        }
    }

    /// ボリューム行の右端に出す取り出しボタン [ユーザー要望、Finder の
    /// サイドバーと同じ]。取り出せるボリュームのときだけ出す（判定は
    /// `VolumeEjector.isEjectable`、`FolderTreeNode.mountedVolumes()` が
    /// 一覧を作るときにまとめて読んでいる）。
    ///
    /// **行全体のタップ（＝そのフォルダへ移動）と競合させない**ため、
    /// `Button` は行の `.onTapGesture` より手前でヒットテストされる必要がある。
    /// SwiftUI では後から重ねた `Button` がタップを消費するのでこの並びで
    /// 成立するが、取り出したボリュームへ移動してしまうと実害がある（消えた
    /// 場所を開こうとする）ので、実機で「ボタンを押しても行が選択されない」
    /// ことを確認してある。
    @ViewBuilder
    private var ejectButton: some View {
        if node.isEjectableVolume {
            Button {
                Task { await VolumeEjectAction.eject(node.url) }
            } label: {
                Image(systemName: "eject.fill")
                    // 見出しの ＋/歯車と実際の描画サイズを揃える [ユーザー要望]。
                    // **指定サイズではなく実測したインクの大きさで合わせている** —
                    // SF Symbols はシンボルごとに固有の縦横比・光学サイズを持ち、
                    // 同じ指定サイズでも描かれる大きさが違う（`caption`(11pt) 指定だと
                    // `eject.fill` は 10.0pt、`gearshape` は 11.5pt になる）。
                    // `body`(13pt) 指定でこのシンボルのインクが 11.5pt になり、
                    // 歯車と高さがちょうど一致する（実測値）。
                    .font(.system(size: Tokens.fontSize.body))
                    // 選択中は濃い青の背景になるため、ラベルと同じく白にする。
                    .foregroundStyle(isSelected ? Color(nsColor: .alternateSelectedControlTextColor) : Color.secondary)
            }
            .buttonStyle(.plain)
            // ネットワークは「接続解除」[NV-96、Finder に合わせる]。
            .help(node.isNetworkVolume ? "action.disconnect" : "action.eject")
        }
    }

    @ViewBuilder
    private var rowLabel: some View {
        HStack(spacing: Tokens.spacing.xs) {
        Label {
            if let displayNameKey {
                Text(displayNameKey)
            } else {
                Text(node.displayName)
            }
        } icon: {
            // Finder と同じアイコン [ユーザー要望]。シンボリックリンクは
            // `NSWorkspace` が対象種別のアイコンにエイリアスの矢印バッジを
            // 重ねて返すため、以前のような専用の代用アイコンは不要になった。
            Image(nsImage: FileIconProvider.shared.icon(for: node.url, isDirectory: true))
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

            // 縮退している登録ルートの警告 [1-17]。`.unsupportedFileSystem`
            // （閲覧はできるが同一性を追跡できない [FS-08]）と、外部での移動で
            // 入れ子が破れた場合 [RG3-05] がここに出る。**起動時にダイアログを
            // 出さずに行へ残す**のがこの見せ方の要点［ユーザー判断］——邪魔に
            // ならず、状態がその場に残るので後からでも気づける。
            if let annotation, let message = Self.warningMessage(for: annotation, locale: locale) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: Tokens.fontSize.caption))
                    .foregroundStyle(isSelected ? Color(nsColor: .alternateSelectedControlTextColor) : Tokens.Colors.dangerText)
                    .help(message)
                    .padding(.trailing, Tokens.spacing.xs)
            }

            // 取り出しボタンは行の右端に置く [ユーザー要望]。上の `Label` が
            // `maxWidth: .infinity` で残り幅を占めるので、自然に右詰めになる。
            ejectButton
        }
            .padding(.leading, Tokens.spacing.xs)
            // 右端は詰める [ユーザー要望: 取り出しボタンの右にボタン1つ分の
            // 余白が空いていた]。**負の値にしてはいけない** — 下の
            // `.clipShape` は padding 適用後の矩形で切り抜くため、はみ出した
            // ぶんはそのまま欠ける（実際に `-8` にしたところ ⏏ が右半分だけ
            // 切れた）。0 にして行の内側ぎりぎりまで寄せるのが上限。
            .padding(.trailing, 0)
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
            // **クリックの処理を `List` に任せる** [LP-06]。以前はここで
            // `.onTapGesture` を直接受けていたが、それだと `List` が「今どの行に
            // いるか」を知らないままになり、キーボードの ↑ ↓ が動かなかった
            // （フォーカスは確かにツリーにあるのに動かない、という形で現れた）。
            // 選択は `.tag` を通じて `listSelection` に入り、ペイン側の
            // `.onChange` が実際の移動を行う。
            .dropDestination(for: URL.self) { items, _ in // [DD-05] ツリーへドロップで移動
                // 縮退している登録ルートへは落とさせない [1-17]。メニューから
                // 塞いでも D&D が空いていたら意味が無い——**書き込みの経路は
                // まとめて閉じる**。
                guard menuContext.allowsWritingInto else { return false }
                DropHandling.performDrop(
                    items, into: node.url, operations: operations,
                    onComplete: {
                        // 他のウインドウ・ペインへの反映は
                        // `FileOperationService` → `DirectoryChangeHub` が担う
                        // [10章 §10.0]。ここでは自分の行だけを即座に更新する。
                        if children != nil { loadChildren() }
                    },
                    onFailure: onDropFailure
                )
                return true
            } isTargeted: { isDropTargeted = $0 && menuContext.allowsWritingInto }
    }

    /// 行に添える警告の文言。出すものが無ければ `nil`。
    ///
    /// **`.unsupportedFileSystem` を優先する。** 入れ子より深刻で、かつ
    /// 「このボリュームでは同一性を追跡できない」ほうが先に手当てすべき
    /// 事象だから（入れ子はフォルダを動かせば直るが、こちらはボリューム
    /// そのものを替えるか登録をやめるしかない）。
    static func warningMessage(for annotation: RegisteredRootAnnotation, locale: Locale) -> String? {
        if case .unsupportedFileSystem(_, let fileSystemName) = annotation.status {
            guard let fileSystemName else {
                return String(localized: "folderTree.status.unsupportedFileSystem", locale: locale)
            }
            return String(
                format: String(localized: "folderTree.status.unsupportedFileSystemNamed", locale: locale),
                fileSystemName
            )
        }
        if annotation.isNested {
            return String(localized: "folderTree.status.nested", locale: locale)
        }
        return nil
    }

    /// 右クリックメニューは全行に付ける [ユーザー要望: 中央ペインの
    /// フォルダ用メニューに原則あわせる]。項目の出し分けは
    /// `FolderTreeContextMenu` が `branch`（グループ）と `role`
    /// （ルートか通常フォルダか）から判断する。
    private var labelWithContextMenu: some View {
        rowLabel.contextMenu {
            FolderTreeContextMenu(context: menuContext, operations: operations, actions: menuActions)
        }
    }

    var body: some View {
        Group {
            if node.hasSubfolders == false {
                // **直下にサブフォルダが無いと分かっている行には三角を出さない**
                // [ユーザー報告: 登録したライブラリフォルダの直下にファイルしか
                // 無いのに三角が出る]。ツリーはフォルダしか表示しないので、
                // 開いても何も出ない三角は嘘である。`DisclosureGroup` は
                // 中身の有無に関わらず必ず三角を描くため、素の行として描く。
                //
                // **`nil`（判定していない／できない）のときは従来どおり三角を
                // 出す** — 誤って消すと「開けるはずのフォルダが開けない」
                // 行き止まりになるのに対し、誤って出しても「開いたら空だった」
                // で済む [`FolderTreeNode.hasSubfolders` 参照]。
                // **先頭に余白を足さないこと。** `List` は三角の分の
                // 溝を行の側で確保しており、`DisclosureGroup` でない行の
                // ラベルも同じ位置から始まる（[実測] 同じ階層で、三角のある
                // 行のラベルが x=920.0、素の行も余白なしで x=920.0。18pt
                // 足した最初の版は 938.0 になり、その分だけ右へずれていた）。
                labelWithContextMenu
            } else {
                disclosureRow
            }
        }
        // **`.tag` は `DisclosureGroup` 自身に付ける（label ではない）。**
        // 公式の作法どおり [nilcoalescing.com の解説]。label 側へ付けると
        // 選択と行の対応が壊れ、最初の ↓ で先頭行へ飛んだきり動かなくなる
        // （実機で踏んだ。**最初にこれを調べずに実機で 3 通り試して溶かした**
        // ——CLAUDE.md 冒頭「不可解な事象はまず WebSearch で調べる」）。
        .tag(rowID)
        // **`ScrollViewReader` の探し先も枝込みにする。** `ForEach` の暗黙の
        // identity は `FolderTreeNode.id`（パス文字列）なので、明示しないと
        // 同じパスの行が 2 つの枝にある場合にどちらへ飛ぶか決まらない。
        .id(rowID)
        .disabled(node.isSymlink) // [SL-05]
        // [ユーザー要望] `List` の行virtualizationを利用して「実際に画面へ
        // 描画されているか」を追跡する（`revealSelectionIfNeeded` の
        // 「既に表示範囲内ならスクロールしない」判定に使う）。
        .onAppear { visibleIDs.insert(rowID) }
        .onDisappear { visibleIDs.remove(rowID) }
        .onChange(of: isExpanded.wrappedValue, initial: true) { _, expanded in
            guard expanded else {
                // **たたんだら忘れる** [レビューで発見]。以前は `children` を
                // 抱えたままだったため、①たたんだ行が監視され続けて変更の
                // たびに読み直され、②開き直しても `children != nil` を理由に
                // 読み直しが飛ばされて、たたんでいる間の変更が反映されない、
                // という 2 つの問題があった。捨てておけば、開いたときに必ず
                // 実体を読み直す。
                children = nil
                accessDenied = false
                volumeNotMounted = false
                return
            }
            guard children == nil, !accessDenied, !volumeNotMounted else { return }
            loadChildren()
        }
        // 子を読み込んでいる間だけ、このフォルダの直下を見張る [10章 §10.0]。
        // Finder で項目を足した・消した・改名した場合にもツリーが追随する。
        // 折りたたんでいる行は見張らない（表示していないものを読み直しても
        // 意味が無いうえ、監視ルートを無駄に増やさないため）。閉じている間の
        // 変更は、開いたときの `loadChildren()` がそのまま拾う。
        .onChange(of: WatchKey(url: node.url, isLoaded: children != nil), initial: true) { _, key in
            watch.watch(key.isLoaded ? key.url : nil, scope: .shallow)
        }
        .onChange(of: watch.generation) {
            guard children != nil else { return }
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
            guard children != nil || accessDenied || volumeNotMounted else { return }
            accessDenied = false
            volumeNotMounted = false
            loadChildren()
        }
    }

    /// `watch` の登録内容を決める識別子。`.onChange` に渡すため
    /// `Equatable` な値にまとめる。
    private struct WatchKey: Equatable {
        let url: URL
        let isLoaded: Bool
    }

    /// 子フォルダを読み込む。
    ///
    /// **列挙はメインスレッドで行わない** [NV6-02]。ツリーの 1 行を開くだけで
    /// `contentsOfDirectory` が走り、相手が応答しなければ SMB で 30 秒、
    /// NFS の hard マウント（既定）なら**無限に**メインスレッドが止まる。
    /// ツリーは 1 回の展開で複数行が同時に読み込みを始めるので、中央ペインの
    /// 一覧より当たりやすい。
    ///
    /// - Note: 世代番号は要らない。読み込みを起こすのはこの行自身だけで、
    ///   行が消えれば `@State` ごと消える。ただし**遅れて戻ってきた結果で
    ///   `accessDenied` を上書きしない**よう、対象が変わっていないことは
    ///   確かめる。
    private func loadChildren() {
        let target = node
        Task {
            let outcome = await FileIO.perform { Self.readChildren(of: target) }
            guard node.id == target.id else { return }
            switch outcome {
            case let .loaded(loaded):
                children = loaded
                accessDenied = false
            case .denied:
                children = nil
                accessDenied = true
                volumeNotMounted = false
            case .volumeNotMounted:
                children = nil
                accessDenied = false
                volumeNotMounted = true
            }
        }
    }

    private enum ChildrenOutcome: Sendable {
        case loaded([FolderTreeNode])
        case denied
        /// ボリュームが接続されていない [1-17]。`denied` と分けるのは、
        /// **アクセス権を足しても直らない**ため——同じ扱いにすると、
        /// 環境設定「アクセス権」タブへ誘導したきり行き止まりになる。
        case volumeNotMounted
    }

    /// **メインアクタの外で走る。** `FileIO.perform` の中からのみ呼ぶこと。
    private nonisolated static func readChildren(of node: FolderTreeNode) -> ChildrenOutcome {
        do {
            return .loaded(try FolderTreeNode.children(of: node))
        } catch FolderTreeAccessError.volumeNotMounted {
            return .volumeNotMounted
        } catch {
            return .denied
        }
    }

    /// サブフォルダを持つ（か、持つか分からない）行。**中身の有無に
    /// 関わらず `DisclosureGroup` は必ず三角を描く**ので、三角を出さない
    /// 行はこちらを通さない（`body` 参照）。
    @ViewBuilder
    private var disclosureRow: some View {
        DisclosureGroup(isExpanded: node.isSymlink ? .constant(false) : isExpanded) {
            if volumeNotMounted {
                VolumeNotMountedRow() // [1-17][SB-05]
            } else if accessDenied {
                AccessDeniedRow(onGrantInPlace: grantAccessInPlace) // [SB-04][LP2-09]
            } else if let children {
                ForEach(children) { child in
                    FolderTreeRow(
                        node: child, expandedIDs: $expandedIDs, visibleIDs: $visibleIDs,
                        selection: selection,
                        branch: branch, role: .plainFolder, onSelect: onSelect,
                        onDropFailure: onDropFailure,
                        operations: operations, menuActions: menuActions,
                        // 注記（警告の見た目）は根だけ、書き込みの可否は配下すべてへ。
                        allowsWriting: allowsWriting
                    )
                }
            } else {
                ProgressView()
                    .controlSize(.small)
            }
        } label: {
            labelWithContextMenu
        }
    }
}

/// ボリュームが取り外されている [1-17][SB-05][LP-04]。
///
/// **`AccessDeniedRow` と分けてあるのが要点。** 以前は
/// `FolderTreeNode.children(of:)` が `NSCocoaErrorDomain` の失敗をすべて
/// 「アクセス権がありません」に丸めていたため、外付けを抜いただけでも
/// 環境設定「アクセス権」タブへ誘導していた——許可を足しても直らないので、
/// ユーザーは行き止まりに入る。ここには**ボタンを置かない**: 直す方法は
/// アプリの外（挿し直す・サーバへ繋ぐ）にあり、押せるものを出しても嘘になる。
private struct VolumeNotMountedRow: View {
    var body: some View {
        Label {
            Text("folderTree.volumeNotMounted")
        } icon: {
            Image(systemName: "externaldrive.badge.xmark")
        }
        .font(.system(size: Tokens.fontSize.caption))
        .foregroundStyle(.secondary)
    }
}

/// [SB-04][LP2-09] アクセス権が無い。**フルディスクアクセスへ誘導していた旧実装は撤去した**
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
    /// 非 `nil` なら、環境設定へ送らずその場で許可パネルを出す
    /// [ホームグループの行だけ、`FolderTreeRow.grantAccessInPlace` 参照]。
    var onGrantInPlace: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.spacing.xs) {
            Text("folderTree.accessDenied")
                .font(.system(size: Tokens.fontSize.caption))
                .foregroundStyle(Tokens.Colors.dangerText)
            Button("folderTree.grantAccessEllipsis") {
                if let onGrantInPlace {
                    onGrantInPlace()
                } else {
                    PreferencesNavigation.shared.pendingCategory = .access
                    openWindow(id: "preferences")
                }
            }
            .font(.system(size: Tokens.fontSize.caption))
        }
    }
}
