import AppKit
import Observation
import QooInfrastructure
import QuickLookUI

/// Quick Look 連携の司令塔 [9.7 節、QL-01〜QL-10]。ウインドウごとに 1 つ。
///
/// ## なぜウインドウごとなのか
/// `QLPreviewPanel` はアプリ全体で 1 つの共有パネルだが、「何をプレビューするか」
/// はウインドウ（そのタブの選択）ごとに違う。AppKit はレスポンダチェーンを
/// たどって「今このパネルを制御するのは誰か」を決める設計になっており、
/// キーウインドウが変わればコントローラも切り替わる。その仕組みにそのまま
/// 乗るため、このクラスも `MainWindowView` と 1 対 1 にする
/// （チェーンへの差し込みは `QuickLookPanelInstaller` が行う）。
///
/// ## 仕様書との差分（実装時に判明したこと）
/// 仕様書 9.7 節 QL2-08 は「`QLPreviewPanel` の `previewItem` に独自ビューを
/// 持つ `NSViewController` を返す方式」としていたが、**`QLPreviewPanel` に
/// 項目ごとの独自ビューを差し込む API は存在しない**（SDK の
/// `QLPreviewPanel.h` を直接確認済み。データ源は `QLPreviewItem` のみで、
/// その実体は `previewItemURL`＝ファイル URL）。そのため独自プレビューは
/// 「中の先頭画像を実ファイルとして書き出し、その URL を渡す」方式で実現する
/// （`QuickLookCoverStore` 参照）。App Extension を使わないという QL2-08 の
/// 設計判断自体は維持している。仕様書側もこの記述に訂正済み。
///
/// この方式の帰結として、QL-06 が求める併記メタデータ（タイトル・シリーズ名・
/// 巻数・評価・ラベル・ファイルサイズ）はパネル上に重ねられない。フェーズ 1 に
/// 存在するのはファイル名（パネルのタイトルに出る）とファイルサイズ（常設
/// インスペクタに出る）だけなので実害は無いが、**フェーズ 2 でラベル・評価が
/// 入った時点で「カバー＋メタデータを 1 枚の画像／PDF に合成して渡す」か
/// 「独自パネルへ移行する」かの判断が必要になる**［フォローアップとして記録］。
@MainActor
final class QuickLookController: NSObject, @MainActor QLPreviewPanelDelegate {
    /// 選択の読み書き・移動の対象。`WindowState` は参照型（`@Observable`）
    /// なので、値をコピーせずその都度読むことで常に最新を見る
    /// [`FolderContentView.currentFolder` のコメントと同じ理由]。
    /// `WindowState` 側はこのコントローラを参照しないため循環しない。
    private let windowState: WindowState

    /// 中央ペインの**表示順**（ソート・フォルダまとめ適用後）。矢印キーで
    /// 選択を隣へ動かす [QL-07] ために必要で、`FolderContentView` が
    /// `publishQuickLookOrder()` から押し込む。
    var orderedURLs: [URL] = []

    /// パネルへ渡すデータ源。**メインアクターから切り離してある**
    /// （`QuickLookItemSource` のコメント参照: QuickLook はバックグラウンドから
    /// 問い合わせてくることがある）。項目の実体はここが唯一持ち、この
    /// コントローラは書き手としてだけ触る。
    private let itemSource = QuickLookItemSource()
    private var items: [QuickLookPreviewItem] {
        get { itemSource.items }
        set { itemSource.items = newValue }
    }
    /// このコントローラがパネルを制御中か（`beginPreviewPanelControl` 〜
    /// `endPreviewPanelControl` の間）。
    private var isControllingPanel = false
    private var isObservingTab = false
    /// パネルを開いたときのフォルダ。ナビゲーションを検出して閉じるために持つ。
    private var folderWhenOpened: URL?

    init(windowState: WindowState) {
        self.windowState = windowState
        super.init()
        // データ源から「この項目を表示しようとしている」通知を受けて、カバーの
        // 遅延解決を始める [QL-09]。呼ばれるスレッドは不定なので、必ずメイン
        // アクターへ移し替えてから触る。
        itemSource.setWillDisplayHandler { [weak self] item in
            Task { @MainActor in
                self?.resolveCoverIfNeeded(for: item)
            }
        }
    }

    // MARK: - 表示の切り替え [QL-01]

    /// Space キー／File メニューから呼ぶ。開いていれば閉じ、閉じていれば開く。
    func toggle() {
        if let panel = visiblePanel {
            panel.orderOut(nil)
            return
        }
        show()
    }

