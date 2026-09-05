import Foundation
import QooInfrastructure
import QooKit

/// Undo/Redo スタック本体 [11章 §11.2、UD-02][UD-05][UD-11]。アプリ全体で
/// 単一のインスタンスを使う想定（`FileOperationService.shared`/
/// `ThumbnailService.shared` と同じ方針、ウインドウ単位に分けない [ST-03]）。
/// テストでは `init()` で独立インスタンスを作れる
/// （`FileOperationService`/`SecureExtractor` と同じ理由）。
@MainActor
@Observable
public final class CommandStack {
    public static let shared = CommandStack()

    private var undoStack: [any Command] = []
    private var redoStack: [any Command] = []
    /// [UD-05] 既定 50。環境設定 UI（1-12）が無いフェーズ1では変更不可。
    public var depth = 50

    /// [HS-01 の簡易版] DB（`OperationLogRecord`、07章）がまだ無いフェーズ1
    /// では永続化しない、メモリのみの操作履歴。CSV エクスポート・保持期間・
    /// 専用の操作履歴ウインドウ（OH-01〜05、15章 §15.13）はフェーズ2
    /// （DB 導入時）の対象。アプリ終了で消える点は Undo スタック自体と同じ
    /// 「セッション一時状態」の扱い。
    public private(set) var operationHistory: [OperationHistoryEntry] = []
    private let historyLimit = 500

    private let soundPlayer: any SystemSoundPlaying
    private let generation: LibraryGeneration
    /// 永続化される操作履歴 [HS-01][OH-01]。**上の `operationHistory`（メモリ）
    /// とは別物**——あちらは上限 500 件・アプリ終了で消えるセッション一時状態で、
    /// Undo メニューと同じ寿命。こちらは 90 日残る [HS-04]。
    private let operationLog: OperationLogRecorder

    public init(soundPlayer: any SystemSoundPlaying = SystemSoundPlayer.shared,
                generation: LibraryGeneration = .shared,
                operationLog: OperationLogRecorder = .shared) {
        self.soundPlayer = soundPlayer
        self.generation = generation
        self.operationLog = operationLog
    }

    public var undoTitle: String? { undoStack.last?.displayName } // [UD-06]
    public var redoTitle: String? { redoStack.last?.displayName }
    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    /// コマンドを実行しスタックへ積む [UD-01][CS-05]。新しい操作を実行したら
    /// redo スタックは破棄する（一般的な Undo/Redo の規則: 分岐した「やり直し」
    /// 先は残さない）。
    /// ユーザーの中断か（`Task` の取り消しと、バックエンドが投げる
    /// 専用エラーの両方を受ける）。
    public static func isCancellation(_ error: any Error) -> Bool {
        if error is CancellationError { return true }
        if let extractError = error as? ExtractError, extractError == .cancelled { return true }
        // **ユーザー自身のキャンセルを失敗として扱わない** [NV4-03]。
        // ゴミ箱を持たない場所で `NSWorkspace.recycle` を呼ぶと macOS が
        // 「すぐに削除されます」の確認ダイアログを出し、**キャンセルすると
        // `NSUserCancelledError`（`NSCocoaErrorDomain 3072`）が返る**
        // （1-16b の実測、8章 §8.11.4）。これをそのまま流すと、
        // **ユーザーが自分でキャンセルしたのにエラーダイアログが出る**。
        if let cocoa = error as? CocoaError, cocoa.code == .userCancelled { return true }
        if (error as NSError).domain == NSCocoaErrorDomain,
           (error as NSError).code == NSUserCancelledError { return true }
        return false
    }

