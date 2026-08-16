import AppKit
import QooApplication
import QooInfrastructure
import QooKit
import SwiftUI

/// 中央ペイン（`FolderContentView`）とフォルダツリー（`FolderTreePane`）が
/// 共有するファイル操作レイヤ。
///
/// **なぜ独立した型にするのか** [ユーザー要望でフォルダツリーにも中央ペインと
/// 同じコンテキストメニューを付けたため]: 複製・コピー／カット・ペースト・
/// ゴミ箱・圧縮・展開・エイリアス・ロック・新規フォルダといった同じ操作を
/// 2 箇所で別々に実装すると、片方だけ直したときに挙動が静かにずれていく。
/// ここに一本化し、対象 URL と書き込み先フォルダを引数で受け取る形にする
/// ことで、「中央ペインは現在のフォルダ、ツリーは右クリックした行の親
/// フォルダ」といった違いを呼び出し側の引数だけで吸収する。
///
/// 守っている制約:
/// - すべての変更操作は `CommandStack.shared` 経由で実行する [A-03][UD-02]。
///   ファイルシステムの変更自体は各 `Command` が `FileOperationService` に
///   委譲する [FO-01][FO-02]。
/// - エラー提示は必ず `NotificationRouter` 経由 [ER-01]。
/// - **一覧の更新はここでは行わない** [10章 §10.0]。ファイルが実際に動けば
///   `FileOperationService` が `DirectoryChangeHub` へ伝え、影響を受ける
///   フォルダを表示しているウインドウ・ペインだけが読み直す。`onSuccess` は
///   「作ったファイルを選択してスクロールする」など、**その呼び出し元だけが
///   やりたいこと**のために残してある。
///
/// この型は View ではないため `@Environment(\.locale)`/`@AppStorage` を
/// 使えない。表示言語は `AppLanguage.effectiveLocale`、環境設定は
/// `UserDefaults` の直接読み取りで参照する [1-12 ローカライズ方針、
/// `WindowState.loadDefaultListStyle()` と同じパターン]。設定値は操作を
/// 実行する瞬間に読むため、リアクティブな購読が無くても常に最新の値になる。
@MainActor
@Observable
final class FolderOperations {
    /// 実行中の処理の見出し [UI-09]。**描画は
    /// `OperationProgressCenter` 経由で別ウインドウが行う**［ユーザー要望］。
    /// ここが `nil` でないことは「この操作レイヤが何か走らせている」ことを
    /// 表すだけで、画面上のどこにも直接は出ない。
    var busyMessage: String?
    /// `OperationProgressCenter` に登録した処理の控え。
    private var progressHandle: OperationProgressCenter.Handle?
    /// `currentPauseToken` の実体。`endProgress()` で捨てる。
    private var pauseTokenForCurrentOperation: PauseToken?
    /// 進行中の転送の進み具合 [UI-09][A-04]。`busyMessage` と対で使い、
    /// 総量が分かっていれば確定進捗、分からなければ不定進捗になる。
    var progress: OperationProgress?
    /// 実行中の転送。進捗シートの「キャンセル」はこれを取り消す
    /// （`FileCopyEngine` がコールバックで `Task.isCancelled` を見ている）。
    var cancellableTask: Task<Void, Never>?
    /// 衝突の判断を待っている状態 [FM-11]。
    var pendingConflict: PendingConflict?
    /// [FM-12]「以降すべてに適用」が選ばれたあとの一括判断。1 回の操作の間だけ
    /// 有効で、次の操作の開始時にリセットする。
    private var conflictBlanketDecision: ConflictPolicy?
    /// 完全削除の一連のダイアログ（確認 → ロック済み項目の判断）。
    ///
    /// **1 つの `@State` に enum でまとめる** — 確認シートを閉じた直後に
    /// ロック確認シートを出す、という連続した遷移になるため、別々の
    /// `.sheet` 修飾子を重ねると表示が不安定になりやすい
    /// [`FolderTreePane.FolderTreePrompt` が `.alert` で同じ理由の対処を
    /// している。既存の圧縮／展開パスワードシートは互いに独立した経路で
    /// 連続遷移しないため、そのまま個別の `.sheet` に残している]。
    var pendingDeletionStep: PermanentDeletionStep?

    private var locale: Locale { AppLanguage.effectiveLocale }

    /// [ER-11]「以降すべてに適用」が選ばれたあとの一括判断。1 回の完全削除
    /// 操作の間だけ有効で、次の操作の開始時にリセットする。
    private var lockedItemBlanketDecision: LockedItemDecision?

    // MARK: - コマンド実行の共通経路

    /// `CommandStack` でコマンドを実行し、成功時に `onSuccess`、失敗時に
    /// `NotificationRouter` へのエラー提示までを行う唯一の経路。`command` が
    /// `nil`（対象が空で実行するものが無い）なら何もしない。
    ///
    /// **一覧の更新はここでは行わない** [10章 §10.0]。コマンドが実際に
    /// ファイルを動かせば `FileOperationService` が `DirectoryChangeHub` へ
    /// 伝え、影響を受けるフォルダを表示しているすべてのウインドウ・ペインが
    /// 読み直す。`onSuccess` は「作ったファイルを選択する」など、**この
    /// 呼び出し元だけがやりたいこと**のために残してある。
    private func run(
        _ command: (any Command)?,
        failure: String.LocalizationValue,
        busyMessageKey: String.LocalizationValue? = nil,
        onSuccess: @escaping @MainActor () -> Void
    ) {
        guard let command else { return }
        let showsProgress = busyMessageKey != nil
        // 一時停止は「バイトを運ぶ処理」にだけ意味がある。`transferOptions()`
        // が同じトークンを `OpOptions` へ渡しているので、ここで作った 1 個が
        // 窓のボタンと実際の処理の両方に届く。
        let pauseToken = showsProgress ? currentPauseToken : nil
        let task = Task {
            defer {
                // 通常はこの下で明示的に片付け済み。ここは取りこぼしへの
                // 保険（`endProgress` は 2 回呼んでも無害）。
                //
                // **自分が出した表示だけを片付ける** [レビューで発見]。
                // 無条件に消すと、進捗を出さない操作（複製など）が終わった
                // ときに、並行して走っている転送の進捗まで消えてしまう。
                if showsProgress { endProgress() }
            }
            var failed: (any Error)?
            var partial: CommandResult?
            do {
                let result = try await CommandStack.shared.run(command)
                // **一部だけ終わった場合も必ず知らせる** [ER-12][ER-14]。
                // 例外は投げられないので、ここで拾わないと「エラーも出ずに
                // 一部のファイルだけが動いた」状態になる。提示は進捗表示を
                // 片付けたあとで行う（下記）。
                if case .partial(_, let failures) = result, !failures.isEmpty {
                    partial = result
                }
                onSuccess()
            } catch is CancellationError {
                // ユーザー自身が止めたので、失敗として提示しない。
            } catch {
                // 取り消し直後は下位から任意のエラーが返り得る（中断した処理の
                // 後片付けが失敗した等）。それも提示しない。
                //
                // **OS が出したダイアログでのキャンセルも同じ扱いにする**
                // [NV4-03]。ゴミ箱を持たない場所での `NSWorkspace.recycle` は
                // macOS の確認ダイアログを出し、キャンセルすると
                // `NSUserCancelledError` を返す。これを提示すると
                // **ユーザーが自分でキャンセルしたのにエラーが出る**。
                if !Task.isCancelled, !CommandStack.isCancellation(error) { failed = error }
            }
            // **エラーを見せる前に進捗表示を片付ける** [実機検証で発見]。
            // `presentError` はユーザーがダイアログを閉じるまで完了しない
            // （`NotificationRouter.presentModally` が `withCheckedContinuation`
            // で待つ）。`defer` に任せていたため、失敗したコピーの進捗ウインドウが
            // 「2.91 GB / 4.29 GB」で止まったまま、エラーダイアログの後ろに
            // residual として残り続けていた。
            if showsProgress { endProgress() }
            if let failed {
                await NotificationRouter.shared.presentError(
                    failed, whatHappened: String(localized: failure, locale: locale)
                )
            } else if case let .partial(succeeded, failures)? = partial {
                await NotificationRouter.shared.present(NotificationItem(
                    category: .warning, severity: .sheet,
                    title: String(localized: "error.partiallyCompleted", locale: locale),
                    body: Self.partialSummary(command: command, succeeded: succeeded, failed: failures)
                ))
            }
        }
        if let busyMessageKey {
            cancellableTask = task
            // 中断手段は**この時点で**渡す。あとから差し込む形にすると、
            // 窓が出た最初の描画でボタンが出ない。
            beginProgress(
                String(localized: busyMessageKey, locale: locale),
                cancel: { task.cancel() }, pauseToken: pauseToken
            )
        }
    }

