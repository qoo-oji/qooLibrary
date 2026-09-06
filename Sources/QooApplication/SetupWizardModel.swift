//
//  初回セットアップウィザードの進行と、その永続化 [OB-01〜OB-03、15章 §15.12]。
//
//  **中身（アクセス権の付与・関連付けの割り当て）はここでは扱わない。**
//  それぞれ `VolumeAccessStore` / `AppAssociationStore` が持っており、View が
//  直接触る——ここが横取りすると、環境設定タブと 2 通りの経路ができて片方
//  だけが直される [SW-04 の「既存の導線が担う」と同じ理由]。このモデルが
//  受け持つのは「いま何ステップ目か」と「完了したか」だけ。
//
import Foundation
import QooKit

/// 進行の永続化 [OB-03][SW-05]。
///
/// **持つのは「完了したか」と「現在のステップ」の 2 つだけ。** ステップ 1〜3 は
/// 読むか 1 回選ぶかで、入力途中という状態が存在しない（ステップ 4 以降は
/// 登録ウィザードの担当で、あちらは元から再開を持たない）。
public enum SetupWizardProgress {

    enum PreferenceKeys {
        static let hasCompleted = "qoo.setup.hasCompleted"
        static let currentStep = "qoo.setup.currentStep"
    }

    public static func hasCompleted(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: PreferenceKeys.hasCompleted)
    }

    /// 中断した位置 [OB-03]。記録が無ければ先頭から。
    public static func savedStep(_ defaults: UserDefaults = .standard) -> SetupStep {
        guard let raw = defaults.object(forKey: PreferenceKeys.currentStep) as? Int,
              let step = SetupStep(rawValue: raw) else { return .welcome }
        return step
    }

    public static func saveStep(_ step: SetupStep, _ defaults: UserDefaults = .standard) {
        defaults.set(step.rawValue, forKey: PreferenceKeys.currentStep)
    }

    /// 完了として記録する [SW-06]。**最後まで進んで「完了」を押したときと、
    /// 明示的に「あとで」を選んだときにだけ呼ぶ**——途中で窓を閉じただけの
    /// 状態を「完了」と記録すると、再開できるはずの利用者が二度と案内を
    /// 受けられなくなる（「再開可能な状態を失敗として記録する」既知の型）。
    public static func markCompleted(_ defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: PreferenceKeys.hasCompleted)
        defaults.removeObject(forKey: PreferenceKeys.currentStep)
    }

    /// メニューからのやり直し [OB-01] で先頭へ戻す。
    /// **完了印も落とす**——やり直したまま途中で閉じたら、次の起動でも
    /// 続きから出るのが「やり直し」の意味に合う。
    public static func reset(_ defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: PreferenceKeys.hasCompleted)
        defaults.removeObject(forKey: PreferenceKeys.currentStep)
    }
}

@MainActor
@Observable
public final class SetupWizardModel {

    public private(set) var step: SetupStep
    /// 完了した（窓を閉じてよい）。View が監視する。
    public private(set) var isFinished = false

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard, startingAt: SetupStep? = nil) {
        self.defaults = defaults
        self.step = startingAt ?? SetupWizardProgress.savedStep(defaults)
    }

    /// 次のステップへ。最後なら完了する。
    ///
    /// **「続ける」と「スキップ」で実装を分けない** [SW-04]——スキップした
    /// 項目を覚える必要が無い（後からの案内は既存の導線が現在の状態を見て
    /// 行う）ので、結果は同じになる。ボタンの文言だけが違う。
    public func advance() {
        guard let next = step.next else { finish(); return }
        step = next
        SetupWizardProgress.saveStep(next, defaults)
    }

    public func goBack() {
        guard let previous = step.previous else { return }
        step = previous
        SetupWizardProgress.saveStep(previous, defaults)
    }

    /// 完了として記録して閉じる [SW-06]。
    public func finish() {
        SetupWizardProgress.markCompleted(defaults)
        isFinished = true
    }
}
