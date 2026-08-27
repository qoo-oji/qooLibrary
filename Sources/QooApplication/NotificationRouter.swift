import Foundation
import QooInfrastructure
import QooKit

/// エラー・通知の提示ルーティング [13.1 節、ER-01]。**機能ごとに独自の提示
/// 方法を作らない** — `severity` に応じてどう見せるか（アプリモーダル／
/// シート／インライン／一時通知／ログのみ）を決めるのはこの型の中だけで行う。
///
/// 実際のアラート描画は AppKit が必要なため `qooLibraryApp` 側
/// （`NotificationRouterPresenterController`）が担うが、**いつ・どの強度で
/// 出すかの判断はこちら（`QooApplication`、AppKit/SwiftUI 非依存）に
/// 閉じている**。`currentModalItem` を `@Observable` で公開し、プレゼンタ側は
/// それを監視して描画するだけの薄い橋渡しにする（`CommandStack` の
/// `undoTitle`/`redoTitle` と同じ「状態はここ、描画は View 側」という分離）。
/// プレゼンタ側は SwiftUI の `.alert` ではなく `NSAlert` を直接使う
/// （`NotificationRouterPresenterController` のコメント参照: 複数ウインドウ
/// への宣言的バインディングでは重複表示・表示漏れの両方を実機で確認した）。
///
/// フェーズ1で実装していないもの: `BatchNotificationSession`（ER-10〜16、
/// 「以降すべてに適用」・結果サマリ）は、現時点でこれを必要とする一括処理
/// フロー自体がまだ無い（既存の一括処理は単純な「最初の失敗で中断」処理に
/// 留まっている）ため、具体的な呼び出し元が無いまま作る投機的な実装になって
/// しまう。`NotificationHistoryStore`（SwiftData 版）・通知履歴ウインドウ
/// （NW-01〜08）・`SystemNotificationGate`（ER-30〜34）もフェーズ2以降。
/// アラートに出すボタンの決定 [ER-01][ER-03]。
///
/// **View の条件式ではなく値として持つ**——`NotificationRouterPresenter` は
/// アプリターゲットにあり `swift test` から触れないので、ここに置かないと
/// 「閉じる手段が必ずある」ことをテストで固定できない。
public enum NotificationAlertButtons {
    /// 合成した「閉じる」の識別子。呼び出し側のどの `RecoveryAction` とも
    /// 一致しないので、押しても何も起きない（＝ただ閉じる）。
    public static let dismissActionID = "notification-dismiss"

    /// `NSAlert.addButton` へ渡す順に並べたボタン。
    ///
    /// **末尾に必ず閉じる手段を足す。** 行動を促すボタンしか無いと、
    /// 知らせを受け取っただけの利用者が**窓を開くしか道が無くなる**
    /// ——実機検証で、走査結果のシートが「整理する…」1 つになっていて
    /// 気づいた（未解決の導線を足したことで `actions.isEmpty` の分岐から
    /// 外れ、OK が消えていた）。巻数の確認 [EM-31] と差し替えの確認 [ID-05] も
    /// 同じ形で、以前からこの穴を持っていた。
    ///
    /// - Parameters:
    ///   - okTitle: 行動を促すボタンが無いときの文言（「OK」）。
    ///   - dismissTitle: 併記するときの文言（「閉じる」）。
    public static func actions(for item: NotificationItem,
                               okTitle: String, dismissTitle: String) -> [RecoveryAction] {
        guard !item.actions.isEmpty else {
            return [RecoveryAction(id: dismissActionID, title: okTitle, kind: .dismiss)]
        }
        // 呼び出し側が自前で閉じる手段を用意しているなら、二重に足さない。
        guard !item.actions.contains(where: { $0.kind == .dismiss }) else { return item.actions }
        return item.actions
            + [RecoveryAction(id: dismissActionID, title: dismissTitle, kind: .dismiss)]
    }
}

@MainActor
@Observable
public final class NotificationRouter {
    public static let shared = NotificationRouter()

    /// 現在表示中の通知（`.appModal`/`.sheet`/`.inline` のみ）。
    public private(set) var currentModalItem: NotificationItem?

