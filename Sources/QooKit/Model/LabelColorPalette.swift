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
    /// 明度（OKLCH の L）。**ライトもダークも同じ値を使う**。
    ///
    /// ［ユーザー指定、2026-08-30「なるべく明るい色で」］——以前はダークだけ
    /// 明度を落としていた（L=0.52）が、それが「暗い」の正体だった。明るい帯に
    /// 黒文字なら、暗い地の上でも明るい地の上でも読める（最小 7.9:1[実測]）。
    ///
    /// **これ以上明るくすると赤の端がサーモン色に転ぶ**——`一番下が赤` [ユーザー
    /// 指定] を満たせなくなる。L=0.78 で `#FF9687`、L=0.84 で `#FFB5AA`[実測]。
    static let lightness = 0.72
    /// 彩度（OKLCH の C）。**純色は使わない**が [CO-02]、フィールドを色で
    /// 見分けられるところまで上げる。sRGB の外へ出る色相は自動で落ちる
    /// （実効 0.122〜0.197[実測]）。
    static let chroma = 0.22
    /// 色相の始点（度、OKLCH）＝**アプリアイコンの青**［ユーザー指定］。
    ///
    /// **HSV の色相（205 度）とは別の値**——OKLCH は知覚的に均等な空間なので、
    /// 同じ色でも角度が違う。
    static let hueStart = 247.4
    /// 色相の終点＝**赤**（`#FF0000` の OKLCH 色相が 29.2 度）。
    static let hueEnd = 29.0

    /// グループ数 `count` に対する既定色を生成する [CO-01][MT-13]。
    ///
    /// **色相環を一周させず、青から赤までを等分する**［ユーザー指定、2026-08-30:
    /// 「10 種類をかけて青→緑→黃→赤と変化するようにグラデーションを。一番上の
    /// ラベルが青、一番下が赤」］。247.4 度から 29.0 度へ**下る**ことで、
    /// 青 → 水色 → 緑 → 黄 → 橙 → 赤 の順に並ぶ。
    ///
    /// **端は件数によらず青と赤**——`count` が 10 でなくても、先頭が青・末尾が
    /// 赤になる（要望の「一番上／一番下」を満たすため）。`count == 1` は青。
    ///
    /// **HSV ではなく OKLCH で回す**。HSV で彩度・明度を固定したまま色相を
    /// 動かすと、**緑と黄が飛び抜けて明るく・鮮やかに見える**（`#8AFF1A` の
    /// ような蛍光色になる）——人間の目が色相ごとに違う明るさを感じるため。
    /// OKLCH なら**どの色相でも同じ明るさに見え**、原色じみた色が出ない。
    public static func palette(count: Int) -> [LabelColor] {
        guard count > 0 else { return [] }
        return hues(count: count).map { hue in
            let hex = hex(lightness: lightness, chroma: chroma, hue: hue)
            // ライトとダークで同じ色を使う（上記）。器は分けたままにしてあるので、
            // 将来モードごとに変えたくなったらここだけ直せばよい。
            return LabelColor(hexLight: hex, hexDark: hex)
        }
    }

    /// 色相の並び（度）。**青から赤へ単調に降りる**のがこの機能の定義そのもの
    /// なので、色の生成から切り出して直接検査できるようにしてある
    /// ——RGB の成分は途中で単調にならない（緑は R=0、赤の端は B>0）ので、
    /// 「青→赤」を成分の大小で確かめようとすると必ず失敗する[実測]。
    public static func hues(count: Int) -> [Double] {
        guard count > 0 else { return [] }
        return (0..<count).map { i in
            let t = count == 1 ? 0 : Double(i) / Double(count - 1)
            return hueStart + (hueEnd - hueStart) * t
        }
    }

    /// 1 始まりのグループ番号に対する既定色。
    public static func color(forGroupIndex index: Int, of count: Int) -> LabelColor? {
        let all = palette(count: count)
        guard index >= 1, index <= all.count else { return nil }
        return all[index - 1]
    }

    // MARK: - 色空間

    /// OKLCH → `#RRGGBB`。**sRGB の外へ出る色相では彩度を落として収める**
    /// （gamut mapping）。単純に切り詰めると色相がずれるため、二分探索で
    /// 「収まる最大の彩度」を求める。緑・シアンは同じ L でも取れる彩度が
    /// 低いので、そこだけ少し淡くなる[実測: C=0.169 → 0.118〜0.169]。
    public static func hex(lightness: Double, chroma: Double, hue: Double) -> String {
        let c = gamutMappedChroma(lightness: lightness, chroma: chroma, hue: hue)
        let (r, g, b) = srgb(lightness: lightness, chroma: c, hue: hue)
        func clamp(_ v: Double) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", clamp(r), clamp(g), clamp(b))
    }

    /// sRGB に収まる最大の彩度を二分探索で求める。
    ///
    /// **切り詰め（clamp）で済ませてはならない**——成分を 0...1 へ丸めると
    /// 色相がずれ、緑が黄緑に転ぶ。丸めた後では「収まっているか」を検査しても
    /// 必ず真になるので、**ずれたことに気づけない。**
    static func gamutMappedChroma(lightness: Double, chroma: Double, hue: Double) -> Double {
        guard !isInSRGB(lightness: lightness, chroma: chroma, hue: hue) else { return chroma }
        var lo = 0.0, hi = chroma
        for _ in 0..<40 {
            let mid = (lo + hi) / 2
            if isInSRGB(lightness: lightness, chroma: mid, hue: hue) { lo = mid } else { hi = mid }
        }
        return lo
    }

    static func isInSRGB(lightness: Double, chroma: Double, hue: Double) -> Bool {
        let (r, g, b) = linearRGB(lightness: lightness, chroma: chroma, hue: hue)
        let tolerance = 1e-4
        return [r, g, b].allSatisfy { $0 >= -tolerance && $0 <= 1 + tolerance }
    }

    /// OKLCH → 線形 sRGB（gamut の判定に使う。ガンマは掛けない）。
    static func linearRGB(lightness: Double, chroma: Double, hue: Double) -> (Double, Double, Double) {
        let a = chroma * cos(hue * .pi / 180)
        let bb = chroma * sin(hue * .pi / 180)
        // OKLab → LMS'
        let l_ = lightness + 0.3963377774 * a + 0.2158037573 * bb
        let m_ = lightness - 0.1055613458 * a - 0.0638541728 * bb
        let s_ = lightness - 0.0894841775 * a - 1.2914855480 * bb
        let l = l_ * l_ * l_, m = m_ * m_ * m_, s = s_ * s_ * s_
        return (4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
                -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
                -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s)
    }

    /// OKLCH → sRGB（ガンマ適用済み、0...1）。
    static func srgb(lightness: Double, chroma: Double, hue: Double) -> (Double, Double, Double) {
        let (r, g, b) = linearRGB(lightness: lightness, chroma: chroma, hue: hue)
        func gamma(_ v: Double) -> Double {
            let c = min(max(v, 0), 1)
            return c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055
        }
        return (gamma(r), gamma(g), gamma(b))
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
