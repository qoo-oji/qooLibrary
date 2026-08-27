import QooApplication
import QooKit
import SwiftUI

/// 環境設定「通知」タブ [15.10 節][NT-07]。
///
/// 仕様書 §15.10 はこのタブに 2 つを置くと定めている——**システム通知の
/// 有効／無効 [ER-33]** と**通知履歴の保持期間・上限 [NT-07]**。前者は
/// 今回の範囲外［ユーザー判断、2026-08］なので、後者だけを実装する。
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
                Button("preferences.resetToDefaults") {
                    retentionDays = AppLimits.Notifications.defaultRetentionDays
                    maxCount = AppLimits.Notifications.defaultMaxCount
                }
            }
        }
        .formStyle(.grouped)
        .padding(Tokens.spacing.m)
    }
}