    /// 部分的にしか終わらなかったときの本文 [ER-14]。何件が済み、何が残り、
    /// なぜ止まったのかを並べる。件数が多いときは先頭数件に絞る
    /// （全部並べるとダイアログが画面外まで伸びる）。
    private static func partialSummary(
        command: any Command, succeeded: Int, failed: [FailedItem]
    ) -> String {
        let locale = AppLanguage.effectiveLocale
        var lines = [command.displayName, ""]
        lines.append(String(
            format: String(localized: "error.partialCounts", locale: locale), succeeded, failed.count
        ))
        for item in failed.prefix(5) {
            lines.append("• \(item.item): \(item.reason)")
        }
        if failed.count > 5 {
            lines.append(String(
                format: String(localized: "error.partialMore", locale: locale), failed.count - 5
            ))
        }
        return lines.joined(separator: "\n")
    }

    /// コピー・移動に渡す共通の `OpOptions` [FM-11][FM-12][UI-09]。
    ///
    /// **`.ask` を既定にする** — 以前はすべて `.keepBoth` 固定で、ユーザーは
    /// 一度も尋ねられなかった。「新しい版で上書きしたい」つもりの操作が黙って
    /// 「名前 2」を増やす、という意図と違う結果になっていた。
    /// - Important: 呼ぶたびに「以降すべてに適用」の記憶を捨てる [FM-12]。
    ///   **`run()` の中でリセットしてはいけない** — D&D は `run()` を通らない
    ///   ため、前回の「置き換える」が次のドロップへ持ち越され、確認なしで
    ///   上書きしてしまう [レビューで発見]。1 回の操作 ＝ 1 回の
    ///   `transferOptions()` なので、ここが正しい置き場所。
    func transferOptions() -> OpOptions {
        conflictBlanketDecision = nil
        return OpOptions(
            conflictPolicy: .ask,
            conflictResolver: { [weak self] source, destination in
                await self?.askConflictDecision(source: source, destination: destination) ?? .skip
            },
            progress: progressReporter,
            pauseToken: currentPauseToken
        )
    }

    /// いま実行中（またはこれから始める）1 回の操作で共有する一時停止トークン。
    /// **操作ごとに作り直す** — 前の操作で一時停止したまま終わった状態が
    /// 次の操作へ持ち越されると、始めた途端に止まっているように見える。
    private var currentPauseToken: PauseToken {
        if let pauseTokenForCurrentOperation { return pauseTokenForCurrentOperation }
        let token = PauseToken()
        pauseTokenForCurrentOperation = token
        return token
    }

    /// 進捗の報告先。転送・圧縮・展開のすべてが同じ窓へ流れるよう共有する。
    private var progressReporter: ProgressReporter {
        ProgressReporter { [weak self] value in
            Task { @MainActor in self?.publish(value) }
        }
    }

    /// [FM-11][FM-12] 衝突 1 件ごとの判断。「以降すべてに適用」が選ばれて
    /// いれば以後は尋ねずにその判断を使う。
    ///
    /// 継続の扱いは `askLockedItemDecision` と同じ — 必ず 1 回だけ再開し、
    /// シートが現れなかった場合の保険を置く（返らないと操作が止まる）。
    private func askConflictDecision(source: URL, destination: URL) async -> ConflictPolicy {
        if let blanket = conflictBlanketDecision { return blanket }
        return await withCheckedContinuation { continuation in
            let pending = PendingConflict(source: source, destination: destination) { [self] policy, applyToAll in
                if applyToAll { conflictBlanketDecision = policy }
                continuation.resume(returning: policy)
            }
            pendingConflict = pending
            Task { [weak pending] in
                try? await Task.sleep(for: .seconds(2))
                guard let pending, !pending.didAppear else { return }
                Log.ui.error("衝突ダイアログが表示されませんでした。安全側にスキップします: \(Log.path(destination))")
                pending.resolve(.skip, applyToAll: false)
                if pendingConflict === pending { pendingConflict = nil }
            }
        }
    }

    /// 進捗表示を出す**唯一の入口**。`busyMessage` を直に書かないこと —
    /// 書くと別ウインドウに現れない［ユーザー要望: 進捗はすべてウインドウへ］。
    ///
    /// - Parameter cancel: 中断手段。無い処理では `nil`（ボタンを出さない）。
    private func beginProgress(
        _ title: String, cancel: (@MainActor () -> Void)? = nil, pauseToken: PauseToken? = nil
    ) {
        busyMessage = title
        progressHandle = OperationProgressCenter.shared.begin(
            title: title, cancel: cancel, pauseToken: pauseToken
        )
    }

    /// `beginProgress` と対で必ず呼ぶ（`defer` で呼ぶのが安全）。
    private func endProgress() {
        busyMessage = nil
        progress = nil
        cancellableTask = nil
        pauseTokenForCurrentOperation = nil
        if let handle = progressHandle {
            OperationProgressCenter.shared.finish(handle)
            progressHandle = nil
        }
    }

    /// 進捗を別ウインドウへ流す。
    private func publish(_ value: OperationProgress) {
        progress = value
        guard let progressHandle else { return }
        OperationProgressCenter.shared.update(progressHandle, progress: value, detail: progressDetail)
    }

    /// 進捗の副題。「3/12 件 — 1.2 GB / 8.4 GB」のように、件数と
    /// バイト数の両方を出す（どちらか片方では「あと何個か」「あとどれくらいか」
    /// のどちらかが分からない）。
    var progressDetail: String? {
        guard let progress else { return nil }
        var parts: [String] = []
        if progress.totalItems > 1 {
            // 「今 N 件目を処理中」。**総数を超えないよう頭打ちにする** —
            // 最後の 1 件を終えた直後は `completedItems == totalItems` になり、
            // 素朴に +1 すると「150 件中 151 件目」と出る（実機で確認）。
            let current = min(progress.completedItems + 1, progress.totalItems)
            parts.append(String(
                format: String(localized: "progress.itemCount", locale: locale),
                current, progress.totalItems
            ))
            // **残り件数も明示する**［ユーザー要望: 総数と残り数が知りたい］。
            // 「12 件中 3 件目」からも引き算すれば分かるが、待っている側に
            // 暗算を強いる表示にしない。
            let remaining = max(0, progress.totalItems - progress.completedItems)
            if remaining > 0 {
                parts.append(String(
                    format: String(localized: "progress.remainingItems", locale: locale), remaining
                ))
            }
        }
        if progress.totalBytes > 0 {
            let formatter = ByteCountFormatter()
            parts.append("\(formatter.string(fromByteCount: progress.completedBytes)) / \(formatter.string(fromByteCount: progress.totalBytes))")
        }
        // 処理中のファイル名はここには入れない — 窓が独立した行として
        // 出すため（`OperationProgressWindowContent`）。件数・バイト数と
        // 同じ行に混ぜると、名前が長いときに数字が押し出されて読めなくなる。
        return parts.isEmpty ? nil : parts.joined(separator: " — ")
    }

