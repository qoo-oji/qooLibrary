import Foundation
import QooKit

public enum OperationKind: Sendable, Equatable {
    case createDirectory, copy, move, rename, trash, deletePermanently, restoreFromTrash
    /// 展開のステージングディレクトリから最終位置への移送 [EX-04]。
    case promoteFromStaging
    /// Finder の「エイリアスを作成」相当。
    case createAlias
    /// Finder の「ロック」/「ロック解除」相当（`.isUserImmutableKey`）。
    case setLocked

    /// 診断ログ用の安定した短い識別子 [LG2-01]。**ユーザー向けの表示名では
    /// ない**（ローカライズしない・バージョン間で変えない）。ログを機械的に
    /// 絞り込めるようにするためのもの。
    public var logLabel: String {
        switch self {
        case .createDirectory: "createDirectory"
        case .copy: "copy"
        case .move: "move"
        case .rename: "rename"
        case .trash: "trash"
        case .deletePermanently: "deletePermanently"
        case .restoreFromTrash: "restoreFromTrash"
        case .promoteFromStaging: "promoteFromStaging"
        case .createAlias: "createAlias"
        case .setLocked: "setLocked"
        }
    }
}

public enum ConflictPolicy: Sendable, Equatable {
    case ask // ダイアログ [FM-11]
    case replace // [FM-13]
    case keepBoth // 連番付与 [CF-01]
    case skip
}

public struct OpOptions: Sendable {
    public var conflictPolicy: ConflictPolicy
    /// `.ask` が選ばれた場合に呼ばれる、衝突 1 件ごとの解決手段。
    /// 「以降すべてに適用」[FM-12] の状態は**呼び出し側が持つ**
    /// （`FolderOperations.conflictBlanketDecision`）。完全削除のロック確認
    /// [PD-06] と同じ形で、汎用の `BatchNotificationSession`（ER-10〜16）を
    /// 待たずに要件を満たしている。
    public var conflictResolver: (@Sendable (_ source: URL, _ destination: URL) async -> ConflictPolicy)?
    /// 進み具合の報告先 [8章 §8.1、UI-09][A-04]。`nil` なら進捗を数える処理
    /// 自体を行わない（合計サイズの走査を省く。`ProgressTracker` 参照）。
    public var progress: ProgressReporter?
    /// 一時停止／再開 [ユーザー要望]。`nil` なら一時停止できない。
    public var pauseToken: PauseToken?

    public init(
        conflictPolicy: ConflictPolicy = .ask,
        conflictResolver: (@Sendable (_ source: URL, _ destination: URL) async -> ConflictPolicy)? = nil,
        progress: ProgressReporter? = nil,
        pauseToken: PauseToken? = nil
    ) {
        self.conflictPolicy = conflictPolicy
        self.conflictResolver = conflictResolver
        self.progress = progress
        self.pauseToken = pauseToken
    }
}

/// 一括処理が途中で失敗したときに、**そこまでに実際に動いた分の受領書**を
/// 一緒に運ぶ [ER-13][ER-16]。
///
/// **なぜ要るのか**［監査で発見］: 以前は `transfer` が失敗した時点で
/// `receipts` を捨てて例外を投げていた。100 件のうち 30 件が実際に移動した
/// あとで 31 件目が失敗すると、**移動済みの 30 件が Undo にも操作履歴にも
/// 残らない**。ユーザーから見ると「エラーが出た。でもファイルは動いている。
/// 元に戻す手段が無い」という状態になる。
///
/// 受領書さえ運べれば、呼び出し側（`Command`）は「部分的に成功した」として
/// 記録でき、⌘Z で戻せる。
public struct PartialTransferFailure: Error {
    /// そこまでに完了した分。**捨ててはならない。**
    public let receipts: [OpReceipt]
    /// どの項目で止まったか。
    public let failedItem: URL
    /// 本来の失敗理由。ユーザーへの提示にはこちらを使う。
    public let underlying: any Error

    public init(receipts: [OpReceipt], failedItem: URL, underlying: any Error) {
        self.receipts = receipts
        self.failedItem = failedItem
        self.underlying = underlying
    }
}

