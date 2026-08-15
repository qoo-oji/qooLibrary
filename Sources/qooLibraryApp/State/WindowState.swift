import Foundation
import SwiftUI

/// 現在のタブがどちらの入口から辿り着いたかを表す [ユーザー要望: 実体として
/// 同じフォルダでも、ボリューム経由かライブラリ／テンポラリフォルダ経由かで
/// 「フォルダツリーのどのグループが反応するか」「『上の階層へ』で登録
/// フォルダの外へ出られるか」を分けたい]。フォルダの URL だけでは
/// （フォルダツリーで手動でボリュームを辿って登録フォルダと同じ実フォルダに
/// たどり着くこともあり得るため）どちらの入口から来たか判別できないため、
/// タブの状態として明示的に持ち回る。
public enum NavigationRoot: Sendable, Equatable {
    case volume
    case registeredFolder(id: UUID, rootURL: URL)
}

/// 戻る/進む履歴の1件 [KB-02 相当]。フォルダ URL だけでなく `NavigationRoot`
/// も一緒に記録し、戻る/進むで当時の文脈も正しく復元する。
struct TabHistoryEntry: Sendable, Equatable {
    let url: URL
    let navigationRoot: NavigationRoot
}

/// 1 タブ分の状態。フォルダごとに独立して選択・スクロール位置・検索文字列を持つ。
public struct TabState: Identifiable, Sendable, Equatable {
    public let id: UUID
    public var folder: URL?
    public var title: String
    public var selection: Set<URL> = []
    public var searchText: String = ""
    /// 現在のフォルダがどちらの入口から辿り着いたか [`NavigationRoot` 参照]。
    public var navigationRoot: NavigationRoot = .volume
    /// 戻る/進む用の履歴 [KB-02 相当、Finder ツールバーの矢印ボタンと同等の機能]。
    /// タブごとに独立させる（タブ切替で他タブの履歴に影響しない）。
    var backHistory: [TabHistoryEntry] = []
    var forwardHistory: [TabHistoryEntry] = []
    /// 「戻る」「1階層上へ」で親フォルダへ移動したとき、直前までいた
    /// フォルダまで中央ペインをスクロールさせるための一時的な信号
    /// [ユーザー要望: 「戻る」「一階層上へ」の操作で1つ上の階層のフォルダに
    /// 移動した場合、それまでいたフォルダをハイライトし、表示できる位置まで
    /// あらかじめスクロールしておいてほしい]。ハイライト自体は `selection`
    /// を直接更新するだけで済むが、スクロールは `FolderContentView` 側の
    /// `pendingScrollTarget`（「ここに圧縮」で確立済みの、ユーザー自身の
    /// クリックとプログラム的な選択変更を区別する仕組み）に伝える必要がある
    /// ため、この専用フィールドで橋渡しする。`FolderContentView` が消費後に
    /// `nil` へ戻す。
    public var pendingRevealURL: URL?

    public init(id: UUID = UUID(), folder: URL?, title: String) {
        self.id = id
        self.folder = folder
        self.title = title
    }
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
/// ウインドウ（＝この View 階層のインスタンス）ごとに独立して生成する。同じ
/// フォルダを 2 ウインドウで開いても、タブ構成・選択・表示モードは互いに影響しない。
///
/// `labelSelection` / `ratingFilter` / `sort` はラベル・評価ドメイン型
/// （`Label`, `RatingFilter`, `SortDescriptorSpec`）がまだ存在しない
/// （フェーズ 2 で導入）ため未実装。タブと表示・選択の骨格のみ、このフェーズで
/// 実装する。
@MainActor
@Observable
public final class WindowState {
    public var tabs: [TabState]
    public var selectedTabID: TabState.ID
    public var displayMode: DisplayMode = .folder // [ST-22]
    // 既定は `.list`。1-9 でアイコン表示を実装するまで `.icon` になっていたが
    // 何にも参照されておらず（`Table` が常に表示されていた）、実質的な既定表示は
    // ずっとリストだった。アイコン表示の配線に合わせてここで初めて意味を持つ値に
    // なるため、今回の変更で見た目が急に変わらないよう明示的に `.list` にする。
    //
    // 1-12 で、この既定値自体を環境設定「表示」タブから変更できるようにした
    // （`DisplayPreferencesTab.swift` 参照）。ウインドウ固有状態自体は
    // 引き続き DB に保存しない [ST-20] が、「次に開くウインドウの既定値」だけは
    // `UserDefaults` から `init` 時に一度だけ読む（`MainWindowView.init` の
    // `isRightPaneCollapsed` と同じ「素の値を一度だけ読む」パターン。
    // `@AppStorage` を `if` 条件内で直接使うと SwiftUI の Observation が
    // 無限に再評価を繰り返す不具合を実機検証で確認済みのため、そのパターンは
    // 避けている）。
    public var listStyle: ListStyle // [ST-22][LV-04]
    public var iconSize: Double // [IV-04][ST-22]

