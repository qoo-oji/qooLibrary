import AppKit
import SwiftUI

// MARK: - 閉じる操作

/// ダイアログウインドウを閉じる。
///
/// **`@Environment(\.dismiss)` は使えない** [実測]。`NSHostingController` を
/// ウインドウとして出した構成では `dismiss()` を呼んでもウインドウは閉じない
/// （シート・ポップオーバー・シーンとして提示されたビューでしか効かない）。
/// 使い勝手を揃えるため、同じ「呼ぶだけ」の形のものを配る。
struct DialogDismissAction {
    private let close: @MainActor () -> Void

    init(_ close: @escaping @MainActor () -> Void) { self.close = close }

    @MainActor
    func callAsFunction() { close() }
}

extension EnvironmentValues {
    /// `DialogWindowPresenter` が配る。ダイアログの外では何もしない。
    @Entry var dialogDismiss = DialogDismissAction {}
}

// MARK: - 提示

/// SwiftUI のビューを **独立したアプリケーションモーダルのウインドウ** として
/// 出す［ユーザー要望: 「ウインドウのように見えて実はウインドウでないもの」を
/// Finder と同じく本物のウインドウにする］。
///
/// ## Finder の実際の設計（`Finder.app` の nib を読み、実体化して確認）
/// Finder は入力を伴うダイアログを nib の名前で明確に区別している。
/// `NewFolderWindow` / `GotoWindow` / `BulkRenameWindow` / `ConnectToWindow` /
/// `ViewOptionsWindow` はいずれも**独立した `NSWindow`**（`NSPanel` ではない）で、
/// `NewFolderWindow` と `BulkRenameWindow` は `.titled` のみ＝**閉じるボタンを
/// 持たない**。決定かキャンセルでしか閉じられない、古典的なモーダルダイアログの
/// 作りである。ここでもそれに揃える。
/// 一方 `CompressionPasswordSheet` などパスワード系は Finder ではシートだが、
/// 入力ダイアログの見た目を揃える方を優先してウインドウにしている
/// ［ユーザー判断］。
///
/// ## なぜ `NSApp.runModal(for:)` を使わないのか【重要】
/// 最初はそちらで実装したが、**macOS 14 以降 `runModal` と SwiftUI の
/// 組み合わせは壊れている**（Apple Developer Forums に複数報告。macOS 13 では
/// 動いていたものが 14 でボタンを押しても何も起きなくなる）。実機でも次の
/// 症状をすべて踏んだ:
/// - ダイアログ内のボタンをクリックしても反応しない
/// - Return を押しても `.onSubmit` が発火しない
/// - 非同期処理の完了から `stopModal()` を呼んでもウインドウが閉じない
///   （移動そのものは成功しているのにウインドウだけが残り、次に何かキーを
///   押した瞬間に閉じる）。これは Apple の仕様どおりで、`stopModal` が効くのは
///   「イベントに応答するコードから呼ばれたとき」だけ。
///
/// 代わりに **`NSViewController.presentAsModalWindow(_:)`** を使う。Apple 自身が
/// WWDC22「Use SwiftUI with AppKit」で `NSHostingController` と組み合わせる例を
/// 示している、この用途の正規の API。入れ子のイベントループを作らないため
/// 上記の問題が起きない。実測で確認した性質:
/// - `isSheet == false`（シートではない独立したウインドウ）
/// - `NSApp.modalWindow` に載る（＝アプリケーションモーダル）
/// - 中身の実寸にウインドウが合う
/// - **`.onSubmit` が Return で発火する**（`runModal` では発火しなかった）
/// - **非同期処理の完了からでも確実に閉じられる**
///
/// ## 宣言的な提示（`.sheet`）をやめた理由
/// `.sheet` は「どのビューが載せるか」を決める必要があり、同じ状態を複数の
/// ビューが監視すると二重に出る。実際 `folderOperationsHost(_:)` は
/// `FolderContentView` と `FolderTreePane` の両方に適用されている。
/// アプリ全体で唯一のこのオブジェクトが命令的に 1 枚だけ出す形にすれば、
/// その問題が構造的に起こり得ない（`NotificationRouterPresenterController` が
/// `NSAlert` について同じ判断をしている）。
///
/// ## キーボード（実測に基づく）
/// - **Esc** → `.keyboardShortcut(.cancelAction)` が発火する。
/// - **Return** → テキストフィールドにフォーカスがあるときは `.onSubmit`
///   （`DialogScaffold` がコンテナに 1 回付けるだけで中のフィールドすべてへ
///   伝播する）。フォーカスがそれ以外なら `.keyboardShortcut(.defaultAction)`。
///   2 つは排他なので二重発火しない。
/// - この経路にしているのは **IME を壊さないため**。Return を横取りする
///   キーモニタを置くと、日本語入力の変換確定がダイアログの確定として
///   横取りされてしまう。`.onSubmit` は変換確定後の `insertNewline:` でしか
///   呼ばれないので、その危険が構造的に無い。
@MainActor
final class DialogWindowPresenter {
    static let shared = DialogWindowPresenter()

