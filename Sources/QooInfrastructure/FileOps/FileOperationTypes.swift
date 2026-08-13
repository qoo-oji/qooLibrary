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
    /// `BatchNotificationSession`（1-12b でも未実装、具体的な利用箇所が無い
    /// ままの投機的実装を避けたため）がまだ無いため、暫定的に呼び出し側が
    /// 直接解決ロジックを渡す形にしている。「以降すべてに適用」[FM-12] は
    /// `BatchNotificationSession` 側が担う予定（実際に `.ask` を使う一括処理
    /// フローができたタイミングで導入する）。
    public var conflictResolver: (@Sendable (_ source: URL, _ destination: URL) async -> ConflictPolicy)?

    public init(
        conflictPolicy: ConflictPolicy = .ask,
        conflictResolver: (@Sendable (_ source: URL, _ destination: URL) async -> ConflictPolicy)? = nil
    ) {
        self.conflictPolicy = conflictPolicy
        self.conflictResolver = conflictResolver
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

public enum FileOperationError: Error, Sendable, Equatable {
    case sourceNotFound(URL)
    /// `.ask` が指定されたが `conflictResolver` が渡されなかった、または解決手段が
    /// 再度 `.ask` を返した（無限ループ防止のため 1 回のみ許容する）。
    case conflictResolutionRequired(source: URL, destination: URL)
    case operationFailed(String)
}
