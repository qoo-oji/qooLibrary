//
//  保護文字列 [9.2.3][PT-01〜PT-11]。
//
//  **記法は正規表現**（2026-08 の仕様変更）。以前は完全一致のリテラルのみで
//  [PT-11][PTI-04]、`(1999)`〜`(2024)` のような「括弧の中の年号」を 1 本で書けなかった。
//  旧記法（リテラル）からの変換は `LegacyVolumeNotation.regex(fromProtectedLiteral:)`。
//
import Foundation

public struct ProtectedToken: Sendable, Hashable, Codable, Identifiable {
    public enum Position: String, Sendable, Codable, Hashable {
        case anywhere, prefix, suffix
    }

    public let id: UUID
    /// 正規表現。`\((19[0-9]{2})\)` のように、区切り文字を含むが 1 かたまりとして
    /// 扱いたい範囲を表す。
    public var pattern: String
    public var position: Position          // [PT-05]
    public var isEnabled: Bool

    public init(id: UUID = UUID(), pattern: String,
                position: Position = .anywhere, isEnabled: Bool = true) {
        self.id = id
        self.pattern = pattern
        self.position = position
        self.isEnabled = isEnabled
    }
}

public struct CompiledProtectedToken: Sendable {
    public let id: UUID
    public let pattern: String
    public let position: ProtectedToken.Position
    let regex: SafeRegex
    let health: RegexPatternHealth

    init(id: UUID, pattern: String, position: ProtectedToken.Position,
         regex: SafeRegex, health: RegexPatternHealth) {
        self.id = id
        self.pattern = pattern
        self.position = position
        self.regex = regex
        self.health = health
    }
}

extension CompiledProtectedToken: Equatable {
    public static func == (lhs: CompiledProtectedToken, rhs: CompiledProtectedToken) -> Bool {
        lhs.id == rhs.id && lhs.pattern == rhs.pattern && lhs.position == rhs.position
    }
}

public enum ProtectedTokenCompiler {

    /// 有効なものだけをコンパイルする。**正規表現として読めないものは落とす**
    /// （保存時に `LibrarySettingsDraft.validate()` が弾く）。
    ///
    /// 照合は**大文字小文字を無視**する。旧実装の照合キーが小文字化していた挙動を
    /// 保つため [PT-04]。被検査文字列を小文字化するのではなく正規表現の側の option に
    /// するので、ユーザーが書いた `[A-Z]` が壊れない。
    public static func compileAll(_ tokens: [ProtectedToken]) -> [CompiledProtectedToken] {
        let health = RegexPatternHealth()
        return tokens.filter(\.isEnabled).compactMap { token in
            guard !token.pattern.isEmpty,
                  let regex = try? SafeRegex(token.pattern, caseInsensitive: true) else { return nil }
            return CompiledProtectedToken(id: token.id, pattern: token.pattern,
                                          position: token.position,
                                          regex: regex, health: health)
        }
    }
}