    /// 表示中のダイアログ。`dismiss()` の宛先であり、二重提示の判定でもある。
    ///
    /// **提示を予約する時点で立てる。** ウインドウを実際に作るのは次のループ
    /// なので、あとから入る値だけで判定すると、続けて 2 回呼ばれたときに
    /// 両方が guard を通り、1 枚目を閉じた直後に 2 枚目が独りでに開く
    /// ［実機検証で発見: 確定して閉じたはずのダイアログが 1.4 秒後にまた現れた］。
    private var isPresenting = false
    private weak var current: NSViewController?

    private init() {}

    /// ダイアログを出す。**呼び出し元をブロックしない**（`runModal` と違い、
    /// この関数はすぐ返る）。結果は `content` に渡したクロージャで受け取る。
    ///
    /// - Parameters:
    ///   - title: ウインドウのタイトルバーに出す文字列。**中身側で見出しを
    ///     重ねて描かないこと** — 同じ文字列が 2 回出て冗長になる。
    ///   - content: `dismiss` を受け取って中身を組み立てるクロージャ。
    ///     `@Environment(\.dialogDismiss)` からも同じものが読める。
    ///
    /// - Important: **ビューの更新中（`body` の評価中）から呼んではならない。**
    ///   ボタンのアクション・メニュー項目・キーバインドなど、ユーザーの操作を
    ///   起点にしてのみ呼ぶこと。
    func present<Content: View>(
        title: String,
        @ViewBuilder content: @escaping (DialogDismissAction) -> Content
    ) {
        // 既に 1 枚出ている（か、出ようとしている）なら何もしない。
        // アプリケーションモーダルなので本来ユーザー操作からは起こり得ないが、
        // コード経路が増えたときにモーダルが入れ子になるのを構造的に防ぐ。
        guard !isPresenting else { return }
        isPresenting = true

        // **1 回分の実行を後ろへ回す。** メニュー項目やコンテキストメニューから
        // 呼ばれた場合、AppKit のメニュートラッキングが完全に終わってから
        // 提示する（`PaneWindows` や `WindowFrameAutosave` と同じ、「AppKit
        // 自身の処理が落ち着くのを待つ」既存パターン）。
        DispatchQueue.main.async { [self] in
            show(title: title, content: content)
        }
    }

