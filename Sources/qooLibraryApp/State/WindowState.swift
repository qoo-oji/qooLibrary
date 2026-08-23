import Foundation
import QooApplication
import QooInfrastructure
import SwiftUI

/// 現在のタブがどちらの入口から辿り着いたかを表す [ユーザー要望: 実体として
/// 同じフォルダでも、ボリューム経由かライブラリ／テンポラリフォルダ経由かで
/// 「フォルダツリーのどのグループが反応するか」「『上の階層へ』で登録
/// フォルダの外へ出られるか」を分けたい]。フォルダの URL だけでは
/// （フォルダツリーで手動でボリュームを辿って登録フォルダと同じ実フォルダに
/// たどり着くこともあり得るため）どちらの入口から来たか判別できないため、
/// タブの状態として明示的に持ち回る。
///
/// **`Codable`/`Hashable` にしているのは `TabTarget` の一部として
/// `WindowGroup(for:)` の値になるため** [ネイティブタブ移行]。新しいタブを
/// 開くときに入口の文脈も一緒に運ぶ必要がある。
public enum NavigationRoot: Sendable, Hashable, Codable {
    case volume
    /// フォルダツリーの「よく使う項目」グループ経由 [ユーザー要望]。
    /// アプリケーション・ホーム・デスクトップなど、環境設定で表示を選べる
    /// 標準の場所が並ぶ枝（`FavoriteLocations`）。
    ///
    /// **ボリューム経由と分ける理由は、登録フォルダのときとまったく同じ。**
    /// 実体としては同じ `~/Downloads` でも、よく使う項目から入ったのか
    /// Macintosh HD を手で辿って来たのかで、①ツリーのどのグループが自動展開
    /// されるか ②⌘↑ でホームより上へ出られるか、が変わる。
    ///
    /// **`.registeredFolder` と違い根の URL を持たない。** 根になり得る場所は
    /// `FavoriteLocations.visible` から引けるので、持たせても「どの値が正か」を
    /// 照合する必要が生まれるだけで得るものが無い。
    case favorites
    case registeredFolder(id: UUID, rootURL: URL)

    /// 登録フォルダ経由なら登録 ID。ボリューム／よく使う項目経由なら `nil`。
    /// ラベルフィルタがライブラリを解決するのに使う [LF-01]。
    public var registrationUUID: UUID? {
        if case .registeredFolder(let id, _) = self { return id }
        return nil
    }
}

/// 新しいタブ／ウインドウの行き先 [ネイティブタブ移行]。
///
/// `WindowGroup(for:)` に渡す値。**`URL` 単体ではなく `NavigationRoot` も
/// 運ぶ**——以前は「新規ウインドウで開く」だけが `WindowGroup(for: URL.self)`
/// の制約で入口を引き継げないという既知の制限だったが、タブも同じ仕組みに
/// 乗せる以上「新規タブで開く」まで文脈を失うのは受け入れられないため、
/// 値型を拡張した。
public struct TabTarget: Sendable, Hashable, Codable {
    public var url: URL?
    public var navigationRoot: NavigationRoot
    /// **同じ行き先でも毎回新しいタブを開くための一意な印** [実機検証で発見]。
    ///
    /// `openWindow(value:)` は、その値を既に表示しているウインドウがあれば
    /// **新しいシーンを作らずそれを前面に出すだけ**という仕様。これが無いと
    /// ⌘T を 2 回押しても（どちらも行き先がホームなので）タブが 1 つしか
    /// 増えず、同じフォルダを「新規タブで開く」も 2 回目以降が効かない。
    /// 生成のたびに異なる値を持たせることで、常に新しいタブになる。
    public var instanceID: UUID

    public init(url: URL?, navigationRoot: NavigationRoot = .volume, instanceID: UUID = UUID()) {
        self.url = url
        self.navigationRoot = navigationRoot
        self.instanceID = instanceID
    }

    /// ⌘T・タブバーの ＋・Dock からの起動などで開く既定の行き先。
    ///
    /// **実ホーム**［ユーザー判断、1-16 移動メニューの Finder 準拠］。読めない
    /// ときだけ仮想ホームへ落ちる（`StandardLocation.defaultHome` 参照）。
    ///
    /// 入口は `StandardLocation.homeDestination` が決める——「よく使う項目」に
    /// ホームを表示していればその行がフォーカスされ、隠していればボリューム
    /// ツリー側が反応する [ユーザー要望・ユーザー判断]。
    public static var home: TabTarget {
        let destination = StandardLocation.homeDestination
        return TabTarget(url: destination.url, navigationRoot: destination.navigationRoot)
    }
}

/// 戻る/進む履歴の1件 [KB-02 相当]。フォルダ URL だけでなく `NavigationRoot`
/// も一緒に記録し、戻る/進むで当時の文脈も正しく復元する。
struct TabHistoryEntry: Sendable, Equatable {
    let url: URL
    let navigationRoot: NavigationRoot
}