/// **本来の理由をそのまま見せる** [ER-03]［エラー文言の棚卸しで発見］。
///
/// この型は「途中まで運べた」ことを呼び出し側へ伝えるための入れ物で、
/// 失敗の理由そのものは `underlying` が持っている。準拠していなかったため、
/// **展開の移送が途中で失敗するとユーザーには
/// 「操作を完了できませんでした。（QooInfrastructure.PartialTransferFailure
/// エラー1）」しか出なかった**（`MoveFilesCommand`/`CopyFilesCommand` は
/// この型を捕まえて `.partial` に変えるので出ないが、`promoteFromStaging`
/// を使う展開の経路はそのまま抜けてくる）。
///
/// 三要素も `underlying` へ委譲する。入れ物が説明を横取りしない。
extension PartialTransferFailure: UserPresentableError {
    private var presentable: (any UserPresentableError)? { underlying as? any UserPresentableError }

    public var whatHappened: String {
        presentable?.whatHappened ?? underlying.localizedDescription
    }

    public var whyItHappened: String { presentable?.whyItHappened ?? "" }
    public var recoverySuggestions: [RecoveryAction] { presentable?.recoverySuggestions ?? [] }
    public var recoveryHint: String? { presentable?.recoveryHint }
    public var severity: NotificationSeverity { presentable?.severity ?? .sheet }

    public var technicalDetail: String? {
        // 「何件目で止まったか」は問い合わせのときに効く情報なので添える。
        let progress = QooInfrastructureStrings.format("fileOp.partial.transferProgress",
                                 receipts.count, failedItem.lastPathComponent)
        return [presentable?.technicalDetail, progress].compactMap { $0 }.joined(separator: "\n")
    }
}

extension PartialTransferFailure: LocalizedError {
    public var errorDescription: String? {
        [whatHappened, whyItHappened, recoveryHint ?? ""].filter { !$0.isEmpty }.joined(separator: " ")
    }
}

/// `trash` の途中失敗で、既にゴミ箱へ移せた分の受領書を運ぶ
/// [ER-13][ER-16、2026-08 既知の不具合の一掃]。`NSWorkspace.recycle` は
/// エラーと同時に「移せた分」の対応表を返すことがあり、以前はエラー時に
/// これを丸ごと捨てていた——実際にはゴミ箱へ移動したのに Undo にも
/// 操作履歴にも残らない（フェーズ1完了前監査からの既知の課題）。
///
/// `PartialTransferFailure` の Trash 版。`failedItem` を持たないのは、
/// `recycle` が「どの項目で失敗したか」を返さないため。
public struct PartialTrashFailure: Error {
    /// そこまでにゴミ箱へ移せた分。**捨ててはならない。**
    public let receipts: [TrashReceipt]
    /// 本来の失敗理由。ユーザーへの提示にはこちらを使う。
    public let underlying: any Error

    public init(receipts: [TrashReceipt], underlying: any Error) {
        self.receipts = receipts
        self.underlying = underlying
    }
}

/// 三要素は `underlying` へ委譲する（`PartialTransferFailure` と同じ理由:
/// 入れ物が説明を横取りしない [ER-03]）。
extension PartialTrashFailure: UserPresentableError {
    private var presentable: (any UserPresentableError)? { underlying as? any UserPresentableError }

    public var whatHappened: String {
        presentable?.whatHappened ?? underlying.localizedDescription
    }

    public var whyItHappened: String { presentable?.whyItHappened ?? "" }
    public var recoverySuggestions: [RecoveryAction] { presentable?.recoverySuggestions ?? [] }
    public var recoveryHint: String? { presentable?.recoveryHint }
    public var severity: NotificationSeverity { presentable?.severity ?? .sheet }

    public var technicalDetail: String? {
        let progress = QooInfrastructureStrings.format("fileOp.partial.trashProgress", receipts.count)
        return [presentable?.technicalDetail, progress].compactMap { $0 }.joined(separator: "\n")
    }
}