    /// コンテキストメニューのように**対象を明示して**呼ぶ経路用。既に開いて
    /// いれば内容を差し替えるだけで、閉じない（`toggle()` に寄せると、
    /// プレビューを開いたまま別の項目を右クリックして選んだときに閉じてしまう）。
    func show() {
        guard canPreviewSelection else { return }
        // 開くときは「今の選択」を必ず対象にする。`rebuildItems()` の戻り値
        // （変化の有無）で早期 return してはならない——同じ項目を選んだまま
        // 2 回目に開こうとしたときに何も起きなくなる。
        rebuildItems()
        guard !items.isEmpty else { return }
        // `shared()` はパネルがまだ無ければここで生成する（存在確認だけを
        // したい `visiblePanel` と違い、ここでは生成させたい）。
        guard let panel = QLPreviewPanel.shared() else { return }
        folderWhenOpened = windowState.currentTab?.folder
        if !panel.isVisible {
            panel.makeKeyAndOrderFront(nil)
        }
        // 次の実行サイクルで、制御権が渡ってきたかの確認と表示内容の反映を行う。
        //
        // - `makeKeyAndOrderFront` の時点ではまだ `beginPreviewPanelControl`
        //   が呼ばれていないことがあるため、確認を 1 サイクル遅らせる。
        // - **`reloadData()` は毎回呼ぶ**。閉じてから開き直しても AppKit が
        //   制御権をこのコントローラに残したままにする場合があり、その経路では
        //   `beginPreviewPanelControl`（＝ `reloadData()` を呼ぶ側）が発生せず、
        //   前回の項目が表示されたままになる。
        DispatchQueue.main.async { [weak self] in
            guard let self, panel.isVisible else { return }
            self.adoptPanelIfUncontrolled(panel)
            panel.reloadData()
            panel.currentPreviewItemIndex = 0
        }
    }

    /// 現在の選択でプレビューできるものがあるか（メニュー項目の活性判定用）。
    var canPreviewSelection: Bool {
        !(windowState.currentTab?.selection.isEmpty ?? true)
    }

    /// レスポンダチェーンからこのコントローラが見つからなかった場合の保険。
    ///
    /// 正しい経路は `QuickLookPanelInstaller` が差し込んだレスポンダ経由の
    /// `beginPreviewPanelControl`（最小の AppKit アプリで実際に到達することを
    /// 確認済み、同ファイルのコメント参照）だが、SwiftUI が管理するウインドウの
    /// レスポンダ構成は将来変わり得る。渡ってこなかった場合でもプレビュー自体は
    /// 成立させ、原因を追えるようにログを残す。
    private func adoptPanelIfUncontrolled(_ panel: QLPreviewPanel) {
        guard !isControllingPanel, panel.isVisible else { return }
        Log.ui.warning("QLPreviewPanel の制御権が渡ってこなかったため、データソースを直接設定した（レスポンダチェーンへの差し込みが効いていない可能性）")
        beginControlling(panel)
    }

    // MARK: - パネルの制御権 [`QuickLookPanelInstaller` から呼ばれる]

    func beginControlling(_ panel: QLPreviewPanel) {
        isControllingPanel = true
        panel.dataSource = itemSource
        panel.delegate = self
        // 別ウインドウから制御権が移ってきた場合、`items` にはこのウインドウの
        // 古い選択が残っていることがあるため、必ず組み直す。
        rebuildItems()
        if folderWhenOpened == nil { folderWhenOpened = windowState.currentTab?.folder }
        panel.reloadData()
        // 項目数が減っていると、パネルが保持している添字が範囲外のままになり
        // `previewItemAt` が `nil` を返して何も表示されなくなる。範囲外のときだけ
        // 先頭へ戻す（範囲内ならユーザーが見ていた位置を保つ）。
        if !items.indices.contains(panel.currentPreviewItemIndex) {
            panel.currentPreviewItemIndex = 0
        }
        startObservingTab()
    }

    func endControlling(_ panel: QLPreviewPanel) {
        isControllingPanel = false
        stopObservingTab()
        cancelCoverResolution()
        folderWhenOpened = nil
        if (panel.dataSource as AnyObject?) === itemSource { panel.dataSource = nil }
        if (panel.delegate as AnyObject?) === self { panel.delegate = nil }
    }