public enum DisplayMode: Sendable, Equatable {
    case folder // [VM-01 以降] ライブラリ表示モードは 2-9 でラベル基盤ができてから
}

/// `String` を rawValue にしているのは、1-12 環境設定「表示」タブの既定表示
/// モード設定を `@AppStorage` で直接扱えるようにするため（`RawRepresentable`
/// かつ `RawValue == String` であれば `@AppStorage` が素直に対応する）。
public enum ListStyle: String, Sendable, Equatable {
    case icon, list // [LV-04]
}

/// ウインドウ固有状態 [11章 §11.4 状態の 3 分類]。**DB に保存しない** [ST-20]。
///
/// **1 ウインドウ ＝ 1 タブ** [ネイティブタブ移行、ユーザー要望「Finder と同じ
/// タブおよびタブバーの外観・仕様にしたい」]。以前はこの型が `tabs: [TabState]`
/// を抱え、独自の `TabBarView` がそれを描いていたが、**Finder のタブはそもそも
/// macOS ネイティブのウインドウタブそのもの**で、独自実装を Finder に似せる
/// 方向には勝ち目が無い（材質・アニメーション・ドラッグ挙動まで含めて）。
/// ネイティブタブでは 1 つのタブが 1 つの `NSWindow` ＝ この `WindowState` の
/// 1 インスタンスに対応するため、タブの配列そのものが不要になった。
/// タブを束ねる役目は `WindowTabJoiner` が持つ。
///
/// この移行で **MW-03（タブのドラッグによる並べ替え・別ウインドウへの移動）が
/// 自動的に満たされた**——独自タブバーでは未実装のまま残っていた要件。
///
/// [ST-22 の変更] `listStyle`/`iconSize` は以前「ウインドウ単位でタブ間共有」
/// だったが、1 ウインドウ＝1 タブになったことで**タブごと**になった。
/// **Finder も表示モードはタブごとに記憶する**ため、Finder 準拠としてはむしろ
/// 正しくなっている [ユーザー承認済みの仕様変更、`docs/Specifications/11_アプリ層_コマンドとロック.md` 更新済み]。
@MainActor
@Observable
public final class WindowState {
    public var folder: URL?
    /// ウインドウ／タブのタイトル。`MainWindowView` が `.navigationTitle` に
    /// 渡し、**それがそのままネイティブタブのタイトルになる**（Finder と同じく
    /// フォルダ名がタブに出る）。
    public var title: String
    public var selection: Set<URL> = []
    public var searchText: String = ""
    /// 現在のフォルダがどちらの入口から辿り着いたか [`NavigationRoot` 参照]。
    public var navigationRoot: NavigationRoot = .volume
    /// 戻る/進む用の履歴 [KB-02 相当、Finder ツールバーの矢印ボタンと同等の機能]。
    /// タブごとに独立する（＝ウインドウごと。ネイティブタブでは同じこと）。
    var backHistory: [TabHistoryEntry] = []
    var forwardHistory: [TabHistoryEntry] = []
    /// 「戻る」「1階層上へ」で親フォルダへ移動したとき、直前までいた
    /// フォルダまで中央ペインをスクロールさせるための一時的な信号
    /// [ユーザー要望]。ハイライト自体は `selection` を直接更新するだけで
    /// 済むが、スクロールは `FolderContentView` 側の `pendingScrollTarget`
    /// （「ここに圧縮」で確立済みの、ユーザー自身のクリックとプログラム的な
    /// 選択変更を区別する仕組み）に伝える必要があるため、この専用フィールドで
    /// 橋渡しする。`FolderContentView` が消費後に `nil` へ戻す。
    public var pendingRevealURL: URL?
    /// 直前の移動が**フォルダツリー由来**か [ユーザー要望: ツリーを矢印で
    /// 辿りたい]。
    ///
    /// 中央ペインは移動のたびにキーボードフォーカスを取り戻す（⌘↑ や戻る／
    /// 進むの直後に矢印キーが効かなくなる不具合への対処）。だがツリーから
    /// 移動したときにそれをやると、**1 回動いた時点でフォーカスがツリーから
    /// 奪われ、2 回目の矢印が効かない**。ツリー由来の移動ではフォーカスを
    /// そのままにする。
    public var navigationCameFromTree = false
    public var displayMode: DisplayMode = .folder // [ST-22]
    // 既定は `.list`。1-12 で、この既定値自体を環境設定「表示」タブから変更
    // できるようにした（`DisplayPreferencesTab.swift` 参照）。ウインドウ固有
    // 状態自体は引き続き DB に保存しない [ST-20] が、「次に開くウインドウの
    // 既定値」だけは `UserDefaults` から `init` 時に一度だけ読む
    // （`MainWindowView.init` の `isRightPaneCollapsed` と同じ「素の値を一度
    // だけ読む」パターン。`@AppStorage` を `if` 条件内で直接使うと SwiftUI の
    // Observation が無限に再評価を繰り返す不具合を実機検証で確認済みのため、
    // そのパターンは避けている）。
    public var listStyle: ListStyle // [LV-04]
    /// ラベルフィルタ [LF-01〜LF-14]。**ウインドウ固有** [ST-21][LF-06]
    /// ——選択は DB に保存せず、同じライブラリを 2 枚開けば別々に絞れる。
    /// ピン留めとグループの並び順だけは全ウインドウ共有 [ST-23]。
    public let labelFilter = LabelFilterModel()
    public var iconSize: Double // [IV-04]