    /// 複数のコマンドを 1 回の操作として 1 つの Undo 単位にまとめる [UD-04]。
    /// 1 件ならそのまま返し、0 件なら `nil`（実行するものが無い）。
    static func singleOrComposite(_ commands: [any Command], displayName: String) -> (any Command)? {
        if commands.isEmpty { return nil }
        if commands.count == 1 { return commands[0] }
        return CompositeCommand(displayName: displayName, children: commands)
    }

    // MARK: - 基本のファイル操作

    /// [FM-02] 複製。書き込み先は呼び出し側が決める（中央ペインは現在の
    /// フォルダ、ツリーは対象フォルダの親）。
    /// **複製は尋ねない** — Finder も ⌘D では確認せず、常に「名前 2」を作る。
    /// 「同じ場所にもう 1 つ」が操作の意図そのものだから。
    func duplicate(_ urls: [URL], into destination: URL, onSuccess: @escaping @MainActor () -> Void = {}) {
        guard !urls.isEmpty else { return }
        run(CopyFilesCommand(items: urls, destination: destination), failure: "error.duplicateFailed", onSuccess: onSuccess)
    }

    /// Finder の「名前を変更…」（複数選択時）[ユーザー要望]。
    /// ここではシートを出すだけで、実行は `runBulkRename` から。
    /// - Important: 対象は**すべて同じフォルダにある**必要がある。検索結果
    ///   （再帰）ではサブフォルダの項目が混ざり得るため、呼び出し側が
    ///   絞ってから渡すこと [レビューで発見: 表示中のフォルダと項目名を
    ///   組み合わせて URL を作っていたため、別のファイルを改名しかねなかった]。
    func beginBulkRename(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let parents = Set(urls.map { $0.deletingLastPathComponent().standardizedFileURL })
        guard let folder = parents.first, parents.count == 1 else {
            Task {
                await NotificationRouter.shared.present(NotificationItem(
                    category: .error, severity: .sheet,
                    title: String(localized: "error.operationFailed", locale: locale),
                    body: String(localized: "bulkRename.sameFolderOnly", locale: locale)
                ))
            }
            return
        }
        let names = urls.map(\.lastPathComponent)
        Task {
            // 衝突判定は**実際のフォルダの中身**と突き合わせる（表示中の一覧では
            // なく）。対象自身は除く — 自分とぶつかっていると誤判定しないため。
            //
            // **一覧の読み取りは `FileIO` 経由でなければならない** [NV6-02]。
            // この型は `@MainActor` なので、ここで直に読むと**メインスレッドが
            // 止まる**——応答しない共有では SMB で 30 秒、NFS なら無限に。
            let siblings = await FileIO.perform {
                (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            }
            let request = PendingBulkRename(
                folder: folder,
                names: names,
                existingNames: Set(siblings).subtracting(Set(names))
            )
            DialogWindowPresenter.shared.present(
                title: BulkRenameDialog.windowTitle(count: request.names.count, locale: locale)
            ) { _ in
                BulkRenameDialog(names: request.names, existingNames: request.existingNames) { changes in
                    self.runBulkRename(request, changes: changes)
                }
            }
        }
    }

    func runBulkRename(_ request: PendingBulkRename, changes: [BulkRename.Change]) {
        run(
            BulkRenameCommand(folder: request.folder, changes: changes),
            failure: "error.bulkRenameFailed", busyMessageKey: "folder.renaming"
        ) {}
    }

    /// D&D の実行 [DD-01]。**他の経路と同じ**進捗・キャンセル・衝突の扱いに
    /// するため、`run()` を通す [レビューで発見: D&D だけ進捗もキャンセルも
    /// 出なかった]。
    func runDrop(_ command: any Command, isMove: Bool, onComplete: @escaping @MainActor () -> Void) {
        run(
            command, failure: "error.operationFailed",
            busyMessageKey: isMove ? "folder.moving" : "folder.copying",
            onSuccess: onComplete
        )
    }

    /// [FM-11] コピー（ペースト・D&D）。衝突したら尋ねる。
    func copy(_ urls: [URL], into destination: URL, onSuccess: @escaping @MainActor () -> Void = {}) {
        guard !urls.isEmpty else { return }
        run(
            CopyFilesCommand(items: urls, destination: destination, options: transferOptions()),
            failure: "error.pasteFailed", busyMessageKey: "folder.copying", onSuccess: onSuccess
        )
    }

    /// [FM-11] 移動（カット＆ペースト・D&D）。衝突したら尋ねる。
    func move(_ urls: [URL], into destination: URL, onSuccess: @escaping @MainActor () -> Void = {}) {
        guard !urls.isEmpty else { return }
        run(
            MoveFilesCommand(items: urls, destination: destination, options: transferOptions()),
            failure: "error.moveFailed", busyMessageKey: "folder.moving", onSuccess: onSuccess
        )
    }

    /// [FM-04] ゴミ箱に入れる（Finder のゴミ箱と互換 [TR2-01]）。
    ///
    /// **ゴミ箱を持たない場所では、完全削除の確認へ振り替える** [NV4-02]。
    /// SMB 3 系統すべてでゴミ箱が無いことを実測しており（8章 §8.11.4）、
    /// そのまま `NSWorkspace.recycle` を呼ぶと:
    ///
    /// - macOS の**素の**確認ダイアログが出る（件数・合計サイズ [PD-02] も、
    ///   登録フォルダが強制解除される警告 [PD-14] も出ない）
    /// - 承諾すると完全削除されるが**返却 URL が 0 件**なので、
    ///   `TrashReceipt.trashURL` が `nil` になり **⌘Z が無言で何もしない**
    ///
    /// 振り替え先は既存の完全削除フロー（アプリ自身の確認シート →
    /// `DeletePermanentlyCommand`）で、**Undo スタックには積まれない** [PD-05]。
    /// 「ゴミ箱に入れたのに取り消せない」という食い違いも同時に消える。
    func moveToTrash(_ urls: [URL], onSuccess: @escaping @MainActor () -> Void = {}) {
        guard !urls.isEmpty else { return }
        Task {
            // ゴミ箱の有無の問い合わせは I/O なのでメインスレッドで行わない
            // [NV6-02]。接続中は 0.01 秒だが、**無応答の共有では約 30 秒
            // ブロックする**（遮断計測 §8.11.16 の実測 29,987 ms。以前は
            // ここで同期に呼んでおり、NAS が応答しなくなった直後の削除で
            // メインスレッドが固まる穴だった）。
            let hasTrash = await FileIO.perform { TrashAvailability.hasTrash(forAll: urls) }
            guard hasTrash else {
                pendingDeletionStep = .confirm(PendingPermanentDeletion(
                    urls: urls, becauseNoTrash: true, onSuccess: onSuccess
                ))
                return
            }
            run(TrashCommand(items: urls), failure: "error.trashFailed", onSuccess: onSuccess)
        }
    }

    // MARK: - 完全削除 [FM-14〜FM-18、8章 §8.5]

    /// [FM-14] ゴミ箱を経由しない完全削除。**必ず確認シートを挟む**
    /// [FM-15][PD-02][UD-10] — ここでは実行せず、確認状態を立てるだけ。
    /// 実際の実行は `runPermanentDeletion(_:)`（シートの決定ボタン）から。
    func deletePermanently(_ urls: [URL], onSuccess: @escaping @MainActor () -> Void = {}) {
        guard !urls.isEmpty else { return }
        pendingDeletionStep = .confirm(PendingPermanentDeletion(urls: urls, onSuccess: onSuccess))
    }

    /// 確認シートで「削除」が押されたあとの実行本体。
    ///
    /// `CommandStack` 経由で実行するのは他の操作と同じだが、
    /// `DeletePermanentlyCommand.isUndoable == false` のため Undo スタックには
    /// 積まれない [PD-05]。操作履歴 [HS-01] には残る。
    func runPermanentDeletion(_ request: PendingPermanentDeletion) {
        // 「以降すべてに適用」は 1 回の削除操作ごとにリセットする [ER-11]。
        lockedItemBlanketDecision = nil
        // 完全削除は中断できない [PD-05] ので、キャンセル手段は渡さない。
        beginProgress(String(localized: "permanentDelete.deleting", locale: locale))
        let command = DeletePermanentlyCommand(
            items: request.urls,
            options: DeletePermanentlyOptions(lockedItemResolver: { [self] url in
                await askLockedItemDecision(url)
            })
        )
        Task {
            defer { endProgress() }
            do {
                _ = try await CommandStack.shared.run(command)
                request.onSuccess()
                // **完全削除だけは別途知らせる** [10章 §10.0 の例外]。
                // 消えた項目が登録フォルダ（ライブラリ／テンポラリ）だった
                // 場合、`DeletePermanentlyCommand` がその登録も強制解除する
                // [FM-14]。それは「ファイルの中身」ではなく左ペインが持つ
                // 一覧の変化なので、`DirectoryChangeHub` ではなくこちらの
                // 信号で伝える。
                SessionState.shared.reloadToken += 1
                await presentDeletionSummaryIfNeeded(command)
            } catch {
                await NotificationRouter.shared.presentError(
                    error, whatHappened: String(localized: "error.deletePermanentlyFailed", locale: locale)
                )
                SessionState.shared.reloadToken += 1
            }
        }
    }

    /// [PD-06][ER-11] ロック済み項目 1 件ごとの判断。「以降すべてに適用」が
    /// 選ばれていれば以後は尋ねずにその判断を使う。
    ///
    /// **継続（`CheckedContinuation`）は必ず 1 回だけ再開しなければならない。**
    /// シートを Esc 等で閉じた場合にボタンのコールバックが呼ばれないまま
    /// 終わると、この `await` が永久に返らずアプリが固まる。そのため
    /// `PendingLockedItem` 側で「一度しか呼ばれない」ことを保証し、
    /// 閉じられた場合は安全側の `.skip` で再開する。
    private func askLockedItemDecision(_ url: URL) async -> LockedItemDecision {
        if let blanket = lockedItemBlanketDecision { return blanket }
        return await withCheckedContinuation { continuation in
            let pending = PendingLockedItem(url: url) { [self] decision, applyToAll in
                if applyToAll { lockedItemBlanketDecision = decision }
                continuation.resume(returning: decision)
            }
            pendingDeletionStep = .lockedItem(pending)
            // **シートが実際に現れなかった場合の保険。**
            // 直前に確認シートを閉じたばかりのタイミングで次のシートを要求する
            // ため、SwiftUI が「閉じながら開く」要求を取りこぼすと、シートが
            // 一度も現れず `.onDisappear` の安全網も働かない。そうなると
            // ここの `await` が永久に返らず、「削除しています…」の表示のまま
            // アプリが操作不能になる（削除処理の途中なので影響も大きい）。
            //
            // 現れたかどうかは `didAppear` で判定するため、**ユーザーが
            // 長考している場合にこの保険が誤発動することはない**。
            Task { [weak pending] in
                try? await Task.sleep(for: .seconds(2))
                guard let pending, !pending.didAppear else { return }
                Log.ui.error("ロック確認シートが表示されませんでした。安全側にスキップします: \(Log.path(url))")
                pending.resolve(.skip, applyToAll: false)
                if case .lockedItem(let current) = pendingDeletionStep, current === pending {
                    pendingDeletionStep = nil
                }
            }
        }
    }

    /// [ER-12][ER-14] 完了後の結果サマリ。全件成功なら何も出さない
    /// （成功を報告するだけのダイアログは邪魔なため）。失敗・スキップが
    /// あった場合と、登録フォルダを強制解除した場合にだけ提示する。
    private func presentDeletionSummaryIfNeeded(_ command: DeletePermanentlyCommand) async {
        guard let outcome = command.outcome else { return }
        var lines: [String] = []
        if !outcome.failures.isEmpty || !outcome.skipped.isEmpty {
            lines.append(String(
                format: String(localized: "permanentDelete.summaryCounts", locale: locale),
                outcome.succeededCount, outcome.failures.count, outcome.skipped.count
            ))
            // [ER-14] 失敗は理由別の内訳が分かるようにまとめる。
            let byReason = Dictionary(grouping: outcome.failures, by: \.reason)
            for (reason, items) in byReason.sorted(by: { $0.value.count > $1.value.count }) {
                lines.append("• \(reason)（\(items.count)）: \(items.prefix(3).map { $0.url.lastPathComponent }.joined(separator: ", "))")
            }
        }
        if !command.unregisteredFolders.isEmpty {
            lines.append(String(
                format: String(localized: "permanentDelete.summaryUnregistered", locale: locale),
                command.unregisteredFolders.map(\.displayName).joined(separator: ", ")
            ))
        }
        guard !lines.isEmpty else { return }
        await NotificationRouter.shared.present(NotificationItem(
            category: outcome.failures.isEmpty ? .info : .warning,
            severity: .sheet,
            title: String(localized: "permanentDelete.summaryTitle", locale: locale),
            body: lines.joined(separator: "\n")
        ))
    }

    /// [FM-05] 名前を変更。名前が変わっていなければ何もしない
    /// （Undo スタックへの無意味な積み増しを避ける）。
    ///
    /// 使えない名前（`/` を含む等）は**実行せず理由を伝える**［監査で発見。
    /// 以前はそのまま実行し、`/` がパス区切りとして解釈されて別フォルダへの
    /// 移動になっていた＝ユーザーから見ればファイルが消えた］。
    func rename(_ url: URL, to newName: String, onSuccess: @escaping @MainActor () -> Void = {}) {
        guard !newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard let validName = validatedName(newName, whatHappened: "error.renameFailed") else { return }
        guard validName != url.lastPathComponent else { return }
        run(RenameCommand(item: url, newName: validName), failure: "error.renameFailed", onSuccess: onSuccess)
    }

    /// [FM-01] `parent` の中に新規フォルダを作る。
    ///
    /// **URL を組み立てる前に名前を検証する**［監査で発見］。`/` を含む名前を
    /// そのまま `appendingPathComponent` に渡すとパス区切りとして解釈され、
    /// 「1 つのフォルダ」のつもりが入れ子のフォルダ 2 つになる（実測で再現）。
    /// 組み立てたあとでは元の入力が分からず、正確な理由を伝えられない。
    func createFolder(named name: String, in parent: URL, onSuccess: @escaping @MainActor () -> Void = {}) {
        guard let validName = validatedName(name, whatHappened: "error.createFolderFailed") else { return }
        run(CreateFolderCommand(url: parent.appendingPathComponent(validName)), failure: "error.createFolderFailed", onSuccess: onSuccess)
    }

    /// 名前を検証し、使えなければ理由を提示して `nil` を返す。
    ///
    /// `FileOperationService` 側でも同じ検証をしているが、あちらは URL を
    /// 受け取る段階なので「ユーザーが何と入力したか」を復元できない。
    /// 正確な文言を出すために入口でも見る（二重だが、片方だけでは足りない）。
    private func validatedName(_ raw: String, whatHappened: String.LocalizationValue) -> String? {
        do {
            return try FileNameValidation.sanitized(raw)
        } catch {
            Task {
                await NotificationRouter.shared.presentError(
                    error, whatHappened: String(localized: whatHappened, locale: locale)
                )
            }
            return nil
        }
    }

    /// Finder の「エイリアスを作成」。書き込み先は呼び出し側が決める。
    func createAliases(for urls: [URL], in destination: URL, onSuccess: @escaping @MainActor () -> Void = {}) {
        let children: [any Command] = urls.map { CreateAliasCommand(source: $0, destinationFolder: destination) }
        let command = Self.singleOrComposite(children, displayName: String(localized: "folder.createAlias", locale: locale))
        run(command, failure: "error.createAliasFailed", onSuccess: onSuccess)
    }

    /// Finder の「ロック」/「ロック解除」。
    func setLocked(_ urls: [URL], locked: Bool, onSuccess: @escaping @MainActor () -> Void = {}) {
        guard !urls.isEmpty else { return }
        run(
            SetLockedCommand(items: urls, locked: locked),
            failure: locked ? "error.lockFailed" : "error.unlockFailed",
            onSuccess: onSuccess
        )
    }

    /// Finder の「選択項目で新規フォルダを作成」[Finder/Edit メニュー整備]。
    /// 新規フォルダの作成と選択項目の移動を 1 つの Undo 単位にまとめる [UD-04]。
    /// 衝突時にコマンド自体が失敗しないよう、事前にフォルダ名の空きを探す
    /// （Finder の「新規フォルダ」「新規フォルダ 2」…と同じ体裁）。
    func newFolderWithSelection(
        _ urls: [URL], in parent: URL,
        onSuccess: @escaping @MainActor (URL) -> Void = { _ in }
    ) {
        guard !urls.isEmpty else { return }
        let baseName = String(localized: "action.newFolderWithSelection.baseName", locale: locale)
        let displayName = String(localized: "action.newFolderWithSelection", locale: locale)
        Task {
            // **空き名探しは 1 回ごとにボリュームへの問い合わせ**になる。
            // `@MainActor` のここで回すとメインスレッドが止まるので、
            // ループごと `FileIO` へ渡す [NV6-02]。
            let created = await FileIO.perform {
                var candidate = parent.appendingPathComponent(baseName)
                var suffix = 2
                while FileManager.default.fileExists(atPath: candidate.path) {
                    candidate = parent.appendingPathComponent("\(baseName) \(suffix)")
                    suffix += 1
                }
                return candidate
            }
            let children: [any Command] = [
                CreateFolderCommand(url: created),
                MoveFilesCommand(items: urls, destination: created),
            ]
            let command = Self.singleOrComposite(children, displayName: displayName)
            run(command, failure: "error.newFolderWithSelectionFailed") { onSuccess(created) }
        }
    }

    // MARK: - ペーストボード

    /// パスを改行区切りでテキストとしてコピーする [FM-10]。
    func copyPaths(_ urls: [URL]) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
    }

