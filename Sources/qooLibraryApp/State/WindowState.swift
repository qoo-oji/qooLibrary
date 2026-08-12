import Foundation
import SwiftUI

/// 1 タブ分の状態。フォルダごとに独立して選択・スクロール位置・検索文字列を持つ。
public struct TabState: Identifiable, Sendable, Equatable {
    public let id: UUID
    public var folder: URL?
    public var title: String
    public var selection: Set<URL> = []
    public var searchText: String = ""
    /// 戻る/進む用の履歴 [KB-02 相当、Finder ツールバーの矢印ボタンと同等の機能]。
    /// タブごとに独立させる（タブ切替で他タブの履歴に影響しない）。
    var backHistory: [URL] = []
    var forwardHistory: [URL] = []

    public init(id: UUID = UUID(), folder: URL?, title: String) {
        self.id = id
        self.folder = folder
        self.title = title
    }
}

public enum DisplayMode: Sendable, Equatable {
    case folder // [VM-01 以降] ライブラリ表示モードは 2-9 でラベル基盤ができてから
}

public enum ListStyle: Sendable, Equatable {
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
    public var listStyle: ListStyle = .list // [ST-22][LV-04]
    public var iconSize: Double = 96 // [IV-04][ST-22]

    public init(initialFolder: URL? = FileManager.default.homeDirectoryForCurrentUser) {
        let firstTab = TabState(folder: initialFolder, title: initialFolder?.lastPathComponent ?? "新規タブ")
        self.tabs = [firstTab]
        self.selectedTabID = firstTab.id
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
    public func navigateCurrentTab(to url: URL) {
        guard let index = currentTabIndex else { return }
        if let current = tabs[index].folder, current != url {
            tabs[index].backHistory.append(current)
            tabs[index].forwardHistory.removeAll()
        }
        tabs[index].folder = url
        tabs[index].title = url.lastPathComponent
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
    /// ユーザーにとって意味のある行き先ではないため）。
    public var canGoToParent: Bool {
        guard let folder = currentTab?.folder else { return false }
        return folder.standardizedFileURL != Self.sandboxHomeDirectory
    }

    /// Finder ツールバーの「戻る」相当 [KB-02]。
    public func goBack() {
        guard let index = currentTabIndex, let previous = tabs[index].backHistory.popLast() else { return }
        if let current = tabs[index].folder {
            tabs[index].forwardHistory.append(current)
        }
        tabs[index].folder = previous
        tabs[index].title = previous.lastPathComponent
    }

    /// Finder ツールバーの「進む」相当 [KB-02]。
    public func goForward() {
        guard let index = currentTabIndex, let next = tabs[index].forwardHistory.popLast() else { return }
        if let current = tabs[index].folder {
            tabs[index].backHistory.append(current)
        }
        tabs[index].folder = next
        tabs[index].title = next.lastPathComponent
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
    public func goToParent() {
        guard canGoToParent, let folder = currentTab?.folder else { return }
        navigateCurrentTab(to: folder.deletingLastPathComponent())
    }

    public func openTab(for folder: URL?) {
        let tab = TabState(folder: folder, title: folder?.lastPathComponent ?? "新規タブ")
        tabs.append(tab)
        selectedTabID = tab.id
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

    /// カット（⌘X）で選択された項目の URL 集合 [FM-02 相当]。ペースト時に
    /// 現在のペーストボードの内容がこの集合と一致すれば「カット→ペースト」と
    /// 判断してコピーではなく移動を行う。Finder 自身のカット判定はプライベート
    /// API 頼りで他アプリと相互運用できないため、アプリ内で完結する簡易な
    /// 独自実装にしている（Finder との間で「カット」を伝搬することはできないが、
    /// コピー自体は標準の `NSPasteboard` ファイル URL 経由で相互運用できる）。
    /// アプリ全体で 1 つ（ウインドウをまたいでカット→別ウインドウでペーストも
    /// 成立させるため、`reloadToken` と同じ理由でセッション全体の状態にしている）。
    public var cutURLs: Set<URL> = []
}