    public init(target: TabTarget = .home) {
        self.folder = target.url
        self.navigationRoot = Self.normalizedRoot(target.navigationRoot, for: target.url)
        self.title = target.url?.lastPathComponent ?? String(localized: "action.newTab", locale: AppLanguage.effectiveLocale)
        self.listStyle = Self.loadDefaultListStyle()
        self.iconSize = Self.loadDefaultIconSize()
    }

    private static let defaultListStyleKey = "qoo.preferences.defaultListStyle"
    private static let defaultIconSizeKey = "qoo.preferences.defaultIconSize"

    private static func loadDefaultListStyle() -> ListStyle {
        UserDefaults.standard.string(forKey: defaultListStyleKey).flatMap(ListStyle.init(rawValue:)) ?? .list
    }

    private static func loadDefaultIconSize() -> Double {
        let stored = UserDefaults.standard.double(forKey: defaultIconSizeKey)
        return stored > 0 ? stored : 96
    }

    /// このタブの表示先を変更する。フォルダツリーでの選択 [LP-06] と中央ペイン
    /// でのフォルダ移動（ダブルクリック・Enter・1階層上に戻る等）の両方から使う
    /// 共通経路。呼ぶたびに戻る履歴へ積み、進む履歴は破棄する（ブラウザ・Finder と
    /// 同じ規則）。`goBack`/`goForward` 自身はこのメソッドを経由しない
    /// （履歴を壊さずに移動するため）。
    ///
    /// `root` は `NavigationRoot` を明示的に切り替えたいとき（フォルダツリーの
    /// ボリューム行／登録フォルダ行をクリックしたとき）だけ渡す。`nil`
    /// （既定）は「現在の文脈を引き継ぐ」ことを意味し、中央ペインでの
    /// ダブルクリック・Enter・「1階層上へ」など、ツリーを経由しないナビゲー
    /// ションではこちらを使う。
    /// - Parameter fromTree: フォルダツリーの選択に由来する移動か
    ///   [`navigationCameFromTree` 参照]。
    public func navigate(to url: URL, root: NavigationRoot? = nil, fromTree: Bool = false) {
        navigationCameFromTree = fromTree
        let resolvedRoot = Self.normalizedRoot(root ?? navigationRoot, for: url)
        if let current = folder, current != url {
            backHistory.append(TabHistoryEntry(url: current, navigationRoot: navigationRoot))
            forwardHistory.removeAll()
        }
        folder = url
        title = url.lastPathComponent
        navigationRoot = resolvedRoot
        searchText = "" // [1-16] 移動したら絞り込みは解除する（Finder と同じ）
        // 「最近使ったフォルダ」[1-16 移動メニュー]。**`goBack`/`goForward` は
        // この経路を通らないため履歴に積まれない** — 履歴を行き来しただけで
        // 「最近使った」一覧の順序が入れ替わるのは Finder の挙動とも直感とも
        // ずれるため、意図してこの共通経路だけに置いている。
        RecentFoldersStore.shared.record(url)
    }

