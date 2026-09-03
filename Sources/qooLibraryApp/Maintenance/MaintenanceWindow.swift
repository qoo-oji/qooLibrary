//
//  メンテナンスウインドウ [19章 §19.6、ステージ 4]。
//
//  **ライブラリの「片付けごと」を 1 か所に集める。** 左＝ライブラリ一覧
//  （タブの件数つき）／右＝タブ（見つからないファイル／保管庫）。
//
//  ## なぜ統合したか
//  旧 3 ウインドウはどれも「左＝ライブラリ一覧、右＝一覧と操作」という同じ形
//  だったのに別々のウインドウで、しかも**保管庫は入口ゼロ**だった（Stage P の
//  右クリック最小化で失われたまま、`FileVaultNavigation` の参照が自ウインドウ
//  内にしか無い状態が続いていた）。片付けの入口が 1 つになれば、右クリックを
//  最小に保ったまま [§19.6] すべてに到達できる。
//
//  ## ライブラリの選択はタブ間で共有する
//  これが統合の眼目——タブを切り替えるたびに選び直すのでは、ウインドウが
//  分かれているのと変わらない。`orphans.selectedLibraryID` を正とし、
//  `vault` へ書き戻す（両モデルとも `LibraryServices.libraries` の写しを
//  見ているので、一覧そのものは常に一致する）。
//
//  ## 読み直しの合図はここが一手に引き受ける
//  旧ウインドウが各自持っていた 4 つの `.onChange`（準備完了・着脱・⌘Z・
//  走査）をここへ集めた。**ペインに持たせない**——タブが増えるたびに同じ
//  配線を写すことになり、このリポジトリが繰り返し踏んだ「片方だけ配線して
//  取り残す」形になる。
//
import QooApplication
import QooKit
import SwiftUI

