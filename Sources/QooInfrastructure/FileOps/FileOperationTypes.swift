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
    public let identity: FileIdentity
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
    case sourceNotFound(URL)
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
}

/// **`LocalizedError` に準拠させる理由** [ER-03、実機検証で発見]。
/// 準拠していないと `localizedDescription` が
/// 「操作を完了できませんでした。（QooInfrastructure.FileOperationError エラー2）」
/// という、原因が一切分からない既定文言になる。実際に、書き込み先の
/// 空き容量が足りずにコピーが失敗した場面で、ユーザーにもログにも
/// この文言しか出ず**容量不足だと分からなかった**。`NotificationRouter`
/// も診断ログもこの値を読むので、ここを直せば両方に効く。
///
/// なお文言は日本語のリテラル。この層は文字列カタログ
/// （`Resources/Localizable.xcstrings`、アプリターゲットのリソース）を
/// 参照できず、既存の `operationFailed` の実引数も同じく日本語リテラル
/// なので、それに揃えている［既知の限界。ここの英語化は、エラー文言を
/// アプリ層へ持ち上げる別作業として扱う］。
extension FileOperationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .sourceNotFound(url):
            return "「\(url.lastPathComponent)」が見つかりません。"
        case let .conflictResolutionRequired(_, destination):
            return "「\(destination.lastPathComponent)」がすでに存在するため、処理を続けられませんでした。"
        case let .operationFailed(message):
            return message
        case let .copyFailed(source, destination, code):
            return Self.copyFailureMessage(source: source, destination: destination, errnoCode: code)
        case let .insufficientFreeSpace(required, available, destination):
            let formatter = ByteCountFormatter()
            return "「\(destination.lastPathComponent)」の空き容量が足りません。"
                + "\(formatter.string(fromByteCount: required)) が必要ですが、"
                + "空きは \(formatter.string(fromByteCount: available)) しかありません。"
                + "不要な項目を削除してから、もう一度お試しください。"
        case let .destinationInsideSource(source, destination):
            return "「\(source.lastPathComponent)」を、それ自身の中にある"
                + "「\(destination.lastPathComponent)」へは移動・コピーできません。"
                + "フォルダの外にある別の場所を選んでください。"
        case let .destinationIsReadOnly(destination):
            return "「\(destination.lastPathComponent)」は読み取り専用のため、書き込めません。"
                + "書き込みできる別の場所を選ぶか、ボリュームの設定を確認してください。"
        case let .invalidName(name, reason):
            let detail = reason.errorDescription ?? ""
            return name.isEmpty
                ? detail
                : "「\(name)」は名前として使えません。\(detail)"
        case let .sourceChangedDuringOperation(source):
            return "「\(source.lastPathComponent)」は、処理している間にほかのアプリが書き換えました。"
                + "途中までの内容を写してしまうため中止しました。"
                + "ダウンロードや書き出しが終わってから、もう一度お試しください。"
        case let .nameTooLongForDestination(name, _, length, limit, unitIsBytes):
            // **どこがどう長いのかを数字で示す。** 「長すぎます」だけでは、
            // 同じ名前が Mac 内で使えている理由が分からない。
            let unit = unitIsBytes ? "バイト" : "文字ぶん"
            let hint = unitIsBytes
                ? "書き込み先は名前の長さをバイト数で数えます（日本語は 1 文字あたり 3 バイト）。"
                : ""
            return "「\(name)」は、書き込み先で使える名前の長さを超えています"
                + "（\(length) \(unit)、上限 \(limit) \(unit)）。\(hint)"
                + "名前を短くしてから、もう一度お試しください。"
        case let .fileTooLargeForDestination(item, size, limit, destination):
            let formatter = ByteCountFormatter()
            return "「\(item.lastPathComponent)」（\(formatter.string(fromByteCount: size))）は、"
                + "書き込み先「\(destination.lastPathComponent)」が扱えるファイルの上限"
                + "（\(formatter.string(fromByteCount: limit))）を超えています。"
                + "書き込み先が FAT32 の場合は exFAT で初期化し直すと、この上限は無くなります。"
        case let .pathTooLong(item, destination, resultingBytes, limitBytes):
            return "「\(item.lastPathComponent)」を「\(destination.lastPathComponent)」へ置くと、"
                + "パスが長くなりすぎます（\(resultingBytes) バイト、上限 \(limitBytes) バイト）。"
                + "階層の浅い場所を選ぶか、途中のフォルダ名を短くしてください。"
        }
    }

    /// 失敗の技術詳細 [ER-03 の折りたたみ部分]。`errno` の英語表記のように、
    /// 説明本文に混ぜると読みにくいが、問い合わせの際には要る情報を置く。
    public var technicalReason: String? {
        switch self {
        case let .copyFailed(_, _, code):
            return "errno \(code): \(PosixFailure.systemReason(code))"
        default:
            return nil
        }
    }

    /// 「何ができないのか」＋「なぜか」。理由の翻訳は `PosixFailure` に
    /// 一本化しており、コピー・移動・展開のどの経路でも同じ説明になる。
    private static func copyFailureMessage(source: URL, destination: URL, errnoCode: Int32) -> String {
        let name = source.lastPathComponent
        // 「コピー先」と書かない — この関数はクロスボリュームの移動からも
        // 呼ばれるため、操作名を決め打ちすると嘘になる。
        return "「\(name)」を書き込み先「\(destination.deletingLastPathComponent().lastPathComponent)」へ"
            + "処理できませんでした。\(PosixFailure.explain(errnoCode))"
    }
}
