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

    public init(
        conflictPolicy: ConflictPolicy = .ask,
        conflictResolver: (@Sendable (_ source: URL, _ destination: URL) async -> ConflictPolicy)? = nil,
        progress: ProgressReporter? = nil
    ) {
        self.conflictPolicy = conflictPolicy
        self.conflictResolver = conflictResolver
        self.progress = progress
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
}
