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
    public var listStyle: ListStyle = .icon // [ST-22]
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

    public func openTab(for folder: URL?) {
        let tab = TabState(folder: folder, title: folder?.lastPathComponent ?? "新規タブ")
        tabs.append(tab)
        selectedTabID = tab.id
    }

    /// 最後の 1 枚は閉じない（ウインドウ自体を閉じる操作と役割が重複するため）。
    public func closeTab(_ id: TabState.ID) {
        guard tabs.count > 1, let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs.remove(at: index)
        if selectedTabID == id {
            selectedTabID = tabs[min(index, tabs.count - 1)].id
        }
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
}