    /// Finder で対象を表示する [FM-09]。
    func revealInFinder(_ urls: [URL]) {
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    /// 「ターミナルで開く」[ユーザー要望]。フォルダはそれ自身、ファイルは
    /// その親フォルダを開く（Finder の「フォルダに新規ターミナル」と同じ考え方）。
    ///
    /// **Apple Events は使わない** [実測で判明、CLAUDE.md の A 判定を訂正]。
    /// 以前は「Terminal へ `do script` を送るには
    /// `com.apple.security.automation.apple-events` entitlement とユーザーの
    /// TCC 許可が要る」として実装不能に分類していたが、それは Apple Events
    /// 経由を前提にした話だった。**フォルダを Terminal.app に「書類として
    /// 開かせる」だけなら LaunchServices の経路で足り、追加の entitlement は
    /// 要らない**（`open -a Terminal <dir>` と同じ）。サンドボックス下の
    /// probe で実際に成功することを確認済み。
    ///
    /// ただし**渡すフォルダへのアクセス権は必要**——権限の無い場所を渡すと
    /// `permErr`(-54) で失敗する（probe で `/private/tmp` を渡して確認）。
    /// これは本アプリが表示できているフォルダなら満たされている。
    func openInTerminal(_ urls: [URL]) {
        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.terminalBundleID) else {
            let message = String(localized: "folder.openInTerminalFailed", locale: locale)
            Task {
                await NotificationRouter.shared.present(NotificationItem(
                    category: .error, severity: .sheet, title: message, body: ""
                ))
            }
            return
        }
        // 同じフォルダを複数回開かない（ファイルを複数選ぶと親が重複するため）。
        var seen: Set<String> = []
        let folders = urls.compactMap { url -> URL? in
            let target = url.hasDirectoryPath ? url : url.deletingLastPathComponent()
            let path = target.standardizedFileURL.path
            guard seen.insert(path).inserted else { return nil }
            return target
        }
        guard !folders.isEmpty else { return }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open(folders, withApplicationAt: terminal, configuration: configuration) { _, error in
            guard let error else { return }
            Task { @MainActor in
                await NotificationRouter.shared.presentError(
                    error,
                    whatHappened: String(localized: "folder.openInTerminalFailed", locale: AppLanguage.effectiveLocale)
                )
            }
        }
    }

