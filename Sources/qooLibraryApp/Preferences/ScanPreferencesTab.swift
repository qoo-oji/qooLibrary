import QooApplication
import QooKit
import SwiftUI

/// 環境設定「スキャン」タブ [15.10 節][SY-05][SY-06][VD-09]。
///
/// **取りこぼしへの備えを、利用者が調整できる場所。** 変更の検知（FSEvents）は
/// 完全ではない——他のマシンが加えた変更は届かないし、履歴を持たない
/// ボリューム（ネットワーク共有など、10章 §10.1.0 の実測）では非起動中の
/// 変更を再生できない。そこで定期的なフルスキャンを最終安全網に置く [SY-05]。
///
/// 大きな蔵書やネットワーク越しでは走査そのものが重いので、**間隔を延ばす／
/// 止める手段を用意する**のが SY-05 の趣旨（要件が「変更可能、無効化も可能」と
/// 明記している）。
struct ScanPreferencesTab: View {
    private static let defaultDays = AppLimits.Watch.defaultFullScanInterval / (24 * 60 * 60)

    /// 0 は「無効」。`LibraryServices.configuredFullScanInterval()` と鍵を共有する。
    @AppStorage(LibraryServices.fullScanIntervalDaysKey)
    private var fullScanIntervalDays: Double = defaultDays

    @State private var isRevalidating = false
    @Environment(\.locale) private var locale

    var body: some View {
        Form {
            Section {
                Toggle("preferences.scan.periodicFullScan", isOn: Binding(
                    get: { fullScanIntervalDays > 0 },
                    set: { fullScanIntervalDays = $0 ? Self.defaultDays : 0 }
                ))
                if fullScanIntervalDays > 0 {
                    HStack {
                        Text("preferences.scan.interval")
                        Slider(value: $fullScanIntervalDays, in: 1...90, step: 1)
                        Text(String(format: String(localized: "preferences.scan.intervalDays",
                                                   locale: locale),
                                    Int(fullScanIntervalDays)))
                            .monospacedDigit()
                            .frame(width: 64, alignment: .trailing)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("preferences.scan.header")
            } footer: {
                Text("preferences.scan.footer")
            }

            Section {
                Button("preferences.scan.revalidateVolumes") {
                    isRevalidating = true
                    Task {
                        // [VD-09] 着脱の検知に失敗しても人手で回復できるようにする。
                        await LibraryServices.shared.sync?.revalidateVolumes()
                        isRevalidating = false
                    }
                }
                .disabled(isRevalidating)
            } footer: {
                Text("preferences.scan.revalidateFooter")
            }

            // スライダーで既定値が分かりにくいため
            // [ユーザー指摘: 調整系の設定には必ず「既定に戻す」を付けること]。
            Section {
                Button("preferences.resetToDefaults") {
                    fullScanIntervalDays = Self.defaultDays
                }
            }
        }
        .formStyle(.grouped)
        .padding(Tokens.spacing.l)
    }
}
