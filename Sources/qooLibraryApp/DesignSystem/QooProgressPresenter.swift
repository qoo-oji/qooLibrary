import SwiftUI

/// 進捗シート／ステータスバー表示。キャンセル可能 [UI-09][MX-06]。
/// `progress` が `nil` の場合は不定進捗（`ProgressView` の spinner 相当）。
public struct QooProgressPresenter: View {
    private let title: String
    private let progress: Double?
    private let detail: String?
    private let onCancel: (@MainActor @Sendable () -> Void)?

    public init(
        title: String,
        progress: Double? = nil,
        detail: String? = nil,
        onCancel: (@MainActor @Sendable () -> Void)? = nil
    ) {
        self.title = title
        self.progress = progress
        self.detail = detail
        self.onCancel = onCancel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Tokens.spacing.s) {
            Text(title)
                .font(.system(size: Tokens.fontSize.body))
            if let progress {
                ProgressView(value: progress)
            } else {
                ProgressView()
                    .controlSize(.small)
            }
            if let detail {
                Text(detail)
                    .font(.system(size: Tokens.fontSize.caption))
                    .foregroundStyle(.secondary)
            }
            if let onCancel {
                HStack {
                    Spacer()
                    Button("キャンセル", role: .cancel, action: onCancel)
                }
            }
        }
        .padding(Tokens.spacing.l)
        .frame(minWidth: 280)
    }
}
