//
//  区切り文字 [9.3][DL-01〜DL-16]。
//
import Foundation

/// ペア型（開き／閉じの対を持ち、ネストできる）[DL-01][DL-12][FF-11]。
public struct PairDelimiter: Sendable, Hashable, Codable, Identifiable {
    public let id: UUID
    public let open: Character
    public let close: Character
    public var isEnabled: Bool

    public init(id: UUID = UUID(), open: Character, close: Character, isEnabled: Bool = true) {
        self.id = id
        self.open = open
        self.close = close
        self.isEnabled = isEnabled
    }

    // `Character` は `Codable` ではないため、JSON では 1 文字の文字列として持つ。
    // テンプレート JSON（11.4 節）を人が読み書きできる形にするためでもある。
    private enum CodingKeys: String, CodingKey { case id, open, close, isEnabled }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        open = try Self.singleCharacter(try c.decode(String.self, forKey: .open), .open, c)
        close = try Self.singleCharacter(try c.decode(String.self, forKey: .close), .close, c)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(String(open), forKey: .open)
        try c.encode(String(close), forKey: .close)
        try c.encode(isEnabled, forKey: .isEnabled)
    }

    private static func singleCharacter(
        _ s: String, _ key: CodingKeys,
        _ c: KeyedDecodingContainer<CodingKeys>
    ) throws -> Character {
        guard s.count == 1, let ch = s.first else {
            throw DecodingError.dataCorruptedError(
                forKey: key, in: c,
                debugDescription: "区切り文字は 1 文字でなければならない: \(s.debugDescription)")
        }
        return ch
    }
}

/// セパレータ型（境界を示すだけでネストを持たない）[DL-11][DL-14][DL-15]。
public struct SeparatorDelimiter: Sendable, Hashable, Codable, Identifiable {
    public let id: UUID
    /// 代表表記。フォーマットの保存や表示に使う。
    public let canonical: String
    /// 同一視する表記の集合。`-` に対する `－ ‐ – —` など [DL-15]。
    public let variants: Set<String>
    /// **既定は無効** [DL-11]。タイトル中の文字と誤認する影響が大きいため [R-10]。
    public var isEnabled: Bool

    public init(id: UUID = UUID(), canonical: String, variants: Set<String> = [], isEnabled: Bool = false) {
        self.id = id
        self.canonical = canonical
        self.variants = variants.union([canonical])
        self.isEnabled = isEnabled
    }

    /// 長い順に並べた表記（最長一致で読むため）。
    public var variantsByLengthDesc: [String] {
        variants.sorted { ($0.count, $0) > ($1.count, $1) }
    }
}

public struct DelimiterSet: Sendable, Hashable, Codable {
    public var pairs: [PairDelimiter]
    public var separators: [SeparatorDelimiter]

    public init(pairs: [PairDelimiter] = [], separators: [SeparatorDelimiter] = []) {
        self.pairs = pairs
        self.separators = separators
    }

    public var enabledPairs: [PairDelimiter] { pairs.filter(\.isEnabled) }
    public var enabledSeparators: [SeparatorDelimiter] { separators.filter(\.isEnabled) }

    /// 既定: 角括弧と丸括弧のみ有効。セパレータ型は空 [DL-01][DL-10][DL-11]。
    ///
    /// 実コーパス 2,953 件で `(` は 5,953 回、`[` は 2,440 回現れる。
    /// `【】`(49) `「」`(36) `（）`(11) も現れるが、いずれもタイトルの一部として
    /// 使われている例が多く、既定で境界と解釈すると誤爆する [設計判断]。
    public static let `default` = DelimiterSet(
        pairs: [
            PairDelimiter(open: "[", close: "]"),
            PairDelimiter(open: "(", close: ")"),
        ],
        separators: []
    )

    /// 設定画面で選べる候補（既定では無効なものを含む）[DL-02][DL-15]。
    public static let availablePairs: [(open: Character, close: Character)] = [
        ("[", "]"), ("(", ")"), ("【", "】"), ("〔", "〕"), ("《", "》"),
        ("〈", "〉"), ("「", "」"), ("『", "』"), ("（", "）"), ("｛", "｝"), ("{", "}"),
    ]

    /// セパレータ型の既定候補。**いずれも既定は無効** [DL-11][DL-13]。
    public static func availableSeparators() -> [SeparatorDelimiter] {
        [
            SeparatorDelimiter(canonical: "-", variants: ["-", "－", "‐", "–", "—", "―"]),
            SeparatorDelimiter(canonical: "_", variants: ["_", "＿"]),
            SeparatorDelimiter(canonical: "~", variants: ["~", "～", "〜"]),
        ]
    }
}
