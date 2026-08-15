import Foundation

/// 長時間処理の進み具合 [UI-09][A-04]。
///
/// 「何件目か」と「何バイト目か」の両方を持つ。件数だけだと巨大な 1 ファイルの
/// コピーが `0/1` のまま止まって見え、バイト数だけだと「あと何個あるのか」が
/// 分からないため。
public struct OperationProgress: Sendable, Equatable {
    /// 総量が分からない段階（対象の大きさを数えている最中など）。
    /// この間は不定進捗として見せる。
    public var isDeterminate: Bool { totalBytes > 0 }

    public var completedBytes: Int64
    public var totalBytes: Int64
    public var completedItems: Int
    public var totalItems: Int
    /// 今まさに処理している項目の**表示名**（パスではない）。進捗シートに出す。
    public var currentItemName: String?

    public init(
        completedBytes: Int64 = 0,
        totalBytes: Int64 = 0,
        completedItems: Int = 0,
        totalItems: Int = 0,
        currentItemName: String? = nil
    ) {
        self.completedBytes = completedBytes
        self.totalBytes = totalBytes
        self.completedItems = completedItems
        self.totalItems = totalItems
        self.currentItemName = currentItemName
    }

    /// 0.0〜1.0。総量が不明なら `nil`（呼び出し側は不定進捗にする）。
    public var fraction: Double? {
        guard totalBytes > 0 else { return nil }
        return min(1.0, Double(completedBytes) / Double(totalBytes))
    }
}

/// 進捗の受け取り口 [8章 §8.1 `OpOptions.progress`]。
///
/// **プロトコルにしていない** — `Foundation` が同名の `ProgressReporting`
/// （`NSProgress` 用）を持っており、型の探索が曖昧になるため。用途は
/// 「クロージャを 1 つ運ぶ」だけなので具体型で足りる。
///
/// **通知は呼び出し側で間引く前提**（`copyfile(3)` の status コールバックは
/// 500MB のコピーで 400 回以上呼ばれるため、そのまま UI へ流すと更新だけで
/// 忙しくなる）。間引きは `ProgressTracker` が行う。
public struct ProgressReporter: Sendable {
    private let handler: @Sendable (OperationProgress) -> Void

    public init(_ handler: @escaping @Sendable (OperationProgress) -> Void) {
        self.handler = handler
    }

    public func report(_ progress: OperationProgress) { handler(progress) }
}