    /// 入口と行き先の不変条件を保つ [`NavigationRoot.favorites` 参照]。
    ///
    /// **`.favorites` を名乗れるのは、いま表示している「よく使う項目」の
    /// いずれか、またはその配下だけ。** よく使う項目の行から入っても、
    /// エイリアスやシンボリックリンクを開けばその外へ出られるし、環境設定で
    /// その項目を非表示にすれば行そのものが消える。そのまま `.favorites` を
    /// 名乗り続けると、ツリーの自動展開が
    /// 対応する行を見つけられずファイルシステムルートまで祖先を遡り、
    /// **`/`（＝ Macintosh HD の行 ID）を展開してしまう** — 選んでもいない
    /// ボリュームのツリーが開く、という形で現れる。外へ出たらボリューム経由に
    /// 戻すのが、実際の居場所とも一致する。
    ///
    /// この欠陥は実装後に純粋関数を孤立スクリプトで検証して見つけた。
    /// 同じ形（打ち切り位置を誤って `/` まで遡る）をこのコードベースは
    /// 既に 2 度踏んでおり [1-12 の登録フォルダ、1-16 の外部ボリューム]、
    /// **展開側にも防御を置いてある**（`FolderTreePane.revealSelectionIfNeeded`）
    /// ——砦は 2 枚あってよい。
    ///
    /// **`.registeredFolder` には同じ正規化を掛けない。** 登録フォルダは実体が
    /// 動く・消えることがあり、そこで入口まで黙って変わると「1 階層上へ」の
    /// 境界が予告なく緩む。あちらの縮退は `RegisteredFolderStore` の状態管理
    /// [1-17] が別に面倒を見ている。
    static func normalizedRoot(_ root: NavigationRoot, for url: URL?) -> NavigationRoot {
        guard root == .favorites else { return root }
        guard let url else { return .volume }
        // 照合は成分の境界で行う（素の `hasPrefix` だと `/Users/uu` が
        // `/Users/u` を覆う）——`FavoriteLocations.root(containing:in:)` が担う。
        return FavoriteLocations.containingVisibleRoot(of: url) != nil ? .favorites : .volume
    }

    // 移動メニューの「ホーム」は `StandardLocation.home` として
    // `StandardLocationOpener` が扱う（未許可ならパネルを出してから移動する）
    // ので、ここに専用のメソッドは持たない。
    //
    // **「ホーム」は実ホームを指す**［ユーザー判断、1-16 移動メニューの Finder
    // 準拠］。以前は仮想ホーム（サンドボックスコンテナ）だったが、標準の場所
    // （書類・デスクトップ等）を並べるにあたり「ホームの中の書類」と
    // 「移動 > 書類」が別の場所を指す矛盾が生じるため統一した。仮想ホームの
    // 中身は実ホームとほぼ同じで（Desktop/Downloads/Movies/Music/Pictures は
    // いずれも実物へのシンボリックリンク）、実際に違うのはコンテナ専用の
    // Documents と Library だけ——どちらもアプリの内部実装領域なので失うものは
    // 無い。

    public var canGoBack: Bool { !backHistory.isEmpty }
    public var canGoForward: Bool { !forwardHistory.isEmpty }

    /// サンドボックスの仮想ホーム（`~/Library/Containers/<bundle-id>/Data`、
    /// `FileManager.homeDirectoryForCurrentUser` が返す値 [1-3 の実機検証で
    /// 確認済み]）。この 1 つ上（コンテナ本体のルート）はアプリの内部実装領域で
    /// サンドボックスプロファイルが読み取りを許可しない
    /// [実機検証で発見: Documents から ⌘↑ を連打すると "permission to view it"
    /// エラーになっていた]。
    private static let sandboxHomeDirectory = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL

    /// 仮想ホームより上には昇らない（昇っても読めない場所しかなく、
    /// ユーザーにとって意味のある行き先ではないため）。**登録フォルダ
    /// （ライブラリ／テンポラリ）経由でたどり着いた場合は、その登録ルートより
    /// 上にも昇らない**［ユーザー要望: 登録フォルダはそこが最上位として扱われ
    /// てほしい。ボリューム経由で実体として同じ場所に来た場合はこの制限を
    /// 適用しない — `navigationRoot` で入口を区別しているため、同じ URL でも
    /// 挙動が変わり得る、意図した設計]。
    public var canGoToParent: Bool {
        guard let folder else { return false }
        if folder.standardizedFileURL == Self.sandboxHomeDirectory { return false }
        // よく使う項目から入ったときは**実ホームが天井** [ユーザー判断]。
        // ダウンロードから ⌘↑ でホームへは上がれるが、ホームからは上がれない
        // ——その上（`/Users`）は許可も無く、蔵書管理アプリで開く意味も薄い。
        //
        // `/Applications` のように実ホーム配下でない項目には天井が無い
        // （⌘↑ で `/` へ抜けられる）。そこで止めても得るものが無いため
        // [設計判断]。
        if navigationRoot == .favorites,
           folder.standardizedFileURL == StandardLocation.realHome.standardizedFileURL {
            return false
        }
        if case .registeredFolder(_, let rootURL) = navigationRoot,
           folder.standardizedFileURL == rootURL.standardizedFileURL {
            return false
        }
        return true
    }

