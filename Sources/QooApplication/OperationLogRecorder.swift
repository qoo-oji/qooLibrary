//
//  操作履歴の書き手 [HS-01][OH-01〜OH-03][15章 §15.13]。
//
//  **書き手はここ 1 つ。** `CommandStack.record()`（実行・取り消し・やり直し・
//  失敗・中断）と走査の結果 [OH-03] の 2 経路が同じ入口を通る——記録を機能
//  ごとに散らさない [FO-03 / `NotificationRouter` と同じ考え方]。
//
//  何を記録するか・なぜ消せないのかは `OperationLogStore`（`QooKit`）の型
//  コメントにある。**触る前にそこを読むこと。**
//
import Foundation
import QooInfrastructure
import QooKit

@MainActor
@Observable
public final class OperationLogRecorder {
    public static let shared = OperationLogRecorder()

    public private(set) var store: (any OperationLogStore)?
    /// 一覧の読み直しの合図 [NW の `historyRevision` と同じ形]。
    public private(set) var revision = 0

    /// ストアが繋がる前に出た操作 [AppLimits.Operations.preAttachBufferLimit]。
    ///
    /// **起動直後の操作を取りこぼさないために要る**——退避記録の復旧 [NV-92] は
    /// `LibraryServices.bootstrap()` より前に走りうる。
    private var pendingBeforeStore: [OperationLogDraft] = []
    private var droppedBeforeStore = 0

    public init() {}

    /// 1 件記録する。
    ///
    /// **書き込みの失敗で本体の操作を止めない。** 履歴に残せなかったことを
    /// 理由に、利用者が頼んだ操作を失敗させるのは本末転倒である
    /// （`NotificationRouter.record` と同じ判断）。
    ///
    /// **並びは `date` が保つ。** 追記は投入順に完了するとは限らないが、
    /// 日時はここ（メインアクタ上、＝厳密に順序付く）で確定しており、
    /// 一覧も CSV も `date` の降順で読む。
    public func record(_ draft: OperationLogDraft) {
        guard let store else {
            bufferBeforeStore(draft)
            return
        }
        Task { [weak self] in
            do {
                try await store.append(draft)
            } catch {
                Log.command.warning("操作を履歴に残せなかった: \(String(describing: error))")
                return
            }
            self?.bumpRevision()
        }
    }

    private func bufferBeforeStore(_ draft: OperationLogDraft) {
        pendingBeforeStore.append(draft)
        if pendingBeforeStore.count > AppLimits.Operations.preAttachBufferLimit {
            pendingBeforeStore.removeFirst()
            droppedBeforeStore += 1
        }
    }

    private func bumpRevision() { revision &+= 1 }

    /// ストアを繋ぐ。`LibraryServices.bootstrap()` が 1 度呼ぶ。
    ///
    /// 繋いだ時点で **①溜めていた操作を古い順に流し込み ②期限切れと上限超過を
    /// 落とす** [HS-04]。②を起動時に行うのは、掃除の契機を追記のたびに置くと
    /// 一括処理を繰り返した日にその回数だけ削除が走るため
    /// （`SecureExtractor.cleanupResidualStaging` と同じ「後片付けは次の起動で」）。
    public func attach(_ store: any OperationLogStore,
                       retentionDays: Int, maxCount: Int) async {
        self.store = store
        let buffered = pendingBeforeStore
        pendingBeforeStore = []
        if droppedBeforeStore > 0 {
            Log.command.warning("ストアが繋がる前に \(droppedBeforeStore) 件の操作を捨てた")
            droppedBeforeStore = 0
        }
        // **1 件ずつ守る**［レビューで発見］。ループ全体を `do/catch` で囲むと、
        // 2 件目が投げた時点で 3 件目以降が**どこにも残らずに失われる**
        // （`pendingBeforeStore` は既に空にしてある）。
        for draft in buffered {
            do {
                try await store.append(draft)
            } catch {
                Log.command.warning("溜めていた操作を履歴に残せなかった: \(String(describing: error))")
            }
        }
        // **掃除は追記と別に守る**［同］。同じ catch に入れると、追記が 1 件
        // 失敗しただけでその起動の掃除 [HS-04] が丸ごと飛ぶ——掃除の契機は
        // 起動時 1 度きりなので、次の起動まで上限が効かない。
        do {
            try await store.purgeExpired(retentionDays: retentionDays, maxCount: maxCount)
        } catch {
            Log.command.warning("操作履歴を掃除できなかった: \(String(describing: error))")
        }
        bumpRevision()
    }

    // MARK: - 保持の設定 [HS-04][OH-05]

    public static let retentionDaysKey = "qoo.operations.retentionDays"
    public static let maxCountKey = "qoo.operations.maxCount"

    public static func configuredRetentionDays(_ defaults: UserDefaults = .standard) -> Int {
        configured(retentionDaysKey, in: defaults,
                   default: AppLimits.Operations.defaultRetentionDays)
    }

    public static func configuredMaxCount(_ defaults: UserDefaults = .standard) -> Int {
        configured(maxCountKey, in: defaults, default: AppLimits.Operations.defaultMaxCount)
    }

    /// **キーが無いときだけ既定を使う。** `integer(forKey:)` は未設定でも 0 を
    /// 返すので、素で読むと「無制限」と区別が付かない（環境設定で 0 ＝
    /// 無制限を選べる）。
    private static func configured(_ key: String, in defaults: UserDefaults,
                                   default fallback: Int) -> Int {
        guard defaults.object(forKey: key) != nil else { return fallback }
        return defaults.integer(forKey: key)
    }
}
