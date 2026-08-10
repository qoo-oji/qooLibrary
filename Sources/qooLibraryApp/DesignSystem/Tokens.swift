import SwiftUI

/// デザイントークン。単一のソース（`Resources/DesignTokens.json`）から読み込む [UI-01]。
/// ウインドウごとにボタン配置や色が異なる状態を作らないため、全ウインドウが
/// この型だけを参照する [DT2-01]。
///
/// 色はここではなく Asset Catalog 経由（`Colors` を参照）。コード内に HEX を
/// 直書きしない [DT2-03]。
public enum Tokens {
    public static let spacing = load().spacing
    public static let radius = load().radius
    public static let fontSize = load().fontSize
    public static let iconSize = load().iconSize

    public struct Spacing: Decodable, Sendable {
        public let xs: CGFloat
        public let s: CGFloat
        public let m: CGFloat
        public let l: CGFloat
        public let xl: CGFloat
        public let xxl: CGFloat
    }

    public struct Radius: Decodable, Sendable {
        public let s: CGFloat
        public let m: CGFloat
        public let l: CGFloat
        public let pill: CGFloat
    }

    public struct FontSize: Decodable, Sendable {
        public let caption: CGFloat
        public let body: CGFloat
        public let title3: CGFloat
        public let title2: CGFloat
        public let title1: CGFloat
    }

    public struct IconSize: Decodable, Sendable {
        public let min: CGFloat
        public let max: CGFloat
        public let defaultValue: CGFloat
        public let step: CGFloat
    }

    private struct AllTokens: Decodable {
        let spacing: Spacing
        let radius: Radius
        let fontSize: FontSize
        let iconSize: IconSize
    }

    /// ライト/ダーク両対応。Asset Catalog の appearance で切り替える [UI-07][CO-07]。
    public enum Colors {
        public static let accent = Color("Accent")
        public static let paneBackground = Color("PaneBackground")
        public static let listAlternate = Color("ListAlternate")
        /// 0 件ラベル [LE-04]、衝突行 [CW-13] などに使う。
        public static let dangerText = Color("DangerText")
        public static let warningBadge = Color("WarningBadge")
        /// ロック中グレーアウト [LK-22]。
        public static let disabledOverlay = Color("DisabledOverlay")
    }

    private static func load() -> AllTokens {
        guard
            let url = Bundle.main.url(forResource: "DesignTokens", withExtension: "json"),
            let data = try? Data(contentsOf: url),
            let tokens = try? JSONDecoder().decode(AllTokens.self, from: data)
        else {
            preconditionFailure("Resources/DesignTokens.json is missing or malformed — this is a packaging bug, not a runtime condition to recover from.")
        }
        return tokens
    }
}
