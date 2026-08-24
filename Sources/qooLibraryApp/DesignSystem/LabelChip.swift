//
//  ラベルチップ [UI-06][CO-02][CO-03][CO-05][CO-07]。
//
//  ラベルフィルタ・右ペイン・ラベルグループ編集ウインドウで共用する [13章 §13.3]。
//  **色は DB に入っている動的データ**なので、デザイントークン（`Tokens.Colors`）
//  とは別の経路で扱う——DT2-03「コード中に HEX を直書きしない」が禁じているのは
//  デザインの色をコードへ埋めることであって、利用者が付けた色を描くことではない。
//
import AppKit
import QooKit
import SwiftUI

extension Color {
    /// `#RRGGBB` を読む。読めない値は `nil`——**既定色へ黙って落とさない**。
    /// 落とすと「色が保存できていない」ことに気づけなくなる。
    init?(labelHex hex: String) {
        var text = Substring(hex)
        if text.hasPrefix("#") { text = text.dropFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        self.init(.sRGB,
                  red: Double((value >> 16) & 0xFF) / 255,
                  green: Double((value >> 8) & 0xFF) / 255,
                  blue: Double(value & 0xFF) / 255)
    }

    /// `#RRGGBB` へ書き出す [LE-10][CO-04][CO-06]。
    ///
    /// **sRGB へ変換してから読む。** `ColorPicker` は表示色空間（P3 など）の色を
    /// 返すことがあり、そのまま成分を取ると DB に入る値と画面の色がずれる。
    /// 変換できなければ `nil`——読めない値を書き込むより、保存しないほうがよい。
    var labelHexString: String? {
        guard let srgb = NSColor(self).usingColorSpace(.sRGB) else { return nil }
        let r = Int((srgb.redComponent * 255).rounded())
        let g = Int((srgb.greenComponent * 255).rounded())
        let b = Int((srgb.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}

/// ラベル 1 つの見た目。
///
/// ライトは淡い背景＋濃い文字、ダークは同じ色相のまま暗い背景＋明るい文字
/// [CO-02][CO-07]。**文字色は背景から計算する** [CO-03][CO-05]——色を利用者が
/// 選べる以上、固定の文字色ではいつか読めない組み合わせができる。
struct LabelChip: View {
    let name: String
    /// グループ色、またはラベル固有色 [CO-06]。
    let color: LabelColor
    /// 件数バッジ [LB-05]。`nil` なら出さない。
    var count: Int?
    /// 自動付与の印 [RL-06]。**押せない小さなインジケータ**——手動で付けた
    /// ものと見分けが付かないと、再スキャンで消えるかどうかが読めない。
    var isAutomatic: Bool = false
    /// ピンボタンを出すか [PN-04]。
    var showsPin: Bool = false
    var isPinned: Bool = false
    var onTogglePin: (() -> Void)?

    @Environment(\.colorScheme) private var colorScheme

    private var backgroundHex: String {
        colorScheme == .dark ? color.hexDark : color.hexLight
    }

    private var background: Color {
        Color(labelHex: backgroundHex) ?? Color.secondary.opacity(0.2)
    }

    private var foreground: Color {
        guard let hex = LabelColorPalette.readableForeground(on: backgroundHex),
              let color = Color(labelHex: hex) else { return .primary }
        return color
    }

    var body: some View {
        HStack(spacing: Tokens.spacing.xs) {
            chip
            if showsPin, let onTogglePin {
                // **ピンは行の右端に固定する** [実機検証で発見]。以前は
                // チップに `.overlay(alignment: .trailing) + .offset` で
                // 貼り付けていたため、**名前の長さでピンの位置が動いて
                // 狙いにくかった**（短いラベルだけ左にずれる）。`Spacer` で
                // 押し出せば、どの行でもピンが同じ x に並ぶ。
                Spacer(minLength: Tokens.spacing.xs)
                Button(action: onTogglePin) {
                    Image(systemName: isPinned ? "pin.fill" : "pin")
                        .font(.system(size: Tokens.fontSize.caption))
                }
                .buttonStyle(.plain)
                .foregroundStyle(isPinned ? Color.accentColor : Color.secondary)
                .help(isPinned
                      ? String(localized: "labelFilter.unpin")
                      : String(localized: "labelFilter.pin"))
            }
        }
    }

    private var chip: some View {
        HStack(spacing: Tokens.spacing.xs) {
            Text(name)
                .font(.system(size: Tokens.fontSize.caption))
                .lineLimit(1)
                .truncationMode(.middle)
            if let count {
                Text("\(count)")
                    .font(.system(size: Tokens.fontSize.caption))
                    .monospacedDigit()
                    .opacity(0.65)
            }
            if isAutomatic {                                        // [RL-06]
                Image(systemName: "sparkles")
                    .font(.system(size: Tokens.fontSize.caption))
                    .opacity(0.7)
                    .help(String(localized: "inspector.labels.automatic"))
            }
        }
        .foregroundStyle(foreground)
        .padding(.horizontal, Tokens.spacing.s)
        .padding(.vertical, 2)
        .background(background, in: RoundedRectangle(cornerRadius: Tokens.radius.s))
    }
}