extension PartialTrashFailure: LocalizedError {
    public var errorDescription: String? {
        [whatHappened, whyItHappened, recoveryHint ?? ""].filter { !$0.isEmpty }.joined(separator: " ")
    }
}

public struct OpReceipt: Sendable {
    public let before: FileIdentity?
    public let after: FileIdentity?
    public let fromURL: URL
    public let toURL: URL
    public let kind: OperationKind
}

public struct TrashReceipt: Sendable {
    public let originalURL: URL
    public let trashURL: URL? // NSWorkspace.recycle の結果
    /// `nil` は「識別子を取得できないまま移した」。**受領書自体は捨てない**
    /// ——以前は識別子が取れなかった項目を受領書から黙って落としており、
    /// 実際にはゴミ箱へ移動したのに Undo にも履歴にも残らなかった
    /// [フェーズ1完了時の監査で発見]。復元は `trashURL` だけで足りる。
    public let identity: FileIdentity?
}

// MARK: - 完全削除 [FM-14〜FM-18、8章 §8.5]

/// ロック済み項目に遭遇したときの判断 [PD-06][ER-11]。ER-11 が「都度尋ねる
/// 対象」と定める「ユーザーの選択によって結果が変わるもの」に、完全削除で
/// 該当するのがこれ（Finder も同じくロック項目だけを個別に確認する）。
public enum LockedItemDecision: Sendable, Equatable {
    /// ロックを解除して削除する。
    case delete
    /// この項目は削除しない。
    case skip
}

public struct DeletePermanentlyOptions: Sendable {
    /// ロック済み項目 1 件ごとに判断を求める [PD-06]。**「以降すべてに適用」
    /// の状態は呼び出し側（UI）がこのクロージャに閉じ込めて保持する** —
    /// `OpOptions.conflictResolver` と同じパターンで、`BatchNotificationSession`
    /// （ER-10〜16 の汎用機構、まだ未実装）を待たずに ER-11 を満たすため。
    ///
    /// `nil` の場合、ロック済み項目は**スキップ**する（安全側に倒す。
    /// 確認手段が無いまま黙って消さない）。
    public var lockedItemResolver: (@Sendable (_ url: URL) async -> LockedItemDecision)?

    public init(lockedItemResolver: (@Sendable (_ url: URL) async -> LockedItemDecision)? = nil) {
        self.lockedItemResolver = lockedItemResolver
    }

    /// ユーザーに見えないアプリ内部の領域（展開ステージング等）の後始末用。
    /// 尋ねる相手も、残しておく意味も無いため、ロック済みでも削除する。
    /// **ユーザーのファイルに対して使ってはならない。**
    public static let unattended = DeletePermanentlyOptions(lockedItemResolver: { _ in .delete })
}

/// 完全削除 1 回分の結果。**成功・失敗・スキップを個別に持つ** [ER-14]。
///
/// 他の一括操作（`transfer` 等）が「最初の失敗で例外を投げ、それまでの
/// `OpReceipt` を捨てる」形なのに対し、完全削除だけは最初からこの形にした
/// [ER-13: 最初のエラーで全体を中断しない]。理由は、完全削除では
/// 「実際にファイルは消えているのに、操作は失敗として扱われ記録が残らない」
/// という状態が復元不能な事故に直結するため。
public struct DeletionOutcome: Sendable {
    public let receipts: [OpReceipt]
    public let failures: [DeletionFailure]
    /// ロック済みで、ユーザーが削除しないことを選んだ項目 [PD-06]。
    public let skipped: [URL]

    public init(receipts: [OpReceipt], failures: [DeletionFailure], skipped: [URL]) {
        self.receipts = receipts
        self.failures = failures
        self.skipped = skipped
    }

    public var succeededCount: Int { receipts.count }
    public var isCompleteSuccess: Bool { failures.isEmpty && skipped.isEmpty }
}

public struct DeletionFailure: Sendable, Equatable {
    public let url: URL
    public let reason: String

    public init(url: URL, reason: String) {
        self.url = url
        self.reason = reason
    }
}

