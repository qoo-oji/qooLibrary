//
//  照合の正規化オプション [N-04]。
//
import Foundation

public struct NormalizationOptions: Sendable, Hashable, Codable {
    /// 既定は `false`（大文字小文字を区別しない＝小文字へ畳む）[N-04]。
    public var caseSensitive: Bool

    public init(caseSensitive: Bool = false) {
        self.caseSensitive = caseSensitive
    }

    public static let `default` = NormalizationOptions()
    public static let caseSensitive = NormalizationOptions(caseSensitive: true)
}
