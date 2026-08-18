//
//  巻数の構造化表現 [CR-20][SE-09][SE-10]。
//
import Foundation

public struct VolumeValue: Sendable, Hashable, Codable {
    public enum Kind: String, Sendable, Codable, Hashable { case numeric, ordinal, none }

    public let kind: Kind
    /// `.numeric` のときの値。3.5 のような小数を許容する。
    public let number: Double?
    /// `.ordinal` のときのソート順序値 [SE-10]。
    public let ordinalRank: Int?
    /// 原文表記（`第01巻` `上巻`）。出力書式 [CR-23] とラベル表示に使う。
    public let raw: String?

    public init(kind: Kind, number: Double?, ordinalRank: Int?, raw: String?) {
        self.kind = kind
        self.number = number
        self.ordinalRank = ordinalRank
        self.raw = raw
    }

    public static let none = VolumeValue(kind: .none, number: nil, ordinalRank: nil, raw: nil)

    public static func numeric(_ n: Double, raw: String) -> VolumeValue {
        VolumeValue(kind: .numeric, number: n, ordinalRank: nil, raw: raw)
    }

    public static func ordinal(rank: Int, raw: String) -> VolumeValue {
        VolumeValue(kind: .ordinal, number: nil, ordinalRank: rank, raw: raw)
    }

    /// ソート用の単一キー。`numeric` < `ordinal` < `none` の順で安定させる。
    ///
    /// `ordinal` を `numeric` の後ろへ確実に置くため、順序値そのものではなく
    /// 十分大きな下駄を履かせた値を返す（順序値は 1〜10000 を想定 [SE-10]）。
    public var sortKey: Double {
        switch kind {
        case .numeric: return number ?? 0
        case .ordinal: return Self.ordinalSortBase + Double(ordinalRank ?? 0)
        case .none:    return .infinity
        }
    }

    /// 数値巻数がこの値を超えることは実運用で起こらない（実データの最大は 3 桁）。
    static let ordinalSortBase: Double = 1_000_000
}