public enum FileOperationError: Error, Sendable, Equatable {
    /// `.ask` が指定されたが `conflictResolver` が渡されなかった、または解決手段が
    /// 再度 `.ask` を返した（無限ループ防止のため 1 回のみ許容する）。
    case conflictResolutionRequired(source: URL, destination: URL)
    case operationFailed(String)
    /// コピー・移動が POSIX の失敗で止まった。**errno をそのまま保つ**
    /// [ER-03]。文字列に畳んでしまうと「容量不足なのか権限なのか」を
    /// 呼び出し側が区別できなくなる。
    case copyFailed(source: URL, destination: URL, errnoCode: Int32)
    /// 運ぶ前に空きが足りないと分かった [ER-03]。**書き始める前に**投げる。
    case insufficientFreeSpace(required: Int64, available: Int64, destination: URL)
    /// フォルダを、それ自身またはその配下へ運ぼうとした。**1 バイトも
    /// 書かずに断る** — 実測では `copyfile(3)` が 332 階層まで自己増殖し、
    /// ユーザーのフォルダの中にゴミの木を残してから `ENAMETOOLONG` で
    /// 失敗した（同一ボリュームの移動は `EINVAL` で止まるが、コピーは
    /// 止まらない）。Finder もこの操作は実行前に断る。
    case destinationInsideSource(source: URL, destination: URL)
    /// 書き込み先が読み取り専用ボリューム上にある。**書き始める前に**投げる。
    case destinationIsReadOnly(URL)
    /// この場所にゴミ箱が無い [NV4-01]。**呼び出し側が事前に判定して
    /// 完全削除の経路へ振り分ける**のが本筋で、これはその取りこぼしを
    /// 捕まえる最後の砦。
    case trashUnavailable(URL)
    /// 待ち時間の上限に達した [NV4-04]。**I/O が止まったのではなく、
    /// 待つのをやめただけ**である点に注意 [NV6-03]。
    case timedOut(seconds: Double)
    /// 書き込み先に実際には書けない（`access(2)` の `W_OK` が false）[NV-89]。
    /// **モードビットと `volumeIsReadOnly` の両方が嘘をつく場面がある**ため
    /// （SMB のサーバ側 ACL が POSIX へ写らない、1-16b の実測）、
    /// `destinationIsReadOnly` とは別に持つ。**書き始める前に**投げる。
    case destinationNotWritable(URL, errnoCode: Int32)
    /// ユーザーが入力した名前が使えない [`FileNameValidation`]。
    case invalidName(String, reason: FileNameValidation.Failure)
    /// 出来上がるパスがボリュームの上限（実測で全形式 1024 バイト＝
    /// `PATH_MAX`）を超える。**書き始める前に**投げる。
    case pathTooLong(item: URL, destination: URL, resultingBytes: Int, limitBytes: Int)
    /// 運んでいる最中に、元のファイルが他のアプリに書き換えられた。
    /// **写した内容は最新ではない**ので、移動なら元を消さず、コピーなら
    /// 中途半端な結果を残さない。
    case sourceChangedDuringOperation(URL)
    /// 名前が書き込み先のファイルシステムの上限を超える。
    /// **Mac 内では使える名前でも、書き込み先では使えないことがある** —
    /// 上限の数え方が形式ごとに違うため（`NameLengthLimit` 参照）。
    case nameTooLongForDestination(name: String, item: URL, length: Int, limit: Int, unitIsBytes: Bool)
    /// 1 ファイルが書き込み先のファイルシステムの上限を超える。
    /// **FAT32 は 4GB 弱が上限**で、動画ファイルでは普通に超える。
    /// 上限は OS が `volumeMaximumFileSizeKey` で答えるため、**書き始める
    /// 前に**確実に判定できる（実測: 超過は `EFBIG` で拒否される）。
    case fileTooLargeForDestination(item: URL, size: Int64, limit: Int64, destination: URL)
    /// **「置き換える」の退避を元へ戻せなかった** [NV-92]。ユーザーの元ファイルは
    /// `backup` の名前（先頭がドット）のまま残っており、**Finder にも本アプリにも
    /// 見えない＝消えたように見える**。
    ///
    /// 起きた原因（`underlyingDescription`）より**この事実の方が伝えるべき**なので、
    /// 原因は中に包んで技術詳細へ回す。次回起動時に
    /// `ReplaceBackupJournal.recoverAll()` がもう一度戻そうとする。
    case replaceBackupOrphaned(backup: URL, target: URL, underlyingDescription: String?)
}