    /// Finder ツールバーの「戻る」相当 [KB-02]。
    ///
    /// **移動先が直前までいたフォルダの親であれば、そのフォルダをハイライト
    /// してスクロールする**［ユーザー要望］。「戻る」は必ずしも親フォルダへ
    /// 移動するとは限らない（履歴上の任意のフォルダへ戻り得る）ため、移動先が
    /// 実際に親であるときだけ発動する条件付きの挙動にしている。
    public func goBack() {
        guard let previous = backHistory.popLast() else { return }
        let leavingFolder = folder
        if let current = folder {
            forwardHistory.append(TabHistoryEntry(url: current, navigationRoot: navigationRoot))
        }
        folder = previous.url
        navigationRoot = previous.navigationRoot
        title = previous.url.lastPathComponent
        searchText = "" // [1-16]
        revealIfParent(of: leavingFolder, newFolder: previous.url)
    }

    /// Finder ツールバーの「進む」相当 [KB-02]。
    public func goForward() {
        guard let next = forwardHistory.popLast() else { return }
        if let current = folder {
            backHistory.append(TabHistoryEntry(url: current, navigationRoot: navigationRoot))
        }
        folder = next.url
        navigationRoot = next.navigationRoot
        title = next.url.lastPathComponent
        searchText = "" // [1-16]
    }

    /// `⌘↑` 相当 [KB-02]。`goBack`/`goForward` と同じく `navigate(to:)` を
    /// 経由する（履歴に積む）。
    ///
    /// **`FolderContentView` ではなくここに実装している**
    /// [実機検証で発見したバグの修正]: 以前は `FolderContentView`（値型の
    /// View）が自身の `folder: URL?` プロパティを直接読んで計算していたが、
    /// `.background` 内の非表示ボタンに束縛されたクロージャが、フォルダを
    /// 連続でナビゲートした直後は1回分古い `FolderContentView` インスタンスの
    /// `folder` を参照してしまうことがあり（`Documents/Dummy` にいるつもりで
    /// ⌘↑ を押すと `Documents` を素通りして仮想ホームまで戻ってしまっていた）、
    /// 実際には「1回の入力で2回移動した」のではなく「1回移動を、1段階古い
    /// 位置から行った」結果だった。`WindowState`（`@Observable` の参照型）の
    /// メソッドにすれば常に最新状態を読める。
    ///
    /// **移動元のフォルダをハイライトしてスクロールする**［ユーザー要望、
    /// `goBack()` と同じ。こちらは常に親フォルダへの移動のため無条件］。
    public func goToParent() {
        guard canGoToParent, let folder else { return }
        let parent = folder.deletingLastPathComponent()
        navigate(to: parent)
        selection = [folder]
        pendingRevealURL = folder
    }

    /// 「上の階層」を別のウインドウ／タブで開くための行き先
    /// [1-16 移動メニューの Finder 準拠、⌃⌘↑ と ⌥⌘↑ 用]。
    ///
    /// `canGoToParent` と全く同じ条件で `nil` になるので、境界（仮想ホーム・
    /// 登録フォルダの根）の扱いが `goToParent()` とずれない。
    public var parentTarget: TabTarget? {
        guard canGoToParent, let folder else { return nil }
        return TabTarget(url: folder.deletingLastPathComponent(), navigationRoot: navigationRoot)
    }

    /// 表示中のフォルダ自体が消えていたら、存在する直近の祖先へ静かに移動して
    /// `true` を返す。消えていなければ何もせず `false`。
    ///
    /// 表示中のフォルダをゴミ箱に入れる・名前を変更する経路はツリーからも
    /// 中央ペインからも届く（他ウインドウでの操作・Finder 側での削除でも同じ
    /// ことが起きる）ため、**発生源ごとに手当てするのではなく、実際に読み込みに
    /// 失敗した `FolderContentView.reload()` の 1 箇所から呼ぶ**ことで、経路に
    /// 関わらず自己修復する。
    ///
    /// - 履歴には積まない（消えた場所へ「戻る」ことに意味が無いため）。
    ///   併せて、既に積まれている履歴のうち実体を失ったものも取り除く。
    /// - 名前変更の場合、Finder はウインドウを新しい名前へ追従させるが、
    ///   それには変更前後を同一視するファイル ID の追跡（2-2 の
    ///   `FSEventsWatcher`/`IdentityResolver`）が要る。フェーズ1では
    ///   「親フォルダへ退避する」という安全側の単純な挙動に留める [設計判断]。
    /// **判定に要る `fileExists` はまとめて 1 回、メインスレッドの外で行う**
    /// [NV6-02]。表示中のフォルダ・その祖先・履歴に積まれた項目と、確かめる
    /// 相手が多いうえ、ここへ来るのは「読み込みに失敗した」直後——つまり
    /// 相手が応答しない可能性がいちばん高い場面である。1 件ずつメインスレッドで
    /// 確かめると、そこがそのままビーチボールになる。
    @discardableResult
    public func relocateIfFolderVanished() async -> Bool {
        guard let folder else { return false }
        let candidates: [String] = [folder.standardizedFileURL.path]
            + Self.ancestorPaths(of: folder)
            + backHistory.map(\.url.standardizedFileURL.path)
            + forwardHistory.map(\.url.standardizedFileURL.path)
        let existing = await FileIO.perform { Self.existingPaths(among: candidates) }
        return relocateIfFolderVanished(knownToExist: existing)
    }