    private static let terminalBundleID = "com.apple.Terminal"

    /// `⌘C`/コンテキストメニュー「コピー」。標準の `NSPasteboard` にファイル URL
    /// として書き込むため、Finder との相互運用（Finder へ貼り付け／Finder で
    /// コピーしたものをここへ貼り付け）が両方とも成立する。
    func copyToPasteboard(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects(urls as [NSURL])
        // 素のコピーはカット状態を打ち消す（さもないと直前のカットが
        // 後続のペーストで誤って移動として処理されてしまう）。
        SessionState.shared.cutURLs = []
    }

    /// `⌘X`/コンテキストメニュー「カット」[Finder/Edit メニュー整備の一環で追加]。
    /// Finder 自身のカット判定はプライベート API 頼りで他アプリと相互運用
    /// できないため、`SessionState.cutURLs`（アプリ内で完結する簡易な独自実装、
    /// 型のコメント参照）で「次のペーストは移動にする」ことだけを覚えておく。
    /// ペーストボードへの書き込み自体は `copyToPasteboard` と同じ（Finder への
    /// 貼り付け自体はコピーとして成立する。カットの伝搬はアプリ内ペースト時のみ）。
    func cutToPasteboard(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects(urls as [NSURL])
        SessionState.shared.cutURLs = Set(urls.map { $0.standardizedFileURL.path })
    }

    var canPaste: Bool {
        NSPasteboard.general.canReadObject(forClasses: [NSURL.self], options: nil)
    }

