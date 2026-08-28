//
//  ラベルグループの既定色 [8.1 節][CO-01〜CO-07][MT-13]。
//
//  **10 色のリテラル配列として持たない** [MT-13]。グループ数 N に応じて色相環を
//  N 等分して生成し、彩度・明度は CO-02 の範囲に固定する。ラベルグループの
//  上限が 10 から変わっても既定色が破綻しない。
//
import Foundation

public struct LabelColor: Sendable, Hashable, Codable {
    public let hexLight: String
    public let hexDark: String

    public init(hexLight: String, hexDark: String) {
        self.hexLight = hexLight
        self.hexDark = hexDark
    }
}

public enum LabelColorPalette {
    /// ライトモード: 淡い背景 + 黒フォント [CO-02][CO-03]。
    /// 彩度 15〜25% / 明度 85〜92% の範囲に収める。
    static let lightSaturation = 0.20
    static let lightValue = 0.89
    /// ダークモード: 同じ色相のまま明度を下げ、白フォント前提にする [CO-07]。
    static let darkSaturation = 0.32
    static let darkValue = 0.40
    /// 色相の起点（度）。**1 番目を薄い青にする**［ユーザー指定、CO-01 改訂］。
    /// 以降はグループ番号順に色相環を一周し、全フィールドを閉じた一覧が
    /// きれいなグラデーションになる。彩度は CO-02 の範囲のまま（原色は使わない）。
    static let hueOrigin = 210.0

    /// グループ数 `count` に対する既定色を色相環の等分で生成する [CO-01][MT-13]。
    public static func palette(count: Int) -> [LabelColor] {
        guard count > 0 else { return [] }
        return (0..<count).map { i in
            let hue = (hueOrigin + 360.0 * Double(i) / Double(count)).truncatingRemainder(dividingBy: 360)
            return LabelColor(
                hexLight: hex(hue: hue, saturation: lightSaturation, value: lightValue),
                hexDark: hex(hue: hue, saturation: darkSaturation, value: darkValue))
        }
    }

    /// 1 始まりのグループ番号に対する既定色。
    public static func color(forGroupIndex index: Int, of count: Int) -> LabelColor? {
        let all = palette(count: count)
        guard index >= 1, index <= all.count else { return nil }
        return all[index - 1]
    }

    // MARK: - 色空間

    /// HSV → `#RRGGBB`。
    public static func hex(hue: Double, saturation: Double, value: Double) -> String {
        let (r, g, b) = rgb(hue: hue, saturation: saturation, value: value)
        return String(format: "#%02X%02X%02X",
                      Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
    }

    static func rgb(hue: Double, saturation s: Double, value v: Double) -> (Double, Double, Double) {
        let h = hue.truncatingRemainder(dividingBy: 360) / 60
        let c = v * s
        let x = c * (1 - abs(h.truncatingRemainder(dividingBy: 2) - 1))
        let m = v - c
        let (r1, g1, b1): (Double, Double, Double)
        switch Int(h) {
        case 0: (r1, g1, b1) = (c, x, 0)
        case 1: (r1, g1, b1) = (x, c, 0)
        case 2: (r1, g1, b1) = (0, c, x)
        case 3: (r1, g1, b1) = (0, x, c)
        case 4: (r1, g1, b1) = (x, 0, c)
        default: (r1, g1, b1) = (c, 0, x)
        }
        return (r1 + m, g1 + m, b1 + m)
    }

    /// WCAG の相対輝度 [CO-03][CO-05]。
    public static func relativeLuminance(hex: String) -> Double? {
        guard let (r, g, b) = components(hex: hex) else { return nil }
        func channel(_ c: Double) -> Double {
            c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b)
    }

    /// コントラスト比 [CO-03][CO-05]。4.5:1 以上が WCAG AA。
    public static func contrastRatio(_ a: String, _ b: String) -> Double? {
        guard let la = relativeLuminance(hex: a), let lb = relativeLuminance(hex: b) else { return nil }
        let (hi, lo) = la > lb ? (la, lb) : (lb, la)
        return (hi + 0.05) / (lo + 0.05)
    }

    /// 背景色に対して黒／白のうちコントラストの高い方を返す [CO-05]。
    /// どちらも 4.5:1 未満なら `nil`（呼び出し側が警告アイコンを出す）。
    public static func readableForeground(on background: String) -> String? {
        guard let black = contrastRatio(background, "#000000"),
              let white = contrastRatio(background, "#FFFFFF") else { return nil }
        let best = max(black, white)
        guard best >= 4.5 else { return nil }
        return black >= white ? "#000000" : "#FFFFFF"
    }

    static func components(hex: String) -> (Double, Double, Double)? {
        var s = hex
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        return (Double((v >> 16) & 0xFF) / 255,
                Double((v >> 8) & 0xFF) / 255,
                Double(v & 0xFF) / 255)
    }
}
