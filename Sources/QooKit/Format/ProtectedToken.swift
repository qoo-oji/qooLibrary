//
//  保護文字列 [9.2.3][PT-01〜PT-11]。
//
import Foundation

public struct ProtectedToken: Sendable, Hashable, Codable, Identifiable {
    public enum Position: String, Sendable, Codable, Hashable {
        case anywhere, prefix, suffix
    }

    public let id: UUID
    /// `(仮)` `(完全版)` のような、区切り文字を含むが 1 かたまりとして扱いたい文字列。
    public let text: String
    public var position: Position          // [PT-05]
    public var isEnabled: Bool

    public init(id: UUID = UUID(), text: String,
                position: Position = .anywhere, isEnabled: Bool = true) {
        self.id = id
        self.text = text
        self.position = position
        self.isEnabled = isEnabled
    }

    /// 照合キー（NFC + 全角半角 + 空白畳み込み）[PT-04]。
    public var normalizedKey: String { TextNormalizer.normalize(text) }
}