    /// `⌘V`/コンテキストメニュー「ペースト」。ペーストボード上のファイル URL が
    /// 直前にカットされた集合と一致すれば移動、そうでなければコピー
    /// （Finder の `⌘V` と同じ既定）。**パス文字列（`standardizedFileURL.path`）で
    /// 比較する** — 生の `URL` 同士の `==` はペーストボード往復後の表現差異
    /// （末尾スラッシュ等）で一致しないことがあった [実機検証で発見、
    /// `SessionState.cutURLs` のコメント参照]。
    func paste(into destination: URL, onSuccess: @escaping @MainActor () -> Void = {}) {
        performPaste(into: destination, forcingMove: false, onSuccess: onSuccess)
    }

    /// Finder の「ここに項目を移動」（`⌥⌘V`、「ペースト」の ⌥ 代替）
    /// [Finder 対比監査]。カット状態かどうかに関わらず常に移動として貼り付ける。
    func moveItemsHere(into destination: URL, onSuccess: @escaping @MainActor () -> Void = {}) {
        performPaste(into: destination, forcingMove: true, onSuccess: onSuccess)
    }

    private func performPaste(
        into destination: URL, forcingMove: Bool,
        onSuccess: @escaping @MainActor () -> Void
    ) {
        guard var urls = NSPasteboard.general.readObjects(forClasses: [NSURL.self]) as? [URL], !urls.isEmpty else { return }
        let isCutPaste = !SessionState.shared.cutURLs.isEmpty
            && Set(urls.map { $0.standardizedFileURL.path }) == SessionState.shared.cutURLs
        let isMove = forcingMove || isCutPaste

        if isMove {
            // 既に書き込み先に居る項目を除く。移動先が現在の親と同じだと
            // 「自分自身との衝突」になり、既定の `.ask`（`conflictResolver`
            // 未設定）では `conflictResolutionRequired` がそのまま技術的な
            // エラー文言で表示されてしまう。Finder も同じ状況では項目自体を
            // 無効にするため、ここで静かに除外するのが挙動として自然。
            let destinationPath = destination.standardizedFileURL.path
            urls.removeAll { $0.deletingLastPathComponent().standardizedFileURL.path == destinationPath }
            guard !urls.isEmpty else { return }
        }

        let options = transferOptions() // [FM-11] 衝突したら尋ねる
        let command: any Command = isMove
            ? MoveFilesCommand(items: urls, destination: destination, options: options)
            : CopyFilesCommand(items: urls, destination: destination, options: options)
        run(
            command,
            failure: isMove ? "error.moveItemsHereFailed" : "error.pasteFailed",
            busyMessageKey: isMove ? "folder.moving" : "folder.copying"
        ) {
            if isCutPaste { SessionState.shared.cutURLs = [] }
            onSuccess()
        }
    }

    // MARK: - 圧縮・展開 [9.4 節]

    /// `.tar.gz` のような複合拡張子も含めてアーカイブ名から拡張子を除いた
    /// ベース名を返す（展開先フォルダ名・圧縮先の既定名に使う）[AR-21]。
    static func archiveBaseName(_ url: URL) -> String {
        let name = url.lastPathComponent
        if name.lowercased().hasSuffix(".tar.gz") {
            return String(name.dropLast(".tar.gz".count))
        }
        return url.deletingPathExtension().lastPathComponent
    }

    /// 現在の環境設定から `CompressionOptions` を組み立てる
    /// [環境設定「圧縮／展開」タブ、`CompressionPreferencesTab` と同じ
    /// `UserDefaults` キーを共有する]。
    var compressionOptions: CompressionOptions {
        let defaults = UserDefaults.standard
        let format = defaults.string(forKey: PreferenceKeys.compressionFormat).flatMap(CompressibleFormat.init(rawValue:)) ?? .zip
        let storedEncryption = defaults.string(forKey: PreferenceKeys.compressionEncryption).flatMap(ArchiveEncryptionMethod.init(rawValue:)) ?? .none
        return CompressionOptions(
            format: format,
            zipLevel: (defaults.object(forKey: PreferenceKeys.compressionZipLevel) as? Int).flatMap(ZipCompressionLevel.init(rawValue:)) ?? .normal,
            sevenZipCodec: defaults.string(forKey: PreferenceKeys.compressionSevenZipCodec).flatMap(SevenZipCodec.init(rawValue:)) ?? .ppmd,
            // **形式が暗号化に対応していなければ、保存されている方式は無視する。**
            // 環境設定「圧縮／展開」タブは 7z を選ぶと暗号化の選択肢を隠すだけで
            // 保存済みの値は消さないため、「zip + AES-256 に設定 → あとで 7z に
            // 変更」した利用者は、正規化しないと素の「ここに圧縮」でパスワードを
            // 尋ねられたうえで**平文の .7z** を受け取ってしまう（libarchive の
            // 7z ライターは暗号化オプションを黙って無視する、実測済み）。
            // 読み取りのこの 1 箇所で潰しておけば、`compressHere` /
            // `compressWithDialog` / `compressHereWithPassword` のどの経路でも
            // 同じ保証が効く [code-review の指摘で発見]。
            encryption: format == .zip ? storedEncryption : .none
        )
    }

    /// 展開時の安全上限 [EX-21、環境設定「圧縮／展開」タブ]。GB 単位で保存して
    /// いるため `ExtractLimits.maxUncompressedBytes`（バイト単位）へ変換する。
    var extractLimits: ExtractLimits {
        let defaults = UserDefaults.standard
        let defaultGB = Double(AppLimits.Extraction.defaultMaxUncompressedBytes) / 1_000_000_000
        let gb = defaults.object(forKey: PreferenceKeys.extractionMaxUncompressedGB) as? Double ?? defaultGB
        let entries = defaults.object(forKey: PreferenceKeys.extractionMaxEntries) as? Double ?? Double(AppLimits.Extraction.defaultMaxEntries)
        let ratioWarn = defaults.object(forKey: PreferenceKeys.extractionRatioWarn) as? Double ?? AppLimits.Extraction.defaultRatioWarn
        let ratioAbort = defaults.object(forKey: PreferenceKeys.extractionRatioAbort) as? Double ?? AppLimits.Extraction.defaultRatioAbort
        return ExtractLimits(
            maxUncompressedBytes: Int64(gb * 1_000_000_000),
            maxEntries: Int(entries),
            ratioWarn: ratioWarn,
            ratioAbort: ratioAbort
        )
    }

    /// [AR-10] 「ここに圧縮」。単一選択時は項目名、複数選択時は書き込み先
    /// フォルダ名を既定のアーカイブ名にする。暗号化が有効ならパスワードシートを
    /// 挟んでから実行する。
    func compressHere(
        _ urls: [URL], into destinationFolder: URL,
        onCompleted: @escaping @MainActor (URL) -> Void = { _ in }
    ) {
        guard !urls.isEmpty else { return }
        let name = urls.count == 1 ? Self.archiveBaseName(urls[0]) : destinationFolder.lastPathComponent
        beginCompression(PendingCompression(
            items: urls, destinationName: name, destinationFolder: destinationFolder,
            options: compressionOptions, conflictPolicy: .keepBoth, onCompleted: onCompleted
        ))
    }

    /// Finder の「パスワード付きで圧縮」（「圧縮」の ⌥ 代替）[Finder 対比監査]。
    /// 環境設定で暗号化を無効にしていても、この操作のときだけ暗号化を有効に
    /// してパスワードシートを開く。
    ///
    /// **既定形式が zip のときだけ提供する**（`canCompressWithPassword`）。
    /// libarchive の 7z ライターは暗号化オプション自体を持たず、指定しても
    /// 黙って無視される（`LibarchiveBackendTests` で実測済み）ため、7z のまま
    /// 提供するとパスワードを尋ねておきながら平文のアーカイブを作ってしまう。
    /// 黙って zip に切り替えることもしない — 環境設定「圧縮／展開」タブで
    /// 「7z 選択時は暗号化 UI 自体を表示しない」としたのと同じ、
    /// 「機能しない設定を見せない」方針に揃える［設計判断］。
    var canCompressWithPassword: Bool {
        compressionOptions.format == .zip
    }

