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
/// ## 通知履歴 [NT-01][NW-01〜08]
/// `attachHistoryStore(_:retentionDays:maxCount:)` を `LibraryServices.bootstrap()`
/// が 1 度呼ぶと、以後すべての通知が `notificationRecord` へ落ちる。
/// **ここが唯一の書き手**——記録を機能ごとに散らさない。何を残すか・
/// 未読の定義は `record(_:)` のコメントにある。
///
/// まだ実装していないもの: `BatchNotificationSession`（ER-10〜16、
/// 「以降すべてに適用」・結果サマリ）は、現時点でこれを必要とする一括処理
/// フロー自体がまだ無い（既存の一括処理は単純な「最初の失敗で中断」処理に
/// 留まっている）ため、具体的な呼び出し元が無いまま作る投機的な実装になって
/// しまう。`SystemNotificationGate`（ER-30〜34）は今回の範囲外
/// ［ユーザー判断、2026-08］——権限要求・アプリの活性状態の監視・30 秒以上の
/// 計測という別の関心事で、サンドボックス下の実機検証も別途要る。
///
/// **通知履歴はライブラリ DB に載っている** [07章 §7.3]。DB を開けない起動
/// （`LibraryServices.startupFailure`）では履歴が使えず、その間の通知は
/// 最大 `AppLimits.Notifications.preAttachBufferLimit` 件だけ溜まって
/// そのまま失われる——通知そのものは従来どおり出るので、知らせ損ねはしない。
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

    /// 未読件数 [NT-02]。ステータスバーのバッジが**これだけ**を出す
    /// ——孤立 [OR-05]・ペンディング [PW-14]・再スキャン警告 [MX-10] の
    /// 個別バッジは持たない [NT-06]。
    public private(set) var unreadCount = 0

    /// 履歴が変わるたびに増える。開いている履歴ウインドウが読み直す合図で、
    /// 値そのものに意味は無い（`LibraryServices.contentRevision` と同じ形）。
    public private(set) var historyRevision = 0

    /// 通知履歴の実体 [NT-01][02章 §2.4]。`LibraryServices.bootstrap()` が
    /// 繋ぐ。**繋がるまでの通知は下の待ち行列に溜める。**
    @ObservationIgnored
    public private(set) var historyStore: (any NotificationHistoryStore)?

    /// ストアが繋がる前に出た通知 [AppLimits.Notifications.preAttachBufferLimit]。
    ///
    /// **起動直後の通知を取りこぼさないために要る**——退避記録の復旧 [NV-92]・
    /// 登録フォルダの読み込み失敗・残存ステージングの後始末は、どれも
    /// `bootstrap()` より前に走りうる。
    @ObservationIgnored
    private var pendingBeforeStore: [NotificationItem] = []
    @ObservationIgnored
    private var droppedBeforeStore = 0
    @ObservationIgnored
    private var unreadCountGeneration = 0

    private var pendingContinuation: CheckedContinuation<RecoveryAction?, Never>?
    private var queue: [(item: NotificationItem, continuation: CheckedContinuation<RecoveryAction?, Never>)] = []

    public init() {}

    /// [CB-10] `severity` に応じて提示手段を自動選択する。呼び出し側は
    /// 提示手段を指定できない。
    @discardableResult
    public func present(_ item: NotificationItem) async -> RecoveryAction? {
        logToConsole(item)
        record(item)

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

    /// 履歴に残す [NT-01][CB-11]。
    ///
    /// **強度を問わずすべて残す**［ユーザー判断、2026-08］。要件は「強度 4 以上」
    /// と定めていたが、着手前の実測で **`.transient` を使う呼び出しは 3 箇所、
    /// 残り 70 箇所超はすべて `.sheet`** と分かった——そのままでは履歴が常に
    /// 空になり、NW-01 の「エラー」区分は永久に 0 件になる。
    /// **未読に数えるのは従来どおり強度 4 以上**（`StoredNotification.countsAsUnread`）
    /// なので、シートを目の前で閉じた直後にバッジが立つ雑音は起きない。
    ///
    /// **書き込みの失敗で通知そのものを止めない。** 履歴に残せなかったことを
    /// 理由に、利用者へ知らせるべきことを知らせないのは本末転倒である。
    private func record(_ item: NotificationItem) {
        guard let store = historyStore else {
            bufferBeforeStore(item)
            return
        }
        Task { [weak self] in
            do {
                try await store.append(item)
            } catch {
                Log.ui.warning("通知を履歴に残せなかった: \(String(describing: error))")
                return
            }
            // **足し込まずに数え直す**［レビューで発見］。楽観的に `+= 1` すると、
            // 別の経路が走らせた `refreshUnreadCount()`（COUNT）の結果が後から
            // 到着して上書きし、バッジが多くも少なくもなる。COUNT は
            // 高々 1,000 行（`purgeExpired` の上限 [NT-07]）なので安い。
            await self?.noteHistoryChanged()
        }
    }

    private func bufferBeforeStore(_ item: NotificationItem) {
        pendingBeforeStore.append(item)
        if pendingBeforeStore.count > AppLimits.Notifications.preAttachBufferLimit {
            pendingBeforeStore.removeFirst()
            droppedBeforeStore += 1
        }
    }

    /// 通知履歴のストアを繋ぐ [NT-01]。`LibraryServices.bootstrap()` が 1 度呼ぶ。
    ///
    /// 繋いだ時点で **①溜めていた通知を古い順に流し込み ②期限切れと上限超過を
    /// 落とし [NT-07] ③未読件数を数え直す**。②を起動時に行うのは、
    /// 掃除の契機を追記のたびに置くと 1 万件の通知が出た日に 1 万回走るため
    /// （`SecureExtractor.cleanupResidualStaging` と同じ「後片付けは次の起動で」）。
    public func attachHistoryStore(_ store: any NotificationHistoryStore,
                                   retentionDays: Int, maxCount: Int) async {
        historyStore = store
        let buffered = pendingBeforeStore
        pendingBeforeStore = []
        if droppedBeforeStore > 0 {
            Log.ui.warning("ストアが繋がる前に \(droppedBeforeStore) 件の通知を捨てた")
            droppedBeforeStore = 0
        }
        do {
            for item in buffered {
                try await store.append(item)
            }
            try await store.purgeExpired(retentionDays: retentionDays, maxCount: maxCount)
        } catch {
            Log.ui.warning("通知履歴の初期化に失敗した: \(String(describing: error))")
        }
        await refreshUnreadCount()
        historyRevision &+= 1
    }

    /// 未読件数を数え直す [NT-02]。既読化・削除のあとに呼ぶ。
    ///
    /// **世代番号で古い結果を捨てる。** 数え直しは同時に何本も走りうる
    /// （通知の追記・既読化・削除）ので、素直に代入すると先に投げた COUNT の
    /// 結果が後から着いて新しい値を上書きする（`FileSystemEventStream` の
    /// ルート差し替えと同じ形）。
    public func refreshUnreadCount() async {
        guard let historyStore else { unreadCount = 0; return }
        unreadCountGeneration &+= 1
        let generation = unreadCountGeneration
        do {
            let counted = try await historyStore.unreadCount()
            guard generation == unreadCountGeneration else { return }
            unreadCount = counted
        } catch {
            Log.ui.warning("未読件数を数えられない: \(String(describing: error))")
        }
    }

    /// 履歴を書き換えたことを知らせる。ウインドウ側が既読化・削除のあとに呼ぶ。
    public func noteHistoryChanged() async {
        await refreshUnreadCount()
        historyRevision &+= 1
    }

    // MARK: - 環境設定の鍵 [NT-07]

    /// 保持期間（日）。`0` 以下なら期限では消さない。
    public static let retentionDaysKey = "qoo.notifications.retentionDays"
    /// 保持件数の上限。`0` 以下なら件数では消さない。
    public static let maxCountKey = "qoo.notifications.maxCount"

    public static func configuredRetentionDays(
        _ defaults: UserDefaults = .standard) -> Int {
        guard defaults.object(forKey: retentionDaysKey) != nil else {
            return AppLimits.Notifications.defaultRetentionDays
        }
        return defaults.integer(forKey: retentionDaysKey)
    }

    public static func configuredMaxCount(_ defaults: UserDefaults = .standard) -> Int {
        guard defaults.object(forKey: maxCountKey) != nil else {
            return AppLimits.Notifications.defaultMaxCount
        }
        return defaults.integer(forKey: maxCountKey)
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