    public init(initialFolder: URL? = FileManager.default.homeDirectoryForCurrentUser) {
        let firstTab = TabState(folder: initialFolder, title: initialFolder?.lastPathComponent ?? String(localized: "action.newTab", locale: AppLanguage.effectiveLocale))
        self.tabs = [firstTab]
        self.selectedTabID = firstTab.id
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

    public var currentTabIndex: Int? {
        tabs.firstIndex { $0.id == selectedTabID }
    }

    public var currentTab: TabState? {
        get { currentTabIndex.map { tabs[$0] } }
        set {
            guard let newValue, let index = currentTabIndex else { return }
            tabs[index] = newValue
        }
    }

    /// アクティブなタブの表示先を変更する。フォルダツリーでの選択 [LP-06] と
    /// 中央ペインでのフォルダ移動（ダブルクリック・Enter・1階層上に戻る等）の
    /// 両方から使う共通経路。呼ぶたびに戻る履歴へ積み、進む履歴は破棄する
    /// （ブラウザ・Finder と同じ規則）。`goBack`/`goForward` 自身はこのメソッドを
    /// 経由しない（履歴を壊さずに移動するため）。
    ///
    /// `root` は `NavigationRoot` を明示的に切り替えたいとき（フォルダツリーの
    /// ボリューム行／登録フォルダ行をクリックしたとき）だけ渡す。`nil`
    /// （既定）は「現在のタブの文脈を引き継ぐ」ことを意味し、中央ペインでの
    /// ダブルクリック・Enter・「1階層上へ」など、ツリーを経由しないナビゲー
    /// ションではこちらを使う。
    public func navigateCurrentTab(to url: URL, root: NavigationRoot? = nil) {
        guard let index = currentTabIndex else { return }
        let resolvedRoot = root ?? tabs[index].navigationRoot
        if let current = tabs[index].folder, current != url {
            tabs[index].backHistory.append(TabHistoryEntry(url: current, navigationRoot: tabs[index].navigationRoot))
            tabs[index].forwardHistory.removeAll()
        }
        tabs[index].folder = url
        tabs[index].title = url.lastPathComponent
        tabs[index].navigationRoot = resolvedRoot
        tabs[index].searchText = "" // [1-16] 移動したら絞り込みは解除する（Finder と同じ）
        // 「最近使ったフォルダ」[1-16 移動メニュー]。**`goBack`/`goForward` は
        // この経路を通らないため履歴に積まれない** — 履歴を行き来しただけで
        // 「最近使った」一覧の順序が入れ替わるのは Finder の挙動とも直感とも
        // ずれるため、意図してこの共通経路だけに置いている。
        RecentFoldersStore.shared.record(url)
    }

    /// 移動メニューの「ホーム」[1-16]。サンドボックスの仮想ホーム
    /// （`FolderContentView` の `canGoToParent` が上限としている場所と同じ）へ
    /// 移動する。ユーザーに見せる表記は実装詳細を出さず単に「ホーム」にする
    /// [ユーザー指摘、環境設定「起動時に開くフォルダ」と同じ方針]。
    public func goHome() {
        navigateCurrentTab(to: FileManager.default.homeDirectoryForCurrentUser, root: .volume)
    }

    public var canGoBack: Bool {
        currentTabIndex.map { !tabs[$0].backHistory.isEmpty } ?? false
    }

    public var canGoForward: Bool {
        currentTabIndex.map { !tabs[$0].forwardHistory.isEmpty } ?? false
    }

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
        guard let tab = currentTab, let folder = tab.folder else { return false }
        if folder.standardizedFileURL == Self.sandboxHomeDirectory { return false }
        if case .registeredFolder(_, let rootURL) = tab.navigationRoot,
           folder.standardizedFileURL == rootURL.standardizedFileURL {
            return false
        }
        return true
    }

    /// Finder ツールバーの「戻る」相当 [KB-02]。
    ///
    /// **移動先が直前までいたフォルダの親であれば、そのフォルダをハイライト
    /// してスクロールする**［ユーザー要望: 「戻る」「一階層上へ」で1つ上の
    /// 階層へ移動した場合、それまでいたフォルダを表示できる位置まで
    /// あらかじめハイライト・スクロールしておいてほしい］。「戻る」は必ずしも
    /// 親フォルダへ移動するとは限らない（履歴上の任意のフォルダへ戻り得る）
    /// ため、移動先が実際に親であるときだけ発動する条件付きの挙動にしている。
    public func goBack() {
        guard let index = currentTabIndex, let previous = tabs[index].backHistory.popLast() else { return }
        let leavingFolder = tabs[index].folder
        if let current = tabs[index].folder {
            tabs[index].forwardHistory.append(TabHistoryEntry(url: current, navigationRoot: tabs[index].navigationRoot))
        }
        tabs[index].folder = previous.url
        tabs[index].navigationRoot = previous.navigationRoot
        tabs[index].title = previous.url.lastPathComponent
        tabs[index].searchText = "" // [1-16]
        revealIfParent(of: leavingFolder, newFolder: previous.url, at: index)
    }

