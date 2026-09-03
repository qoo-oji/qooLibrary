//
//  正規化済み文字列の型安全なラッパ [N-03][NM-06]。
//
import Foundation

/// 生の `String` と取り違えないための値型。
///
/// 等価判定とハッシュは**正規化済みの `key` だけ**を見る。`raw`（表示用の原文）が
/// 違っても、照合上は同じものとして扱われる [N-03]。ラベルの一意性判定は
/// `(fieldID, key)` の組で行い、表示名は最初に登録された原文を使う [NM-06]。
public struct NormalizedString: Sendable, Hashable, Codable, CustomStringConvertible {
    /// 原文（表示用）[N-03]。
    public let raw: String
    /// 正規化済み（照合用）。
    public let key: String

    public init(_ raw: String) {
        self.raw = raw
        self.key = TextNormalizer.normalize(raw)
    }

    /// 既に正規化済みの値から組み立てる（DB からの読み出し等）。
    public init(raw: String, key: String) {
        self.raw = raw
        self.key = key
    }

    public var description: String { raw }
    public var isEmpty: Bool { key.isEmpty }

    public static func == (l: Self, r: Self) -> Bool { l.key == r.key }
    public func hash(into h: inout Hasher) { h.combine(key) }
}