    /// 実体の有無を調べ終えたうえでの判定と適用。**ここはメインアクタで、
    /// I/O は 1 つも行わない**（`mountedVolumeURLs` はマウント表を読むだけで
    /// ネットワークへは出ない）。
    @discardableResult
    func relocateIfFolderVanished(knownToExist existing: Set<String>) -> Bool {
        guard let folder else { return false }
        guard !existing.contains(folder.standardizedFileURL.path) else { return false }
        // **ボリュームが外れているだけなら退避しない** [RG3-06][NV-93]。
        //
        // 退避は「削除・改名で行き先を失った」ときの救済であって、
        // 「ボリュームが一時的に外れた」ときの正しい応答ではない。
        // 外れただけなら**挿し直せば戻れる**のに、ここで祖先へ移動して
        // しかも履歴から実在しない項目を取り除いてしまうと、**接続し直しても
        // 元の場所へ戻れなくなる**（[SB-05] に正面から反する）。
        //
        // ネットワークボリュームでは切断が例外ではなく通常状態なので
        // （8章 §8.11）、これは稀な事故ではなく日常的に踏まれる。
        guard !Self.isOnAnUnmountedVolume(folder) else { return false }
        // **退避先は登録ルートで止める** [RG3-06]。ライブラリ／テンポラリ経由で
        // 開いているタブは、その登録フォルダが「最上位」として振る舞う
        // （`canGoToParent` が同じ境界で ⌘↑ を止めている）。退避だけがその境界を
        // 越えて外へ出ると、「⌘↑ では出られないのに、中のフォルダを消したら
        // 勝手に外に出た」という食い違いになる。
        //
        // ボリューム経由（`.volume`）のタブには境界が無いので、従来どおり
        // ファイルシステムのルートまで遡ってよい。
        let ancestors = Self.ancestorPaths(of: folder)
        // **境界が現在地を実際に含んでいるときだけ適用する** [レビューで発見]。
        // `navigationRoot` は「どの入口から来たか」を持ち回る値で、パスバーで
        // 登録ルートより上の階層へ移ったり、`relocate` で登録先が変わったり
        // すると、`.registeredFolder` のまま現在地が `rootURL` の外に出る。
        // その状態で無条件に絞ると候補が空になり、**自己修復そのものが
        // 黙って働かなくなる**——タブが読み込みエラーのまま行き止まりになる。
        let floor: String? = {
            guard case .registeredFolder(_, let rootURL) = navigationRoot else { return nil }
            let root = rootURL.standardizedFileURL.path
            guard ancestors.contains(root) else { return nil }
            return root
        }()
        let reachable = ancestors.filter { path in
            guard let floor else { return true }
            return path == floor || path.hasPrefix(floor + "/")
        }
        guard let target = reachable.last(where: { existing.contains($0) })
            .map({ URL(fileURLWithPath: $0) })
        else { return false }
        self.folder = target
        title = target.lastPathComponent
        selection = []
        searchText = "" // [1-16]
        backHistory.removeAll { !existing.contains($0.url.standardizedFileURL.path) }
        forwardHistory.removeAll { !existing.contains($0.url.standardizedFileURL.path) }
        return true
    }

    /// 渡されたパスのうち、実際に存在するもの。**この関数がこの経路で唯一
    /// I/O を行う場所**で、`FileIO.perform` の中からのみ呼ぶ [NV6-02]。
    nonisolated static func existingPaths(among paths: [String]) -> Set<String> {
        var result: Set<String> = []
        for path in paths where FileManager.default.fileExists(atPath: path) {
            result.insert(path)
        }
        return result
    }

