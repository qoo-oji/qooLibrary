//
//  照合の結果 [9 章][CW-16][HP-06]。
//
import Foundation

public struct FieldValue: Sendable, Hashable {
    /// トリム済みの**原文**（表示用）[WS-05][N-03]。内部の空白は原文のまま保つ。
    public let text: String
    /// 照合用の正規化形。
    public let normalized: String
    /// `@volume` のときのみ。
    public let volume: VolumeValue?

    public init(text: String, normalized: String, volume: VolumeValue? = nil) {
        self.text = text
        self.normalized = normalized
        self.volume = volume
    }
}

/// どの範囲がどのフィールドか。元のファイル名（保護復元後）における文字範囲 [CW-16][HP-06]。
public struct FieldSpan: Sendable, Equatable {
    public let field: FieldRef
    public let range: Range<Int>

    public init(field: FieldRef, range: Range<Int>) {
        self.field = field
        self.range = range
    }
}

public struct ParseResult: Sendable {
    public let matchedFormatID: UUID
    public let fields: [FieldRef: FieldValue]
    /// 出現順。フィールド分解表示に使う [CW-16]。
    public let spans: [FieldSpan]
    /// `@librarytype` の不一致。スキャン時は警告のみ、移動時はマッチ失敗 [RW-01]。
    public var libraryTypeMismatch: Bool

    public init(matchedFormatID: UUID, fields: [FieldRef: FieldValue],
                spans: [FieldSpan], libraryTypeMismatch: Bool = false) {
        self.matchedFormatID = matchedFormatID
        self.fields = fields
        self.spans = spans
        self.libraryTypeMismatch = libraryTypeMismatch
    }

}

/// 1 フォーマットとの照合結果。失敗しても診断情報を返す。
public struct MatchOutcome: Sendable {
    public let result: ParseResult?
    /// 照合が最も進んだ入力位置。「最も近いフォーマット」の推定に使う [UR2-05]。
    public let furthestIndex: Int
    /// 探索ノード数の上限を超えて打ち切ったか [MT2-02]。
    public let exceededStepLimit: Bool
    public let steps: Int

    public var matched: Bool { result != nil }
}