/// **`UserPresentableError` に準拠させる理由** [ER-03]。
///
/// 以前は `LocalizedError` だけで、1 本の文字列にすべてを詰めていた。
/// その形だと 3 つの問題が避けられなかった［棚卸しで発見］:
///
/// 1. 呼び出し側のタイトル（「コピーできませんでした」）と本文の
///    「…できませんでした」が**二重になる**。
/// 2. 未知の `errno` で「処理できませんでした。処理できませんでした。」と
///    **同じ文が 2 回**出る。
/// 3. `strerror` の**英語が本文に混ざる**。
///
/// このプロトコルは三要素（何が／なぜ／次に何ができるか）と技術詳細を
/// **型として要求する**ので、**新しいケースを足したときに書き忘れられない**。
/// 合成（どれをタイトルに、どれを本文に置くか）は
/// `NotificationRouter.presentError` の 1 箇所だけが決める。
///
/// 文言は `Resources/<lang>.lproj/Localizable.strings` から
/// `QooInfrastructureStrings` 経由で引く。**`String(localized:)` を
/// 使ってはならない**（`locale:` は `.lproj` を選ばない。理由は
/// `LocalizedStrings` の型コメント）。
///
/// **`operationFailed` の実引数だけは呼び出し側が組み立てた文字列**で、
/// ここでは訳せない——投げる側が訳したものを渡すこと。
extension FileOperationError: UserPresentableError {
    /// 何が起きたか（1 文）。**操作名は入れない** — それは呼び出し側が
    /// タイトルとして持っている。ここは「どの項目がどうなったか」に徹する。
    public var whatHappened: String {
        switch self {
        case let .conflictResolutionRequired(_, destination):
            return QooInfrastructureStrings.format("fileOp.what.alreadyExists", destination.lastPathComponent)
        case let .operationFailed(message):
            return message
        case let .copyFailed(source, _, _):
            return QooInfrastructureStrings.format("fileOp.what.copyFailed", source.lastPathComponent)
        case let .insufficientFreeSpace(_, _, destination):
            return QooInfrastructureStrings.format("fileOp.what.insufficientFreeSpace", destination.lastPathComponent)
        case let .destinationInsideSource(source, destination):
            return QooInfrastructureStrings.format("fileOp.what.destinationInsideSource",
                                                    source.lastPathComponent, destination.lastPathComponent)
        case let .destinationIsReadOnly(destination):
            return QooInfrastructureStrings.format("fileOp.what.destinationIsReadOnly", destination.lastPathComponent)
        case let .destinationNotWritable(destination, _):
            return QooInfrastructureStrings.format("fileOp.what.destinationNotWritable", destination.lastPathComponent)
        case let .trashUnavailable(url):
            return QooInfrastructureStrings.format("fileOp.what.trashUnavailable", url.lastPathComponent)
        case .timedOut:
            return QooInfrastructureStrings.text("fileOp.what.timedOut")
        case let .invalidName(name, _):
            return name.isEmpty ? QooInfrastructureStrings.text("fileOp.what.nameEmpty")
                                : QooInfrastructureStrings.format("fileOp.what.invalidName", name)
        case let .sourceChangedDuringOperation(source):
            return QooInfrastructureStrings.format("fileOp.what.sourceChanged", source.lastPathComponent)
        case let .nameTooLongForDestination(name, _, _, _, _):
            return QooInfrastructureStrings.format("fileOp.what.nameTooLong", name)
        case let .fileTooLargeForDestination(item, _, _, destination):
            return QooInfrastructureStrings.format("fileOp.what.fileTooLarge",
                                                    item.lastPathComponent, destination.lastPathComponent)
        case let .pathTooLong(item, destination, _, _):
            return QooInfrastructureStrings.format("fileOp.what.pathTooLong",
                                                    item.lastPathComponent, destination.lastPathComponent)
        case let .replaceBackupOrphaned(_, target, _):
            return QooInfrastructureStrings.format("fileOp.what.replaceBackupOrphaned", target.lastPathComponent)
        }
    }