    func compressHereWithPassword(
        _ urls: [URL], into destinationFolder: URL,
        onCompleted: @escaping @MainActor (URL) -> Void = { _ in }
    ) {
        guard !urls.isEmpty, canCompressWithPassword else { return }
        var options = compressionOptions
        if options.encryption == .none {
            // 環境設定で方式を選んでいれば尊重し、無効のときだけ既定を補う。
            // `zipTraditional` は既知の攻撃手法で短時間に突破できる弱い暗号化
            // （`ArchiveEncryptionMethod` のコメント参照）のため、明示的に
            // 選ばれていない限り採用しない。
            options.encryption = .aes256
        }
        let name = urls.count == 1 ? Self.archiveBaseName(urls[0]) : destinationFolder.lastPathComponent
        beginCompression(PendingCompression(
            items: urls, destinationName: name, destinationFolder: destinationFolder,
            options: options, conflictPolicy: .keepBoth, onCompleted: onCompleted
        ))
    }

    /// [AR-11] ファイル名・保存先を指定するダイアログ。zip/7z は環境設定の
    /// 既定形式に従う。
    func compressWithDialog(
        _ urls: [URL], startingIn folder: URL,
        onCompleted: @escaping @MainActor (URL) -> Void = { _ in }
    ) {
        guard !urls.isEmpty else { return }
        let options = compressionOptions
        let ext = options.format == .zip ? "zip" : "7z"
        let defaultName = urls.count == 1 ? Self.archiveBaseName(urls[0]) : folder.lastPathComponent
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(defaultName).\(ext)"
        panel.allowedContentTypes = options.format == .zip ? [.zip] : []
        panel.directoryURL = folder
        panel.prompt = String(localized: "folder.compressPanelPrompt", locale: locale)
        panel.message = String(localized: "folder.chooseSaveDestination", locale: locale)
        guard panel.runModal() == .OK, let destinationURL = panel.url else { return }
        beginCompression(PendingCompression(
            items: urls,
            destinationName: destinationURL.deletingPathExtension().lastPathComponent,
            destinationFolder: destinationURL.deletingLastPathComponent(),
            options: options,
            // NSSavePanel は既存ファイルの上書き確認を既に行っているため、
            // ここでは `.keepBoth`（自動連番）ではなく `.replace` にする。
            conflictPolicy: .replace,
            onCompleted: onCompleted
        ))
    }

    /// 暗号化の有無でパスワードの入力を挟むかどうかを振り分ける。
    private func beginCompression(_ request: PendingCompression) {
        guard request.options.encryption != .none else {
            runCompression(request, passphrase: nil)
            return
        }
        DialogWindowPresenter.shared.present(
            title: String(localized: "archivePassword.setTitle", locale: locale)
        ) { _ in
            ArchivePasswordDialog(mode: .setPassword) { password in
                self.runCompression(request, passphrase: password)
            }
        }
    }

    /// パスワードの入力後もここへ戻ってくる（`beginCompression` 参照）。
    func runCompression(_ request: PendingCompression, passphrase: String?) {
        let pauseToken = currentPauseToken
        let task = Task {
            defer { endProgress() }
            do {
                // 完了後に作成したアーカイブを選択状態にするため、`CommandStack`
                // に渡す前に具体的な型のまま変数へ保持しておく（`CompressCommand`
                // は `final class` のため、`run(_:)` 実行後も同じインスタンスの
                // `resultURL` を読める）[ユーザー要望]。
                let command = CompressCommand(
                    items: request.items, destinationName: request.destinationName,
                    destinationFolder: request.destinationFolder,
                    options: request.options, passphrase: passphrase,
                    conflictPolicy: request.conflictPolicy, progress: progressReporter,
                    pauseToken: pauseToken
                )
                _ = try await CommandStack.shared.run(command)
                if let resultURL = command.resultURL {
                    request.onCompleted(resultURL)
                }
            } catch is CancellationError {
                // ユーザー自身が止めたので、失敗として提示しない。
            } catch ExtractError.cancelled {
                // 同上（バックエンドは `Task.isCancelled` を見て専用の
                // エラーを投げるため、両方を受ける）。
            } catch {
                guard !Task.isCancelled else { return }
                // エラーを見せる**前に**進捗表示を片付ける（`run()` と同じ
                // 理由 — `presentError` はダイアログが閉じられるまで返らない）。
                endProgress()
                await NotificationRouter.shared.presentError(
                    error, whatHappened: String(localized: "error.compressFailed", locale: locale)
                )
            }
        }
        cancellableTask = task
        // 中断手段は**この時点で**渡す（`run()` と同じ理由）。
        beginProgress(
            String(localized: "folder.compressing", locale: locale),
            cancel: { task.cancel() }, pauseToken: pauseToken
        )
    }

    /// 展開先フォルダを新規作成する場合は `CreateFolderCommand` + `ExtractCommand`
    /// を 1 つの Undo 単位にまとめる [UD-04]。複数アーカイブの一括展開も
    /// まとめて 1 単位にする（`MX2-08` の精神）。途中で失敗したら残りは中断する
    /// 暫定対応 [ER-20 の趣旨に近い、`BatchNotificationSession`〈結果サマリ・
    /// 部分失敗の集約〉はまだ実装していないため]。
    ///
    /// **パスワードの対話的な再試行は単一アーカイブ展開時のみ提供する**
    /// [環境設定「圧縮／展開」タブ、設計判断]。複数選択の一括展開中に
    /// パスワード保護されたアーカイブに遭遇した場合、どれが原因か・途中まで
    /// 成功した分をどう扱うかの UX が複雑になるため、通常のエラー表示に留める。
    func extract(
        _ urls: [URL], destination: @escaping (URL) -> URL,
        passphrase: String? = nil,
        onSuccess: @escaping @MainActor () -> Void = {}
    ) {
        guard !urls.isEmpty else { return }
        let busyTitle = urls.count == 1
            ? String(localized: "folder.extractingOne", locale: locale)
            : String(format: String(localized: "folder.extractingCount", locale: locale), urls.count)
        let limits = extractLimits
        let pauseToken = currentPauseToken
        // 展開先の算出はパス演算だけなので、ここ（`@MainActor`）で済ませてよい。
        // **存在確認はボリュームへの問い合わせ**なので、まとめてタスクの中で行う。
        let targets = urls.map(destination)
        let name = urls.count == 1
            ? String(format: String(localized: "folder.extractCommandName", locale: locale), urls[0].lastPathComponent)
            : String(format: String(localized: "folder.extractCommandNameCount", locale: locale), urls.count)
        let entryPassphrase = urls.count == 1 ? passphrase : nil
        let reporter = progressReporter
        let task = Task {
            defer { endProgress() }
            // **`@MainActor` のまま `fileExists` を回してはいけない** [NV6-02]。
            // アーカイブの数だけ問い合わせが走り、応答しない共有では
            // メインスレッドがそのぶん止まる。1 回にまとめて `FileIO` へ渡す。
            let existing = await FileIO.perform {
                Set(targets.filter { FileManager.default.fileExists(atPath: $0.path) }.map(\.path))
            }
            var children: [any Command] = []
            for (url, target) in zip(urls, targets) {
                if !existing.contains(target.path) {
                    children.append(CreateFolderCommand(url: target))
                }
                children.append(ExtractCommand(
                    archiveURL: url, destination: target, limits: limits,
                    passphrase: entryPassphrase, progress: reporter, pauseToken: pauseToken
                ))
            }
            guard let command = Self.singleOrComposite(children, displayName: name) else { return }
            do {
                _ = try await CommandStack.shared.run(command)
                onSuccess()
            } catch is CancellationError {
                // ユーザー自身が止めたので、失敗として提示しない。
            } catch ExtractError.cancelled {
                // 同上（バックエンドは `Task.isCancelled` を見て [EX-24] の
                // 専用エラーを投げるため、両方を受ける）。
            } catch let error as ExtractError where urls.count == 1 && (error == .passwordProtected || error == .incorrectPassphrase) {
                let retryMessage = error == .incorrectPassphrase ? String(localized: "error.incorrectPassphrase", locale: locale) : nil
                let archiveURL = urls[0]
                let target = destination(archiveURL)
                DialogWindowPresenter.shared.present(
                    title: String(localized: "archivePassword.unlockTitle", locale: locale)
                ) { _ in
                    ArchivePasswordDialog(mode: .unlock(retryErrorMessage: retryMessage)) { password in
                        self.extract(
                            [archiveURL], destination: { _ in target },
                            passphrase: password, onSuccess: onSuccess
                        )
                    }
                }
            } catch {
                guard !Task.isCancelled else { return }
                // エラーを見せる**前に**進捗表示を片付ける（`run()` と同じ理由）。
                endProgress()
                await NotificationRouter.shared.presentError(
                    error, whatHappened: String(localized: "error.extractFailed", locale: locale)
                )
                onSuccess()
            }
        }
        cancellableTask = task
        beginProgress(busyTitle, cancel: { task.cancel() }, pauseToken: pauseToken)
    }

