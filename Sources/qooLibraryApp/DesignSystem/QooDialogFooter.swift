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
public struct QooDialogFooter: View {
    private let confirm: DialogButton
    private let cancel: DialogButton?
    private let extra: [DialogButton]
    /// 入力が未確定の間は決定ボタンだけを無効化する（キャンセルは常に押せる）
    /// [`ArchivePasswordSheet` が最初の利用箇所]。
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
                Button(button.title, role: button.role, action: button.action)
            }
            Spacer()
            if let cancel {
                Button(cancel.title, role: cancel.role, action: cancel.action)
                    .keyboardShortcut(.cancelAction)
            }
            Button(confirm.title, role: confirm.role, action: confirm.action)
                .keyboardShortcut(.defaultAction)
                .disabled(confirmDisabled)
        }
        .padding(Tokens.spacing.m)
    }
}