    @discardableResult
    public func run(_ command: any Command) async throws -> CommandResult {
        let result: CommandResult
        do {
            result = try await command.execute()
        } catch {
            // 失敗したコマンドは `record` を通らないため、ここで明示的に残す
            // [LG2-01]。ユーザーには `NotificationRouter` 経由でエラーが
            // 提示されるが、ログには「どのコマンドが」失敗したかも要る。
            //
            // **中断は失敗ではない**（ユーザー自身の意思）ので、`error` では
            // なく `info` で残す。`error` にすると、既定のログレベルしか
            // 出していない環境でキャンセルの記録だけが目立ち、本当の失敗が
            // 埋もれる。
            //
            // **操作履歴にも残す** [HS-01]。`PartialTransferFailure` のように
            // 「失敗」でありながら**ファイルは動いている**ものがあるので、
            // 残さないと履歴が「何も起きなかった」と嘘をつく。
            // 診断ログへの記録も `record` が行う（1 箇所に集める）。
            record(command, action: Self.isCancellation(error)
                   ? .cancelled
                   : .failed(reason: error.localizedDescription))
            throw error
        }
        record(command, action: .executed)
        await playCompletionSound(for: command, result: result)
        if command.isUndoable {
            undoStack.append(command)
            if undoStack.count > depth {
                undoStack.removeFirst() // [CS-01] スタックからは捨てるが操作履歴は残す
            }
        }
        redoStack.removeAll()
        return result
    }

    /// 取り消す。**結果は呼び出し側へ返す** [ER-01]。
    ///
    /// **ここで `NotificationRouter` を待ってはいけない**［実装中に踏んだ］。
    /// 一度この中から提示していたが、2 つ問題があった:
    /// 1. `presentModally` はユーザーがダイアログを閉じるまで返らないため、
    ///    提示側がいないテストでは**永久に返らない**。
    /// 2. 呼び出し側が進捗ウインドウを片付ける前にダイアログが出てしまう
    ///    （`FolderOperations.run` が「エラーを見せる前に片付ける」ために
    ///    わざわざ順序を作っているのを台無しにする）。
    ///
    /// 記録（ログ・操作履歴）はここの責務のまま。**いつ・どう見せるか**だけを
    /// 呼び出し側に委ねる。
    @discardableResult
    public func undo() async -> UndoOutcome {
        guard let command = undoStack.popLast() else { return .nothingToDo }
        do {
            let result = try await command.undo()
            switch result {
            case .complete:
                record(command, action: .undone)
                redoStack.append(command)
                return .complete(operationName: command.displayName)
            case .partial(let succeeded, let failed):
                record(command, action: .undonePartially(succeeded: succeeded, failedCount: failed.count))
                // **redo スタックへ積まない** [2026-08 既知の不具合の一掃]。
                // 部分的にしか元へ戻っていない状態で Redo すると、`execute()` が
                // 元の `items` で再実行され「移動元が既に存在しない」といった
                // エラーになる（フェーズ1完了前監査で記録した既知の課題）。
                // 部分取り消しの後は Undo/Redo のどちらの再試行も正しく再現
                // できないため、操作履歴に記録を残してスタックからは外す。
                return .partial(operationName: command.displayName, succeeded: succeeded, failed: failed)
            case .impossible(let reason):
                record(command, action: .undoFailed(reason: reason))
                // スタックへ戻さない（同じコマンドの Undo を再試行しても直らないため）。
                return .failed(operationName: command.displayName, reason: reason)
            }
        } catch {
            record(command, action: .undoFailed(reason: error.localizedDescription))
            return .failed(operationName: command.displayName, reason: error.localizedDescription)
        }
    }

    /// やり直す。`undo()` と同じ理由で結果だけを返す。
    @discardableResult
    public func redo() async -> UndoOutcome {
        guard let command = redoStack.popLast() else { return .nothingToDo }
        do {
            let result = try await command.redo()
            record(command, action: .redone)
            await playCompletionSound(for: command, result: result)
            undoStack.append(command)
            return .complete(operationName: command.displayName)
        } catch {
            record(command, action: .redoFailed(reason: error.localizedDescription))
            return .failed(operationName: command.displayName, reason: error.localizedDescription)
        }
    }