    /// [AR-22] 展開先をユーザーに選ばせる。
    func extractToChosenDestination(_ urls: [URL], onSuccess: @escaping @MainActor () -> Void = {}) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "folder.extractPanelPrompt", locale: locale)
        panel.message = String(localized: "folder.chooseExtractDestination", locale: locale)
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        extract(urls, destination: { _ in destination }, onSuccess: onSuccess)
    }

    /// `@AppStorage` を使えないこの型から環境設定を読むためのキー定義。
    /// **`CompressionPreferencesTab`/`FolderContentView` の `@AppStorage` と
    /// 同じ文字列でなければならない**ため、1 箇所にまとめて取り違えを防ぐ。
    enum PreferenceKeys {
        static let compressionFormat = "qoo.preferences.compression.format"
        static let compressionZipLevel = "qoo.preferences.compression.zipLevel"
        static let compressionSevenZipCodec = "qoo.preferences.compression.sevenZipCodec"
        static let compressionEncryption = "qoo.preferences.compression.encryption"
        static let extractionMaxUncompressedGB = "qoo.preferences.extraction.maxUncompressedGB"
        static let extractionMaxEntries = "qoo.preferences.extraction.maxEntries"
        static let extractionRatioWarn = "qoo.preferences.extraction.ratioWarn"
        static let extractionRatioAbort = "qoo.preferences.extraction.ratioAbort"
    }
}

// MARK: - 保留中のダイアログ状態

/// 圧縮の実行に必要な情報一式 [環境設定「圧縮／展開」タブ]。暗号化が有効な
/// ときはこの値を保持したままパスワードの入力を挟み、入力後に同じ値で
/// そのまま実行する（`FolderOperations.beginCompression` 参照）。
struct PendingCompression {
    let items: [URL]
    let destinationName: String
    let destinationFolder: URL
    let options: CompressionOptions
    let conflictPolicy: ConflictPolicy
    /// 作成されたアーカイブの URL を受け取る。中央ペインが「作成した圧縮
    /// ファイルを選択してスクロールする」ために使う [ユーザー要望]。
    let onCompleted: @MainActor (URL) -> Void
}

/// 完全削除の一連のダイアログ。確認 → （ロック済み項目があれば）その判断、
/// という順に遷移する [FM-15][PD-06]。
enum PermanentDeletionStep: Identifiable {
    case confirm(PendingPermanentDeletion)
    case lockedItem(PendingLockedItem)

    var id: UUID {
        switch self {
        case .confirm(let request): request.id
        case .lockedItem(let request): request.id
        }
    }
}

/// ロック済み項目 1 件分の判断待ち [PD-06][ER-11]。
///
/// **`resolve` は高々 1 回しか下流へ伝わらない。** 呼び出し側は
/// `CheckedContinuation` を再開するためにこれを使っており、2 回再開すると
/// クラッシュ、0 回だと永久に待ち続けてアプリが固まる。シートのボタンと
/// `onDismiss`（Esc で閉じられた場合）の両方から呼ばれても安全なように、
/// ここで一度きりを保証する。
@MainActor
final class PendingLockedItem: Identifiable {
    let id = UUID()
    let url: URL
    /// シートが実際に表示されたか。表示されないまま終わった場合の保険
    /// （`FolderOperations.askLockedItemDecision` の見張り）が、ユーザーの
    /// 長考と「そもそも出なかった」を取り違えないようにするための印。
    var didAppear = false
    private var callback: ((LockedItemDecision, Bool) -> Void)?

    init(url: URL, onResolve: @escaping (LockedItemDecision, Bool) -> Void) {
        self.url = url
        self.callback = onResolve
    }

    /// - Parameter applyToAll: 「以降すべてに適用」[ER-11]
    func resolve(_ decision: LockedItemDecision, applyToAll: Bool) {
        guard let callback else { return }
        self.callback = nil
        callback(decision, applyToAll)
    }
}

// MARK: - 判断を待つシートのホスト

extension View {
    /// `FolderOperations` が**操作の途中で判断を仰ぐ**シートをこのビューに
    /// 載せる。`FolderOperations` を使うビューは必ず 1 回だけ適用する。
    ///
    /// ここに残っているのは、いずれも**実行中の処理が答えを待っている**もの
    /// （衝突・完全削除の確認・ロック済み項目）だけ。名前や圧縮パスワードの
    /// **入力**ダイアログは独立したウインドウへ移した
    /// （`DialogWindowPresenter` 参照）。
    func folderOperationsHost(_ operations: FolderOperations) -> some View {
        modifier(FolderOperationsHostModifier(operations: operations))
    }
}

private struct FolderOperationsHostModifier: ViewModifier {
    @Bindable var operations: FolderOperations

    func body(content: Content) -> some View {
        content
            // 進捗は**別の小さなウインドウ**に出す［ユーザー要望］。
            // 実体は `OperationProgressWindowController`（アプリ全体で 1 つ）。
            // 以前はここでウインドウ全体を薄暗くするオーバーレイを描いていた。
            // [FM-11][FM-12] 同名の項目があったときの判断。
            .sheet(item: $operations.pendingConflict) { pending in
                ConflictResolutionSheet(pending: pending) {
                    operations.pendingConflict = nil
                }
            }
            // 完全削除の確認とロック済み項目の判断は連続して遷移するため、
            // 1 つの `.sheet` で切り替える（`PermanentDeletionStep` のコメント参照）。
            .sheet(item: $operations.pendingDeletionStep) { step in
                switch step {
                case .confirm(let request):
                    PermanentDeleteConfirmationSheet(request: request) {
                        operations.runPermanentDeletion(request)
                    }
                case .lockedItem(let request):
                    LockedItemDecisionSheet(request: request)
                }
            }
    }
}