    /// [CB-11 の簡易版] DB（`NotificationHistoryStore`、07章）がまだ無い
    /// フェーズ1では永続化しない、メモリのみの履歴。強度4以上（見逃されうる
    /// 一時通知／ログのみ）だけを記録する。専用の履歴ウインドウ（NW-01〜08）
    /// はまだ無く、閲覧 UI は無い。
    public private(set) var history: [NotificationItem] = []
    private let historyLimit = 500

    private var pendingContinuation: CheckedContinuation<RecoveryAction?, Never>?
    private var queue: [(item: NotificationItem, continuation: CheckedContinuation<RecoveryAction?, Never>)] = []

    public init() {}

    /// [CB-10] `severity` に応じて提示手段を自動選択する。呼び出し側は
    /// 提示手段を指定できない。
    @discardableResult
    public func present(_ item: NotificationItem) async -> RecoveryAction? {
        logToConsole(item)
        recordIfNeeded(item)

        switch item.severity {
        case .appModal, .sheet, .inline:
            // 専用の「一時通知（トースト）」UI がまだ無いため、フェーズ1では
            // この3段階すべてを同じアラートで表示する（データモデル上は
            // 区別を保持しており、UI が揃い次第 severity で描き分けられる）。
            return await presentModally(item)
        case .transient, .logOnly:
            return nil
        }
    }

    /// エラーをユーザーへ提示する唯一の入口 [ER-01]。
    ///
    /// 主要なエラー型（`FileOperationError`/`ExtractError`/
    /// `RegisteredFolderError`/`VolumeEligibilityError`/
    /// `PartialTransferFailure`）は `UserPresentableError` に準拠しており、
    /// 三要素が**型として要求される**ため書き忘れが起きない。準拠していない
    /// 素の `Error`（Foundation・将来増える型）にも安全網がある
    /// （`looksLikeTheUninformativeDefault` 参照）。
    /// - Parameter whatHappened: **何をしようとして失敗したか**（「コピー
    ///   できませんでした」）。操作を知っているのは呼び出し側だけなので、
    ///   ここは常にタイトルとして使う。
    ///
    /// ## 合成の規則（ここ 1 箇所だけが決める）[ER-03]
    /// ```
    /// タイトル: 何をしようとして失敗したか（呼び出し側）
    /// 本文    : 何が起きたか → なぜ → 次に何ができるか（エラー型）
    /// 折りたたみ: 技術詳細（errno・ライブラリの英語メッセージ）
    /// ```
    /// **以前は `UserPresentableError` に準拠していると呼び出し側の
    /// `whatHappened` を捨ててタイトルを差し替えていた**ため、「どの操作で
    /// 失敗したのか」が消えていた。逆に未準拠の型では 1 本の文字列に
    /// 操作名まで詰め込んでいて、タイトルと本文で「できませんでした」が
    /// 二重になっていた［棚卸しで発見］。両方をここで解消する。
    @discardableResult
    public func presentError(
        _ error: Error,
        whatHappened: String,
        severity: NotificationSeverity = .sheet,
        category: NotificationItem.Category = .error
    ) async -> RecoveryAction? {
        if let presentable = error as? any UserPresentableError {
            return await present(NotificationItem(
                category: category,
                severity: presentable.severity,
                title: whatHappened,
                body: Self.body(for: presentable),
                technicalDetail: presentable.technicalDetail,
                actions: presentable.recoverySuggestions
            ))
        }
        let rendered = Self.body(for: error)
        return await present(NotificationItem(
            category: category,
            severity: severity,
            title: whatHappened,
            body: rendered.body,
            technicalDetail: rendered.technicalDetail
        ))
    }

    /// 「操作を完了できませんでした。（Module.Type エラー1）」という、原因が
    /// 一切分からない既定文言かどうか。
    ///
    /// **安全網** [ER-03]。主要なエラー型は `UserPresentableError` に準拠させて
    /// あるが、準拠を忘れた型・将来増える型がこの経路へ来ることは避けられない。
    /// そのとき生の既定文言をそのまま見せるくらいなら、**説明できないことを
    /// 正直に言い、詳細は折りたたみへ回す**ほうがまだ役に立つ。
    static func looksLikeTheUninformativeDefault(_ text: String) -> Bool {
        // ローカライズされるため文言では判定できない。**末尾の
        // 「… error 1.)」「…エラー1）」という構造**で見る。
        //
        // 型名の形を当てにしてはいけない［実測］。入れ子で宣言された型は
        // 「(d.(unknown context at $113f78388).Inner error 1.)」のようになり、
        // 「Module.Type」を期待する正規表現では捕まえられなかった。
        let pattern = #"(error|エラー)\s*-?\d+\.?[)）]\s*$"#
        return text.range(of: pattern, options: .regularExpression) != nil
    }