    /// なぜ起きたか。数字で示せるものは数字で示す（「足りません」だけでは
    /// どれだけ空ければよいのか分からない）。
    public var whyItHappened: String {
        let formatter = ByteCountFormatter()
        switch self {
        case .conflictResolutionRequired:
            return QooInfrastructureStrings.text("fileOp.why.conflictResolutionRequired")
        case .operationFailed:
            return ""
        case let .copyFailed(_, _, code):
            return PosixFailure.reason(code)
        case let .insufficientFreeSpace(required, available, _):
            return QooInfrastructureStrings.format("fileOp.why.insufficientFreeSpace",
                                                    formatter.string(fromByteCount: required),
                                                    formatter.string(fromByteCount: available))
        case .destinationInsideSource:
            return QooInfrastructureStrings.text("fileOp.why.destinationInsideSource")
        case .destinationIsReadOnly:
            return QooInfrastructureStrings.text("fileOp.why.destinationIsReadOnly")
        case let .destinationNotWritable(_, code):
            // サーバ側のアクセス許可が POSIX パーミッションへ写らないことが
            // あるため、表示上の権限とは食い違い得る [NV-29]。
            return PosixFailure.reason(code, context: .destination)
        case .trashUnavailable:
            return QooInfrastructureStrings.text("fileOp.why.trashUnavailable")
        case let .timedOut(seconds):
            // 1 秒未満を `Int` に落とすと「0 秒待っても応答がありません」に
            // なってしまうため、そこだけ小数で見せる。
            let shown = seconds < 1 ? String(format: "%.1f", seconds) : String(Int(seconds))
            return QooInfrastructureStrings.format("fileOp.why.timedOut", shown)
        case let .invalidName(_, reason):
            return reason.errorDescription ?? ""
        case .sourceChangedDuringOperation:
            return QooInfrastructureStrings.text("fileOp.why.sourceChanged")
        case let .nameTooLongForDestination(_, _, length, limit, unitIsBytes):
            // **単位を差し込む形にしない**——英語では数と単位の並びも、
            // 注記の要否も文ごとに違う。鍵そのものを分ける。
            return unitIsBytes
                ? QooInfrastructureStrings.format("fileOp.why.nameTooLongInBytes", length, limit)
                : QooInfrastructureStrings.format("fileOp.why.nameTooLongInCharacters", length, limit)
        case let .fileTooLargeForDestination(_, size, limit, _):
            return QooInfrastructureStrings.format("fileOp.why.fileTooLarge",
                                                    formatter.string(fromByteCount: size),
                                                    formatter.string(fromByteCount: limit))
        case let .pathTooLong(_, _, resultingBytes, limitBytes):
            return QooInfrastructureStrings.format("fileOp.why.pathTooLong", resultingBytes, limitBytes)
        case let .replaceBackupOrphaned(backup, _, _):
            return QooInfrastructureStrings.format("fileOp.why.replaceBackupOrphaned", backup.lastPathComponent)
        }
    }

    /// **押して意味のある操作は無い** [ER-03]。
    ///
    /// 一度これを「助言の文章をボタンにする」実装にしたが、
    /// 「不要な項目を削除して空きを増やすか、別の場所を選んでください。」が
    /// **ボタン名**になるうえ、`presentError` が「ボタンがあるなら文章は
    /// 出さない」規則なので**助言が本文から消えた**（棚卸しで発見）。
    /// 助言は文章（`recoveryHint`）として本文に置く。
    ///
    /// 将来 `RecoveryAction.Kind` に「環境設定の該当タブを開く」が入れば、
    /// 権限まわりはボタンにする価値がある（現在の `Kind` は
    /// `retry`/`openSystemSettings`/`dismiss` の 3 つで、アプリ内の
    /// 環境設定を指す手段が無い）。
    public var recoverySuggestions: [RecoveryAction] { [] }