    private func show<Content: View>(
        title: String,
        content: (DialogDismissAction) -> Content
    ) {
        guard let presenter = Self.presentingViewController() else {
            // 提示先のウインドウが無い（全ウインドウを閉じている等）。
            // 出しようが無いので予約だけ解いて諦める。
            isPresenting = false
            return
        }

        let dismiss = DialogDismissAction { [weak self] in self?.dismissCurrent() }
        let controller = DialogHostingController(
            rootView: content(dismiss)
                .environment(\.dialogDismiss, dismiss)
                // 独立したウインドウは SwiftUI の environment を継承しない。
                // 表示言語の上書きをここで配り直す [1-12 ローカライズ方針]。
                .appLanguageOverride()
        )
        // 中身の高さが変わったらウインドウも追従させる。ただし
        // **`sizingOptions = [.preferredContentSize]` は使わない** [クラッシュ修正]。
        // あれはウインドウのフレームを SwiftUI コンテンツの制約で（表示サイクルの
        // 中で同期的に）駆動する。ポップアップ式の Picker（一括リネームの
        // 「桁数」「区切り文字」）を開くとメニュー追跡の入れ子イベントループが
        // 表示サイクルを回し、保留中のウインドウリサイズ
        // （`_changeWindowFrameFromConstraintsIfNecessary`）の最中に
        // `NSHostingView` が safe area 無効化 → `setNeedsUpdateConstraints` を
        // 再要求して、AppKit のレイアウトパス超過検出が NSException を投げて
        // 即死した（実機で 2 回発生、DiagnosticReports の同一スタックで確認。
        // 「Update Constraints in Window pass 超過」系の既知の例外クラス）。
        // 空にするとホスティングビューがウインドウへ制約を張らなくなり、
        // この経路そのものが消える。追従は `DialogHostingController` が
        // レイアウト確定後に 1 サイクル遅らせて行う（`PaneWindows` 等と同じ
        // 「AppKit 自身の処理が落ち着くのを待つ」既存パターン）。
        controller.sizingOptions = []
        // 初期サイズは提示前に実測で与える（`presentAsModalWindow` は
        // ビューの現在のフレームでウインドウを作るため、与えないと
        // ゼロサイズで開いてしまう）。
        let fit = controller.view.fittingSize
        controller.view.setFrameSize(fit)
        controller.preferredContentSize = fit
        controller.title = title
        // 保険。アプリ側を経由せず AppKit の都合で閉じられた場合に、
        // 「提示中」のまま固まって以後どのダイアログも出せなくなるのを防ぐ。
        controller.onDismissed = { [weak self, weak controller] in
            guard let self, let controller else { return }
            finish(controller)
        }

        current = controller
        presenter.presentAsModalWindow(controller)
    }

    /// 何度呼ばれても安全。確定・キャンセル・Esc が重なって呼ぶことがある。
    ///
    /// **`presentingViewController?.dismiss(_:)` では閉じない** [実測]。
    /// 提示されている側の `dismiss(nil)` を呼ぶこと。
    private func dismissCurrent() {
        guard let controller = current else { return }
        // 先に状態を解く。ユーザー操作による閉じ方はすべてここを通るので、
        // これが後始末の主経路になる（`onDismissed` は保険）。
        finish(controller)
        controller.dismiss(nil)
    }

    /// 後始末。同じダイアログについて何度呼ばれても 1 回だけ効く。
    fileprivate func finish(_ controller: NSViewController) {
        guard current === controller else { return }
        current = nil
        isPresenting = false
    }

    /// 提示元。キーウインドウの内容ビューコントローラを使い、無ければ
    /// 表示中の適当なウインドウにフォールバックする。
    private static func presentingViewController() -> NSViewController? {
        let window = NSApp.keyWindow
            ?? NSApp.mainWindow
            ?? NSApp.windows.first(where: { $0.isVisible && $0.contentViewController != nil })
        return window?.contentViewController
    }
}

/// ダイアログの中身を載せるホスト。閉じられたことを presenter へ返し、
/// Finder に合わせてウインドウのボタンを隠す。
private final class DialogHostingController<Content: View>: NSHostingController<Content> {
    var onDismissed: (@MainActor () -> Void)?

