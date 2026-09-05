import QooApplication
import QooKit
import SwiftUI

/// 環境設定「履歴」タブ [15.10 節][NT-07][HS-04]。
///
/// **通知履歴と操作履歴の保持をここへまとめてある**［ユーザー判断、2026-09］。
/// どちらも「履歴をいつまで・何件残すか」という同じ性質の設定で、タブを
/// 分けると探す場所が 2 つになる。タブ名を「通知」から「履歴」へ改めたのは
/// そのため——内部の識別子（`PreferencesCategory.notifications`）と型名は
/// 据え置きで、変えたのは表示名だけ。
///
/// 仕様書 §15.10 はこのタブに**システム通知の有効／無効 [ER-33]** も置くと
/// 定めているが、今回の範囲外［ユーザー判断、2026-08］。
/// `SystemNotificationGate`（ER-30〜34）は権限要求・アプリの活性状態の監視・
/// 30 秒以上の計測という別の関心事で、サンドボックス下の実機検証も別途要る。
///
/// **スライダーがあるタブには「既定に戻す」を必ず置く**［ユーザー指摘の
/// 一般原則: 既定値が分かりにくいため］。
struct NotificationPreferencesTab: View {
    @AppStorage(NotificationRouter.retentionDaysKey)
    private var retentionDays: Int = AppLimits.Notifications.defaultRetentionDays
    @AppStorage(NotificationRouter.maxCountKey)
    private var maxCount: Int = AppLimits.Notifications.defaultMaxCount
    @AppStorage(OperationLogRecorder.retentionDaysKey)
    private var opRetentionDays: Int = AppLimits.Operations.defaultRetentionDays
    @AppStorage(OperationLogRecorder.maxCountKey)
    private var opMaxCount: Int = AppLimits.Operations.defaultMaxCount

    @Environment(\.locale) private var locale
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Form {
            Section {
                Toggle("preferences.notifications.limitByAge", isOn: Binding(
                    get: { retentionDays > 0 },
                    set: { retentionDays = $0 ? AppLimits.Notifications.defaultRetentionDays : 0 }
                ))
                if retentionDays > 0 {
                    HStack {
                        Text("preferences.notifications.retention")
                        Slider(value: Binding(get: { Double(retentionDays) },
                                              set: { retentionDays = Int($0) }),
                               in: 1...365, step: 1)
                        Text(String(format: String(localized: "preferences.notifications.days",
                                                   locale: locale), retentionDays))
                            .monospacedDigit()
                            .frame(width: 64, alignment: .trailing)
                            .foregroundStyle(.secondary)
                    }
                }

                Toggle("preferences.notifications.limitByCount", isOn: Binding(
                    get: { maxCount > 0 },
                    set: { maxCount = $0 ? AppLimits.Notifications.defaultMaxCount : 0 }
                ))
                if maxCount > 0 {
                    HStack {
                        Text("preferences.notifications.maxCount")
                        Slider(value: Binding(get: { Double(maxCount) },
                                              set: { maxCount = Int($0) }),
                               in: 100...10_000, step: 100)
                        Text(String(format: String(localized: "preferences.notifications.items",
                                                   locale: locale), maxCount))
                            .monospacedDigit()
                            .frame(width: 84, alignment: .trailing)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("preferences.notifications.header")
            } footer: {
                // **いつ効くかを書く。** 掃除は起動時に 1 度だけ走る
                // ——追記のたびに走らせると、通知が大量に出た日にその回数だけ
                // 削除が走ることになる。設定を変えた瞬間に一覧が縮まないのは
                // 意図した挙動なので、黙っていると不具合に見える。
                Text("preferences.notifications.footer")
            }

            Section {
                LabeledContent("preferences.notifications.unread") {
                    Text(String(format: String(localized: "preferences.notifications.unreadCount",
                                               locale: locale),
                                NotificationRouter.shared.unreadCount))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Button("notifications.windowTitle") {
                    NotificationHistoryNavigation.open(openWindow: openWindow)
                }
            }

            Section {
                Toggle("preferences.operations.limitByAge", isOn: Binding(
                    get: { opRetentionDays > 0 },
                    set: { opRetentionDays = $0 ? AppLimits.Operations.defaultRetentionDays : 0 }
                ))
                if opRetentionDays > 0 {
                    HStack {
                        Text("preferences.operations.retention")
                        Slider(value: Binding(get: { Double(opRetentionDays) },
                                              set: { opRetentionDays = Int($0) }),
                               in: 1...365, step: 1)
                        Text(String(format: String(localized: "preferences.notifications.days",
                                                   locale: locale), opRetentionDays))
                            .monospacedDigit()
                            .frame(width: 64, alignment: .trailing)
                            .foregroundStyle(.secondary)
                    }
                }

                Toggle("preferences.operations.limitByCount", isOn: Binding(
                    get: { opMaxCount > 0 },
                    set: { opMaxCount = $0 ? AppLimits.Operations.defaultMaxCount : 0 }
                ))
                if opMaxCount > 0 {
                    HStack {
                        Text("preferences.operations.maxCount")
                        Slider(value: Binding(get: { Double(opMaxCount) },
                                              set: { opMaxCount = Int($0) }),
                               in: 100...10_000, step: 100)
                        Text(String(format: String(localized: "preferences.notifications.items",
                                                   locale: locale), opMaxCount))
                            .monospacedDigit()
                            .frame(width: 84, alignment: .trailing)
                            .foregroundStyle(.secondary)
                    }
                }
                Button("operations.windowTitle") {
                    OperationHistoryNavigation.open(openWindow: openWindow)
                }
            } header: {
                Text("preferences.operations.header")
            } footer: {
                // **消せないことをここで言う**——一覧に削除が無いのは意図で
                // あって手抜きではない（`OperationLogStore` の型コメント参照）。
                // 掃除が起動時に 1 度だけなのは通知履歴と同じ。
                Text("preferences.operations.footer")
            }

            Section {
                Button("preferences.resetToDefaults") {
                    retentionDays = AppLimits.Notifications.defaultRetentionDays
                    maxCount = AppLimits.Notifications.defaultMaxCount
                    opRetentionDays = AppLimits.Operations.defaultRetentionDays
                    opMaxCount = AppLimits.Operations.defaultMaxCount
                }
            }
        }
        .formStyle(.grouped)
        .padding(Tokens.spacing.m)
    }
}