    /// 完了音を鳴らす唯一の経路 [ユーザー要望]。
    ///
    /// **`undo()` からは呼ばない**［設計判断］。音は「その操作が起きたこと」に
    /// 付随するものなので、取り消しで圧縮完了音が鳴るのは意味が逆になる。
    /// かといって取り消しの中身（例: 圧縮の取り消し＝生成物をゴミ箱へ）に
    /// 応じた別の音を鳴らし分けると、同じ ⌘Z が対象によって違う音になり
    /// かえって分かりにくい。**やり直し（redo）は操作をもう一度起こすので鳴らす。**
    ///
    /// 部分成功では鳴らさない — Finder も鳴らす前にエラーの有無を確認しており、
    /// 一部失敗した操作を「完了」の音で締めるのは誤解を招く。失敗の提示自体は
    /// `NotificationRouter` の担当 [ER-01]。
    private func playCompletionSound(for command: any Command, result: CommandResult) async {
        guard case .success = result, let effect = command.completionSound else { return }
        await soundPlayer.play(effect)
    }

    /// 操作履歴への記録は必ずここを通る [CS-05]。診断ログへの記録も同じ
    /// 1 箇所で行うことで、経路（実行／取り消し／やり直し）が増えても
    /// 記録漏れが構造的に起きない [FO-03 と同じ考え方]。
    ///
    /// 操作履歴（ユーザー向け・メモリのみ）と診断ログ（開発者向け・ファイル）は
    /// **別のストア**であり相互参照しない [LG2-07][CB-25]。同じ事象を
    /// それぞれの粒度で記録しているだけ。
    /// **操作履歴には `displayName`、診断ログには `logDescription`** を使う。
    /// 前者はユーザー向けの文言（「12 件のファイルを移動」）、後者は対象を
    /// 絶対パスで表した診断用の文字列で、書き出し時の匿名化 [LG2-06] が
    /// 効くのは後者だけ（`Command.logDescription` のコメント参照）。
    private func record(_ command: any Command, action: OperationHistoryEntry.Action) {
        let detail = command.logDescription
        switch action {
        case .executed, .undone, .redone:
            Log.command.info("\(action.logLabel): \(detail)")
        case .cancelled:
            // **中断は失敗ではない**（ユーザー自身の意思）ので `error` にしない。
            // `error` にすると、既定のログレベルしか出していない環境で
            // キャンセルの記録だけが目立ち、本当の失敗が埋もれる。
            Log.command.info("\(action.logLabel): \(detail)")
        case .undonePartially(let succeeded, let failedCount):
            Log.command.warning("\(action.logLabel): \(detail) — 成功 \(succeeded) 件 / 失敗 \(failedCount) 件")
        case .failed(let reason), .undoFailed(let reason), .redoFailed(let reason):
            Log.command.error("\(action.logLabel): \(detail) — \(reason)")
        }
        operationHistory.append(OperationHistoryEntry(date: Date(), displayName: command.displayName, action: action))
        if operationHistory.count > historyLimit {
            operationHistory.removeFirst()
        }
        // **永続化される操作履歴もここから書く** [HS-01][OH-01]。run / undo /
        // redo と失敗・中断のすべてがこの関数を通るので、コマンドを足す人が
        // 記録を配線し忘れる余地が無い（ログ・音・読み直しの合図と同じ理由で
        // ここへ集めてある）。
        operationLog.record(Self.draft(for: command, action: action))
        // **画面の読み直しはここ 1 箇所から知らせる** [§19.13 #2]。run / undo /
        // redo のどれもこの関数を通るので、コマンドを足す人が合図を配線し忘れる
        // 余地が無い（ログと操作履歴を 1 箇所に集めているのと同じ考え方）。
        //
        // **`operationHistory.count` を鍵にするのはもうやめた。** あれは上限
        // 500 件で頭打ちになるので、501 回目以降の操作では値が動かず、
        // それを観ていた画面が黙って ⌘Z に追随しなくなっていた。
        generation.bump()
    }