    /// 既に存在していて、かつ表示中のパネル。**`sharedPreviewPanelExists()` を
    /// 先に確認する**——`shared()` は呼ぶだけでパネルを生成してしまうため、
    /// 「開いているか？」を知りたいだけの場面で副作用を起こさないようにする。
    private var visiblePanel: QLPreviewPanel? {
        guard QLPreviewPanel.sharedPreviewPanelExists(),
              let panel = QLPreviewPanel.shared(), panel.isVisible
        else { return nil }
        return panel
    }

    // MARK: - 項目の構築

    /// 現在の選択から項目を組み直す。**内容が変わったときだけ `true` を返す**
    /// ——選択の変化を監視して呼ぶ経路（``syncWithCurrentTab()``）と、自分で
    /// 選択を動かす経路（``moveSelection(by:)``）が互いを呼び戻すのを、
    /// フラグではなく「変化が無ければ何もしない」という形で断ち切るため。
    @discardableResult
    private func rebuildItems() -> Bool {
        let urls = selectedURLsInDisplayOrder()
        guard urls != items.map(\.sourceURL) else { return false }
        cancelCoverResolution()
        items = urls.map(QuickLookPreviewItem.init(sourceURL:))
        return true
    }

    /// 選択を中央ペインの表示順に並べたもの。Finder と同じく「プレビューの
    /// 対象は現在の選択」とし、複数選択ならパネルの ‹ › で選択内を巡れる。
    private func selectedURLsInDisplayOrder() -> [URL] {
        guard let selection = windowState.currentTab?.selection, !selection.isEmpty else { return [] }
        let ordered = orderedURLs.filter(selection.contains)
        guard ordered.count == selection.count else {
            // 表示順がまだ届いていない／古い場合の保険。順序を安定させるため
            // だけの経路なので、一覧と同じ自然順で並べておく。
            return selection.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        }
        return ordered
    }

    // MARK: - カバー画像の遅延解決 [QL-03][QL-08][QL-09]

    /// パネルが実際に表示しようとした項目だけ解決する。選択が 100 件あっても
    /// ユーザーが見た分しか読み込まないため、無駄なアーカイブ走査が起きない。
    private func resolveCoverIfNeeded(for item: QuickLookPreviewItem) {
        guard item.coverState == .notStarted else { return }
        // pdf / epub / 画像 / 動画は標準 Quick Look にそのまま委ねる [QL-02]。
        guard PreviewableFileKind.of(item.sourceURL).needsCustomCoverPreview else {
            item.coverState = .unavailable
            return
        }
        item.coverState = .resolving
        item.resolveTask = Task { [weak self] in
            let coverURL = await QuickLookCoverStore.shared.coverFileURL(for: item.sourceURL)
            guard !Task.isCancelled else { return }
            self?.applyResolvedCover(coverURL, to: item)
        }
    }

    private func applyResolvedCover(_ coverURL: URL?, to item: QuickLookPreviewItem) {
        item.resolveTask = nil
        guard let coverURL else {
            // 画像を 1 枚も含まないアーカイブ・空フォルダなど。元の URL のまま
            // 標準 Quick Look に委ねる（アーカイブ／フォルダアイコンが出る）。
            item.coverState = .unavailable
            return
        }
        item.previewURL = coverURL
        item.coverState = .resolved
        // 今まさに表示中の項目だけ描き直す。他の項目は次に表示されるときに
        // `previewItemURL` が読み直されるため、何もしなくてよい。
        guard isControllingPanel, let panel = visiblePanel,
              (panel.currentPreviewItem as AnyObject?) === item
        else { return }
        panel.refreshCurrentPreviewItem()
    }

    private func cancelCoverResolution() {
        for item in items {
            item.resolveTask?.cancel()
            item.resolveTask = nil
            if item.coverState == .resolving { item.coverState = .notStarted }
        }
    }

    // MARK: - 選択・フォルダ変更への追従

    /// パネルを開いている間だけ、タブの選択とフォルダを監視する。一覧を
    /// クリックして選択を変えるとプレビューも追従する（Finder と同じ）。
    private func startObservingTab() {
        guard !isObservingTab else { return }
        isObservingTab = true
        observeTab()
    }

    private func stopObservingTab() {
        isObservingTab = false
    }