    /// 中身の実寸が変わったらウインドウを追従させる（一括リネームのモード
    /// 切替・エラー文の出入り）。**表示サイクルの中では行わない** — 提示側の
    /// コメント参照。`viewDidLayout` は中身が変わるたびに呼ばれるので、
    /// そこから 1 サイクル遅らせて実寸へ合わせる。
    override func viewDidLayout() {
        super.viewDidLayout()
        guard !isFitScheduled else { return }
        isFitScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isFitScheduled = false
                self.fitWindowToContent()
            }
        }
    }

    private var isFitScheduled = false

    private func fitWindowToContent() {
        guard let window = view.window else { return }
        let target = view.fittingSize
        guard target.width > 1, target.height > 1 else { return }
        let content = window.contentRect(forFrameRect: window.frame)
        // 一致していれば何もしない（`setFrame` 自身が再レイアウトを起こす
        // ため、この打ち切りが無いと追従が自己増殖する）。
        guard abs(content.width - target.width) > 0.5
            || abs(content.height - target.height) > 0.5 else { return }
        var newContent = content
        // 画面上の上端（タイトルバー）を固定して下へ伸縮させる。
        // `setContentSize` は原点（左下）固定なので使わない。
        newContent.origin.y += content.height - target.height
        newContent.size = target
        window.setFrame(window.frameRect(forContentRect: newContent), display: true)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        guard let window = view.window else { return }
        // Finder の `NewFolderWindow` / `BulkRenameWindow` と同じく、決定か
        // キャンセルでのみ閉じる。Esc は常に効くので行き止まりにはならない。
        //
        // **3 つまとめて隠す。** 閉じるボタンだけ隠すと、詰め直しは起きない
        // ので空いた穴が残り、さらにタイトルが拡大ボタンと重なって見える
        // （実機のスクリーンショットで確認）。
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(button)?.isHidden = true
        }
        // 一時的な入力ダイアログを次回起動時に復活させない。
        window.isRestorable = false
    }

    /// **`viewDidDisappear` だけで「閉じられた」と判断してはならない**
    /// ［code-review で指摘され、プローブで再現］。これは **⌘H でアプリを
    /// 隠したときにも呼ばれる**。それを閉じたと見なすと presenter の状態だけが
    /// 先に解け、復帰後もダイアログは出たまま（かつ `NSApp.modalWindow` のまま）
    /// なのに決定・キャンセル・Esc がどれも空振りする——ウインドウのボタンを
    /// 隠しているので**閉じる手段が無くなり、強制終了するしかなくなる**。
    ///
    /// また `willCloseNotification` も使えない — `presentAsModalWindow` の
    /// 解除では発火しないため、こちらは逆に**永久に「提示中」のまま**になる
    /// （どちらも実測で確認）。
    ///
    /// 1 ループ待てば両者を確実に見分けられる [実測]:
    /// 隠しただけなら `presentingViewController` は残り、本当に閉じたなら nil。
    override func viewDidDisappear() {
        super.viewDidDisappear()
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.presentingViewController == nil else { return }
                self.onDismissed?()
            }
        }
    }
}

// MARK: - 中身の骨組み

/// ダイアログウインドウの中身に共通する骨組み。
///
/// 余白・幅・フッターの配置を 1 箇所に集約する [UI-04、機能ごとに独自の
/// ボタン配置を作らない]。**Return での確定もここが引き受ける** — 各ダイアログが
/// 自分でテキストフィールドへ `.onSubmit` を付けて回る作りにすると、新しい
/// ダイアログを足した人が忘れた時点で静かに壊れるため、構造で保証する。
///
/// `.onSubmit` は environment を通って**子孫の submittable なビューすべて**へ
/// 伝播するので、コンテナに 1 回付けるだけで中のどのテキストフィールドで
/// Return を押しても確定になる [実測で確認]。
///
/// タイトルはウインドウのタイトルバーが担う。**ここで見出しを描かないこと。**
struct DialogScaffold<Content: View>: View {
    /// ウインドウの幅。中身の高さは自動で追従する
    /// （`DialogWindowPresenter` の `sizingOptions` 参照）。
    let width: CGFloat
    let confirm: DialogButton
    var cancel: DialogButton?
    var extra: [DialogButton] = []
    /// 入力が未確定の間は決定を無効にする。**Return による確定にも効く。**
    var confirmDisabled: Bool = false
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.spacing.m) {
            content
            QooDialogFooter(
                confirm: confirm, cancel: cancel, extra: extra,
                confirmDisabled: confirmDisabled
            )
        }
        .padding(Tokens.spacing.l)
        .frame(width: width)
        .onSubmit {
            guard !confirmDisabled else { return }
            confirm.action()
        }
    }
}
