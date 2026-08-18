//
//  巻数フォーマット [10.2 節][SE-10][SE-21][SE-23][CR-20]。
//
import Foundation

/// 巻数フォーマットの定義。
///
/// | メタ記号 | 意味 |
/// |---|---|
/// | `??` | 任意桁数の半角／全角数字（1 桁以上）。`3.5` のような小数も許容 |
/// | `<space>` | 半角／全角スペースの **1 個以上**。空白なしにはマッチしない [SE-23][WS-07] |
/// | それ以外 | リテラル。全角半角の差は吸収する [SE-03] |
public struct VolumePattern: Sendable, Hashable, Codable, Identifiable {
    public let id: UUID
    public var source: String            // "第??巻" "vol<space>??" "上巻"
    public var isEnabled: Bool
    public var priority: Int             // 登録順＝優先順 [SE-21]
    /// 序列表記のときの順序値 [SE-10]。数値パターンでは nil。
    public var ordinalRank: Int?

    public init(id: UUID = UUID(), source: String, isEnabled: Bool = true,
                priority: Int = 0, ordinalRank: Int? = nil) {
        self.id = id
        self.source = source
        self.isEnabled = isEnabled
        self.priority = priority
        self.ordinalRank = ordinalRank
    }
}

enum VolumeToken: Sendable, Equatable {
    case literal([Character])     // 正準化済み（全角半角を吸収した形）
    case digits                   // `??`
    case requiredSpace            // `<space>`
}

public struct CompiledVolumePattern: Sendable, Equatable {
    public let id: UUID
    let tokens: [VolumeToken]
    public let ordinalRank: Int?
    public let priority: Int
    public let source: String

    public var isOrdinal: Bool { ordinalRank != nil }

    /// 数字を含まない序列パターン（`上巻` `前編`）か。
    var hasDigits: Bool { tokens.contains(.digits) }
}

public enum VolumePatternCompiler {
    static let digitsMark = Array("??")
    static let spaceMark = Array("<space>")

    /// 巻数フォーマットをトークン列へ。構文エラーは無い（未知の記号はリテラル）。
    public static func compile(_ pattern: VolumePattern) -> CompiledVolumePattern {
        let chars = Array(pattern.source)
        var tokens: [VolumeToken] = []
        var literal: [Character] = []
        var i = 0

        func flush() {
            guard !literal.isEmpty else { return }
            // リテラルは正準化して覚える。照合時に毎回変換しないため [SE-03]。
            tokens.append(.literal(Array(TextNormalizer.canonicalWidth(String(literal)))))
            literal = []
        }

        while i < chars.count {
            if FormatLexer.matches(chars, at: i, Self.digitsMark) {
                flush(); tokens.append(.digits); i += Self.digitsMark.count
            } else if FormatLexer.matches(chars, at: i, Self.spaceMark) {
                flush(); tokens.append(.requiredSpace); i += Self.spaceMark.count
            } else {
                literal.append(chars[i]); i += 1
            }
        }
        flush()
        return CompiledVolumePattern(id: pattern.id, tokens: tokens,
                                     ordinalRank: pattern.ordinalRank,
                                     priority: pattern.priority, source: pattern.source)
    }

    public static func compileAll(_ patterns: [VolumePattern]) -> [CompiledVolumePattern] {
        patterns.filter(\.isEnabled).sorted { $0.priority < $1.priority }.map(compile)
    }
}
