//
//  ラベルグループ色・ラベル固有色の編集 [LE-10][CO-04][CO-05][CO-06][CO-07]。
//
//  **1 つの部品で両方を扱う。** グループはライト／ダークで別の色を持ち [CO-07]、
//  ラベル固有色は 1 色を両方で使う——形は違うが「色を選び、読めるかを確かめ、
//  既定へ戻せる」という中身は同じなので、独立した実装を 2 つ作らない [CP-02]。
//
//  **コントラストは選んだその場で出す** [CO-05]。保存してから「読めない」と
//  気づく形にすると、直すために画面を往復することになる。
//
import QooKit
import SwiftUI

/// 色の持ち方。グループは 2 色、ラベルは 1 色。
enum LabelColorShape: Equatable {
    /// ライトとダークで別の色 [CO-07]。ラベルグループ。
    case lightAndDark
    /// 1 色を両方の外観で使う。ラベル固有色 [CO-06]。
    case single
}

/// 色を出すボタン。押すとポップオーバーで編集する。
struct LabelColorWell: View {
    @Binding var color: LabelColor
    var shape: LabelColorShape = .lightAndDark
    /// 「既定に戻す」で戻す先。`nil` ならボタンを出さない。
    var defaultColor: LabelColor?
    /// プレビューに出す文字。
    var previewName: String

    @State private var isEditing = false
    @Environment(\.colorScheme) private var colorScheme

    private var currentHex: String {
        colorScheme == .dark ? color.hexDark : color.hexLight
    }

    var body: some View {
        Button { isEditing = true } label: {
            RoundedRectangle(cornerRadius: Tokens.radius.s)
                .fill(Color(labelHex: currentHex) ?? .secondary)
                .overlay(
                    RoundedRectangle(cornerRadius: Tokens.radius.s)
                        .strokeBorder(Color.secondary.opacity(0.4), lineWidth: 1))
                .frame(width: 24, height: 16)
                .overlay(alignment: .topTrailing) {
                    // 読めない組み合わせは、開かなくても分かるようにする [CO-05]
                    if !isReadable {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(Color("WarningBadge"))
                            .offset(x: 3, y: -3)
                    }
                }
        }
        .buttonStyle(.borderless)
        .help("labelColor.edit")
        .popover(isPresented: $isEditing, arrowEdge: .bottom) { editor }
    }

    /// ライト・ダークのどちらも 4.5:1 を満たすか [CO-03][CO-05][CO-07]。
    ///
    /// **有効な色ではこれが偽になることは無い**［実測。全 sRGB 色を走査した
    /// 最悪値は 4.583:1（`#5D60FF`）］——黒と白の良いほうを選ぶ限り、
    /// どんな色でも 4.5:1 を上回る。`CO-05` が求める「いずれも 4.5:1 未満なら
    /// 警告」は、数学的にほぼ到達しない条件である。
    ///
    /// それでも警告を残すのは、**読めない hex が入っていたら知らせる**ため
    /// ——`contrast(of:)` は解釈できない値に 0 を返すので、DB に壊れた色が
    /// 入った場合だけこの印が出る。「色が保存できていない」ことに気づける。
    private var isReadable: Bool {
        Self.contrast(of: color.hexLight) >= 4.5 && Self.contrast(of: color.hexDark) >= 4.5
    }

    /// 背景に対して、黒／白のうちコントラストが高いほうの比 [CO-05]。
    static func contrast(of hex: String) -> Double {
        guard let foreground = LabelColorPalette.readableForeground(on: hex),
              let ratio = LabelColorPalette.contrastRatio(hex, foreground) else { return 0 }
        return ratio
    }

    // MARK: - ポップオーバー

    private var editor: some View {
        VStack(alignment: .leading, spacing: Tokens.spacing.m) {
            switch shape {
            case .lightAndDark:
                row("labelColor.light", hex: bindingForLight)
                row("labelColor.dark", hex: bindingForDark)
            case .single:
                row("labelColor.color", hex: bindingForSingle)
            }

            Divider()
            preview

            if let defaultColor {
                Divider()
                Button("labelColor.resetToDefault") { color = defaultColor }
                    .disabled(color == defaultColor)
            }
        }
        .padding(Tokens.spacing.l)
        .frame(width: 260)
    }

    private func row(_ titleKey: LocalizedStringKey, hex: Binding<String>) -> some View {
        HStack(spacing: Tokens.spacing.m) {
            Text(titleKey).frame(width: 64, alignment: .leading)
            ColorPicker("", selection: Binding(
                get: { Color(labelHex: hex.wrappedValue) ?? .gray },
                // **読めない値は書かない**——変換に失敗したら現状のままにする。
                set: { if let text = $0.labelHexString { hex.wrappedValue = text } }),
                supportsOpacity: false)
                .labelsHidden()
            Text(hex.wrappedValue)
                .font(.system(size: Tokens.fontSize.caption, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }

    /// 選んだ色で実際にどう見えるか。**両方の外観を並べる** [CO-07]
    /// ——片方しか見せないと、もう片方が読めなくなっていることに気づけない。
    private var preview: some View {
        VStack(alignment: .leading, spacing: Tokens.spacing.s) {
            previewRow("labelColor.light", hex: color.hexLight, scheme: .light)
            previewRow("labelColor.dark", hex: color.hexDark, scheme: .dark)
        }
    }

    private func previewRow(_ titleKey: LocalizedStringKey, hex: String,
                            scheme: ColorScheme) -> some View {
        HStack(spacing: Tokens.spacing.m) {
            Text(titleKey)
                .font(.system(size: Tokens.fontSize.caption))
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .leading)
            LabelChip(name: previewName, color: LabelColor(hexLight: hex, hexDark: hex))
                .environment(\.colorScheme, scheme)
            Spacer(minLength: 0)
            if Self.contrast(of: hex) < 4.5 {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color("WarningBadge"))
                    .help("labelColor.lowContrast")
            }
        }
    }

    private var bindingForLight: Binding<String> {
        Binding(get: { color.hexLight },
                set: { color = LabelColor(hexLight: $0, hexDark: color.hexDark) })
    }

    private var bindingForDark: Binding<String> {
        Binding(get: { color.hexDark },
                set: { color = LabelColor(hexLight: color.hexLight, hexDark: $0) })
    }

    /// 1 色のとき（ラベル固有色）は両方に同じ値を書く——`labelColor(_:in:)` が
    /// `LabelColor(hexLight: hex, hexDark: hex)` として読むのに合わせる。
    private var bindingForSingle: Binding<String> {
        Binding(get: { color.hexLight },
                set: { color = LabelColor(hexLight: $0, hexDark: $0) })
    }
}
