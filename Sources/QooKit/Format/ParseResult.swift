//
//  照合の結果 [9 章][CW-16][HP-06]。
//
import Foundation

/// 型付きフィールドが取り出した値 [MF-08]。
///
/// **数値と日付を 1 つの enum にまとめる。** `FieldValue` に列を 2 本並べると
/// 「どちらも nil」「どちらも非 nil」という表せてはいけない状態が作れてしまう。
public enum TypedFieldValue: Sendable, Hashable {
    /// 巻・シーズン・話数。
    ///
    /// `impliedSeason` は **`@episode` のパターンが `(?<season>…)` を持つとき**だけ
    /// 非 nil [MF-06]——`S01E01` を 1 本の正規表現で書けるようにするためのもの。
    /// 明示の `@season` が同じフォーマットにあれば**そちらが勝つ**（明示が暗黙に勝つ）。
    case number(VolumeValue, impliedSeason: Double?)
    /// 公開日 [MF-19]。**ISO 8601 の部分形**（`2024` / `2024-01` / `2024-01-15`）。
    case date(String)
}

public struct FieldValue: Sendable, Hashable {
    /// トリム済みの**原文**（表示用）[WS-05][N-03]。内部の空白は原文のまま保つ。
    public let text: String
    /// 照合用の正規化形。
    public let normalized: String
    /// 型付きフィールドのときのみ [MF-08]。
    public let typed: TypedFieldValue?

    /// `@volume` `@season` `@episode` の数値。
    public var volume: VolumeValue? {
        if case .number(let v, _) = typed { return v }
        return nil
    }
    /// `@episode` のパターンが同時に読んだシーズン [MF-06]。
    public var impliedSeason: Double? {
        if case .number(_, let s) = typed { return s }
        return nil
    }
    /// `@date` の値（ISO 8601 の部分形）[MF-19]。
    public var date: String? {
        if case .date(let d) = typed { return d }
        return nil
    }

    public init(text: String, normalized: String, typed: TypedFieldValue? = nil) {
        self.text = text
        self.normalized = normalized
        self.typed = typed
    }

    /// 既存の呼び出し口。巻数だけを渡す形。
    public init(text: String, normalized: String, volume: VolumeValue?) {
        self.init(text: text, normalized: normalized,
                  typed: volume.map { .number($0, impliedSeason: nil) })
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

    public init(matchedFormatID: UUID, fields: [FieldRef: FieldValue],
                spans: [FieldSpan]) {
        self.matchedFormatID = matchedFormatID
        self.fields = fields
        self.spans = spans
    }

}

/// 1 フォーマットとの照合結果。失敗しても診断情報を返す。
public struct MatchOutcome: Sendable {
    public let result: ParseResult?
    /// 照合が最も進んだ入力位置。「最も近いフォーマット」の推定に使う [UR2-05]。
    public let furthestIndex: Int
    /// **満たしたフォーマット要素の数**（最上位のノード列における添字の最大値）。
    ///
    /// 「最も近いフォーマット」の第一キー [UR2-05]。入力位置だけでは**飽和する**
    /// ——自由文字列フィールド（`@title` 等）に入った時点で走査位置が入力の末尾へ
    /// 届くので、`@title (@genre)` と `[@studio] @title @volume` がどちらも
    /// 「末尾まで到達」で同点になる（実測、2026-09-01）。要素数なら
    /// 「このフォーマットのどこまで筋が通ったか」を表せる。
    ///
    /// **括弧の中は数えない**（グループ全体で 1 要素）——入れ子の添字を最上位の
    /// 添字と混ぜると、深い括弧を持つフォーマットが不当に有利になる。
    /// `nodes.count` と等しければ「全要素を満たしたが入力が余った」を意味する。
    public let satisfiedNodes: Int
    /// 探索ノード数の上限を超えて打ち切ったか [MT2-02]。
    public let exceededStepLimit: Bool
    public let steps: Int

    public var matched: Bool { result != nil }
}
