import Foundation
import Testing

@testable import QooApplication
@testable import QooKit

/// `UserDefaults(suiteName:)` は OS レベルのドメイン登録を伴うため、
/// 並列実行下では別テストの直後の内容を拾うことがある
/// （`UserDefaultsKeyBindingStoreTests` と同じ理由）。直列に固定する。
@Suite("初回セットアップの進行 [OB-01〜OB-03]", .serialized)
struct SetupWizardModelTests {

    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "qoo-setup-test-\(UUID().uuidString)")!
    }

    // MARK: 永続化 [OB-03][SW-05]

    @Test("記録が無ければ先頭から")
    func defaultsToFirstStep() {
        let d = makeDefaults()
        #expect(SetupWizardProgress.savedStep(d) == .welcome)
        #expect(!SetupWizardProgress.hasCompleted(d))
    }

    @Test("中断した位置を覚えて、次回そこから再開する [OB-03]")
    @MainActor
    func remembersStep() {
        let d = makeDefaults()
        SetupWizardProgress.saveStep(.appAssociations, d)
        #expect(SetupWizardProgress.savedStep(d) == .appAssociations)
        // 新しいモデルは記録された位置から始まる。
        #expect(SetupWizardModel(defaults: d).step == .appAssociations)
    }

    @Test("壊れた記録は先頭へ倒す")
    func recoversFromBadValue() {
        let d = makeDefaults()
        d.set(99, forKey: "qoo.setup.currentStep")
        #expect(SetupWizardProgress.savedStep(d) == .welcome)
    }

    @Test("完了すると印が立ち、途中のステップの記録は消える [SW-06]")
    func completionClearsStep() {
        let d = makeDefaults()
        SetupWizardProgress.saveStep(.accessGrant, d)
        SetupWizardProgress.markCompleted(d)
        #expect(SetupWizardProgress.hasCompleted(d))
        // 残しておくと、やり直したときに途中から始まってしまう。
        #expect(SetupWizardProgress.savedStep(d) == .welcome)
    }

    @Test("やり直しは完了印も落とす [OB-01]")
    func resetClearsBoth() {
        let d = makeDefaults()
        SetupWizardProgress.saveStep(.accessGrant, d)
        SetupWizardProgress.markCompleted(d)
        SetupWizardProgress.reset(d)
        #expect(!SetupWizardProgress.hasCompleted(d))
        #expect(SetupWizardProgress.savedStep(d) == .welcome)
    }

    // MARK: 進行

    @Test("進むと記録される——閉じても次回そこから [OB-03]")
    @MainActor
    func advanceRecordsProgress() {
        let d = makeDefaults()
        let model = SetupWizardModel(defaults: d)
        model.advance()
        #expect(model.step == .accessGrant)
        #expect(SetupWizardProgress.savedStep(d) == .accessGrant)
        #expect(!model.isFinished)
    }

    @Test("最後のステップで進むと完了する [SW-06]")
    @MainActor
    func advanceFromLastStepFinishes() {
        let d = makeDefaults()
        let model = SetupWizardModel(defaults: d, startingAt: .appAssociations)
        model.advance()
        #expect(model.isFinished)
        #expect(SetupWizardProgress.hasCompleted(d))
    }

    @Test("戻れる。戻った位置も記録する。先頭では何もしない")
    @MainActor
    func goBack() {
        let d = makeDefaults()
        // **記録を「進んだ状態」にしてから戻る。** `startingAt:` で始めると
        // 記録は初期値のままなので、「戻るときに記録しない」実装でも
        // `savedStep` が `.welcome` を返してしまい、この主張を検証できない
        // ［変異検証で空振りして判明］。
        SetupWizardProgress.saveStep(.accessGrant, d)
        let model = SetupWizardModel(defaults: d)
        #expect(model.step == .accessGrant)

        model.goBack()
        #expect(model.step == .welcome)
        #expect(SetupWizardProgress.savedStep(d) == .welcome)

        model.goBack()
        #expect(model.step == .welcome)
    }

    @Test("途中で閉じただけでは完了印を立てない [SW-06][OB-03]")
    @MainActor
    func closingWithoutFinishingKeepsProgress() {
        let d = makeDefaults()
        let model = SetupWizardModel(defaults: d)
        model.advance()          // アクセス権のステップまで進む
        // 「あとで」は `finish()` を呼ばずに窓を閉じるだけ。
        #expect(!SetupWizardProgress.hasCompleted(d))
        // 次の起動は続きから [OB-03]。
        #expect(SetupWizardModel(defaults: d).step == .accessGrant)
        #expect(model.step == .accessGrant)
    }

    @Test("完了した後は自動では出さない [SW-01]")
    @MainActor
    func doesNotPresentAfterCompletion() {
        let d = makeDefaults()
        let model = SetupWizardModel(defaults: d, startingAt: .appAssociations)
        model.finish()
        #expect(!SetupWizardGate.shouldPresent(
            hasCompleted: SetupWizardProgress.hasCompleted(d), libraryCount: 0))
    }
}