    /// `url` が、いま接続されていないボリューム上を指しているか [NV-93]。
    ///
    /// **マウント一覧と突き合わせるだけで判定する。** ブックマークを解決したり
    /// パスを触ったりしない——RG3-01 の判定順序と同じ理由で、**判定の過程で
    /// ボリュームをマウントしてしまう**ことを避けるため（8章 §8.7.1 BM-5）。
    /// ネットワークではその副作用が「接続タイムアウト分のブロック」と
    /// 「認証ダイアログ」を意味する。
    ///
    /// `/Volumes/…` 配下でなければ（＝起動ボリューム上なら）常に `false`。
    /// **判定できないときは `true`（外れている扱い）に倒す** ——
    /// 退避させないほうが害が小さいため。誤って `false` に倒すと、
    /// 繋がっているのに履歴ごと捨ててしまう [SB-05]。
    ///
    /// - Important: ここには以前「判定できないときは `false` に倒す」と
    ///   書いてあったが、委譲先の実際の向きは逆である。**同じ変更で
    ///   `RegisteredFolderStore` の食い違いを直しておきながら、
    ///   こちらに新しい食い違いを作っていた**（レビューで指摘された）。
    ///   これを信じて `MountTable` 側を「直す」と NV-93 が再発する。
    ///
    /// 判定そのものは ``MountTable`` が持つ [NV-93]。ここで自前に書き直さない
    /// ——同じ「マウント表と突き合わせる」処理がアプリ層とインフラ層に
    /// 二重にあると、片方だけ直したときに静かにずれる。
    ///
    /// 共通化して得たもの: ①入れ子のマウント（`/Volumes/.timemachine/<UUID>/…`
    /// のように入口が `/Volumes/<名前>` より深い形）を正しく扱えるようになった
    /// ②`getmntinfo(MNT_NOWAIT)` になり、どのファイルシステムにも
    /// 問い合わせないことが型の側で保証される ③テストが付いた。
    static func isOnAnUnmountedVolume(_ url: URL) -> Bool {
        MountTable.current().isOnAnUnmountedVolume(url)
    }

    /// `url` の祖先のパス（`url` 自身は含まない）。浅い順。
    ///
    /// **`URL.deletingLastPathComponent()` を繰り返す実装にしない** — ルート
    /// `/` に対して呼ぶと `/` 自身ではなく `/..` を返すことがある（Apple の
    /// ドキュメントに明記された挙動で、本プロジェクトでは 1-8 のパスバーと
    /// `FolderTreePane.ancestorPaths` で 2 度、無限ループとして踏んでいる）。
    /// `PathBarView.pathComponents` と同じく `pathComponents` から積み上げる。
    ///
    /// **実体の有無はここでは見ない** — I/O は `existingPaths(among:)` に
    /// 集めてあり、そちらは `FileIO` の中で 1 回だけ走る [NV6-02]。
    nonisolated static func ancestorPaths(of url: URL) -> [String] {
        let components = url.standardizedFileURL.pathComponents
        guard let first = components.first else { return [] }
        var current = URL(fileURLWithPath: first)
        var ancestors = [current.path]
        for component in components.dropFirst() {
            current = current.appendingPathComponent(component)
            ancestors.append(current.path)
        }
        return ancestors.dropLast()
    }

    /// `leavingFolder` が `newFolder` の直下（親子関係）である場合だけ、
    /// `leavingFolder` を選択・スクロール対象にする [`goBack()`/`goToParent()`
    /// 共通のヘルパー]。
    private func revealIfParent(of leavingFolder: URL?, newFolder: URL) {
        guard let leavingFolder,
              leavingFolder.deletingLastPathComponent().standardizedFileURL == newFolder.standardizedFileURL
        else { return }
        selection = [leavingFolder]
        pendingRevealURL = leavingFolder
    }

    /// ライブラリ根から見た現在フォルダの相対パス [VM-02][LF-14]。
    ///
    /// DB の `relativePath` と同じ綴り方（根を剥がしただけ、先頭に `/` を付けない。
    /// 根そのものなら空文字）にする——`LibraryEnumerator.snapshot` がそう作る。
    ///
    /// **現在地が根の配下に無ければ `nil`**。`navigationRoot` は「どの入口から
    /// 来たか」を持ち回る値なので、パスバーで登録ルートより上へ移ったり
    /// `relocate` で登録先が変わったりすると `.registeredFolder` のまま外に出る
    /// （`relocateIfFolderVanished` が同じ配慮をしている）。その状態で相対パスを
    /// 作ると、まったく無関係な場所を指す文字列ができる。
    public var libraryRelativePath: String? {
        guard case .registeredFolder(_, let rootURL) = navigationRoot,
              let folder else { return nil }
        let root = rootURL.standardizedFileURL.path
        let current = folder.standardizedFileURL.path
        if current == root { return "" }
        guard current.hasPrefix(root + "/") else { return nil }
        return String(current.dropFirst(root.count + 1))
    }

    /// このタブの現在地を、新しいタブ／ウインドウの行き先として表す。
    /// 「新規タブで開く」などが入口の文脈ごと引き継ぐために使う。
    public func target(for url: URL) -> TabTarget {
        TabTarget(url: url, navigationRoot: navigationRoot)
    }

    // MARK: - サムネイル表示 [DS-01][DS-04][DS-06][DS-07]