    /// Finder ツールバーの「進む」相当 [KB-02]。
    public func goForward() {
        guard let index = currentTabIndex, let next = tabs[index].forwardHistory.popLast() else { return }
        if let current = tabs[index].folder {
            tabs[index].backHistory.append(TabHistoryEntry(url: current, navigationRoot: tabs[index].navigationRoot))
        }
        tabs[index].folder = next.url
        tabs[index].navigationRoot = next.navigationRoot
        tabs[index].title = next.url.lastPathComponent
        tabs[index].searchText = "" // [1-16]
    }

    /// `⌘↑` 相当 [KB-02]。`goBack`/`goForward` と同じく `navigateCurrentTab(to:)`
    /// を経由する（履歴に積む）。
    ///
    /// **`FolderContentView` ではなくここに実装している**
    /// [実機検証で発見したバグの修正]: 以前は `FolderContentView`（値型の
    /// View）が自身の `folder: URL?` プロパティを直接読んで計算していたが、
    /// `.background` 内の非表示ボタンに束縛されたクロージャが、フォルダを
    /// 連続でナビゲートした直後は1回分古い `FolderContentView` インスタンスの
    /// `folder` を参照してしまうことがあり（`Documents/Dummy` にいるつもりで
    /// ⌘↑ を押すと `Documents` を素通りして仮想ホームまで戻ってしまっていた）、
    /// 実際には「1回の入力で2回移動した」のではなく「1回移動を、1段階古い
    /// 位置から行った」結果だった（`goToParent()`/`navigateCurrentTab(to:)` の
    /// 双方に一時的なログを仕込んだ実機検証で確認）。`goBack`/`goForward` は
    /// 元から `WindowState`（`@Observable` の参照型）のメソッドとして実装
    /// されており同種の問題が出ていなかったため、同じ設計に揃えた。
    ///
    /// **移動元のフォルダをハイライトしてスクロールする**［ユーザー要望、
    /// `goBack()` と同じ。こちらは常に親フォルダへの移動のため無条件で
    /// 発動する］。
    public func goToParent() {
        guard canGoToParent, let folder = currentTab?.folder else { return }
        let parent = folder.deletingLastPathComponent()
        navigateCurrentTab(to: parent)
        guard let index = currentTabIndex else { return }
        tabs[index].selection = [folder]
        tabs[index].pendingRevealURL = folder
    }

    /// 表示中のフォルダ自体が消えていたら、存在する直近の祖先へ静かに移動して
    /// `true` を返す。消えていなければ何もせず `false`。
    ///
    /// [フォルダツリーにコンテキストメニューを追加したことに伴う対応]
    /// 表示中のフォルダをゴミ箱に入れる・名前を変更する経路がツリーから直接
    /// 届くようになり（他ウインドウでの操作・Finder 側での削除でも同じことが
    /// 起きる）、そのままだと中央ペインが読み込みエラーのまま行き止まりに
    /// なっていた。**発生源ごとに手当てするのではなく、実際に読み込みに失敗
    /// した `FolderContentView.reload()` の 1 箇所から呼ぶ**ことで、経路
    /// （ツリー／中央ペイン／D&D／別ウインドウ／アプリ外）に関わらず自己修復
    /// する。
    ///
    /// - 履歴には積まない（消えた場所へ「戻る」ことに意味が無いため）。
    ///   併せて、既に積まれている履歴のうち実体を失ったものも取り除く。
    /// - 名前変更の場合、Finder はウインドウを新しい名前へ追従させるが、
    ///   それには変更前後を同一視するファイル ID の追跡（2-2 の
    ///   `FSEventsWatcher`/`IdentityResolver`）が要る。フェーズ1では
    ///   「親フォルダへ退避する」という安全側の単純な挙動に留める [設計判断]。
    @discardableResult
    public func relocateCurrentTabIfFolderVanished() -> Bool {
        guard let index = currentTabIndex, let folder = tabs[index].folder else { return false }
        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: folder.path) else { return false }
        guard let target = Self.nearestExistingAncestor(of: folder) else { return false }
        tabs[index].folder = target
        tabs[index].title = target.lastPathComponent
        tabs[index].selection = []
        tabs[index].searchText = "" // [1-16]
        tabs[index].backHistory.removeAll { !fileManager.fileExists(atPath: $0.url.path) }
        tabs[index].forwardHistory.removeAll { !fileManager.fileExists(atPath: $0.url.path) }
        return true
    }

