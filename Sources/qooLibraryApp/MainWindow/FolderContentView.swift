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
    /// ラベルフィルタが有効なときに、この一覧へ残してよい**直下の子の名前**
    /// [VM-02][LF-14]。`nil` は「絞らない」（フィルタ全 OFF、ライブラリの外、
    /// または件数を数えられなかったとき）。
    ///
    /// **DB の一覧をそのまま描くのではなく、実体の一覧を絞る**——フォルダ表示
    /// モードではすべてのファイル操作が可能でなければならず [VM-03]、フィルタが
    /// 全 OFF なら DB に載っていないもの（対象拡張子以外）も従来どおり見える
    /// 必要がある [VM-01]。集合には「該当ファイルの名前」と「該当ファイルを
    /// 配下に持つフォルダの名前」の両方が入っている。
    var allowedChildNames: Set<String>?
    /// 再帰検索の結果へラベルフィルタを効かせる [LF-14]。残してよい URL を返す。
    /// `nil` は「絞らない」（フィルタ全 OFF・ライブラリの外・問い合わせ失敗）。
    ///
    /// **直下の名前（`allowedChildNames`）では検索結果を絞れない**——深い所の
    /// 該当ファイルは、それを含む直下フォルダの名前へ畳まれて集合に入るため、
    /// 名前で突き合わせると同じフォルダの非該当ファイルまで通る。
    var filterDeepResults: ((_ urls: [URL]) async -> Set<URL>?)?
    /// フィルタが変わったことの合図。`.task(id:)` の鍵に混ぜる。
    var labelFilterRevision: Int = 0
    @Binding var selection: Set<URL>
    /// 「戻る」「1階層上へ」で親フォルダへ移動した直後、直前までいた
    /// フォルダまでスクロールするための信号 [`WindowState.pendingRevealURL`
    /// 参照、ユーザー要望]。ハイライト自体は `selection` が既に伝えるため、
    /// ここでは「スクロールが必要」という事実だけを受け取り、既存の
    /// `pendingScrollTarget`（「ここに圧縮」で確立済みの、ユーザー自身の
    /// クリックとプログラム的な選択変更を区別する仕組み）へ橋渡しする。
    @Binding var pendingRevealURL: URL?
    /// 直前の移動がフォルダツリー由来か [`WindowState.navigationCameFromTree`
    /// 参照]。真ならキーボードフォーカスを中央ペインへ移さない。
    var navigationCameFromTree: Bool = false
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
    /// 表示中のフォルダ自体が消えていたら、存在する直近の祖先へ移動して
    /// `true` を返す [`WindowState.relocateCurrentTabIfFolderVanished()` 参照]。
    /// `reload()` が読み込みに失敗したときだけ呼ぶ。
    ///
    /// **`async`** — 判定には `fileExists` が何度も要り、応答しない共有では
    /// そこがそのままメインスレッドの停止になる [NV6-02]。
    let relocateIfFolderVanished: () async -> Bool
    /// コンテキストメニューの「新規タブで開く」「新規ウインドウで開く」
    /// [MW-01/MW-04 の周辺、要件定義書には無いがユーザー要望で追加]。
    let onOpenInNewTab: (URL) -> Void
    let onOpenInNewWindow: (URL) -> Void
    /// Quick Look [QL-01]。このウインドウ専用のコントローラ（`MainWindowView`
    /// が `WindowState` と 1 対 1 で生成する）。このビューは Space キー・
    /// メニューからの起動と、矢印キーでの選択移動 [QL-07] に必要な
    /// 「一覧の表示順」の受け渡し（`publishQuickLookOrder()`）だけを担う。
    let quickLook: QuickLookController
    /// リスト/アイコン切替 [LV-04] とアイコンサイズ [IV-04]。`WindowState`
    /// （ウインドウ単位、タブをまたいで共有 [ST-22]）が保持する。
    @Binding var listStyle: ListStyle
    @Binding var iconSize: Double
    /// ツールバーの「新規フォルダ」ボタン（`MainWindowView`）から届く合図
    /// [FM-01]。増分されたらダイアログを出す。ダイアログを出す側をこのビューに
    /// 置いているのは、作成先のフォルダと作成後の再読み込みを知っているのが
    /// ここだけのため。
    @Binding var newFolderRequests: Int
    /// パスバー・ステータスバーの表示 [1-16 表示メニュー、Finder の
    /// 「パスバーを隠す」「ステータスバーを隠す」相当]。**`@AppStorage` では
    /// なく素の `Bool` として受け取る** — 永続化と `UserDefaults` の読み書きは
    /// `MainWindowView` 側が `isRightPaneCollapsed` と同じ「素の値を一度だけ
    /// 読み、変更時に明示的に書き戻す」パターンで行う（`@AppStorage` を
    /// ビュー構造を決める `if` 条件で直接読むとハングする既知の不具合を
    /// 避けるため、`ThreePaneWindow.isRightPaneCollapsed` のコメント参照）。
    let isPathBarVisible: Bool
    let isStatusBarVisible: Bool
    /// サムネイルが隠れている理由。隠れていなければ `nil` [DS-01][DS-04][DS-07]。
    /// **合成済みの実効値を受け取るだけ**にしている（全体トグルと登録フォルダの
    /// 強制非表示を合成するのは `WindowState.thumbnailHiddenReason` の役目で、
    /// 同じ判定をここでも書くと二重管理になる）。
    let thumbnailHiddenReason: ThumbnailHiddenReason?
    /// アプリ全体のサムネイル表示トグルを反転する [DS-02]。ステータスバーの
    /// ボタンから呼ぶ。
    let onToggleThumbnails: () -> Void
    /// 名前での絞り込み [1-16 検索]。タブごとに独立して保持する
    /// （`TabState.searchText`。1-3 の時点から型としてはあったが、この節まで
    /// どこからも書き込まれない状態だった）。
    @Binding var searchText: String

    @State private var entries: [FolderEntry] = []
    /// 再帰検索の結果 [ユーザー要望: サブフォルダも再帰的に検索する]。
    /// 検索していないときは空。
    @State private var searchResults: [FolderEntry] = []
    /// 検索結果のうちラベルフィルタに該当するもの [LF-14]。`nil` は絞らない。
    @State private var allowedDeepURLs: Set<URL>?
    /// 走査中か（進捗表示用）。
    @State private var isSearching = false
    /// 上限（`AppLimits.Search.maxResults`）に達して打ち切ったか。
    @State private var searchTruncated = false
    /// 走査の世代 [実機検証で発見したバグの修正]。**キャンセルは協調的**なので、
    /// `.task(id:)` が古い走査を打ち切っても、その走査が既に
    /// `await MainActor.run { onBatch(...) }` の中で待っていれば、**新しい走査が
    /// `searchResults` を空にした後で古い結果が流れ込む**。実際、`001.jpg` が
    /// 1 つしか無いフォルダで検索すると同じ項目が 2 件並び、総数も実際の
    /// ファイル数を超えていた（打鍵のたびに走査が作られるため）。
    /// 世代を照合して、古い走査からの結果は捨てる。
    @State private var searchGeneration = 0
    /// 一覧の読み込みの世代 [NV6-02]。検索と同じ理由で要る——読み込みが
    /// メインスレッドを離れたことで、速く連続してフォルダを移ると走査の
    /// 順序が入れ替わり、**古いフォルダの中身が新しいフォルダの一覧として
    /// 表示され得る**。
    @State private var reloadGeneration = 0
    @State private var loadError: String?
    /// 読み込み失敗の理由が「権限が無い」ときだけ「アクセスを許可…」を出す。
    @State private var loadErrorIsAccessDenied = false
    @State private var renamingEntry: FolderEntry?
    @State private var renameText = ""
    @FocusState private var isRenameFieldFocused: Bool
    /// Finder 流「選択済みの項目をもう一度クリックするとリネーム」の識別用
    /// [ユーザー要望]。クリックのたびに増分し、ダブルクリックや他の選択操作
    /// （＝別のクリック）が割り込んだら保留中のリネーム開始タイマーを
    /// 無効化する（`handleSingleClick`/`rowCell`/`IconGridView` 参照）。
    @State private var pendingRenameGeneration = 0
    @State private var isDropTargeted = false
    /// リスト表示でファイルをフォルダ行へドラッグしているときの、行全体の
    /// ハイライト対象 [`DropIntoFolderModifier` のコメント参照、ユーザー要望]。
    @State private var dropTargetedFolderURL: URL?
    /// `dropTargetedFolderURL` によって `selection` を一時的に上書きする前の、
    /// 元の選択状態 [`DropIntoFolderModifier` のコメント参照]。ドラッグが
    /// 終わったらこれに戻す。
    @State private var selectionBeforeDropHighlight: Set<URL>?
    @FocusState private var isListFocused: Bool
    /// Shift クリックでの範囲選択の起点 [LV-06 相当]。
    @State private var selectionAnchor: URL?
    /// 先頭文字で項目へ飛ぶための打鍵バッファ [ユーザー要望、Finder 標準の
    /// type-select]。数千件のフォルダで目的の項目へ行く手段が ⌘F しか無い
    /// のは、ファイルマネージャーとして実用に耐えない。
    @State private var typeSelectBuffer = ListKeyboardNavigation.TypeSelectBuffer()
    /// アイコン表示の実測列数。矢印キーの上下移動に要る
    /// （`LazyVGrid` は自分が何列で並べたかを教えてくれない）。
    @State private var iconGridColumnCount = 1
    /// 複数選択された行を一度にドラッグするための `dragContainer` 系 API のスコープ
    /// [DD-02][設計判断: macOS 26 で追加された API、詳細は `.draggable(containerItemID:)` の
    /// 呼び出し箇所のコメント参照]。
    @Namespace private var dragNamespace
    /// ファイル操作の共通レイヤ [`FolderOperations` 参照]。フォルダツリー
    /// （`FolderTreePane`）とまったく同じ実装を共有し、実行中表示・パスワード
    /// シートの状態もこのオブジェクトが持つ（描画は `.folderOperationsHost(_:)`）。
    @State private var operations = FolderOperations()
    /// 表示中のフォルダの直下を見張る [10章 §10.0]。Finder や他アプリが
    /// 項目を追加・削除・改名しても、こちらの一覧が古いまま取り残されない
    /// ようにする。アプリ自身の操作も同じ経路で届く
    /// （`FileOperationService` が通知する）。
    @State private var folderWatch = DirectoryObservation()
    /// 再帰検索の結果を見張る。検索中だけ**配下すべて**を対象にする
    /// （検索していないときは見張らない — 深い階層の変更で無駄に走査を
    /// やり直さないため）。
    @State private var searchWatch = DirectoryObservation()
    /// 走査をやり直すと決めた時点の `searchWatch.generation`
    /// [レビューで指摘された「やり直しの嵐」への対処]。
    ///
    /// `searchWatch.generation` をそのまま `.task(id:)` の一部にすると、
    /// 走査中に変更が届くたびに打ち切って最初からやり直すことになる。変更が
    /// 続いている間はいつまでも結果が出ず、一覧が空になっては埋まり直す。
    /// **走っている間は溜めておき、終わってから 1 回だけ反映する。**
    @State private var appliedSearchGeneration = 0
    /// 走査中に変更が届いたか（終わったら 1 回だけやり直す）。
    @State private var searchRerunPending = false
    /// リスト表示の現在のソート順 [LV-01]。タブ切替をまたいで保持されて構わない
    /// 軽微な状態のため `WindowState`/`TabState` へは持ち上げず、他の一時的な
    /// `@State`（`selectionAnchor` 等）と同じくこのビュー内で完結させる。
    /// リスト表示の現在のソート順 [LV-01]。
    ///
    /// **アプリ全体で 1 つを覚える**［ユーザー判断］。既存のカラム表示設定・
    /// フォルダまとめ設定と同じ扱いで、起動のたびに名前昇順へ戻らない。
    /// Finder はフォルダごとに覚えるが、あれは `.DS_Store` に書いており、
    /// 本アプリはライブラリ配下にファイルを作らない方針 [CL-01] なので
    /// 同じ手は使えない。
    @State private var sortOrder: [FolderSortComparator] = FolderSortComparator.loadPersisted()
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
    /// 隠しファイルを表示するか [ユーザー要望、Finder の ⇧⌘. 相当]。
    /// ステータスバー左端のボタンで切り替える。一覧の読み込み（`reload()`）と
    /// 再帰検索の両方が参照する。
    @AppStorage("qoo.folderList.showHiddenFiles") private var showHiddenFiles = false
    /// 名前列が長すぎるときの省略位置 [ユーザー要望、環境設定「表示」タブ
    /// `NameTruncationMode` と同じキーを共有する]。
    @AppStorage("qoo.folderList.nameTruncationMode") private var nameTruncationMode: NameTruncationMode = .tail
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
    /// 変更日／サイズ／種類／作成日／追加日カラムの「内容に合わせた幅」
    /// [ユーザー指摘: 固定の `ideal` 値では実際の表示文字列に対して無駄に
    /// 広かった]。フォールバック値は以前からの固定 `ideal` と同じにして
    /// おき、`entries` が読み込まれる前・空フォルダの一瞬だけ極端に狭く
    /// ならないようにしている。実際の計測は `recomputeAutoFitColumnWidths()`
    /// が `entries`/カラム表示切替のたびに行う。
    @State private var modificationDateColumnWidth: CGFloat = 170
    @State private var sizeColumnWidth: CGFloat = 90
    @State private var kindColumnWidth: CGFloat = 140
    @State private var creationDateColumnWidth: CGFloat = 170
    @State private var addedDateColumnWidth: CGFloat = 170
    /// 検索結果の「場所」列 [ユーザー要望]。相対パスは長くなりがちなので、
    /// 他の列より広めの上限を許す（実際の値は `recomputeAutoFitColumnWidths()`
    /// が中身を計測して決める）。
    @State private var locationColumnWidth: CGFloat = 220
    /// [ユーザー要望] 名前列に、他の列（内容に合わせて詰めた分）を差し引いた
    /// 残りの幅をすべて割り当てる。**SwiftUI の `Table`（macOS）は「最後に
    /// 宣言した列」だけを自動的に残り幅へ伸縮させる仕組みを持つが、名前列は
    /// 先頭列のためこの恩恵を受けられない**（WebSearch で確認: "you simply
    /// don't need to set width constraints on the last column—it will
    /// automatically expand to fill all remaining space"）。そのため
    /// `.onGeometryChange` で `Table` 自身の実測幅を取得し、他列の幅の合計を
    /// 差し引いた残りを明示的にこの列の `ideal` として与える。
    @State private var nameColumnWidth: CGFloat = 280
    /// `otherColumnsWidth` 計算からの余白（列間の区切り線・スクロールバー等）。
    private static let tableChromePadding: CGFloat = 40
    /// `Table` に `.id()` として渡す識別子 [`.id(folder)` だと不具合が
    /// あった、実機検証で発見・修正したバグの説明は `.id(...)` の呼び出し
    /// 箇所を参照]。`reload()` が `entries`/各列の `ideal` 幅の計算を
    /// **終えたあと**でこの値を更新することで、`Table` が新しい列幅を
    /// 使って作り直されるタイミングを、幅の計算完了後まで確実に遅らせる。
    @State private var tableIdentity: URL?

    var body: some View {
        // 選択がプログラム的に変わったとき（例: 「ここに圧縮」完了後に
        // 作成したアーカイブを選択する）に中央ペインをその項目までスクロール
        // させるための `ScrollViewReader`（`Table`/`IconGridView` 双方の
        // スクロール領域を包む）[ユーザー要望]。
        ScrollViewReader { scrollProxy in
        VStack(alignment: .leading, spacing: 0) {
            Group {
            if let loadError {
                // 権限が無いだけなら、行き止まりにせずその場で許可を求められる
                // ようにする [ユーザー要望]。移動メニューを経由しない到達
                // （ツリーのクリック・ダブルクリックで潜る等）では
                // `StandardLocationOpener` の事前判定が働かないため、**実際に
                // 失敗したこの 1 箇所**から同じ導線を出すことで経路によらず
                // 拾える（フォルダツリーの `AccessDeniedRow` と揃う）。
                PlaceholderPane(
                    title: String(localized: "folder.loadError", locale: locale),
                    subtitle: loadError,
                    action: loadErrorIsAccessDenied
                        ? PlaceholderPane.Action(
                            title: String(localized: "folderTree.grantAccessEllipsis", locale: locale),
                            perform: { requestAccessForCurrentFolder() }
                        )
                        : nil
                )
            } else if listStyle == .icon {
                // アイコン表示 [IV-01/08/09、PF-10]。`Table` と違い選択・D&D・
                // コンテキストメニューの AppKit 標準機能が無いため、それぞれ
                // `IconGridView` 側で手動再現している（詳細はそのファイルの
                // コメント参照）。
                iconGrid
            } else {
                // カラムベースのリスト表示 [LV-01〜LV-03]。ソートは `sortOrder`
                // バインディングを通してヘッダクリックで切り替わる。実際の並べ替えは
                // `displayedEntries` がこの状態を見て計算する（`Table` 自身は
                // データを自動ソートしない）。
                Table(displayedEntries, selection: $selection, sortOrder: $sortOrder) {
                    // 検索結果の「場所」[ユーザー要望]。検索中だけ現れ、
                    // **「名前」の左**に入る [ユーザー要望]。
                    // **並び替えの対象にはしない**（`sortUsing:` を付けない）——
                    // `FolderSortComparator.Key` に加えると、検索していない
                    // ときにも「並び替え」メニューへ意味の無い項目が並ぶため。
                    if hasActiveSearch {
                        TableColumn("column.location") { entry in
                            rowCell(entry, isRenaming: renamingEntry?.url == entry.url) {
                                Text(entry.relativeLocation.isEmpty ? "—" : entry.relativeLocation)
                                    .font(.system(size: Tokens.fontSize.body))
                                    .foregroundStyle(.secondary)
                                    .help(entry.relativeLocation) // 長いパスは省略されるため
                            }
                        }
                        .width(min: locationColumnWidth, max: locationColumnWidth)
                    }

                    TableColumn("column.name", sortUsing: FolderSortComparator(key: .name)) { entry in
                        rowCell(entry, isRenaming: renamingEntry?.url == entry.url) {
                            // アイコンを固定幅の枠に収めて Finder のように先頭を揃える
                            // （実機検証で発覚: アイコンの実測幅がまちまちだと名前の
                            // 先頭位置がずれる）。Finder と同じアイコン [ユーザー要望、
                            // `FileIconProvider` 参照]。
                            HStack(spacing: Tokens.spacing.xs) {
                                Image(nsImage: FileIconProvider.shared.icon(for: entry.url, isDirectory: entry.isNavigableFolder))
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
                                    // [ユーザー要望、環境設定「表示」タブ] 省略位置を選べるようにする。
                                    Text(entry.name)
                                        .truncationMode(nameTruncationMode.swiftUIMode)
                                }
                            }
                            .font(.system(size: Tokens.fontSize.body))
                        }
                    }
                    .width(min: 160, ideal: nameColumnWidth)

                    if showModificationDateColumn {
                        TableColumn("column.modificationDate", sortUsing: FolderSortComparator(key: .modificationDate)) { entry in
                            rowCell(entry, isRenaming: renamingEntry?.url == entry.url) {
                                Text(entry.modificationDate.map { Self.dateFormatter.string(from: $0) } ?? "—")
                                    .font(.system(size: Tokens.fontSize.body))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        // [実機検証で発見・修正したバグ] `ideal` は macOS の
                        // `Table` では一切反映されない（WebSearch で確認:
                        // Apple Developer Forums の回答 "idealSize is totally
                        // ignored on macOS"）。内容に合わせた幅を実際に効かせる
                        // 唯一の方法は `min == max` で固定することだった
                        // （この代わりにドラッグでの手動リサイズはできなくなる。
                        // ユーザー確認済み: 区切り線ダブルクリックでの自動調整は
                        // 別途取り下げ済みのため、常時自動調整で置き換える形で
                        // 許容している）。
                        .width(min: modificationDateColumnWidth, max: modificationDateColumnWidth)
                    }

                    if showSizeColumn {
                        TableColumn("column.size", sortUsing: FolderSortComparator(key: .size)) { entry in
                            // [ユーザー要望: Finder に合わせてサイズ列は右詰め]
                            rowCell(entry, isRenaming: renamingEntry?.url == entry.url, alignment: .trailing) {
                                Text(entry.isDirectory ? "—" : Self.sizeFormatter.string(fromByteCount: entry.fileSize ?? 0))
                                    .font(.system(size: Tokens.fontSize.body))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .width(min: sizeColumnWidth, max: sizeColumnWidth)
                    }

                    if showKindColumn {
                        TableColumn("column.kind", sortUsing: FolderSortComparator(key: .kind)) { entry in
                            rowCell(entry, isRenaming: renamingEntry?.url == entry.url) {
                                Text(entry.kindDescription)
                                    .font(.system(size: Tokens.fontSize.body))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .width(min: kindColumnWidth, max: kindColumnWidth)
                    }

                    if showCreationDateColumn { // [ユーザー要望: Finder に合わせてカラムを増やす]
                        TableColumn("column.creationDate", sortUsing: FolderSortComparator(key: .creationDate)) { entry in
                            rowCell(entry, isRenaming: renamingEntry?.url == entry.url) {
                                Text(entry.creationDate.map { Self.dateFormatter.string(from: $0) } ?? "—")
                                    .font(.system(size: Tokens.fontSize.body))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .width(min: creationDateColumnWidth, max: creationDateColumnWidth)
                    }

                    if showAddedDateColumn {
                        TableColumn("column.addedDate", sortUsing: FolderSortComparator(key: .addedDate)) { entry in
                            rowCell(entry, isRenaming: renamingEntry?.url == entry.url) {
                                Text(entry.addedDate.map { Self.dateFormatter.string(from: $0) } ?? "—")
                                    .font(.system(size: Tokens.fontSize.body))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .width(min: addedDateColumnWidth, max: addedDateColumnWidth)
                    }
                }
                // [ユーザー指摘の修正] `.width(ideal:)` は列（`NSTableColumn`）が
                // 最初に作られたときにしか反映されず、以後 `ideal` の値を
                // 再計算しても既存の列は追従しないと実機検証で判明した
                // （`PaneWindows.swift` の `HSplitView.idealWidth` が初回
                // レイアウト後は無視されたのと同じ種類の制約）。フォルダを
                // 移動するたびに列を実際に作り直させることで、そのつど新しい
                // `ideal` を適用させる。`selection`/`sortOrder`/`isListFocused`
                // は `Table` の外側（`FolderContentView` 自身）の状態のため、
                // ここで `Table` だけを作り直しても失われない。
                //
                // [実機検証で発見・修正したバグ] 当初 `.id(folder)`（`folder`
                // をそのまま使う）にしていたが、これだと「種類」列が
                // "ComicBook Zip" のような長い文字列を途中で切ってしまう
                // 不具合が起きた。原因は `.task(id: folder)`（`reload()` を
                // 呼ぶ）が `body` の再評価より**後**に走ること——`folder` が
                // 変わった瞬間の `body` 再評価では、`.id(folder)` により
                // `Table` はその場で新しい identity で作り直されるが、この
                // 時点では `entries`/`kindColumnWidth` 等はまだ**前の
                // フォルダの値のまま**（`reload()` がまだ実行されていない）。
                // その後 `reload()` が実行され正しい幅を計算しても、`folder`
                // 自体はもう変化していないため `.id(folder)` は同じ値のままで
                // `Table` は作り直されず、古い（誤った）幅を持つ列がそのまま
                // 残ってしまっていた。`tableIdentity` は `reload()` が幅の
                // 計算を終えた**あとで**更新するため、`Table` の作り直しが
                // 必ず正しい幅の計算後に起きるようにしている。
                .id(tableIdentity)
                .focused($isListFocused)
                // [ユーザー要望] 名前列に余った幅をすべて割り当てる。`Table`
                // 自身の実測幅が変わるたび（ウインドウ／ペインのリサイズ）に
                // `nameColumnWidth` を再計算する（`nameColumnWidth` 宣言部の
                // コメント参照、SwiftUI の `Table` は最後の列しか自動で残り幅へ
                // 伸縮しないため、名前列（先頭列）の分は明示的に計算する必要が
                // ある）。
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.width
                } action: { newWidth in
                    updateNameColumnWidth(tableWidth: newWidth)
                }
                // [ユーザー指摘の修正] 変更日／サイズ／種類／作成日／追加日の
                // 各列を、表示する文字列の長さに合わせて自動調整する。
                // フォルダ再読み込み時は `reload()` 自身が呼ぶ（上記参照）。
                // ここではカラム表示切替（`entries` 自体は変わらない）のときの
                // 再計測だけを担う。
                .onChange(of: showHiddenFiles) { _, _ in reload() } // [ユーザー要望]
                .onChange(of: showModificationDateColumn) { _, _ in recomputeAutoFitColumnWidths() }
                .onChange(of: showSizeColumn) { _, _ in recomputeAutoFitColumnWidths() }
                .onChange(of: showKindColumn) { _, _ in recomputeAutoFitColumnWidths() }
                .onChange(of: showCreationDateColumn) { _, _ in recomputeAutoFitColumnWidths() }
                .onChange(of: showAddedDateColumn) { _, _ in recomputeAutoFitColumnWidths() }
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
                .onKeyBindingPress(.open, store: keyBindingStore) { openSelection() }
                // 先頭文字で項目へ飛ぶ [ユーザー要望]。矢印での選択移動は
                // `Table` が AppKit から受け取るのでここでは足さない。
                .onKeyPress(characters: .alphanumerics.union(.symbols).union(.punctuationCharacters), phases: .down) { press in
                    handleTypeSelect(press)
                }
                // [QL-01] Space でプレビューを開閉する。パネルが前面にある間は
                // 一覧がフォーカスを失うため、閉じる側は `QLPreviewPanel` 自身の
                // Space 処理が受け持つ（Finder と同じ）。
                .onKeyBindingPress(.quickLook, store: keyBindingStore) { quickLook.toggle() }
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
            }
            // 絞り込んだ結果が 0 件のとき。**一覧の領域にだけ重ねる**——
            // 外側（`VStack` 全体）に付けるとパスバー・ステータスバーまで
            // 覆ってしまい、現在地も件数も見えなくなる（実機で確認）。
            // 読み込みエラー（`loadError`）とは別物なので、一覧の構造そのものは
            // 変えずに重ねるだけにしている。
            .overlay {
                if hasActiveSearch, displayedEntries.isEmpty, loadError == nil {
                    PlaceholderPane(
                        title: String(
                            localized: isSearching ? "folder.searching" : "folder.noSearchResults",
                            locale: locale
                        ),
                        subtitle: isSearching ? "" : String(localized: "folder.noSearchResultsHint", locale: locale)
                    )
                    .background(.background)
                }
            }

            bottomBars
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            // 可視要素を持たないボタンとして配線する標準的な SwiftUI のパターン。
            //
            // **ここにあるのは「変更可能な」操作だけ** [ユーザー要望]。Finder と
            // 同じキーに揃えてある操作（ゴミ箱・新規フォルダ・コピー／カット／
            // ペースト・すべてを選択・複製・上の階層へ 等）は、メニュー項目自身が
            // `.fixedKeyboardShortcut(_:)` を持ちメニューにキーが表示されるので、
            // 二重登録を避けるためここからは外してある。
            customisableKeyBindingButtons
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: Tokens.radius.s)
                    .strokeBorder(Tokens.Colors.accent, lineWidth: 2)
                    .padding(2)
                    .allowsHitTesting(false)
            }
        }
        // 実行中表示（不定進捗 [UI-09]）と圧縮／展開のパスワードシート。
        // 実体は `FolderOperations` が持ち、フォルダツリーとも共有している。
        .folderOperationsHost(operations)
        .dropDestination(for: URL.self) { items, _ in // [DD-03] Finder・他アプリからの取り込み
            // `folder`（構造体に保持された値）ではなく `currentFolder()` を
            // 読む必要がある [フェーズ1完了時の監査で発見: 高速なナビゲーション
            // 直後は SwiftUI がまだ1世代古い `FolderContentView` インスタンスを
            // 保持していることがあり、`goToParent`/`pasteFromPasteboard` で
            // 過去に同種のバグが実際に踏まれている。この経路だけ移行漏れが
            // あった]。
            guard let folder = currentFolder() else { return false }
            DropHandling.performDrop(items, into: folder, operations: operations, onComplete: { reload() }, onFailure: { presentFailureMessage($0) })
            return true
        } isTargeted: { isDropTargeted = $0 }
        // File/Edit メニューバーへの橋渡し [`FolderMenuActions` 参照]。
        // 再帰検索 [ユーザー要望]。`.task(id:)` はキーが変わると前のタスクを
        // 自動でキャンセルしてから始めるので、打鍵のたびに走査が積み上がらない。
        .task(id: searchKey) { await runSearch() }
        // [LF-14] 検索結果へラベルフィルタを効かせる。**結果が増えるたびに
        // 問い合わせ直す**——検索は 64 件ごとに小出しで反映されるので、完了を
        // 待つと「一度すべて出てから絞られる」ちらつきになる。1 回の問い合わせは
        // 900 件以下の `IN` なので、数十回に分かれても費用は小さい。
        .task(id: deepFilterKey) {
            guard hasActiveSearch, let filterDeepResults else {
                allowedDeepURLs = nil
                return
            }
            allowedDeepURLs = await filterDeepResults(searchResults.map(\.url))
        }
        // 検索中だけ配下すべてを見張る [10章 §10.0]。検索していないときは
        // 対象を `nil` にして登録を解く。
        .onChange(of: SearchWatchKey(folder: folder, isSearching: hasActiveSearch), initial: true) { _, key in
            searchWatch.watch(key.isSearching ? key.folder : nil, scope: .deep)
        }
        .onChange(of: searchWatch.generation) { _, newValue in
            // 走っている間は溜める（`appliedSearchGeneration` のコメント参照）。
            if isSearching { searchRerunPending = true } else { appliedSearchGeneration = newValue }
        }
        .onChange(of: isSearching) { _, running in
            guard !running, searchRerunPending else { return }
            searchRerunPending = false
            appliedSearchGeneration = searchWatch.generation
        }
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
            //
            // **ただしフォルダツリーから移動したときは奪わない**
            // [`WindowState.navigationCameFromTree` 参照]。奪うと、ツリーで
            // 矢印キーを 1 回押した時点でフォーカスが中央ペインへ移り、
            // 2 回目以降が効かなくなる。Finder もサイドバーをクリックした
            // だけではフォーカスを移さない。
            if !navigationCameFromTree { isListFocused = true }
        }
        // 表示中のフォルダの変更に追随する [10章 §10.0]。Finder・他アプリ・
        // 他ウインドウ・自分自身のどの操作でも、この 1 本の経路で届く。
        .onChange(of: folder, initial: true) { _, newValue in
            folderWatch.watch(newValue, scope: .shallow)
        }
        .onChange(of: folderWatch.generation) {
            reload()
        }
        // アクセス権の付与・取り消しなど、**ファイルの中身ではなく見え方の
        // 前提**が変わったときの再読み込み [`SessionState.reloadToken` 参照]。
        .onChange(of: SessionState.shared.reloadToken) {
            reload()
        }
        // Quick Look の矢印キー移動 [QL-07] が使う一覧の表示順を届ける。
        // `displayedEntries` は `entries`・`sortOrder`・`groupFoldersAtTop` の
        // 3 つから決まるので、`reload()`（＝ `entries` の更新）とこの 2 つの
        // `.onChange` が揃って初めて漏れが無い（`publishQuickLookOrder()` の
        // コメント参照）。
        .onChange(of: sortOrder) { _, newValue in
            publishQuickLookOrder()
            FolderSortComparator.persist(newValue)
        }
        .onChange(of: groupFoldersAtTop) { _, _ in publishQuickLookOrder() }
        // ツールバーのボタンからの合図でダイアログを出す
        // [`newFolderRequests` 参照]。
        .onChange(of: newFolderRequests) { _, _ in presentNewFolderDialog() }
        // 「戻る」「1階層上へ」で親フォルダへ移動した直後のスクロール
        // [`WindowState.pendingRevealURL` 参照、ユーザー要望]。既存の
        // `pendingScrollTarget` 経路へそのまま橋渡しする。
        .onChange(of: pendingRevealURL) { _, newValue in
            guard let target = newValue else { return }
            pendingScrollTarget = target
            pendingRevealURL = nil
        }
        // リスト表示でファイルをフォルダ行へドラッグしている間、通常の選択と
        // 同じ見た目（`Table` ネイティブの、列をまたいで連続したハイライト
        // バー）を一時的に流用する [`DropIntoFolderModifier` のコメント参照、
        // ユーザー指摘: 独自の半透明背景だと列ごとに分割されて見えて薄い。
        // 「ドラッグ先として選択している、という意味では間違っていない」との
        // 判断で選択そのものを差し替える方式にした]。ドラッグ終了・キャンセル
        // いずれの場合も `dropTargetedFolderURL` は `nil` に戻るため、
        // 必ず元の選択へ復元される。
        .onChange(of: dropTargetedFolderURL) { _, newValue in
            if let newValue {
                if selectionBeforeDropHighlight == nil {
                    selectionBeforeDropHighlight = selection
                }
                selection = [newValue]
            } else if let saved = selectionBeforeDropHighlight {
                selection = saved
                selectionBeforeDropHighlight = nil
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
    /// 中央ペイン下端のパスバーとステータスバー [1-16 表示メニューで表示切替を
    /// 追加]。**`body` から切り出している** — ステータスバーを足した時点で
    /// `body` 全体が「型検査に時間がかかりすぎる」というコンパイルエラーに
    /// なったため（SwiftUI の `ViewBuilder` は 1 つの式が大きくなるほど推論が
    /// 急激に重くなる）。同様に `body` が膨らんだら、まずこうした独立した
    /// 区画を計算プロパティへ切り出すこと。
    @ViewBuilder
    private var bottomBars: some View {
        // **ステータスバーがパスバーより上**［ユーザー要望で入れ替えた。以前は
        // パスバーが上だった］。パスバーが一番下＝ウインドウの最下端に来る。
        if folder != nil, isStatusBarVisible {
            Divider()
            StatusBarView(
                folder: folder,
                // 絞り込み中は一致件数を出す（Finder の検索結果表示と同じ）。
                itemCount: displayedEntries.count,
                selectedCount: selection.count,
                refreshToken: folderWatch.generation,
                isSearching: isSearching,
                searchTruncated: searchTruncated,
                showHiddenFiles: $showHiddenFiles,
                thumbnailHiddenReason: thumbnailHiddenReason, // [DS-07]
                onToggleThumbnails: onToggleThumbnails,
                trailing: { displayOptionControls }
            )
        }

        if let folder, isPathBarVisible {
            Divider()
            PathBarView(folder: folder, onNavigate: onNavigate) // [ユーザー要望: Finder 流のパスバー]
                .padding(.horizontal, Tokens.spacing.m)
                .padding(.vertical, Tokens.spacing.xs)
                .background(.thinMaterial)
        }
    }


    /// アイコン表示 [IV-01/08/09、PF-10]。
    ///
    /// **`body` から切り出している** — `body` が大きくなると SwiftUI の
    /// `ViewBuilder` 式の型検査が急激に重くなり「時間がかかりすぎる」で
    /// 通らなくなる（`bottomBars`・`customisableKeyBindingButtons` と同じ対処）。
    @ViewBuilder
    private var iconGrid: some View {
        IconGridView(
            entries: displayedEntries,
            selection: $selection,
            iconSize: iconSize,
            thumbnailsHidden: thumbnailHiddenReason != nil, // [DS-01]
            dragNamespace: dragNamespace,
            operations: operations,
            onOpenEntry: { openEntries([$0]) },
            onSingleClick: { handleSingleClick($0) },
            onReload: { reload() },
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
        // 実測幅から列数を出す（`IconGridMetrics` のコメント参照）。
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            iconGridColumnCount = IconGridMetrics.columnCount(width: width, iconSize: iconSize)
        }
        .onKeyBindingPress(.open, store: keyBindingStore) { openSelection() }
        .onKeyBindingPress(.quickLook, store: keyBindingStore) { quickLook.toggle() } // [QL-01]
        // アイコン表示の矢印キー移動 [ユーザー要望]。`Table` は AppKit から
        // 無償で受け取るが `LazyVGrid` には何も無く、以前は「何も選んで
        // いないときに先頭／末尾を選ぶ」だけで、選択後は矢印が完全に無反応
        // だった（表示モードで挙動が食い違っていた）。
        .onKeyPress(.downArrow) { moveIconSelection(.down) }
        .onKeyPress(.upArrow) { moveIconSelection(.up) }
        .onKeyPress(.leftArrow) { moveIconSelection(.left) }
        .onKeyPress(.rightArrow) { moveIconSelection(.right) }
        .onKeyPress(characters: .alphanumerics.union(.symbols).union(.punctuationCharacters), phases: .down) { press in
            handleTypeSelect(press)
        }
    }

    /// キーバインドを変更できる操作の隠しボタン一式。
    ///
    /// **`body` から切り出している** — ここが `body` の中にあると、
    /// SwiftUI の `ViewBuilder` 式が大きくなりすぎて「型検査に時間が
    /// かかりすぎる」でコンパイルが通らなくなる（このファイルでは 3 度目。
    /// `bottomBars` と同じ対処）。
    @ViewBuilder
    private var customisableKeyBindingButtons: some View {
        Group {
            KeyBindingButtons(action: .rename, store: keyBindingStore, isDisabled: selection.count != 1) {
                beginRenameFromShortcut()
            }
            // [FM-16] 既定では未割り当て。環境設定「キーボード」タブで
            // ユーザーが自分で割り当てた場合にだけ実際に効く
            // （`KeyBindingButtons` は `combos` が空ならボタンを 1 つも
            // 生成しない）。割り当てても確認シートは必ず経由する [FM-15]。
            KeyBindingButtons(action: .deletePermanently, store: keyBindingStore, isDisabled: selection.isEmpty, role: .destructive) {
                deletePermanently(Array(selection))
            }
            // 戻る／進むだけは 2 つ目の ⌘←／⌘→ をここで配線する
            // （メニュー項目が持てるショートカットは 1 つだけで、そちらは
            // Finder 標準の ⌘[／⌘] を表示する）。
            KeyBindingButtons(
                action: .goBack, store: keyBindingStore,
                isDisabled: !canGoBack, skipsPrimaryCombo: true
            ) {
                onGoBack()
            }
            KeyBindingButtons(
                action: .goForward, store: keyBindingStore,
                isDisabled: !canGoForward, skipsPrimaryCombo: true
            ) {
                onGoForward()
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

    /// リスト/アイコン表示モードに応じた表示オプション。**ステータスバーの
    /// 右端**に置く［ユーザー要望で移動した。以前はパスバーの右端だった］。
    @ViewBuilder
    private var displayOptionControls: some View {
        if listStyle == .icon { // [IV-04]
            Slider(value: $iconSize, in: Tokens.iconSize.min...Tokens.iconSize.max, step: Tokens.iconSize.step)
                .frame(width: 100)
                .controlSize(.small)
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

    private var currentFolderMenuActions: FolderMenuActions {
        let selected = Array(selection)
        var actions = FolderMenuActions()
        actions.canOpen = !selection.isEmpty
        actions.canQuickLook = !selection.isEmpty // [QL-01]
        actions.canNewFolder = folder != nil
        actions.canNewFolderWithSelection = folder != nil && !selection.isEmpty
        // 複数選択でも「名前を変更…」を出す（一括リネームのシートが開く）。
        actions.canRename = !selection.isEmpty
        actions.canDuplicate = !selection.isEmpty
        actions.canMakeAlias = !selection.isEmpty
        actions.canCompress = !selection.isEmpty
        // [Finder 対比監査] 既定の圧縮形式が暗号化に対応していなければ、
        // 選択があっても実行させない（パスワードを尋ねておきながら平文の
        // アーカイブを作ってしまうため、`FolderOperations` のコメント参照）。
        actions.canCompressWithPassword = !selection.isEmpty && operations.canCompressWithPassword
        actions.canMoveToTrash = !selection.isEmpty
        actions.canDeletePermanently = !selection.isEmpty // [FM-14]
        actions.canCopyPath = !selection.isEmpty // [FM-10]
        actions.canCopy = !selection.isEmpty
        actions.canCut = !selection.isEmpty
        actions.canPaste = canPaste && folder != nil
        actions.canSelectAll = !entries.isEmpty
        actions.canDeselectAll = !selection.isEmpty
        actions.canRevealInFinder = !selection.isEmpty
        actions.canOpenInTerminal = folder != nil // 選択が無ければ現在のフォルダが対象
        // [1-16 メニュー抜け監査] 以下 4 つはコンテキストメニューにしか無く、
        // メニューバーからは辿れなかったもの。判定条件はコンテキストメニュー側と
        // 同じにする（新規ウインドウで開く＝フォルダのみ、展開＝アーカイブのみ、
        // このアプリケーションで開く＝単一選択のみ）。
        let selectedEntries = entries.filter { selection.contains($0.url) }
        actions.canOpenInNewWindow = !selection.isEmpty && selectedEntries.allSatisfy(\.isNavigableFolder)
        actions.canExtract = !selection.isEmpty && isExtractable(selected)
        if selection.count == 1, let only = selectedEntries.first {
            actions.openWithTarget = (url: only.url, isDirectory: only.isNavigableFolder)
            actions.extractNamedTitle = actions.canExtract ? archiveBaseName(only.url) : nil
        }
        actions.shareItems = selected

        actions.open = { openSelection() }
        actions.quickLook = { quickLook.toggle() }
        actions.newFolder = { presentNewFolderDialog() }
        actions.newFolderWithSelection = { newFolderWithSelection(selected) }
        actions.rename = {
            if selection.count > 1 { beginBulkRename(Array(selection)) } else { beginRenameFromShortcut() }
        }
        actions.duplicate = { duplicate(selected) }
        actions.makeAlias = { createAliases(for: selected) }
        actions.compress = { compressHere(selected) }
        actions.compressWithPassword = { compressHereWithPassword(selected) }
        actions.moveToTrash = { moveToTrash(selected) }
        actions.deletePermanently = { deletePermanently(selected) }
        actions.copyPath = { copyPaths(selected) }
        actions.copy = { copySelectionToPasteboard(selected) }
        actions.cut = { cutSelectionToPasteboard(selected) }
        actions.paste = { pasteFromPasteboard() }
        actions.moveItemsHere = { moveItemsHere() }
        actions.selectAll = { selectAllInCurrentFolder() }
        actions.deselectAll = { selection.removeAll() }
        actions.revealInFinder = { NSWorkspace.shared.activateFileViewerSelecting(selected) }
        // 選択があればそれ（ファイルなら親）、無ければ現在のフォルダ [ユーザー要望]。
        actions.openInTerminal = {
            let targets = selected.isEmpty ? [currentFolder()].compactMap { $0 } : selected
            operations.openInTerminal(targets)
        }
        actions.openInNewWindow = { selected.forEach(onOpenInNewWindow) }
        actions.compressWithDialog = { compressWithDialog(selected) }
        actions.extractInPlace = { extractInPlace(selected) }
        actions.extractToNamedFolders = { extractToNamedFolders(selected) }
        actions.extractToChosenDestination = { extractToChosenDestination(selected) }

        // 表示メニュー [1-16]。並び替え・カラムの状態はこのビューが持つため、
        // ここから公開する（ペイン・バーの表示状態のようなウインドウ全体の
        // ものは `MainWindowView` が `WindowMenuActions` として公開する）。
        //
        // **`.commands` 側に `@AppStorage` を直接読ませない**ことがこの経路の
        // 眼目 [設計判断]。カラムの実体は `@AppStorage` だが、メニュー側は
        // ここで渡される `Set<FolderColumn>` とクロージャしか見ない —— メニュー
        // バーの `Toggle` を `@AppStorage` に直接束縛し、かつ同じキーを
        // ビュー構造を決める `if` で読むと、SwiftUI の Observation が無限に
        // 再評価してアプリがハングする既知の不具合（CLAUDE.md「タブバー表示
        // トグル」）を踏むパターンそのものになる。
        actions.isListStyleActive = listStyle == .list
        actions.sortKey = sortOrder.first?.key ?? .name
        actions.sortAscending = (sortOrder.first?.order ?? .forward) == .forward
        actions.setSortKey = { key in
            sortOrder = [FolderSortComparator(key: key, order: sortOrder.first?.order ?? .forward)]
        }
        actions.setSortAscending = { ascending in
            sortOrder = [FolderSortComparator(key: sortOrder.first?.key ?? .name, order: ascending ? .forward : .reverse)]
        }
        actions.visibleColumns = visibleColumns
        actions.setColumnVisible = { column, isVisible in setColumnVisible(column, isVisible) }
        actions.groupFoldersAtTop = groupFoldersAtTop
        actions.setGroupFoldersAtTop = { groupFoldersAtTop = $0 }
        return actions
    }

    /// 現在表示中のカラム [LV-02]。`FolderColumn` と `@AppStorage` の対応を
    /// この 2 つのヘルパーに閉じ込め、他の箇所がキー文字列を直接扱わないようにする。
    private var visibleColumns: Set<FolderColumn> {
        var result: Set<FolderColumn> = []
        if showModificationDateColumn { result.insert(.modificationDate) }
        if showSizeColumn { result.insert(.size) }
        if showKindColumn { result.insert(.kind) }
        if showCreationDateColumn { result.insert(.creationDate) }
        if showAddedDateColumn { result.insert(.addedDate) }
        return result
    }

    private func setColumnVisible(_ column: FolderColumn, _ isVisible: Bool) {
        switch column {
        case .modificationDate: showModificationDateColumn = isVisible
        case .size: showSizeColumn = isVisible
        case .kind: showKindColumn = isVisible
        case .creationDate: showCreationDateColumn = isVisible
        case .addedDate: showAddedDateColumn = isVisible
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

    /// カラムセルと同じフォント（`Tokens.fontSize.body`）でテキスト幅を実測
    /// する [`recomputeAutoFitColumnWidths()` 参照]。
    private static func measuredWidth(_ text: String) -> CGFloat {
        let font = NSFont.systemFont(ofSize: Tokens.fontSize.body)
        return (text as NSString).size(withAttributes: [.font: font]).width
    }

    /// [ユーザー指摘の修正] 変更日／サイズ／種類／作成日／追加日カラムが、
    /// 実際に表示する文字列の長さに対して無駄に広かった（固定の `ideal`
    /// 値をそのまま使っていたため）。現在の `entries`（フォルダ内の全項目、
    /// 表示中の一部だけでなく全件を対象にする——スクロールで隠れている
    /// 行の値がヘッダより長い場合に途中で列が詰まって見えるのを避けるため）
    /// とカラム見出し自身の文字列幅を実測し、その最大値＋余白を `ideal` に
    /// 反映する。`min`/`max` は既存の値のまま変更しない（`max` は以前の
    /// 固定 `ideal` を流用しており、手動でのドラッグ拡大の余地を残す）。
    private func recomputeAutoFitColumnWidths() {
        // [ユーザー指摘の修正] Finder のスクリーンショットを基準に、余白を
        // 従来より詰めた（`Tokens.spacing.m * 2 + Tokens.spacing.xs` = 28pt
        // だったものを 16pt に縮小）。**その後、実機診断で「種類」列の
        // "ComicBook Zip" が末尾で切れる不具合が見つかった**——`NSString`
        // での実測（92pt）に 16pt を足した 108pt は `Table` 内の実際のセルが
        // 必要とする幅に対してまだ不足していた（`Table` 自身がセルの左右に
        // 加える余白など、実測に含まれない分があると考えられる）。安全側に
        // 倒して 24pt へ増やした。
        let padding: CGFloat = Tokens.spacing.xl

        func fitWidth(header: String.LocalizationValue, values: [String]) -> CGFloat {
            let headerWidth = Self.measuredWidth(String(localized: header, locale: locale))
            let contentWidth = values.map(Self.measuredWidth).max() ?? 0
            return max(headerWidth, contentWidth) + padding
        }

        if showModificationDateColumn {
            modificationDateColumnWidth = fitWidth(
                header: "column.modificationDate",
                values: entries.map { $0.modificationDate.map { Self.dateFormatter.string(from: $0) } ?? "—" }
            )
        }
        if showSizeColumn {
            sizeColumnWidth = fitWidth(
                header: "column.size",
                values: entries.map { $0.isDirectory ? "—" : Self.sizeFormatter.string(fromByteCount: $0.fileSize ?? 0) }
            )
        }
        if showKindColumn {
            kindColumnWidth = fitWidth(header: "column.kind", values: entries.map(\.kindDescription))
        }
        if showCreationDateColumn {
            creationDateColumnWidth = fitWidth(
                header: "column.creationDate",
                values: entries.map { $0.creationDate.map { Self.dateFormatter.string(from: $0) } ?? "—" }
            )
        }
        if showAddedDateColumn {
            addedDateColumnWidth = fitWidth(
                header: "column.addedDate",
                values: entries.map { $0.addedDate.map { Self.dateFormatter.string(from: $0) } ?? "—" }
            )
        }
        if hasActiveSearch {
            // 相対パスは長くなりがちなので、名前列を潰さないよう上限を設ける
            // （溢れた分はツールチップで読める）。他の列と違い**検索結果の
            // `searchResults` を計測する**——この列は検索中にしか存在しない。
            locationColumnWidth = min(
                fitWidth(header: "column.location", values: searchResults.map { $0.relativeLocation.isEmpty ? "—" : $0.relativeLocation }),
                Self.maxLocationColumnWidth
            )
        }
        updateNameColumnWidth(tableWidth: lastKnownTableWidth)
    }

    /// 「場所」列の上限幅。深い階層だと相対パスが際限なく伸びるため。
    private static let maxLocationColumnWidth: CGFloat = 320

    /// 名前列以外の、現在表示中の列の合計幅 [`nameColumnWidth` 参照]。
    private var otherColumnsWidth: CGFloat {
        var total: CGFloat = 0
        if showModificationDateColumn { total += modificationDateColumnWidth }
        if showSizeColumn { total += sizeColumnWidth }
        if showKindColumn { total += kindColumnWidth }
        if showCreationDateColumn { total += creationDateColumnWidth }
        if showAddedDateColumn { total += addedDateColumnWidth }
        if hasActiveSearch { total += locationColumnWidth }
        return total
    }

    /// `Table` の実測幅（`.onGeometryChange` から渡される）。列の表示/非表示
    /// 切替時にも `nameColumnWidth` を再計算できるよう保持しておく。
    @State private var lastKnownTableWidth: CGFloat = 0

    private func updateNameColumnWidth(tableWidth: CGFloat) {
        guard tableWidth > 0 else { return }
        lastKnownTableWidth = tableWidth
        nameColumnWidth = max(160, tableWidth - otherColumnsWidth - Self.tableChromePadding)
    }

    /// 再帰検索の再実行トリガ。フォルダ・検索語・一覧の再読み込みのいずれかが
    /// 変わったらやり直す。`.task(id:)` は値が変わると**前のタスクを自動的に
    /// キャンセルしてから**新しいタスクを始めるため、打鍵のたびに走査が
    /// 積み上がることはない。
    private struct SearchKey: Equatable {
        let folder: URL?
        let query: String
        /// 検索範囲（フォルダ配下すべて）に変更があった回数
        /// [`appliedSearchGeneration` 参照]。外部で項目が増減しても結果が
        /// 古いまま取り残されないようにする。
        let changeGeneration: Int
        /// アクセス権の付与・取り消しなど、ファイルの中身以外の理由で
        /// 走査結果が変わり得る事象 [`SessionState.reloadToken` 参照]。
        let reloadToken: Int
        let showHiddenFiles: Bool
    }

    /// `searchWatch` の登録内容を決める識別子。`.onChange` に渡すため
    /// `Equatable` な値にまとめる。
    private struct SearchWatchKey: Equatable {
        let folder: URL?
        let isSearching: Bool
    }

    private var searchKey: SearchKey {
        SearchKey(
            folder: folder,
            query: searchText.trimmingCharacters(in: .whitespaces),
            changeGeneration: appliedSearchGeneration,
            reloadToken: SessionState.shared.reloadToken,
            showHiddenFiles: showHiddenFiles
        )
    }

    /// 現在のフォルダ以下を再帰的に走査して、名前が一致する項目を集める。
    ///
    /// **`Task.detached` は使わない** [1-14 で踏んだ教訓]。あれは呼び出し元の
    /// キャンセルを引き継がないため、検索欄を消しても走査が最後まで走り続ける。
    /// `nonisolated` な async 関数を直接 `await` すれば、メインアクタを外れつつ
    /// キャンセルも伝わる。
    ///
    /// 結果は `AppLimits.Search.resultBatchSize` 件ごとに小出しで反映する
    /// （走査の完了を待たずに出しはじめる）。上限に達したら打ち切り、
    /// 打ち切ったことを UI に出す。
    private func runSearch() async {
        guard hasActiveSearch, let folder else {
            searchResults = []
            isSearching = false
            searchTruncated = false
            return
        }
        searchGeneration += 1
        let generation = searchGeneration
        isSearching = true
        searchResults = []
        searchTruncated = false
        let truncated = await Self.enumerateMatches(
            in: folder,
            query: searchText,
            includingHiddenFiles: showHiddenFiles
        ) { batch in
            // 古い走査からの取りこぼしは捨てる（この関数のコメント参照）。
            guard generation == searchGeneration else { return }
            searchResults.append(contentsOf: batch)
            // 結果が増えるたびに「場所」列の幅を測り直す（小出しに反映される
            // ため、最初のひと固まりだけで幅が決まってしまわないように）。
            recomputeAutoFitColumnWidths()
        }
        // 打ち切られた（フォルダや検索語が変わった）場合、この走査は自分の
        // 結果を捨てるが、**`isSearching` は必ず下ろす** — 上げっぱなしだと、
        // 溜めておいた再実行 [`searchRerunPending`] が永久に保留になる。
        isSearching = false
        guard generation == searchGeneration else { return }
        searchTruncated = truncated
    }

    /// 実際の走査。一致した項目を `onBatch` で小出しに返し、上限で打ち切ったら
    /// `true` を返す。
    ///
    /// **走査そのものは `FileIO` の専用スレッドで行う** [NV6-01][NV6-02]。
    /// `nonisolated` にするだけではメインアクタを外れるだけで、走る先は
    /// 協調スレッドプールのまま——再帰検索はネットワーク上でいちばん往復の
    /// 多い操作なので、応答しない共有に当たるとプールのスレッドを 1 本
    /// 占有し続ける（コア数ぶん溜まればアプリの `async` 処理が全部止まる）。
    ///
    /// ひと固まりぶん走査しては戻る、という形で往復する。**結果の順序を
    /// 保つため**であり（1 回の `perform` の中からメインアクタへ小出しに
    /// することはできない — 同期クロージャなので `await` できない）、
    /// 往復は 64 件に 1 回なので費用は無視できる。
    private nonisolated static func enumerateMatches(
        in folder: URL,
        query: String,
        includingHiddenFiles: Bool,
        onBatch: @escaping @MainActor ([FolderEntry]) -> Void
    ) async -> Bool {
        guard let scan = SearchScan(
            folder: folder, query: query, includingHiddenFiles: includingHiddenFiles
        ) else { return false }

        while true {
            let step = await FileIO.perform { scan.nextBatch() }
            if !step.entries.isEmpty {
                if Task.isCancelled { return false }
                await MainActor.run { onBatch(step.entries) }
            }
            if step.finished { return step.truncated }
            if Task.isCancelled { return false }
        }
    }

    /// 再帰検索の走査状態。
    ///
    /// `NSDirectoryEnumerator` は `Sendable` ではないが、**この箱は
    /// `FileIO.perform` の中からしか触られず、しかも 1 度に 1 回ずつ
    /// （`await` で直列化されている）**ので競合しない。その前提を型で
    /// 表せないため `@unchecked` にしている。
    private final class SearchScan: @unchecked Sendable {
        /// ひと固まりぶん進めた結果。
        struct Step {
            let entries: [FolderEntry]
            /// 走査し終えた（もう呼ばなくてよい）。
            let finished: Bool
            /// 上限に達して打ち切った。
            let truncated: Bool
        }

        private static let keys: Set<URLResourceKey> = [
            .isDirectoryKey, .isPackageKey, .fileSizeKey, .contentModificationDateKey,
            .creationDateKey, .addedToDirectoryDateKey, .isUserImmutableKey,
        ]

        private let folder: URL
        private let query: String
        private let enumerator: FileManager.DirectoryEnumerator
        private var total = 0

        init?(folder: URL, query: String, includingHiddenFiles: Bool) {
            guard let enumerator = FileManager.default.enumerator(
                at: folder,
                includingPropertiesForKeys: Array(Self.keys),
                // 読めない場所（権限が無いサブフォルダ等）で止まらず先へ進む。
                options: includingHiddenFiles ? [] : [.skipsHiddenFiles],
                errorHandler: { _, _ in true }
            ) else { return nil }
            self.folder = folder
            self.query = query
            self.enumerator = enumerator
        }

        /// **ブロッキング。`FileIO.perform` の中からのみ呼ぶ。**
        func nextBatch() -> Step {
            var batch: [FolderEntry] = []
            // `NSDirectoryEnumerator` は async コンテキストで `for-in` できない
            // （`makeIterator` が unavailable）ため `nextObject()` で回す。
            while let url = enumerator.nextObject() as? URL {
                // **`Task.isCancelled` ではない** — 借りたスレッドには Task の
                // 文脈が無く、常に `false` を返す [`Cancellation` 参照]。
                if Cancellation.isRequested {
                    return Step(entries: batch, finished: true, truncated: false)
                }
                let values = try? url.resourceValues(forKeys: Self.keys)
                // **パッケージの中へは降りない** [ユーザー要望、Finder 準拠]。
                // `.app` 1 つで数千件あるので、降りると検索結果が中身で埋まり
                // 上限（`AppLimits.Search.maxResults`）に達してしまう。
                // パッケージ自身は結果に含める（下でフィルタに掛ける）。
                // **名前のフィルタより前に呼ぶ** — 名前が一致しなくても中へは
                // 入らせない。
                if values?.isPackage == true { enumerator.skipDescendants() }
                guard NameFilter.matches(name: url.lastPathComponent, query: query) else { continue }
                batch.append(FolderEntry(
                    url: url,
                    name: url.lastPathComponent,
                    isDirectory: values?.isDirectory ?? false,
                    isPackage: values?.isPackage ?? false,
                    fileSize: values?.fileSize.map(Int64.init),
                    modificationDate: values?.contentModificationDate,
                    creationDate: values?.creationDate,
                    addedDate: values?.addedToDirectoryDate,
                    isLocked: values?.isUserImmutable ?? false,
                    relativeLocation: FolderContentView.relativeLocation(of: url, from: folder)
                ))
                total += 1
                if total >= AppLimits.Search.maxResults {
                    return Step(entries: batch, finished: true, truncated: true)
                }
                if batch.count >= AppLimits.Search.resultBatchSize {
                    return Step(entries: batch, finished: false, truncated: false)
                }
            }
            return Step(entries: batch, finished: true, truncated: false)
        }
    }

    /// 検索の起点 `root` から見た、`url` の**親フォルダ**の相対パス
    /// [ユーザー要望]。起点の直下なら空文字を返す。
    ///
    /// `pathComponents` の差分から組み立てる——`URL` の相対パス API は無く、
    /// 文字列の前方一致で切り出すとパス区切りの扱いを誤りやすいため。
    private nonisolated static func relativeLocation(of url: URL, from root: URL) -> String {
        let rootComponents = root.standardizedFileURL.pathComponents
        let parentComponents = url.standardizedFileURL.deletingLastPathComponent().pathComponents
        guard parentComponents.count > rootComponents.count,
              Array(parentComponents.prefix(rootComponents.count)) == rootComponents
        else { return "" }
        return parentComponents.dropFirst(rootComponents.count).joined(separator: "/")
    }

    /// 絞り込みが有効か [1-16 検索]。空白のみの入力は「絞り込んでいない」扱い。
    ///
    /// 検索フィールド自体はウインドウのツールバー（`MainWindowView`）にあり、
    /// このビューは `searchText` を受け取って一覧を絞り込む役目だけを持つ
    /// [Finder 風の「普段はボタン、押すと検索欄」にするためツールバーへ移した]。
    /// 検索結果の絞り込みを問い合わせ直す条件 [LF-14]。
    ///
    /// **URL の配列そのものを鍵にしない**——2,000 件の配列のハッシュを再描画の
    /// たびに計算することになる。件数と検索語で十分区別できる。
    private struct DeepFilterKey: Hashable {
        let folder: URL?
        let searchText: String
        let resultCount: Int
        let filterRevision: Int
    }

    private var deepFilterKey: DeepFilterKey {
        DeepFilterKey(folder: folder, searchText: searchText,
                      resultCount: searchResults.count, filterRevision: labelFilterRevision)
    }

    private var hasActiveSearch: Bool {
        !searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// `entries` に現在のソート順 [LV-01] とフォルダをまとめる設定 [LV-03] を
    /// 適用した、実際に `Table` へ渡す並び。`filter` は相対順序を保つため、
    /// グルーピングを先にソートした結果へ適用しても各グループ内の順序は
    /// 崩れない。
    private var displayedEntries: [FolderEntry] {
        // 検索中は**再帰的に集めた結果**を一覧の元にする [ユーザー要望:
        // サブフォルダも再帰的に検索する]。Finder の検索と同じく、現在の
        // フォルダを起点に配下すべてが対象になる。走査は `searchTask` が
        // 非同期・キャンセル可能に行い、ここは受け取った結果を並べるだけ。
        // 一致判定の規則とその理由は `NameFilter` 側にまとめてある。
        // ライブラリ横断検索・ラベル検索はフェーズ2の担当。
        var result = hasActiveSearch ? searchResults : entries
        // [VM-02] ラベルフィルタ。該当ファイルと、該当ファイルを配下に持つ
        // フォルダだけを残す。
        //
        // **検索中は適用しない**——`searchResults` は配下から再帰的に集めた
        // 一覧なので、直下の子の名前とは照合できない（深い所のファイルは
        // 名前ではなく、それを含む直下フォルダの名前として集合に入っている）。
        // 素朴に名前で突き合わせると「該当が 1 件でもあるフォルダの中身が
        // 全部通る」という、絞れているように見えて絞れていない状態になる。
        // 検索との併用は `matchingRelativePaths` で別に扱う。
        if hasActiveSearch {
            // [LF-14] 検索結果は 1 件ずつ DB へ問い合わせて絞る。
            if let allowed = allowedDeepURLs {
                result = result.filter { allowed.contains($0.url) }
            }
        } else if let allowed = allowedChildNames {
            result = result.filter { allowed.contains($0.name) }
        }
        result.sort(using: sortOrder)
        if groupFoldersAtTop {
            result = result.filter(\.isNavigableFolder) + result.filter { !$0.isNavigableFolder }
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
    private func rowCell(_ entry: FolderEntry, isRenaming: Bool = false, alignment: Alignment = .leading, @ViewBuilder content: () -> some View) -> some View {
        if isRenaming {
            // インライン編集中はこの行の選択・ダブルクリック・D&D 用ジェスチャを
            // すべて外す。`TextField` 自身のクリック（カーソル位置合わせ等）が
            // 誤って選択操作やリネームの再トリガーとして扱われるのを防ぐため
            // [ユーザー要望: Finder 流のインライン名前編集]。
            content()
                .frame(maxWidth: .infinity, alignment: alignment)
        } else {
            content()
                .frame(maxWidth: .infinity, alignment: alignment)
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
                    operations: operations,
                    reload: { reload() },
                    onFailure: { presentFailureMessage($0) },
                    targetedURL: $dropTargetedFolderURL,
                    paintsBackgroundHighlight: false
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
    /// アイコン表示の矢印キー移動 [ユーザー要望]。
    ///
    /// 何も選んでいなければ、まず端の項目を選ぶ（Finder と同じ。↓ で先頭、
    /// ↑ で末尾）。選択済みならその位置から格子上を移動する。
    /// 移動先の計算は `ListKeyboardNavigation.gridTarget` に出してある。
    private func moveIconSelection(_ direction: ListKeyboardNavigation.Direction) -> KeyPress.Result {
        let items = displayedEntries
        guard !items.isEmpty else { return .ignored }
        guard let current = currentSelectionIndex(in: items) else {
            // 端から入る。← → は「まだどこにも居ない」ので反応しない方が自然。
            switch direction {
            case .down: return selectFirstOrLastIfNoneSelected(first: true) ? .handled : .ignored
            case .up: return selectFirstOrLastIfNoneSelected(first: false) ? .handled : .ignored
            case .left, .right: return .ignored
            }
        }
        guard let target = ListKeyboardNavigation.gridTarget(
            from: current, direction: direction, count: items.count, columns: iconGridColumnCount
        ) else { return .handled } // 端では動かないが、キーは消費する（ビープさせない）
        selectSingle(items[target])
        return .handled
    }

    /// 先頭文字で項目へ飛ぶ [ユーザー要望、Finder 標準の type-select]。
    ///
    /// **修飾キー付きの入力は素通しする** — ⌘C などのショートカットを
    /// 横取りしないため。
    private func handleTypeSelect(_ press: KeyPress) -> KeyPress.Result {
        guard press.modifiers.isEmpty || press.modifiers == .shift else { return .ignored }
        guard let character = press.characters.first else { return .ignored }
        let items = displayedEntries
        guard !items.isEmpty else { return .ignored }
        let prefix = typeSelectBuffer.append(character)
        guard let target = ListKeyboardNavigation.typeSelectTarget(
            in: items, prefix: prefix, currentIndex: currentSelectionIndex(in: items), name: \.name
        ) else { return .handled } // 一致が無くても打鍵は消費する（ビープさせない）
        selectSingle(items[target])
        return .handled
    }

    /// 単一選択にして、その項目までスクロールする。矢印移動・type-select 共通。
    private func selectSingle(_ entry: FolderEntry) {
        selection = [entry.url]
        selectionAnchor = entry.url
        pendingScrollTarget = entry.url
    }

    /// いま選んでいる項目の位置。複数選択なら**最後に選ばれたもの**ではなく
    /// 表示順で最初のものを起点にする（どれを起点にしても直感に反しない
    /// 単純な規則を選んだ）。
    private func currentSelectionIndex(in items: [FolderEntry]) -> Int? {
        guard !selection.isEmpty else { return nil }
        return items.firstIndex { selection.contains($0.url) }
    }

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
            Menu("common.sortBy", systemImage: "arrow.up.arrow.down") { // [LV-01]
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
            Button("action.newFolder", systemImage: "folder.badge.plus") {
                presentNewFolderDialog()
            }
            Button("action.paste", systemImage: "document.on.clipboard") { pasteFromPasteboard() }
                .disabled(!canPaste)
                // Finder と同じく ⌥ で「ここに項目を移動」に入れ替わる
                // [Finder 対比監査]。
                .modifierKeyAlternate(.option) {
                    Button("folder.moveItemsHere", systemImage: "folder") { moveItemsHere() }
                        .disabled(!canPaste)
                }
            // Finder は空きスペースの右クリックにも「すべて選択」を出す
            // [Finder/Edit メニュー整備の一環で追加]。
            // 現在いるフォルダをターミナルで開く [ユーザー要望]。
            if let folder = currentFolder() {
                Divider()
                Button("folder.openInTerminal", systemImage: "terminal") { operations.openInTerminal([folder]) }
            }
            Button("action.selectAll", systemImage: "character.textbox") { selectAllInCurrentFolder() }
                .disabled(entries.isEmpty)
                // Finder と同じく ⌥ で「すべてを選択解除」に入れ替わる
                // [Finder 対比監査]。
                .modifierKeyAlternate(.option) {
                    Button("action.deselectAll", systemImage: "character.textbox") { selection.removeAll() }
                        .disabled(selection.isEmpty)
                }
        } else {
            let targets = Array(urls)
            let targetEntries = entries.filter { urls.contains($0.url) }
            Button("action.open", systemImage: "arrow.up.forward.app") { openEntries(targetEntries) } // [KB-02 相当]
            // [QL-01] 右クリックした対象が現在の選択と違う場合は、まず選択を
            // 合わせてから開く——Quick Look の対象は「現在の選択」であり
            // （`QuickLookController` 参照）、`.contextMenu(forSelectionType:)`
            // が渡してくる対象と食い違ったままでは別のファイルが出てしまう。
            Button("action.quickLook", systemImage: "eye") {
                selection = urls
                quickLook.show()
            }
            // 「アプリケーションで開く」[12章 §12.9、単一選択のみ]。フォルダも
            // 対象に含む——`OpenWithMenu` 側でフォルダかどうかに応じて拡張子
            // ベース／`public.folder` ベースの候補列挙を切り替える
            // [ユーザー指摘: フォルダの右クリックメニューにも「このアプリ
            // ケーションで開く」が無いのはおかしい]。
            if targets.count == 1, let only = targetEntries.first {
                OpenWithMenu(url: only.url, isDirectory: only.isNavigableFolder)
                // **パッケージの中を見る唯一の導線** [ユーザー要望、Finder 準拠]。
                // ダブルクリックは起動に割り当てたので、中身を見たいときは
                // ここから入る。訳語は Finder の実文言から写した
                // （`LocalizableMerged.strings` の `N158`）。
                if only.isPackage {
                    Button("folder.showPackageContents", systemImage: "shippingbox") {
                        onNavigate(only.url)
                    }
                }
            }
            if targetEntries.allSatisfy(\.isNavigableFolder) {
                // 新規タブ/ウインドウで開くはフォルダのみ意味を持つ。Finder は
                // 複数選択なら選択したフォルダの数だけタブ/ウインドウを開く。
                Button(targets.count == 1 ? "folder.openInNewTab" : "folder.openEachInNewTab", systemImage: "plus.square.on.square") {
                    targets.forEach(onOpenInNewTab)
                }
                Button(targets.count == 1 ? "folder.openInNewWindow" : "folder.openEachInNewWindow", systemImage: "plus.rectangle") {
                    targets.forEach(onOpenInNewWindow)
                }
            }
            Divider()
            // 単一選択はその場でのインライン編集、複数選択は一括リネームの
            // シート（Finder と同じ使い分け）[FM-05、ユーザー要望]。
            if targets.count == 1, let only = targetEntries.first {
                Button("folder.renameEllipsis", systemImage: "pencil") { beginRename(only) } // [FM-05]
            } else if targets.count > 1 {
                Button("menu.renameItems", systemImage: "pencil") { beginBulkRename(targets) }
            }
            Button("folder.duplicate", systemImage: "plus.square.on.square") { duplicate(targets) } // [FM-02]
            Button("action.copy", systemImage: "document.on.document") { copySelectionToPasteboard(targets) } // [KB-02 相当、⌘C]
                // Finder と同じく ⌥ で「パス名をコピー」に入れ替わる [FM-10]
                // [Finder 対比監査。⌥ 代替の一覧と、対応しなかった項目の理由は
                // CLAUDE.md「Finder の ⌥ 代替項目」節を参照]。
                .modifierKeyAlternate(.option) {
                    Button("folder.copyPath", systemImage: "document.on.document") { copyPaths(targets) }
                }
            Button("action.cut", systemImage: "scissors") { cutSelectionToPasteboard(targets) } // [Finder/Edit メニュー整備、⌘X]
            // Finder の「選択項目で新規フォルダを作成」[Finder/Edit メニュー整備]。
            // 移動先を作る操作のため、フォルダ自身が対象に混ざっていても
            // Finder と同じく無条件に出す。
            Button("action.newFolderWithSelection") { newFolderWithSelection(targets) }
            Divider()
            Button("folder.moveToTrash", systemImage: "trash", role: .destructive) { moveToTrash(targets) } // [FM-04]
                // Finder と同じく ⌥ で「すぐに削除…」に入れ替わる [FM-14]
                // [Finder 対比監査]。対にすることで、ゴミ箱が出せない場面で
                // 完全削除だけが現れる経路を構造的に無くしている。
                .modifierKeyAlternate(.option) {
                    Button("folder.deletePermanentlyEllipsis", systemImage: "trash", role: .destructive) {
                        deletePermanently(targets)
                    }
                }
            Divider()
            // 圧縮・展開関連をサブメニューにまとめる [ユーザー要望]。
            Menu("folder.compressExtractSubmenu", systemImage: "zipper.page") {
                Button("folder.compressHere", systemImage: "zipper.page") { compressHere(targets) } // [AR-10]
                    // Finder と同じく ⌥ で「パスワード付きで圧縮」に入れ替わる
                    // [Finder 対比監査]。既定の圧縮形式が暗号化に対応している
                    // ときだけ差し替える（`canCompressWithPassword` 参照）。
                    .modifierKeyAlternate(.option) {
                        if operations.canCompressWithPassword {
                            Button("folder.compressHereWithPassword", systemImage: "zipper.page") { compressHereWithPassword(targets) }
                        }
                    }
                Button("folder.compressEllipsis", systemImage: "zipper.page") { compressWithDialog(targets) } // [AR-11]
                if isExtractable(targets) {
                    Divider()
                    Button("folder.extractInPlace", systemImage: "shippingbox.and.arrow.backward") { extractInPlace(targets) } // [AR-20]
                    if targets.count == 1, let single = targets.first {
                        Button(String(format: String(localized: "folder.extractToNamed", locale: locale), archiveBaseName(single)), systemImage: "shippingbox.and.arrow.backward") { extractToNamedFolders(targets) } // [AR-21]
                    } else {
                        Button("folder.extractEachToOwnFolder", systemImage: "shippingbox.and.arrow.backward") { extractToNamedFolders(targets) } // [AR-23]
                    }
                    Button("folder.extractEllipsis", systemImage: "shippingbox.and.arrow.backward") { extractToChosenDestination(targets) } // [AR-22]
                }
            }
            Divider()
            Button("folder.revealInFinder", systemImage: "macwindow") { NSWorkspace.shared.activateFileViewerSelecting(targets) } // [FM-09]
            // ターミナルで開く [ユーザー要望]。ファイルを選んでいる場合は
            // その親フォルダを開く（`FolderOperations.openInTerminal` 参照）。
            Button("folder.openInTerminal", systemImage: "terminal") { operations.openInTerminal(targets) }
            ShareLink(items: targets) { Label("folder.shareEllipsis", systemImage: "square.and.arrow.up") } // [共有、既定ラベルが英語 "Share..." になるため明示的に指定]
            Button("folder.createAlias", systemImage: "square.on.square.dashed") { createAliases(for: targets) }
            Divider()
            Button(targetEntries.allSatisfy(\.isLocked) ? "folder.unlock" : "folder.lock",
                   systemImage: targetEntries.allSatisfy(\.isLocked) ? "lock.open" : "lock") {
                toggleLock(targetEntries)
            }
            // 「情報を見る」の簡易シートは 1-10 で常設の右ペイン
            // インスペクタ（`InspectorPane`）に置き換えたため削除した。
        }
    }

    /// 一覧を読み直す。
    ///
    /// **一覧の読み込みはメインスレッドで行わない** [NV6-02]。
    /// `contentsOfDirectory` は応答しないサーバに当たると戻ってこず、SMB なら
    /// 30 秒、NFS の hard マウント（既定）なら**無限に**メインスレッドが
    /// 止まる（＝ビーチボール）。ネットワーク上のフォルダを開くという、
    /// もっとも頻度の高い操作がそのままアプリの停止になっていた。
    ///
    /// そのため実際の走査は `FileIO.perform` の中で行い、**結果だけを
    /// メインアクタへ戻して当てる**。呼び出し側の書き方は変えていない
    /// （このメソッドは即座に返り、表示は 1 フレーム後に入れ替わる。
    /// Finder も同じく非同期に読み込む）。
    ///
    /// - Note: **世代番号で古い結果を捨てる。** 非同期になったことで、速く
    ///   連続してフォルダを移ると走査の順序が入れ替わり得る。再帰検索
    ///   （`appliedSearchGeneration`）で既に使っているのと同じ手当て。
    /// 表示中のフォルダへのアクセスをその場で求める [ユーザー要望]。
    ///
    /// 許可の取得・永続化は移動メニューと同じ `StandardLocationOpener` に委ねる
    /// ——許可 UI が 2 つに分かれると、片方だけ直して取り残される
    /// （1-12 のアプリ関連付けで実際に起きた）。
    ///
    /// `folder`（構造体に保持された値）ではなく `currentFolder()` を読む
    /// [既知の罠: ナビゲーション直後は 1 世代古い View インスタンスの
    /// クロージャが実行され得る]。
    private func requestAccessForCurrentFolder() {
        guard let folder = currentFolder() else { return }
        Task {
            guard await StandardLocationOpener.requestAccess(to: folder, locale: locale) else { return }
            reload()
        }
    }

    private func reload() {
        reloadGeneration &+= 1
        let generation = reloadGeneration
        guard let folder else {
            entries = []
            loadError = nil
            publishQuickLookOrder() // タブにフォルダが無い状態でも表示順は空に揃える
            tableIdentity = folder
            return
        }
        let includeHidden = showHiddenFiles
        Task {
            let outcome = await FileIO.perform {
                Self.readEntries(in: folder, includingHidden: includeHidden)
            }
            // 走査中に別のフォルダへ移った／もう一度読み直しが要求された。
            guard generation == reloadGeneration else { return }
            await apply(outcome, for: folder)
        }
    }

    /// 一覧の読み込み結果。`FileIO` の境界をまたぐので `Sendable`。
    private enum FolderReadOutcome: Sendable {
        case loaded([FolderEntry])
        /// `isAccessDenied` は「アクセスを許可…」を出してよいかの判断材料
        /// （消えている・壊れているといった他の失敗と区別する）。
        case failed(String, isAccessDenied: Bool)
    }

    /// **実際の走査。メインアクタの外で走る。**
    ///
    /// `includingPropertiesForKeys` で先読みした値は URL にキャッシュされる
    /// ので、一覧の読み込みは項目数ぶんの往復ではなく **1 往復**で済む
    /// （1-16b の実測、8章 §8.11.7）。**先読みしていないキーを後から読むと
    /// 項目ごとに往復が発生する**ので、ここの `keys` と下で読む値は必ず揃える。
    private nonisolated static func readEntries(
        in folder: URL, includingHidden: Bool
    ) -> FolderReadOutcome {
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey, .isPackageKey, .fileSizeKey, .contentModificationDateKey,
            .creationDateKey, .addedToDirectoryDateKey, .isUserImmutableKey,
        ]
        do {
            let urls = try FileManager.default.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: Array(keys),
                options: includingHidden ? [] : [.skipsHiddenFiles]
            )
            return .loaded(urls.map { url in
                let values = try? url.resourceValues(forKeys: keys)
                return FolderEntry(
                    url: url,
                    name: url.lastPathComponent,
                    isDirectory: values?.isDirectory ?? false,
                    isPackage: values?.isPackage ?? false,
                    fileSize: values?.fileSize.map(Int64.init),
                    modificationDate: values?.contentModificationDate,
                    creationDate: values?.creationDate,
                    addedDate: values?.addedToDirectoryDate,
                    isLocked: values?.isUserImmutable ?? false
                )
            })
        } catch {
            // **ボリュームが外れているだけなら、そう言う** [RG3-06][1-17]。
            // OS の生の文言（「ファイル…が存在しないため開けませんでした」等）
            // では、挿し直せば戻ることが伝わらない。判定はマウント表と
            // 突き合わせるだけで当のパスには触れない [NV6-02]。
            if MountTable.current().isOnAnUnmountedVolume(folder) {
                return .failed(
                    String(localized: "folder.volumeNotConnected", locale: AppLanguage.effectiveLocale),
                    isAccessDenied: false
                )
            }
            return .failed(error.localizedDescription, isAccessDenied: Self.isAccessDenied(error))
        }
    }

    /// 読めなかった理由が「権限が無い」かどうか。**ここでだけ判定する。**
    ///
    /// 権限のときだけ「アクセスを許可…」を出したいので、消えている・壊れている
    /// といった他の失敗と区別する必要がある。判定を外すと、実体が消えたフォルダ
    /// でも許可パネルを勧めてしまう。
    private nonisolated static func isAccessDenied(_ error: Error) -> Bool {
        let nsError = error as NSError
        switch nsError.domain {
        case NSCocoaErrorDomain:
            return nsError.code == NSFileReadNoPermissionError
        case NSPOSIXErrorDomain:
            return nsError.code == Int(EACCES) || nsError.code == Int(EPERM)
        default:
            // `underlyingError` に POSIX が包まれていることがある。
            guard let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError else { return false }
            return isAccessDenied(underlying)
        }
    }

    /// 読み込み結果を表示へ当てる。**ここはメインアクタ。**
    private func apply(_ outcome: FolderReadOutcome, for folder: URL) async {
        switch outcome {
        case let .loaded(loaded):
            entries = loaded
            loadError = nil
            // ゴミ箱・移動等で消えた項目を選択から取り除く [実機検証で発見:
            // ファイルをゴミ箱に入れても `selection` に URL が残ったままになり、
            // 右ペインのインスペクタ（`InspectorPane`）が `.task(id: url)` の
            // id（＝ URL 自体）が変わらないため削除前の情報を表示し続けて
            // いた]。選択が空になれば `InspectorPane` は現在のフォルダ自身の
            // 情報表示にフォールバックする（既存の設計）。
            let currentURLs = Set(entries.map(\.url))
            selection.formIntersection(currentURLs)
        case let .failed(message, isAccessDenied):
            // 表示中のフォルダ自体が消えている場合（ツリーや別ウインドウから
            // ゴミ箱へ入れた・名前を変更した、アプリ外の Finder で削除した等）は、
            // エラー表示で行き止まりにせず存在する直近の祖先へ移動する
            // [`WindowState.relocateCurrentTabIfFolderVanished()` 参照]。移動すると
            // `folder` が変わり `.task(id: folder)` 経由でここが再実行されるため、
            // 続きの処理は次の呼び出しに任せて打ち切ってよい。
            if await relocateIfFolderVanished() { return }
            entries = []
            loadError = message
            loadErrorIsAccessDenied = isAccessDenied
        }
        publishQuickLookOrder()
        recomputeAutoFitColumnWidths() // [ユーザー指摘の修正] 列幅を内容に合わせて再計測する。
        // 幅の計算を終えたあとで更新する（`tableIdentity` 宣言部と `.id(...)`
        // 呼び出し箇所のコメント参照）。同一フォルダ内の再読み込み（D&D 等）
        // では `folder` の値自体は変わらないため、`Table` は作り直されず
        // スクロール位置等も保たれる。
        tableIdentity = folder
    }

    /// Quick Look の矢印キー移動 [QL-07] に必要な「一覧の表示順」を
    /// `QuickLookController` へ届ける。
    ///
    /// `QuickLookController` 側が `displayedEntries` をその場で計算する形
    /// （クロージャを渡す等）にはしていない——このビューは値型で作り直される
    /// ため、参照を保持すると 1 世代古いインスタンスを読んでしまう既知の罠
    /// （`currentFolder` のコメント参照）に嵌る。並び替えは
    /// `localizedStandardCompare` を伴い安くないので、`body` の評価ごとに
    /// 計算し直すのではなく、順序が実際に変わる 3 箇所からだけ押し込む。
    private func publishQuickLookOrder() {
        quickLook.orderedURLs = displayedEntries.map(\.url)
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
        operations.copyPaths(urls) // [FM-10]
    }

    /// `⌘C`/コンテキストメニュー「コピー」。
    private func copySelectionToPasteboard(_ urls: [URL]) {
        operations.copyToPasteboard(urls)
    }

    /// `⌘X`/コンテキストメニュー「カット」[Finder/Edit メニュー整備の一環で追加]。
    private func cutSelectionToPasteboard(_ urls: [URL]) {
        operations.cutToPasteboard(urls)
    }

    /// `⌘V`/コンテキストメニュー「ペースト」。ペースト先は `folder`（構造体に
    /// 保持された値）ではなく `currentFolder()` を読む [実機検証で発見した
    /// バグの修正、`currentFolder` の宣言部のコメント参照]。
    private func pasteFromPasteboard() {
        guard let folder = currentFolder() else { return }
        operations.paste(into: folder) { reload() }
    }

    /// Finder の「ここに項目を移動」（「ペースト」の ⌥ 代替）[Finder 対比監査]。
    /// 貼り付け先の解決は `pasteFromPasteboard()` と同じく `currentFolder()` を読む。
    private func moveItemsHere() {
        guard let folder = currentFolder() else { return }
        operations.moveItemsHere(into: folder) { reload() }
    }

    private var canPaste: Bool {
        operations.canPaste
    }

    /// `⌘A`/空きスペースの右クリック「すべて選択」[Finder/Edit メニュー整備]。
    private func selectAllInCurrentFolder() {
        guard !entries.isEmpty else { return }
        selection = Set(entries.map(\.url))
    }

    /// Finder の「選択項目で新規フォルダを作成」[Finder/Edit メニュー整備]。
    private func newFolderWithSelection(_ urls: [URL]) {
        guard let folder = currentFolder() else { return }
        operations.newFolderWithSelection(urls, in: folder) { created in
            selection = [created]
            reload()
        }
    }

    private func createAliases(for urls: [URL]) {
        guard let folder = currentFolder() else { return }
        operations.createAliases(for: urls, in: folder) { reload() }
    }

    /// 対象が全てロック済みなら解除、そうでなければロックする（Finder と同じ
    /// トグル規則）。
    private func toggleLock(_ targets: [FolderEntry]) {
        guard !targets.isEmpty else { return }
        let shouldLock = !targets.allSatisfy(\.isLocked)
        operations.setLocked(targets.map(\.url), locked: shouldLock) { reload() }
    }

    private func beginRename(_ entry: FolderEntry) {
        renamingEntry = entry
        renameText = entry.name
    }

    /// `⌘R` ショートカット用。バッチ名変更 UI が無いため単一選択時のみ動く
    /// [FM-05]。
    /// Finder の「名前を変更…」（複数選択時）[ユーザー要望]。単一選択のときは
    /// 従来どおり中央ペインでのインライン編集（Finder も同じ）。
    private func beginBulkRename(_ urls: [URL]) {
        operations.beginBulkRename(orderedForDisplay(urls))
    }

    /// **一覧に見えている順**に並べ替える［実機検証で発見］。
    ///
    /// 選択は `Set` なので、そのまま配列にすると順序が不定になる。
    /// `BulkRename.plan(names:)` は「表示順で渡すこと」を前提に**その順で
    /// 連番を振る**ので、渡す順が不定だと「1 番目に見えている項目が 5 番」の
    /// ような結果になり、プレビューの並びも毎回変わる。ここは一括リネームへ
    /// 入る唯一の入口なので、経路（⌘R・コンテキストメニュー・ファイル
    /// メニュー）によらず必ず揃う。
    ///
    /// 一覧に無い項目（並び替えの直後など）は末尾に、名前の自然順で置く。
    private func orderedForDisplay(_ urls: [URL]) -> [URL] {
        var rank: [URL: Int] = [:]
        for (index, entry) in displayedEntries.enumerated() { rank[entry.url] = index }
        return urls.sorted { left, right in
            switch (rank[left], rank[right]) {
            case let (leftRank?, rightRank?): return leftRank < rightRank
            case (nil, _?): return false
            case (_?, nil): return true
            case (nil, nil):
                return left.lastPathComponent.localizedStandardCompare(right.lastPathComponent) == .orderedAscending
            }
        }
    }

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
    /// - Note: リンクの解決は `readlink`/ブックマーク解決を伴う I/O なので、
    ///   **メインスレッドでは行わない** [NV6-02]。ネットワーク上のリンクを
    ///   ダブルクリックしただけで固まらないようにするため。
    private func openEntries(_ targets: [FolderEntry]) {
        let urls = targets.map(\.url)
        Task {
            // [SL-02] リンクは**開くときだけ**リンク先へ追従する（表示上の
            // 追従のみ。一覧ではリンク自体を 1 項目として見せる [SL-01]）。
            let resolved = await FileIO.perform { urls.map { LinkResolver.resolve($0) } }
            if resolved.count == 1, let only = resolved.first {
                // **パッケージ（`.app` など）は中へ入らず開く** [ユーザー要望:
                // ダブルクリックで起動し、中を見るのはコンテキストメニューから]。
                // 実体はディレクトリだが、利用者にとっては 1 つの項目である。
                if only.isNavigableFolder {
                    onNavigate(only.url)
                } else {
                    openWithAssociation(only.url)
                }
                return
            }
            for target in resolved where !target.isNavigableFolder {
                openWithAssociation(target.url)
            }
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
        operations.rename(entry.url, to: renameText) { reload() }
    }

    private func cancelRename() {
        renamingEntry = nil
    }

    private func duplicate(_ urls: [URL]) {
        guard let folder = currentFolder() else { return }
        operations.duplicate(urls, into: folder) { reload() }
    }

    private func moveToTrash(_ urls: [URL]) {
        operations.moveToTrash(urls) { reload() }
    }

    /// [FM-14] 完全削除。確認シートは `FolderOperations` 側が出す
    /// [FM-15][PD-02] ため、ここでは対象を渡すだけ。
    private func deletePermanently(_ urls: [URL]) {
        operations.deletePermanently(urls) { reload() }
    }

    /// [FM-01] 新規フォルダ。Finder の `NewFolderWindow` と同じく独立した
    /// ウインドウで名前を尋ねる（`DialogWindowPresenter` 参照）。
    ///
    /// **作成先は `folder` ではなく `currentFolder()` から読む** — このビューは
    /// 値型なので、フォルダを続けて移動した直後は 1 世代古いインスタンスの
    /// クロージャが呼ばれることがあり、`folder` だと移動前の場所に作ってしまう
    /// [1-9 の ⌘↑ 以来、この経路で繰り返し踏んでいる罠]。
    private func presentNewFolderDialog() {
        guard let folder = currentFolder() else { return }
        DialogWindowPresenter.shared.present(
            title: String(localized: "action.newFolder", locale: locale)
        ) { _ in
            NameInputDialog(
                placeholder: String(localized: "folder.namePlaceholder", locale: locale),
                confirmTitle: String(localized: "common.create", locale: locale),
                initialName: String(localized: "action.newFolder", locale: locale)
            ) { name in
                operations.createFolder(named: name, in: folder) { reload() }
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
    /// ベース名を返す（展開先フォルダ名・メニューのラベルに使う）[AR-21]。
    /// 実体はフォルダツリーとの共通層（`FolderOperations`）にある。
    private func archiveBaseName(_ url: URL) -> String {
        FolderOperations.archiveBaseName(url)
    }

    private func extractInPlace(_ urls: [URL]) {
        guard let folder = currentFolder() else { return }
        operations.extract(urls, destination: { _ in folder }) { reload() } // [AR-20]
    }

    private func extractToNamedFolders(_ urls: [URL]) {
        guard let folder = currentFolder() else { return }
        // [AR-21][AR-23]
        operations.extract(urls, destination: { folder.appendingPathComponent(FolderOperations.archiveBaseName($0)) }) { reload() }
    }

    private func extractToChosenDestination(_ urls: [URL]) {
        operations.extractToChosenDestination(urls) { reload() } // [AR-22]
    }

    /// [AR-10] 「ここに圧縮」。単一選択時は項目名、複数選択時はカレント
    /// フォルダ名を既定のアーカイブ名にする。暗号化が有効な場合は
    /// パスワードシートを挟む（判断は `FolderOperations` 側）。
    private func compressHere(_ urls: [URL]) {
        guard let folder = currentFolder() else { return }
        operations.compressHere(urls, into: folder) { selectCompressionResult($0) }
    }

    /// Finder の「パスワード付きで圧縮」（「圧縮」の ⌥ 代替）[Finder 対比監査]。
    private func compressHereWithPassword(_ urls: [URL]) {
        guard let folder = currentFolder() else { return }
        operations.compressHereWithPassword(urls, into: folder) { selectCompressionResult($0) }
    }

    /// [AR-11] ファイル名・保存先を指定するダイアログ。
    private func compressWithDialog(_ urls: [URL]) {
        guard let folder = currentFolder() else { return }
        operations.compressWithDialog(urls, startingIn: folder) { selectCompressionResult($0) }
    }

    /// 圧縮の完了後に、作成されたアーカイブを選択してその位置までスクロール
    /// する [ユーザー要望]。`pendingScrollTarget` を経由するのは「プログラム的な
    /// 選択変更のときだけスクロールする」ため（`.onChange(of: pendingScrollTarget)`
    /// のコメント参照）。
    private func selectCompressionResult(_ url: URL) {
        reload()
        selection = [url]
        pendingScrollTarget = url
    }
}

/// 「アプリケーションで開く」サブメニュー [12章 §12.9、ユーザー要望]。
/// `AppAssociationService.candidates(for:)` を `body` 評価時に同期的に呼ぶ。
///
/// **[実機検証で発見・修正したバグ] 当初は `.task(id: url)` による非同期
/// 読み込みだったが、実際に候補アプリが一切表示されず「その他…」しか
/// 出ない不具合が実機で見つかった。** 一時的な診断ログで `candidates(for:)`
/// 自体は正しい候補（例: mkv → Movist/Infuse/IINA/QuickTime Player 等）を
/// 返していることを確認したため、原因はデータ取得側ではなく描画側——SwiftUI
/// の `Menu`/`.contextMenu` は AppKit の `NSMenu` へブリッジされる際に一度
/// 構築されると、`.task` の完了後に `@State` を更新しても、既に表示（また
/// は表示準備）済みのサブメニューの中身が再構築されないことが原因だった。
/// `candidates(for:)` 自体は `Launch Services` への同期的な問い合わせのみで
/// 実際の非同期処理を伴わないため、`AppAssociationService` 側の型を
/// `async` から同期関数へ変更し、`body` 評価時（＝コンテキストメニューが
/// 実際に構築される時点）に確定させることで解消した。
/// **`private` を外してモジュール内可視にしている** — フォルダツリーの
/// コンテキストメニュー（`FolderTreeContextMenu`）でも同じサブメニューを
/// 使うため [ユーザー要望: ツリーのメニューを中央ペインに原則あわせる。
/// `FolderEntry`/`DropIntoFolderModifier` を `IconGridView` と共有している
/// のと同じパターン]。
struct OpenWithMenu: View {
    @Environment(\.locale) private var locale
    let url: URL
    let isDirectory: Bool

    private let service: AppAssociationService = AppAssociationStore.shared

    /// 「常にこのアプリケーションで開く」を出せる条件 [Finder 対比監査]。
    /// 既定アプリは拡張子ごとに保存する（`AppAssociationService.setPrimary`）
    /// ため、拡張子を持たないフォルダには適用できない。
    private var canSetAsDefault: Bool {
        !isDirectory && !url.pathExtension.isEmpty
    }

    var body: some View {
        // フォルダは拡張子を持たないため `candidates(for:)`（拡張子ベース）
        // ではなく `candidatesForFolders()`（`public.folder` ベース）を使う
        // [ユーザー指摘、`AppAssociationService.candidatesForFolders()` 参照]。
        let candidates = isDirectory ? service.candidatesForFolders() : service.candidates(for: url.pathExtension)
        Menu("folder.openWithSubmenu") {
            items(candidates, setAsDefault: false)
        }
        // Finder と同じく ⌥ でサブメニューごと「常にこのアプリケーションで
        // 開く」に入れ替わる [Finder 対比監査、AS-01]。選んだアプリを
        // qooLibrary 内部の既定アプリとして保存してから開く（macOS システム
        // 全体の関連付けは変更しない、`AppAssociationService` のコメント参照）。
        .modifierKeyAlternate(.option) {
            if canSetAsDefault {
                Menu("folder.alwaysOpenWithSubmenu") {
                    items(candidates, setAsDefault: true)
                }
            }
        }
    }

    @ViewBuilder
    private func items(_ candidates: [AppCandidate], setAsDefault: Bool) -> some View {
        ForEach(candidates) { candidate in
            Button {
                open(with: candidate.bundleID, setAsDefault: setAsDefault)
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
        Button("folder.openWithOtherEllipsis") { chooseOtherApplication(setAsDefault: setAsDefault) }
    }

    /// `setAsDefault` が `true` のときは、開く前にこの拡張子の既定アプリとして
    /// 保存する [AS-01]。保存に失敗しても開く動作自体は続行する — 既定に
    /// できなかったことと、いま開けないことは別の問題のため。
    private func open(with bundleID: String, setAsDefault: Bool) {
        Task {
            if setAsDefault {
                do {
                    try await service.setPrimary(bundleID, for: url.pathExtension)
                } catch {
                    await NotificationRouter.shared.presentError(
                        error, whatHappened: String(localized: "error.setDefaultApplicationFailed", locale: locale)
                    )
                }
            }
            do {
                try await service.open([url], with: bundleID)
            } catch {
                // 以前はここで `try?` により黙って握りつぶしていた
                // [ER-01: 失敗はすべて `NotificationRouter` 経由で提示する]。
                await NotificationRouter.shared.presentError(
                    error, whatHappened: String(localized: "error.openWithApplicationFailed", locale: locale)
                )
            }
        }
    }

    /// Finder の「このアプリケーションで開く > その他…」相当。`setAsDefault`
    /// が `false` なら選んだアプリはこの1回だけ使う（既定として保存するかは
    /// 環境設定「ビューア」タブ、または ⌥ 側の「常に…」の役割）。
    private func chooseOtherApplication(setAsDefault: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = String(localized: "folder.openWithChoosePrompt", locale: locale)
        guard panel.runModal() == .OK, let appURL = panel.url,
              let bundle = Bundle(url: appURL), let bundleID = bundle.bundleIdentifier
        else { return }
        open(with: bundleID, setAsDefault: setAsDefault)
    }
}

struct FolderEntry: Identifiable {
    var id: URL { url }
    let url: URL
    let name: String
    /// **実体がディレクトリか。** パッケージ（`.app` など）もディレクトリなので
    /// ここは `true` になる——「中へ入れるか」は `isNavigableFolder` を見ること。
    let isDirectory: Bool
    /// Finder が「1 つの項目」として扱うディレクトリ [`URLResourceKey.isPackageKey`]。
    /// `.app` / `.photoslibrary` / `.rtfd` / `.bundle` など。
    let isPackage: Bool
    let fileSize: Int64?
    let modificationDate: Date?
    /// Finder の「作成日」列相当 [ユーザー要望: Finder に合わせてカラムを増やす]。
    let creationDate: Date?
    /// Finder の「追加日」列相当（このフォルダへ作成/移動/リネームされた日時）。
    let addedDate: Date?
    let isLocked: Bool
    /// 検索結果のときだけ、**検索の起点フォルダから見た親フォルダの相対パス**
    /// [ユーザー要望: 絞り込まれたファイルがどの階層のものか分かるようにしたい]。
    /// 起点の直下にある項目は空文字（＝「ここ」）。通常の一覧では常に空。
    var relativeLocation: String = ""

    /// **フォルダとして中へ入れるか** [ユーザー要望: `.app` はダブルクリックで
    /// 起動し、中を見るのはコンテキストメニューから]。
    ///
    /// パッケージは実体がディレクトリでも Finder は 1 つの項目として扱う
    /// ——ダブルクリックで起動し、一覧では 1 行、ドロップ先にもならない。
    /// **「実体がディレクトリか」を知りたい箇所（サイズ欄の `—` 表示など）は
    /// `isDirectory` のまま**で、ここを使うのは利用者の操作の行き先を決める
    /// ときだけ。
    ///
    /// 副次的に、写真・ミュージックライブラリ（`.photoslibrary` 等）の中へ
    /// 降りなくなるので、そこで出ていた TCC の許可ダイアログも止まる
    /// [CLAUDE.md に未着手として残っていた件]。
    var isNavigableFolder: Bool { isDirectory && !isPackage }

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
        // パッケージは実体の種別で答える（`.app` なら「アプリケーション」）。
        // 拡張子から引けるので、ここでファイルシステムへ問い合わせ直さない。
        if isDirectory, !isPackage { return String(localized: "kind.folder", locale: locale) }
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
/// `private` を外してモジュール内可視にしている — 表示メニュー
/// （`ViewMenuCommands`）が並び替えの選択肢としてこの `Key` を参照するため
/// [1-16、`FolderEntry`/`DropIntoFolderModifier` と同じ扱い]。
extension FolderSortComparator {
    /// ソート順を覚えておく場所［ユーザー要望、アプリ全体で 1 つ］。
    /// 既存のカラム表示設定と同じ `UserDefaults` 直接読み書きに揃える。
    private static let persistedKeyName = "qoo.folderList.sortKey"
    private static let persistedAscendingName = "qoo.folderList.sortAscending"

    static func loadPersisted() -> [FolderSortComparator] {
        let defaults = UserDefaults.standard
        guard let raw = defaults.string(forKey: persistedKeyName),
              let key = Key(rawValue: raw)
        else { return [FolderSortComparator(key: .name)] }
        // 未設定なら `false` が返るが、その場合は上の `guard` で抜けている。
        let ascending = defaults.bool(forKey: persistedAscendingName)
        return [FolderSortComparator(key: key, order: ascending ? .forward : .reverse)]
    }

    static func persist(_ comparators: [FolderSortComparator]) {
        guard let first = comparators.first else { return }
        UserDefaults.standard.set(first.key.rawValue, forKey: persistedKeyName)
        UserDefaults.standard.set(first.order == .forward, forKey: persistedAscendingName)
    }
}

struct FolderSortComparator: SortComparator {
    /// `String` を rawValue にしているのは、並び順を `UserDefaults` へ
    /// 保存できるようにするため（`ListStyle` と同じ理由）。
    enum Key: String, Hashable, CaseIterable {
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
///
/// **`targetedURL` は呼び出し元と共有するバインディング**［ユーザー要望:
/// リスト表示でファイルをフォルダ行へドラッグしたとき、行全体をハイライト
/// してほしい］。`Table` はカラムごとに独立したセルのため、この modifier は
/// 1行につき（列の数だけ）複数回インスタンス化される——各インスタンスが
/// 自前の `@State` でハイライト状態を持つと、実際にカーソルが乗っている
/// 列のセルしかハイライトされず、他の列（サイズ・種類等）は反応しない。
/// `FolderContentView` 側の1つの `@State`（`dropTargetedFolderURL`）を
/// 全列で共有することで、どの列にカーソルがあっても行全体が反応する。
///
/// **[修正] 半透明の背景色オーバーレイでは、列ごとの隙間のせいでハイライトが
/// 分割されて見え、かつ色も薄くて見づらいという指摘を受けた。** 「ドラッグ先
/// として選択している、という意味では間違っていない」というユーザー判断で、
/// `Table` の場合は独自の背景描画をやめ、代わりに通常の選択（`selection`）と
/// 全く同じ見た目（`Table` がネイティブに描画する、列をまたいで連続した
/// ハイライトバー）を一時的に流用する方式にした——`FolderContentView` 側で
/// `dropTargetedFolderURL` の変化を監視し、ドラッグ中だけ `selection` を
/// 対象フォルダに差し替え、ドラッグが終わったら元の選択に戻す
/// （`selectionBeforeDropHighlight` 参照）。`paintsBackgroundHighlight` を
/// `false` にするとこの modifier 自身は背景を描画しなくなる。アイコン表示
/// （`IconGridView`）は1セル＝1エントリのため列分割の問題が無く、引き続き
/// 独自の背景ハイライト（既定 `true`）を使う。
struct DropIntoFolderModifier: ViewModifier {
    let entry: FolderEntry
    /// 衝突の判断・進捗・キャンセルを担う共有レイヤ [FM-11][UI-09]。
    let operations: FolderOperations
    let reload: () -> Void
    let onFailure: @MainActor @Sendable (String) -> Void
    @Binding var targetedURL: URL?
    var paintsBackgroundHighlight: Bool = true

    func body(content: Content) -> some View {
        // パッケージはドロップ先にしない（Finder と同じ）。実体はディレクトリ
        // なので落とせてしまうが、アプリの中へ物を入れるのは事故でしかない。
        if entry.isNavigableFolder {
            content
                .background(
                    paintsBackgroundHighlight && targetedURL == entry.url
                        ? Tokens.Colors.accent.opacity(0.15) : Color.clear
                )
                .dropDestination(for: URL.self) { items, _ in
                    DropHandling.performDrop(items, into: entry.url, operations: operations, onComplete: { reload() }, onFailure: onFailure)
                    return true
                } isTargeted: { targeted in
                    if targeted {
                        targetedURL = entry.url
                    } else if targetedURL == entry.url {
                        // 別の列（同じ行）の enter が先に発火して既に自分の URL で
                        // 上書きされている場合は誤って消さない。
                        targetedURL = nil
                    }
                }
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
                        // `displayName(atPath:)` を直接呼ばない [NV6-02] — `body` からの
                        // 評価で、しかもパス成分の数だけ呼ばれるため、応答しない共有では
                        // 描画のたびにその本数ぶんメインスレッドが止まる。
                        Text(DisplayNameCache.shared.name(for: url))
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

