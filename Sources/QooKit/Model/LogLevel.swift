import Foundation

/// 診断ログの重要度 [LG2-03][2章 §2.6]。
///
/// **`rawValue` が小さいほど重大**（`error` = 0）。環境設定で選んだレベルは
/// 「そのレベル以下（＝それ以上に重大）のものだけを出力する」というしきい値
/// として働くため、`record.level <= currentLevel` が出力条件になる。
///
/// `QooInfrastructure` ではなく `QooKit` に置いているのは、`AppLimits.Logging`
/// が既定値としてこの型を持つため（`AppLimits` は `QooKit`）。この型自体は
/// `Foundation` にしか依存しない純粋な値型なので [A-01] に反しない。
public enum LogLevel: Int, Sendable, Codable, CaseIterable, Comparable {
    case error = 0
    case warning = 1
    case info = 2
    case debug = 3

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// ログ 1 行の先頭に出す 1 文字表記（`E`/`W`/`I`/`D`）。
    /// 桁が揃うため、書き出したログを目視・`grep` で追いやすい。
    public var symbol: String {
        switch self {
        case .error: "E"
        case .warning: "W"
        case .info: "I"
        case .debug: "D"
        }
    }

    /// 永続化・診断情報 JSON 用の安定した識別子。表示名（ローカライズ対象）
    /// とは別物で、こちらはバージョン間で変えない。
    public var identifier: String {
        switch self {
        case .error: "error"
        case .warning: "warning"
        case .info: "info"
        case .debug: "debug"
        }
    }

    public init?(identifier: String) {
        guard let match = LogLevel.allCases.first(where: { $0.identifier == identifier }) else { return nil }
        self = match
    }
}
