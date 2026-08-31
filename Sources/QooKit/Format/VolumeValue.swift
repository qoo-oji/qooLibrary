//
//  巻数の構造化表現 [CR-20][SE-09]。
//
//  **序列巻数（`上巻` = 1, `下巻` = 3 のように順序値を持つ種別）は 2026-08 の
//  仕様変更で廃止した** [ユーザー判断]。`上巻` のような表記は巻数ではなく
//  「シリーズ名を切るための区切り」として扱う（`VolumePatternKind.separator`）。
//
import Foundation

public struct VolumeValue: Sendable, Hashable, Codable {
    public enum Kind: String, Sendable, Codable, Hashable { case numeric, none }

    public let kind: Kind
    /// `.numeric` のときの値。3.5 のような小数を許容する。
    public let number: Double?
    /// 原文表記（`第01巻`）。出力書式 [CR-23] とラベル表示に使う。
    /// **畳む前の原文**を入れること——全角や NFD の表記を失わないため。
    public let raw: String?

    public init(kind: Kind, number: Double?, raw: String?) {
        self.kind = kind
        self.number = number
        self.raw = raw
    }

    public static let none = VolumeValue(kind: .none, number: nil, raw: nil)

    public static func numeric(_ n: Double, raw: String) -> VolumeValue {
        VolumeValue(kind: .numeric, number: n, raw: raw)
    }

    /// 利用者が手で入力した巻数を読む [RP-14]。
    ///
    /// 空（空白のみを含む）は「巻数なし」＝ `.none`。**数値として読めない
    /// 入力は `nil` を返して受け付けない**——`.none` に落とすと、打ち間違いが
    /// 「巻数を消す操作」として黙って通ってしまう。
    ///
    /// 全角数字は `TextNormalizer` で畳んでから読む（`１２` を弾かない）。
    /// `raw` には**畳む前の入力**を入れる——この型の規約どおり、表記を失わない。
    public static func parsingUserInput(_ text: String) -> VolumeValue? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return VolumeValue.none }
        guard let n = Double(TextNormalizer.normalize(trimmed)), n.isFinite else { return nil }
        return .numeric(n, raw: trimmed)
    }

    /// ソート用の単一キー。`numeric` < `none` の順で安定させる。
    public var sortKey: Double {
        switch kind {
        case .numeric: return number ?? 0
        case .none:    return .infinity
        }
    }
}
