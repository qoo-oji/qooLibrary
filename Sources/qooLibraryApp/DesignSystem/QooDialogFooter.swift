import AppKit
import SwiftUI

/// ダイアログの決定ボタン 1 個分の記述。
public struct DialogButton: Identifiable, Sendable {
    public let id = UUID()
    public let title: String
    public let role: ButtonRole?
    public let action: @MainActor @Sendable () -> Void

    public init(title: String, role: ButtonRole? = nil, action: @escaping @MainActor @Sendable () -> Void) {
        self.title = title
        self.role = role
        self.action = action
    }
}

/// 決定・キャンセルの配置を macOS HIG に統一する [UI-04]。
/// 機能ごとに独自のボタン配置を作らない。
///
/// **余白は自分では持たない。** 外周の余白は包む側（`DialogScaffold`・各シート）の
/// `.padding` が一元的に担う。以前はここにも `.padding(m)` があり、全使用箇所で
/// 外周と二重になって「ボタンの下だけ広い」「ボタンの右端が入力欄の右端と
/// 揃わない」見た目を作っていた［ユーザー指摘で発覚］。
public struct QooDialogFooter: View {
    private let confirm: DialogButton
    private let cancel: DialogButton?
    private let extra: [DialogButton]
    /// 入力が未確定の間は決定ボタンだけを無効化する（キャンセルは常に押せる）。
    /// **Return による確定にも効く** — `DialogScaffold` がここと同じ値を見て
    /// `.onSubmit` を止める。
    private let confirmDisabled: Bool

    public init(confirm: DialogButton, cancel: DialogButton?, extra: [DialogButton] = [], confirmDisabled: Bool = false) {
        self.confirm = confirm
        self.cancel = cancel
        self.extra = extra
        self.confirmDisabled = confirmDisabled
    }

    public var body: some View {
        HStack(spacing: Tokens.spacing.s) {
            ForEach(extra) { button in
                footerButton(button)
            }
            Spacer()
            if let cancel {
                footerButton(cancel)
            }
            footerButton(confirm)
                .keyboardShortcut(.defaultAction)
                .disabled(confirmDisabled)
        }
    }

    /// フッター内の全ボタンを同幅にするための、ラベル幅の下限［ユーザー要望:
    /// ボタンの幅が違うと違和感がある。最も広いもの——多くは「キャンセル」——に
    /// 合わせる。左端の `extra`（衝突シートの「スキップ」等）も揃える対象］。
    /// 固定値ではなく全ラベルの実測幅の max を使う — どれが広いかはロケールで
    /// 変わる（ja: キャンセル＞移動、en: Cancel＞Go）ため。ボタンが 1 つだけ
    /// なら揃える相手がいないので制約しない。
    private var footerLabelWidth: CGFloat? {
        var titles = extra.map(\.title)
        if let cancel { titles.append(cancel.title) }
        titles.append(confirm.title)
        guard titles.count > 1 else { return nil }
        return DialogButtonMetrics.maxLabelWidth(titles)
    }

    @ViewBuilder
    private func footerButton(_ button: DialogButton) -> some View {
        // **幅はラベル側で確保する。** `Button` の外に `.frame` を付けても枠が
        // 広がるだけでボタンの見た目（カプセル）は元の大きさのまま
        // （`OperationProgressWindowContent` で実測済みの罠）。
        let base = Button(role: button.role) { button.action() } label: {
            Text(button.title).frame(minWidth: footerLabelWidth)
        }
        // Esc は「キャンセルの意味を持つボタン」（`role == .cancel`）にだけ
        // 結び付ける。衝突ダイアログの「両方とも残す」のように、キャンセル位置に
        // あってもキャンセルではないボタンへ Esc を割り当てると、「Esc ＝ 何も
        // しない」という共通の意味が壊れる（衝突シートの Esc はシートを閉じる
        // → スキップ扱い、という既存の経路のまま）。
        if button.role == .cancel {
            base.keyboardShortcut(.cancelAction)
        } else {
            base
        }
    }
}

/// ボタンラベルの表示幅の実測。隣接ボタンの同幅化に使う
/// （`QooDialogFooter`・進捗ウインドウで共有）。
enum DialogButtonMetrics {
    static func maxLabelWidth(
        _ titles: [String],
        controlSize: NSControl.ControlSize = .regular
    ) -> CGFloat {
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize(for: controlSize))
        return titles
            .map { ceil(($0 as NSString).size(withAttributes: [.font: font]).width) }
            .max() ?? 0
    }
}