    /// サムネイルを隠している理由。隠していなければ `nil`。
    ///
    /// **実効値の判定がここにあるのは、判断材料が 2 つに分かれているから**:
    /// 全体トグル（`ThumbnailVisibility`、アプリ全体）と、登録フォルダごとの
    /// 強制非表示（`RegisteredFolderIndex`）で、後者は「今どの入口から入った
    /// タブなのか」（`navigationRoot`）を知らないと引けない。その文脈を持つ
    /// のはこの型だけなので、合成もここで行い、UI 各所へは合成済みの値だけを
    /// 配る（同じ合成を複数箇所に散らさない）。
    ///
    /// どちらも `@Observable` な状態を読むため、SwiftUI の `body` から読めば
    /// 変化に追従する [DS-03 の「全ウインドウ・全タブに即座に反映」]。
    public var thumbnailHiddenReason: ThumbnailHiddenReason? {
        // **登録フォルダ側を先に見る。** 両方効いている場合、ユーザーがこの
        // ウインドウで全体トグルを戻しても表示は変わらない——「なぜ隠れて
        // いるのか」として案内すべきは、その動かない側 [DS-07]。
        if case .registeredFolder(let id, _) = navigationRoot,
           let entry = RegisteredFolderIndex.shared.entry(id: id),
           entry.thumbnailsAlwaysHidden {
            return .registeredFolder(displayName: entry.displayName)
        }
        return ThumbnailVisibility.shared.isGloballyHidden ? .globalToggle : nil
    }

    /// このウインドウでサムネイル・カバー画像を出すか [DS-01][DS-04]。
    public var areThumbnailsHidden: Bool { thumbnailHiddenReason != nil }
}

/// サムネイルが隠れている理由 [DS-07: 「非表示になっている理由が分かる
/// ようにする」]。
public enum ThumbnailHiddenReason: Sendable, Equatable {
    /// アプリ全体のトグル（⌃⌘I・表示メニュー・ステータスバー）で隠している。
    case globalToggle
    /// この登録フォルダが「常に非表示」に設定されている [DS-04]。
    case registeredFolder(displayName: String)
}

/// セッション一時状態 [11章 §11.4]。メモリのみ、DB にもウインドウ復元にも
/// 含めない [ST-20]。`LockManager`/`CommandStack` 相当のドメイン型がまだ
/// 存在しないため、アプリ全体で 1 つ生成される器だけをこのフェーズで用意する。
@MainActor
@Observable
public final class SessionState {
    public static let shared = SessionState()
    private init() {}

    /// **ファイルの中身以外の理由**で、表示しているものを読み直す必要が
    /// 生じたときに増やす、アプリ全体で 1 つの信号。
    ///
    /// ファイルの追加・削除・改名・書き換えは**ここでは扱わない**
    /// [10章 §10.0]。それらは `DirectoryChangeHub` が、影響を受けるフォルダを
    /// 表示している場所だけへ届ける（アプリの外で起きた変更も同じ経路で届く）。
    /// 以前はファイル操作のたびにこの値を増やしていたが、1 回の改名で
    /// 全ウインドウ・展開済みの全ツリー行が読み直す作りだったうえ、
    /// アプリの外で起きた変更には最初から追随できなかった。
    ///
    /// 残っている用途は「同じファイルでも見え方の前提が変わる」もの:
    /// - 環境設定「アクセス権」でのボリューム許可の付与・取り消し
    /// - ボリュームの取り出し [1-16]
    /// - ライブラリ／テンポラリ登録の増減（完全削除に伴う強制解除を含む）
    ///
    /// ウインドウ単位ではなくセッション全体で 1 つ（`SessionState.shared`）
    /// なのは、どれもアプリ全体に効く事象だから。
    public var reloadToken: Int = 0

    /// カット（⌘X）で選択された項目の識別子集合 [FM-02 相当]。ペースト時に
    /// 現在のペーストボードの内容がこの集合と一致すれば「カット→ペースト」と
    /// 判断してコピーではなく移動を行う。Finder 自身のカット判定はプライベート
    /// API 頼りで他アプリと相互運用できないため、アプリ内で完結する簡易な
    /// 独自実装にしている（Finder との間で「カット」を伝搬することはできないが、
    /// コピー自体は標準の `NSPasteboard` ファイル URL 経由で相互運用できる）。
    /// アプリ全体で 1 つ（ウインドウをまたいでカット→別ウインドウでペーストも
    /// 成立させるため、`reloadToken` と同じ理由でセッション全体の状態にしている）。
    ///
    /// **`Set<URL>` ではなく `Set<String>`（`standardizedFileURL.path`）で
    /// 持つ** [実機検証で発見したバグの修正]。`NSPasteboard.readObjects`
    /// でペーストボードから読み戻した `URL` は、カット時に書き込んだ元の
    /// `URL` と（末尾スラッシュの有無など）表現が異なることがあり、生の
    /// `URL` 同士の `==` 比較では一致せず「カットしたのにコピーになる」
    /// 不具合が起きていた。`FolderTreeRow.isSelected` と同じ
    /// `standardizedFileURL.path` 文字列比較に揃えることで解消した。
    public var cutURLs: Set<String> = []
}