    /// `url` の祖先のうち、実際に存在する最も深いもの（`url` 自身は除く）。
    ///
    /// **`URL.deletingLastPathComponent()` を繰り返す実装にしない** — ルート
    /// `/` に対して呼ぶと `/` 自身ではなく `/..` を返すことがある（Apple の
    /// ドキュメントに明記された挙動で、本プロジェクトでは 1-8 のパスバーと
    /// `FolderTreePane.ancestorPaths` で 2 度、無限ループとして踏んでいる）。
    /// `PathBarView.pathComponents` と同じく `pathComponents` から積み上げる。
    private static func nearestExistingAncestor(of url: URL) -> URL? {
        let components = url.standardizedFileURL.pathComponents
        guard let first = components.first else { return nil }
        var current = URL(fileURLWithPath: first)
        var ancestors = [current]
        for component in components.dropFirst() {
            current = current.appendingPathComponent(component)
            ancestors.append(current)
        }
        return ancestors.dropLast().last { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// `leavingFolder` が `newFolder` の直下（親子関係）である場合だけ、
    /// `leavingFolder` を選択・スクロール対象にする [`goBack()`/`goToParent()`
    /// 共通のヘルパー]。
    private func revealIfParent(of leavingFolder: URL?, newFolder: URL, at index: Int) {
        guard let leavingFolder,
              leavingFolder.deletingLastPathComponent().standardizedFileURL == newFolder.standardizedFileURL
        else { return }
        tabs[index].selection = [leavingFolder]
        tabs[index].pendingRevealURL = leavingFolder
    }

    /// `root` は新しいタブの入口 [`NavigationRoot` 参照]。ライブラリ／
    /// テンポラリ配下のフォルダを「新規タブで開く」場合に、その登録フォルダを
    /// 入口として引き継ぐために渡す（既定の `.volume` のままだと「1階層上へ」
    /// の境界やフォルダツリーの自動展開スコープが失われる）。
    public func openTab(for folder: URL?, root: NavigationRoot = .volume) {
        var tab = TabState(folder: folder, title: folder?.lastPathComponent ?? String(localized: "action.newTab", locale: AppLanguage.effectiveLocale))
        tab.navigationRoot = root
        tabs.append(tab)
        selectedTabID = tab.id
        if let folder {
            RecentFoldersStore.shared.record(folder) // [1-16 移動メニュー]
        }
    }

    /// タブバーの「＋」・`⌘T` の共通経路 [KB-02 相当]。フォルダ登録・環境設定が
    /// まだ無い（1-13/1-12）ため、選択ダイアログを出さず既定の仮想ホームを開く
    /// [設計判断、実機検証時のユーザー指摘]。
    public func openDefaultTab() {
        openTab(for: FileManager.default.homeDirectoryForCurrentUser)
    }

    /// 最後の 1 枚は閉じない（ウインドウ自体を閉じる操作と役割が重複するため）。
    public func closeTab(_ id: TabState.ID) {
        guard tabs.count > 1, let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs.remove(at: index)
        if selectedTabID == id {
            selectedTabID = tabs[min(index, tabs.count - 1)].id
        }
    }

    /// タブバーの右クリックメニュー「他のタブを閉じる」用。
    public func closeOtherTabs(keeping id: TabState.ID) {
        guard let keep = tabs.first(where: { $0.id == id }) else { return }
        tabs = [keep]
        selectedTabID = keep.id
    }
}

/// セッション一時状態 [11章 §11.4]。メモリのみ、DB にもウインドウ復元にも
/// 含めない [ST-20]。`LockManager`/`CommandStack` 相当のドメイン型がまだ
/// 存在しないため、アプリ全体で 1 つ生成される器だけをこのフェーズで用意する。
@MainActor
@Observable
public final class SessionState {
    public static let shared = SessionState()
    private init() {}

    /// ファイル操作（D&D・コンテキストメニュー等）が完了するたびに増やす。
    /// `FSEventsWatcher`（2-2 で実装）が無いため、暫定的にこれを見て一覧を
    /// 再読み込みするポーリング代替とする。ウインドウ単位ではなくセッション全体で
    /// 1 つ（`SessionState.shared`）を共有することで、あるウインドウでの操作が
    /// 他のウインドウ／ペインの表示にも反映される
    /// [1-6 実機検証で発見: ウインドウ間の D&D で移動元ウインドウの一覧が古いまま
    /// になり、既に存在しないファイルへ再度ドラッグして "no such file" エラーに
    /// なる事象があった。ウインドウ単位の `reloadToken` だった名残]。
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
