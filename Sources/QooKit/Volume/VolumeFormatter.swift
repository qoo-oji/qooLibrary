//
//  巻数の出力書式 [5.5][CR-20〜CR-25][VO-01〜VO-03]。変換リネームの出力側で使う。
//
import Foundation

public struct VolumeOutputStyle: Sendable, Hashable, Codable, Identifiable {
    public enum NumeralWidth: String, Sendable, Codable, Hashable { case halfwidth, fullwidth }

    public let id: UUID
    /// 名前を付けて共有できる [CR-25][VO-03]。
    public var name: String
    /// `{n}` が数値プレースホルダ [CR-22]。
    public var numericTemplate: String
    /// 0 = ゼロ埋めしない [CR-22]。
    public var digits: Int
    public var numeralWidth: NumeralWidth
    /// `{s}` は原文 [CR-22][CR-23]。**種別ごとにテンプレートを分けることで
    /// `第上巻巻` のような破綻を構造的に防ぐ** [VO-01]。
    public var ordinalTemplate: String
    public var noneOutput: String

    public init(id: UUID = UUID(), name: String = "既定",
                numericTemplate: String = "第{n}巻", digits: Int = 2,
                numeralWidth: NumeralWidth = .halfwidth,
                ordinalTemplate: String = "{s}", noneOutput: String = "") {
        self.id = id
        self.name = name
        self.numericTemplate = numericTemplate
        self.digits = digits
        self.numeralWidth = numeralWidth
        self.ordinalTemplate = ordinalTemplate
        self.noneOutput = noneOutput
    }

    public static let `default` = VolumeOutputStyle()
}

public enum VolumeFormatter {
    public static func render(_ v: VolumeValue, style: VolumeOutputStyle) -> String {
        switch v.kind {
        case .none:
            return style.noneOutput                                        // [CR-30 で周囲ごと削除]
        case .ordinal:
            return style.ordinalTemplate.replacingOccurrences(of: "{s}", with: v.raw ?? "")
        case .numeric:
            guard let n = v.number else { return style.noneOutput }
            var s = (n == n.rounded() && n.magnitude < 1e15)
                ? String(Int(n))
                : String(n)                                                // 3.5 は "3.5"
            // ゼロ埋めは整数部にのみ適用する。
            if style.digits > 0 {
                let parts = s.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
                var intPart = String(parts[0])
                let negative = intPart.hasPrefix("-")
                if negative { intPart.removeFirst() }
                if intPart.count < style.digits {
                    intPart = String(repeating: "0", count: style.digits - intPart.count) + intPart
                }
                if negative { intPart = "-" + intPart }
                s = parts.count > 1 ? intPart + "." + parts[1] : intPart
            }
            if style.numeralWidth == .fullwidth { s = toFullwidthDigits(s) }
            return style.numericTemplate.replacingOccurrences(of: "{n}", with: s)
        }
    }

    /// 半角数字・記号を全角へ [CR-22]。`WidthFolding` の逆写像。
    static func toFullwidthDigits(_ s: String) -> String {
        var view = String.UnicodeScalarView()
        for scalar in s.unicodeScalars {
            if scalar.value >= 0x21, scalar.value <= 0x7E,
               let wide = Unicode.Scalar(scalar.value + WidthFolding.asciiOffset) {
                view.append(wide)
            } else {
                view.append(scalar)
            }
        }
        return String(view)
    }
}