    /// 三要素を 1 つの本文にする。**空の要素は行ごと落とす**（「なぜ」が
    /// 無いケースで空行が空くのを避ける）。
    private static func body(for error: any UserPresentableError) -> String {
        var parts = [error.whatHappened, error.whyItHappened]
        // 「次に何ができるか」は、押して意味のある操作（`recoverySuggestions`）
        // が無い場合に文章として添える。両方あると重複するので片方だけ。
        if error.recoverySuggestions.isEmpty, let hint = error.recoveryHint {
            parts.append(hint)
        }
        return parts.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    /// 素の `Error` から「なぜ起きたか」「次に何ができるか」を組み立てる [ER-03]。
    ///
    /// **`localizedDescription` だけを見ていた**［監査で発見］。Foundation の
    /// ファイル系エラーは `localizedRecoverySuggestion` に対処法を持っている
    /// ことがあり（実測: 読み取り専用ボリュームへの書き込みで
    /// 「Try saving the file to another volume.」）、それを毎回捨てていた。
    /// ER-03 の三要素のうち三つ目が、手元にあるのに表示されていなかったことになる。
    ///
    /// `localizedFailureReason` は `localizedDescription` に含まれていることが
    /// 多いので、重複しないときだけ足す。
    private static func body(for error: Error) -> (body: String, technicalDetail: String?) {
        let nsError = error as NSError
        let description = error.localizedDescription
        guard !looksLikeTheUninformativeDefault(description) else {
            // 説明できないことを正直に言い、生の文言は折りたたみへ回す。
            return (
                "原因を特定できないエラーが起きました。\n"
                    + "同じ操作を繰り返して再現する場合は、ヘルプメニューの「診断情報を書き出す」で"
                    + "記録を保存してください。",
                description
            )
        }
        var parts = [description]
        if let reason = nsError.localizedFailureReason, !description.contains(reason) {
            parts.append(reason)
        }
        if let suggestion = nsError.localizedRecoverySuggestion {
            parts.append(suggestion)
        }
        return (parts.joined(separator: "\n"), nil)
    }

    private func presentModally(_ item: NotificationItem) async -> RecoveryAction? {
        guard currentModalItem == nil else {
            return await withCheckedContinuation { continuation in
                queue.append((item, continuation))
            }
        }
        currentModalItem = item
        return await withCheckedContinuation { continuation in
            pendingContinuation = continuation
        }
    }

    /// `qooLibraryApp` 側（`NotificationRouterPresenterController`）の
    /// ボタン操作・アラートの dismiss から呼ばれる。
    public func resolve(_ action: RecoveryAction?) {
        pendingContinuation?.resume(returning: action)
        pendingContinuation = nil
        currentModalItem = nil
        advanceQueue()
    }

    private func advanceQueue() {
        guard !queue.isEmpty else { return }
        let next = queue.removeFirst()
        currentModalItem = next.item
        pendingContinuation = next.continuation
    }

    /// [CB-11] 強度4以上（一時通知／ログのみ）だけを履歴に残す。アプリ
    /// モーダル・シート・インラインはその場でユーザーが直接見ているため、
    /// 別途の履歴を必要としない [13.1 節の判断軸]。
    private func recordIfNeeded(_ item: NotificationItem) {
        guard item.severity >= .transient else { return }
        history.append(item)
        if history.count > historyLimit {
            history.removeFirst()
        }
    }

    /// [ER-04] 強度を問わずすべてログには残す（無言で握りつぶさない）。
    /// 1-15 以降は `OSLog` に加えて診断ログのファイルにも残るため
    /// [LG2-01]、ユーザーが「エラーが出た」と報告した際に、実際に表示された
    /// 文言と提示強度をそのまま確認できる。
    private func logToConsole(_ item: NotificationItem) {
        let message = "[強度\(item.severity.rawValue)] \(item.title): \(item.body)"
        switch item.category {
        case .error: Log.ui.error(message)
        case .warning: Log.ui.warning(message)
        case .info: Log.ui.info(message)
        }
    }
}