    /// 次に何ができるか [ER-03]。**示せることが無ければ `nil`**
    /// （当たり障りのない一般論で埋めない）。
    public var recoveryHint: String? { Self.suggestion(for: self) }

    private static func suggestion(for error: FileOperationError) -> String? {
        switch error {
        case .conflictResolutionRequired:
            return QooInfrastructureStrings.text("fileOp.hint.conflictResolutionRequired")
        case .operationFailed:
            return nil
        case let .copyFailed(_, _, code):
            return PosixFailure.recovery(code)
        case .insufficientFreeSpace:
            return QooInfrastructureStrings.text("fileOp.hint.insufficientFreeSpace")
        case .destinationInsideSource:
            return QooInfrastructureStrings.text("fileOp.hint.destinationInsideSource")
        case .destinationIsReadOnly:
            return QooInfrastructureStrings.text("fileOp.hint.destinationIsReadOnly")
        case .trashUnavailable:
            return QooInfrastructureStrings.text("fileOp.hint.trashUnavailable")
        case .timedOut:
            return QooInfrastructureStrings.text("fileOp.hint.timedOut")
        case let .destinationNotWritable(_, code):
            return PosixFailure.recovery(code, context: .destination)
                ?? QooInfrastructureStrings.text("fileOp.hint.destinationNotWritable")
        case let .invalidName(_, reason):
            switch reason {
            case .empty: return QooInfrastructureStrings.text("fileOp.hint.nameEmpty")
            case .forbiddenCharacter: return QooInfrastructureStrings.text("fileOp.hint.forbiddenCharacter")
            case .reservedDotName: return QooInfrastructureStrings.text("fileOp.hint.reservedDotName")
            case .tooLong: return QooInfrastructureStrings.text("fileOp.hint.nameTooLongForName")
            }
        case .sourceChangedDuringOperation:
            return QooInfrastructureStrings.text("fileOp.hint.sourceChanged")
        case .nameTooLongForDestination:
            return QooInfrastructureStrings.text("fileOp.hint.nameTooLong")
        case let .fileTooLargeForDestination(_, _, limit, _):
            // 4GB 弱という上限は FAT32 に固有。断定できるなら断定する。
            return limit <= 4_294_967_295
                ? QooInfrastructureStrings.text("fileOp.hint.fileTooLargeOnFAT32")
                : QooInfrastructureStrings.text("fileOp.hint.fileTooLarge")
        case .pathTooLong:
            return QooInfrastructureStrings.text("fileOp.hint.pathTooLong")
        case .replaceBackupOrphaned:
            return QooInfrastructureStrings.text("fileOp.hint.replaceBackupOrphaned")
        }
    }

    /// 折りたたんで見せる技術詳細 [ER-03]。**本文には混ぜない。**
    public var technicalDetail: String? {
        switch self {
        case let .copyFailed(source, destination, code):
            return "\(PosixFailure.technicalDetail(code))\n\(source.path)\n→ \(destination.path)"
        case let .sourceChangedDuringOperation(source):
            return source.path
        case let .pathTooLong(item, destination, _, _):
            return "\(item.path)\n→ \(destination.path)"
        case let .replaceBackupOrphaned(backup, target, underlying):
            return ([backup.path, "→ \(target.path)"] + (underlying.map { [$0] } ?? []))
                .joined(separator: "\n")
        default:
            return nil
        }
    }

    public var severity: NotificationSeverity { .sheet }
}

/// `localizedDescription`（ログ・`NSError` 経由の表示）でも三要素が読めるように
/// する。`UserPresentableError` は提示用で、ログはこちらを読むため。
extension FileOperationError: LocalizedError {
    public var errorDescription: String? {
        [whatHappened, whyItHappened, recoveryHint ?? ""]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