struct MaintenanceWindow: View {
    @Environment(\.locale) private var locale
    @State private var orphans = OrphanCleanupModel()
    @State private var vault = FileVaultModel()
    @State private var series = SeriesSuggestionModel()
    @State private var tab: MaintenanceTab = .orphans

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            libraryList
                .navigationSplitViewColumnWidth(min: 190, ideal: 230, max: 300)
        } detail: {
            detailPane
                .navigationSplitViewColumnWidth(min: 460, ideal: 600)
        }
        .navigationTitle(Text("maintenance.windowTitle"))
        .frame(minWidth: 760, minHeight: 460)
        .task { await consume(MaintenanceNavigation.shared.pending) }
        .onChange(of: MaintenanceNavigation.shared.pending) { _, _ in
            guard let pending = MaintenanceNavigation.shared.pending else { return }
            Task { await consume(pending) }
        }
        // **起動と同時に状態復元で開かれると、DB の準備より先に `.notReady` で
        // 確定する。** `Window(id:)` は `WindowGroup` と違い
        // `.restorationBehavior(.disabled)` を持たないのでこの経路は実在し、
        // 一度確定すると再試行の契機が無い。
        .onChange(of: LibraryServices.shared.isReady) { _, ready in
            guard ready else { return }
            // **残っている要求を拾い直す**［code-review の指摘］——準備より先に
            // 開かれた要求は `consume` が捨てずに残しているので、ここで
            // ライブラリもタブも指定どおりに落ち着く。
            Task { await consume(MaintenanceNavigation.shared.pending) }
        }
        // **ボリュームの着脱に追随する** [VD-03][VD-05][OR2-06][SB-05]。
        // 孤立タブは一覧そのものを伏せる必要があり、保管庫タブは操作の可否
        // （`canModify`）が変わる。どちらも `reload()` でしか更新されない。
        .onChange(of: LibraryServices.shared.libraries) { _, _ in
            Task { await reloadAll() }
        }
        // DB の中身が変わったら読み直す [§19.13 #2]。⌘Z / ⇧⌘Z（View を通らずに
        // DB を変える）と走査（外部で `.qooarchive` へ出し入れされた場合 [SY-10]、
        // 孤立の増減）が、どちらもこの 1 つの合図に現れる。
        .onChange(of: LibraryGeneration.shared.value) { _, _ in
            Task { await reloadAll() }
        }
        // **シリーズの提案は、そのタブを見ているときだけ検出する**
        // ——候補は事実上ライブラリ全件で、5 万件なら 400 ms かかる
        // （`SeriesSuggestionModel` の型注記に実測がある）。
        .onChange(of: tab) { _, newTab in
            guard newTab == .seriesSuggestions else { return }
            Task { await reloadSeries() }
        }
    }

    // MARK: - 準備と読み直し

    /// 開く要求を受け取る。
    ///
    /// **`orphans` を先に整えて、その選択へ `vault` を合わせる。** 別々に
    /// 既定を選ばせると、孤立のあるライブラリと保管庫の中身があるライブラリが
    /// 違うときに選択が食い違い、タブを切り替えた瞬間に別のライブラリが
    /// 見えることになる。
    ///
    /// **タブは先に、要求は準備できてから消費する**［code-review の指摘］。
    /// ①タブは DB を要らないので即座に適用してよい（通知が「見つからない
    /// ファイル」を指しているのに保管庫タブで開く、が起きない）②DB がまだ
    /// 準備できていないときに要求を捨てると、**起動と同時に開かれた場合に
    /// 行き先が失われる**（`Window(id:)` は状態復元でこの経路を通る）。
    private func consume(_ request: MaintenanceNavigation.Request?) async {
        if let requested = request?.tab { tab = requested }
        guard LibraryServices.shared.isReady else {
            // 要求は残す。`isReady` の変化で拾い直す。
            await orphans.prepare(services: LibraryServices.shared, preferring: nil)
            return
        }
        MaintenanceNavigation.shared.pending = nil
        let requested = request?.libraryID
        await orphans.prepare(services: LibraryServices.shared, preferring: requested)
        await vault.prepare(services: LibraryServices.shared,
                            preferring: orphans.selectedLibraryID ?? requested)
        await alignVaultSelection()
        series.selectedLibraryID = orphans.selectedLibraryID
        if tab == .seriesSuggestions {
            await series.prepare(services: LibraryServices.shared,
                                 preferring: orphans.selectedLibraryID ?? requested)
        }
    }

    private func reloadAll() async {
        await orphans.reload()
        await vault.reload()
        await alignVaultSelection()
        await reloadSeries()
    }

    /// **見えているときだけ走らせる**（上記の実測）。
    ///
    /// **2 度目からは `reload()` を使う**［code-review の指摘］——`prepare()` は
    /// 無条件に `.loading` へ落とすので、⌘Z や走査のたびに一覧がスピナーへ
    /// 戻る（他のタブも `reload()` を呼んでいる）。
    private func reloadSeries() async {
        guard tab == .seriesSuggestions else { return }
        series.selectedLibraryID = orphans.selectedLibraryID
        if series.state == .notReady {
            await series.prepare(services: LibraryServices.shared,
                                 preferring: orphans.selectedLibraryID)
        } else {
            await series.reload()
        }
    }

    private func alignVaultSelection() async {
        guard vault.selectedLibraryID != orphans.selectedLibraryID else { return }
        vault.selectedLibraryID = orphans.selectedLibraryID
        await vault.reload()
    }

    // MARK: - 左: ライブラリ一覧

    /// **選択は 1 つ。** `orphans` を正とし、`vault` へ書き戻す。
    private var selectedLibraryID: Binding<LibraryID?> {
        Binding {
            orphans.selectedLibraryID
        } set: { newValue in
            orphans.selectedLibraryID = newValue
            vault.selectedLibraryID = newValue
            Task { await reloadAll() }
        }
    }

    /// 同名ライブラリの注記 [RG3-31]。衝突している行にだけパスが付く。
    private var nameAnnotations: [LibraryID: String] {
        LibraryNameDisambiguation.annotations(for: orphans.libraries)
    }

    /// 件数は**選択中のタブのもの**を出す。両方を並べると 1 行が 4 段になり、
    /// しかも「いま見ているタブの件数」がどれか読み取りにくくなる。
    private func counts(for tab: MaintenanceTab) -> [LibraryID: Int] {
        switch tab {
        case .orphans: orphans.orphanCounts
        case .vault: vault.archivedCounts
        case .seriesSuggestions: series.suggestionCounts
        }
    }

    private var libraryList: some View {
        List(selection: selectedLibraryID) {
            Section("librarySettings.librariesHeader") {
                ForEach(orphans.libraries, id: \.id) { library in
                    let status = tab.status(for: library, counts: counts(for: tab))
                    Label {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(library.displayName)
                            // 同名のライブラリはパスで区別する [RG3-31]。
                            LibraryPathCaption(annotation: nameAnnotations[library.id])
                            if status.showsCount {
                                Text(String(format: String(localized: countKey(for: tab),
                                                           locale: locale), status.count))
                                    .font(.system(size: Tokens.fontSize.caption))
                                    .foregroundStyle(.secondary)
                            }
                            if status.showsOfflineNote {
                                Text("fileVault.offline")
                                    .font(.system(size: Tokens.fontSize.caption))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } icon: {
                        Image(systemName: status.iconName)
                            .foregroundStyle(status.isDimmed ? .secondary : Color.accentColor)
                    }
                    .opacity(status.isDimmed ? 0.5 : 1)
                    .tag(library.id)
                }
            }
        }
        .overlay {
            if orphans.libraries.isEmpty {
                ContentUnavailableView {
                    Label("librarySettings.noLibraries", systemImage: "books.vertical")
                } description: {
                    Text("librarySettings.noLibrariesHint")
                }
            }
        }
    }

    private func countKey(for tab: MaintenanceTab) -> String.LocalizationValue {
        switch tab {
        case .orphans: "orphanCleanup.count"
        case .vault: "fileVault.archivedCount"
        case .seriesSuggestions: "seriesSuggestions.count"
        }
    }

    // MARK: - 右: タブ

    private var detailPane: some View {
        VStack(spacing: 0) {
            tabPicker
            Divider()
            switch tab {
            case .orphans: OrphanCleanupPane(model: orphans)
            case .vault: FileVaultPane(model: vault)
            case .seriesSuggestions: SeriesSuggestionPane(model: series)
            }
        }
    }

    /// タブに**選択中ライブラリの件数を添える** [§19.6: 各タブに件数を出す]
    /// ——どちらに片付けるものがあるかを、切り替えずに読み取れるようにする。
    private var tabPicker: some View {
        Picker("", selection: $tab) {
            ForEach(MaintenanceTab.allCases) { candidate in
                Text(tabTitle(candidate)).tag(candidate)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.horizontal, Tokens.spacing.m)
        .padding(.vertical, Tokens.spacing.s)
    }

    private func tabTitle(_ candidate: MaintenanceTab) -> String {
        let title = String(localized: String.LocalizationValue(candidate.titleKey), locale: locale)
        guard let library = orphans.libraries.first(where: { $0.id == orphans.selectedLibraryID })
        else { return title }
        let status = candidate.status(for: library, counts: counts(for: candidate))
        guard status.showsCount else { return title }
        return "\(title)（\(status.count)）"
    }
}

/// ウインドウを開く要求を受け渡す [15章 §15.7]。
///
/// `Window(id:)` は同じ id で `openWindow` を呼び直してもビューを作り直さない
/// ので、「開いているウインドウが前面に来ただけ」の場合にも要求が届くように
/// する（旧 `OrphanCleanupNavigation` 等と同じ形）。
@MainActor
@Observable
final class MaintenanceNavigation {
    struct Request: Equatable {
        /// 選んでほしいライブラリ。**`nil` を許す**——メンテナンスは左ペインで
        /// ライブラリを選べるので、表示中のライブラリが無くても開いてよい
        /// （設定やフィールド編集のように 1 つのライブラリを対象にする
        /// ウインドウとは性質が違う）。
        let libraryID: LibraryID?
        /// 開きたいタブ。`nil` なら**今のタブを保つ**——通知から来たときは
        /// 行き先が決まっているが、メニューから開くときは前回の続きが自然。
        let tab: MaintenanceTab?
    }

    static let shared = MaintenanceNavigation()
    var pending: Request?
    private init() {}

    /// 開く経路はここ 1 つ [CP-02]。
    @MainActor
    static func open(libraryID: LibraryID?, tab: MaintenanceTab? = nil,
                     openWindow: OpenWindowAction) {
        shared.pending = Request(libraryID: libraryID, tab: tab)
        openWindow(id: "maintenance")
    }
}