    /// 1 件の操作を永続化する形へ写す [HS-01][OH-01]。
    ///
    /// **`static` にしてある**——`CommandStack` の状態に一切依存しない写像で、
    /// 画面を組み立てずに固定できるようにするため（`DuplicateResolutionModel`
    /// の `lossReport` / `makeDeleteCommand` と同じ扱い）。
    static func draft(for command: any Command,
                      action: OperationHistoryEntry.Action,
                      date: Date = Date()) -> OperationLogDraft {
        OperationLogDraft(
            date: date,
            // **型名を記録する。** 表示名は言語で変わるので、絞り込みの鍵には
            // できない（`OperationLogEntry.commandName` のコメント参照）。
            commandName: String(describing: type(of: command)),
            kind: action.logKind,
            targets: command.logTargets,
            // ファイル操作のコマンドは自分がどのライブラリの中で起きたかを
            // 知らない（そもそもライブラリの外での操作もある）。走査の行だけが
            // 埋める [OperationLogEntry.libraryUUID のコメント参照]。
            libraryUUID: nil,
            summary: command.displayName,
            detail: action.logDetail)
    }
}

extension OperationHistoryEntry.Action {
    /// 永続化される種別 [OH-01]。**`logLabel` とは別物**——あちらは診断ログ用の
    /// 短い日本語で、こちらは DB に焼き付ける生値である。
    var logKind: OperationLogKind {
        switch self {
        case .executed: .executed
        case .failed: .failed
        case .cancelled: .cancelled
        case .undone: .undone
        case .undonePartially: .undonePartially
        case .undoFailed: .undoFailed
        case .redone: .redone
        case .redoFailed: .redoFailed
        }
    }

    /// 行を開いたときにだけ読む内訳 [OH-04]。
    ///
    /// **理由の文はそのまま残す。** `UserPresentableError` を通した三要素の
    /// 文言なので、あとから読んでも「なぜ失敗したか」が分かる。
    var logDetail: String? {
        switch self {
        case .executed, .cancelled, .undone, .redone:
            nil
        case .undonePartially(let succeeded, let failedCount):
            "成功 \(succeeded) 件 / 失敗 \(failedCount) 件"
        case .failed(let reason), .undoFailed(let reason), .redoFailed(let reason):
            reason
        }
    }
}

/// 取り消し・やり直しの結果。**提示は呼び出し側（UI）が行う** [ER-01]。
///
/// 以前は `CommandStack` がログと操作履歴に書くだけで、失敗しても**画面には
/// 何も出なかった**。操作履歴には閲覧 UI が無い（フェーズ2の課題）ため、
/// ⌘Z が失敗しても「取り消したはずのファイルが戻っていない」という結果だけが
/// ユーザーに残っていた。取り消しは「やり直しがきく」という前提を支える機能
/// なので、その前提が崩れたことこそ真っ先に伝えなければならない［監査で発見］。
public enum UndoOutcome: Sendable {
    /// スタックが空だった（何も起きていない。提示するものは無い）。
    case nothingToDo
    case complete(operationName: String)
    case partial(operationName: String, succeeded: Int, failed: [FailedItem])
    case failed(operationName: String, reason: String)

    /// ユーザーに知らせる必要があるか（成功と空振りは黙っていてよい）。
    public var needsAttention: Bool {
        switch self {
        case .nothingToDo, .complete: false
        case .partial, .failed: true
        }
    }
}

public struct OperationHistoryEntry: Sendable, Identifiable {
    public enum Action: Sendable, Equatable {
        case executed
        /// 実行そのものが失敗した。**`PartialTransferFailure` のように
        /// 「失敗」でありながらファイルが動いているものがある**ので記録する。
        case failed(reason: String)
        /// ユーザー自身が中断した。**失敗とは別に扱う**——`isCancellation` が
        /// 診断ログで両者を分けているのと同じ理由。
        case cancelled
        case undone
        case undonePartially(succeeded: Int, failedCount: Int)
        case undoFailed(reason: String)
        case redone
        case redoFailed(reason: String)

        /// 診断ログ用の安定した短い識別子 [LG2-01]。ユーザー向けの表示名では
        /// ない（ローカライズしない・バージョン間で変えない）。
        public var logLabel: String {
            switch self {
            case .executed: "実行"
            case .failed: "実行に失敗"
            case .cancelled: "中断"
            case .undone: "取り消し"
            case .undonePartially: "取り消し（部分）"
            case .undoFailed: "取り消しに失敗"
            case .redone: "やり直し"
            case .redoFailed: "やり直しに失敗"
            }
        }
    }

    public let id = UUID()
    public let date: Date
    public let displayName: String
    public let action: Action
}
