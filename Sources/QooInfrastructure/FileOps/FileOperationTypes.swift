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
        }
    }

    private static func copyFailureMessage(source: URL, destination: URL, errnoCode: Int32) -> String {
        let name = source.lastPathComponent
        let system = String(cString: strerror(errnoCode))
        switch errnoCode {
        case ENOSPC:
            let folder = destination.deletingLastPathComponent().lastPathComponent
            return "「\(name)」をコピーできませんでした。"
                + "コピー先「\(folder)」の空き容量が足りません。"
                + "不要な項目を削除してから、もう一度お試しください。"
        case EACCES, EPERM:
            return "「\(name)」をコピーできませんでした。コピー先に書き込む権限がありません。（\(system)）"
        case EDQUOT:
            return "「\(name)」をコピーできませんでした。ディスク使用量の割り当てを超えています。（\(system)）"
        case EEXIST:
            return "「\(name)」をコピーできませんでした。同じ名前の項目がすでに存在します。"
        default:
            return "「\(name)」をコピーできませんでした。（\(system)）"
        }
    }
}