    /// `withObservationTracking` は 1 回きりの通知のため、変化のたびに登録し直す
    /// [`NotificationRouterPresenterController.observe()` と同じパターン]。
    private func observeTab() {
        withObservationTracking {
            _ = windowState.currentTab?.selection
            _ = windowState.currentTab?.folder
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.isObservingTab else { return }
                self.syncWithCurrentTab()
                self.observeTab()
            }
        }
    }

    private func syncWithCurrentTab() {
        guard isControllingPanel, let panel = visiblePanel else { return }
        // フォルダを移動したらプレビューを閉じる。移動先に無いファイルを
        // 映し続けるより自然で、Finder の挙動とも一致する。
        if windowState.currentTab?.folder != folderWhenOpened {
            panel.orderOut(nil)
            return
        }
        // 選択が空になっただけ（空きスペースのクリック等）でプレビューを畳むと
        // 唐突なので、開いている内容はそのまま保つ [設計判断]。
        guard canPreviewSelection else { return }
        guard rebuildItems() else { return }
        panel.reloadData()
        panel.currentPreviewItemIndex = 0
    }

    // MARK: - QLPreviewPanelDelegate

    /// パネルが処理しなかったイベントだけが届く。矢印キーで一覧の選択を動かし、
    /// プレビューを追従させる [QL-07]。
    ///
    /// 複数選択中は ← → をパネル自身が「選択内の前後の項目」に使うため、
    /// ここへは届かない（＝ ↑ ↓ だけが一覧の選択移動になる）。単一選択のときは
    /// 4 方向とも届き、いずれも前後の項目へ移動する——どちらも Finder と同じ。
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event.type == .keyDown,
              let scalar = event.charactersIgnoringModifiers?.unicodeScalars.first
        else { return false }
        switch Int(scalar.value) {
        case NSUpArrowFunctionKey, NSLeftArrowFunctionKey:
            return moveSelection(by: -1)
        case NSDownArrowFunctionKey, NSRightArrowFunctionKey:
            return moveSelection(by: 1)
        default:
            return false
        }
    }

    /// ズーム元の矩形。SwiftUI の一覧セルの画面座標を求めるには AppKit の
    /// ビュー階層を掘る必要があり、得られる効果（開閉時のズーム演出）に対して
    /// 割に合わないため、`.zero` を返してフェード表示にしている
    /// [設計判断、ヘッダに「`NSZeroRect` を返すとフェードになる」と明記あり]。
    ///
    /// **`nonisolated` にしてある**——このメソッドはプレビューの開閉演出のために
    /// 呼ばれ、キーイベントやウインドウデリゲートと違ってメインスレッドから来る
    /// 保証を確認できていない。状態を一切触らないので隔離を外しても失うものが
    /// 無く、外しておけば万一バックグラウンドから呼ばれてもクラッシュしない
    /// [`QuickLookPreviewItem` のコメントにある実機クラッシュと同じ轍を踏まない
    /// ための予防]。
    nonisolated func previewPanel(_ panel: QLPreviewPanel!, sourceFrameOnScreenFor item: (any QLPreviewItem)!) -> NSRect {
        .zero
    }

    /// `QLPreviewPanelDelegate` は `NSWindowDelegate` を継承する。パネルが
    /// 閉じられたとき、`endPreviewPanelControl` が呼ばれない経路
    /// （前述の保険でデータソースを直接設定した場合）でも解決中のタスクを
    /// 確実に片付けるため、ここでも取り消す。
    func windowWillClose(_ notification: Notification) {
        cancelCoverResolution()
        folderWhenOpened = nil
    }

    // MARK: - 選択の移動 [QL-07]

    /// 一覧の表示順で `delta` ぶん隣の項目を単独選択にする。端では何もしない
    /// （Finder と同じく、先頭より前・末尾より後ろへは回り込まない）。
    private func moveSelection(by delta: Int) -> Bool {
        guard let index = windowState.currentTabIndex, !orderedURLs.isEmpty else { return false }
        let selection = windowState.tabs[index].selection
        let selectedPositions = orderedURLs.indices.filter { selection.contains(orderedURLs[$0]) }
        guard let first = selectedPositions.first, let last = selectedPositions.last else { return false }
        let target = delta < 0 ? first + delta : last + delta
        guard orderedURLs.indices.contains(target) else { return true }

        let url = orderedURLs[target]
        windowState.tabs[index].selection = [url]
        // 一覧側もその項目までスクロールさせる（プレビューだけが進んで一覧が
        // 置き去りになると、パネルを閉じたときに現在位置を見失うため）。
        windowState.tabs[index].pendingRevealURL = url
        // 監視経由でも同期されるが、キー操作への追従は 1 サイクルでも遅らせたく
        // ないためここでも同期する（`rebuildItems()` が冪等なので二重にならない）。
        syncWithCurrentTab()
        return true
    }
}
