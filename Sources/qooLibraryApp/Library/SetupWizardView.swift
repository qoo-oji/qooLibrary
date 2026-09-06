//
//  初回セットアップウィザード [OB-01〜OB-10、15章 §15.12]。
//
//  **自前で持つのは 3 ステップだけ** [SW-02]。要件が定める 7 ステップのうち
//  4 以降は、最後に**登録ウィザードを開いて引き渡す** [RG3-28]——同じ画面を
//  2 つ作らないため。対応表は 15章 §15.12。
//
import AppKit
import QooApplication
import QooInfrastructure
import QooKit
import SwiftUI

struct SetupWizardView: View {

    @Environment(\.locale) private var locale
    @Environment(\.dialogDismiss) private var dismiss

    @State private var model: SetupWizardModel
    /// ステップ 2 の現状 [SW-03]。「設定済み」と見せるために読む。
    @State private var grants: [GrantedVolumeAccess] = []
    /// ステップ 3 の候補と選択。
    @State private var viewerCandidates: [AppCandidate] = []
    /// **3 値で持つ** [code-review の指摘]。`String?` だと「まだ読み込んで
    /// いない」と「システムの既定を選んだ」が同じ `nil` になり、既存の
    /// 関連付けを黙って消す経路ができる（`SetupViewerChoice.shouldApply`）。
    @State private var viewerSelection: ViewerSelection = .notLoaded
    /// 読み込んだ時点の選択。**変わっていなければ何も書かない**ための控え。
    @State private var initialViewerSelection: ViewerSelection = .notLoaded

    /// 最後まで進んだら呼ぶ。登録ウィザードへ引き渡す [SW-02]。
    private let onFinished: @MainActor () -> Void

    init(model: SetupWizardModel, onFinished: @escaping @MainActor () -> Void) {
        _model = State(initialValue: model)
        self.onFinished = onFinished
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.spacing.m) {
            header
            Divider()
            stepBody
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
            footer
        }
        .padding(Tokens.spacing.l)
        .frame(width: 560, height: 420)
        .task { await reload() }
        .onChange(of: model.step) { _, _ in Task { await reload() } }
    }

    // MARK: ヘッダ

    private var header: some View {
        VStack(alignment: .leading, spacing: Tokens.spacing.xs) {
            Text(String(format: AppStrings.text("setupWizard.stepIndicator", locale: locale),
                        model.step.position, SetupStep.count))
                .font(.system(size: Tokens.fontSize.caption))
                .foregroundStyle(.secondary)
            Text(stepTitle)
                .font(.system(size: Tokens.fontSize.title2, weight: .semibold))
        }
    }

    private var stepTitle: String {
        switch model.step {
        case .welcome:         AppStrings.text("setupWizard.step.welcome", locale: locale)
        case .accessGrant:     AppStrings.text("setupWizard.step.accessGrant", locale: locale)
        case .appAssociations: AppStrings.text("setupWizard.step.appAssociations", locale: locale)
        }
    }

    // MARK: 各ステップ

    @ViewBuilder
    private var stepBody: some View {
        switch model.step {
        case .welcome:         welcomeStep
        case .accessGrant:     accessStep
        case .appAssociations: viewerStep
        }
    }

    /// ステップ 1: アプリ全体の役割を 1 画面で [15.12 表]。
    private var welcomeStep: some View {
        VStack(alignment: .leading, spacing: Tokens.spacing.m) {
            Text("setupWizard.welcome.heading")
                .font(.system(size: Tokens.fontSize.body))
            roleRow(icon: "folder", title: "setupWizard.welcome.fileManager.title",
                    detail: "setupWizard.welcome.fileManager.detail")
            roleRow(icon: "books.vertical", title: "setupWizard.welcome.library.title",
                    detail: "setupWizard.welcome.library.detail")
            roleRow(icon: "tray", title: "setupWizard.welcome.temporary.title",
                    detail: "setupWizard.welcome.temporary.detail")
        }
    }

    private func roleRow(icon: String, title: LocalizedStringKey,
                         detail: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: Tokens.spacing.m) {
            Image(systemName: icon)
                .font(.system(size: Tokens.fontSize.title1))
                .foregroundStyle(.tint)
                .frame(width: Tokens.spacing.xxl, alignment: .center)
            VStack(alignment: .leading, spacing: Tokens.spacing.xs) {
                Text(title).font(.system(size: Tokens.fontSize.body, weight: .medium))
                Text(detail)
                    .font(.system(size: Tokens.fontSize.caption))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// ステップ 2: アクセス権 [SB-03][SB-04][SW-08]。
    private var accessStep: some View {
        VStack(alignment: .leading, spacing: Tokens.spacing.m) {
            Text("setupWizard.access.detail")
                .font(.system(size: Tokens.fontSize.body))
                .fixedSize(horizontal: false, vertical: true)
            // **設定済みなら、そう見せる** [SW-03]。飛ばさないのは、やり直し
            // [OB-01] のときに「なぜ飛んだのか」が読めなくなるため。
            if grants.isEmpty {
                Label("setupWizard.access.none", systemImage: "exclamationmark.circle")
                    .font(.system(size: Tokens.fontSize.caption))
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: Tokens.spacing.xs) {
                    Label("setupWizard.access.granted", systemImage: "checkmark.circle.fill")
                        .font(.system(size: Tokens.fontSize.caption))
                        .foregroundStyle(.green)
                    ForEach(grants) { grant in
                        Text(grant.displayName)
                            .font(.system(size: Tokens.fontSize.caption))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Button("setupWizard.access.grantButton") {
                Task {
                    await VolumeAccessAction.requestGrant(locale: locale)
                    await reload()
                }
            }
            Text("setupWizard.access.hint")
                .font(.system(size: Tokens.fontSize.caption))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// ステップ 3: コミック形式を開くアプリ [AS-03][AS-05]。
    ///
    /// **8 拡張子を個別に選ばせない。** ここで決めたいのは「コミックを何で
    /// 開くか」であって拡張子ごとの使い分けではない——細かい調整は環境設定
    /// 「ビューア」タブが持つ。
    private var viewerStep: some View {
        VStack(alignment: .leading, spacing: Tokens.spacing.m) {
            Text("setupWizard.viewer.detail")
                .font(.system(size: Tokens.fontSize.body))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Tokens.spacing.m) {
                Text("setupWizard.viewer.picker")
                    .font(.system(size: Tokens.fontSize.body))
                // タグは bundle ID。空文字が「システムの既定」[AS2-01]。
                FixedWidthPopUp<String>(
                    items: [.init(title: AppStrings.text("setupWizard.viewer.systemDefault",
                                                locale: locale),
                                  tag: "")]
                        + viewerCandidates.map { .init(title: $0.name, tag: $0.bundleID) },
                    selection: Binding(
                        get: { viewerSelection.bundleID ?? "" },
                        set: { viewerSelection = $0.isEmpty ? .systemDefault : .app($0) }))
                    .frame(width: 240)
            }
            Text("setupWizard.viewer.hint")
                .font(.system(size: Tokens.fontSize.caption))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: フッター

    private var footer: some View {
        QooDialogFooter(
            confirm: DialogButton(
                title: model.step.isLast
                    ? AppStrings.text("setupWizard.done", locale: locale)
                    : AppStrings.text("setupWizard.next", locale: locale)
            ) {
                // **「続ける」は常に押せる** [OB-02]。何も設定せずに次へ進めば
                // それがスキップで、後からの案内は既存の導線が現在の状態を
                // 見て行う [SW-04]——専用の「スキップ」ボタンは作らない。
                if model.step == .appAssociations { applyViewerSelection() }
                if model.step.isLast {
                    model.finish()
                    dismiss()
                    onFinished()
                } else {
                    model.advance()
                }
            },
            cancel: DialogButton(title: AppStrings.text("setupWizard.later", locale: locale),
                                 role: .cancel) {
                // **完了印は立てない** [SW-06]。次回の起動で続きから出る
                // [OB-03]。登録が 1 件でもあれば出なくなる [SW-01] ので、
                // 永久に出続けることにはならない。
                dismiss()
            },
            extra: model.step.isFirst ? [] : [
                DialogButton(title: AppStrings.text("setupWizard.back", locale: locale)) {
                    model.goBack()
                }
            ])
    }

    // MARK: 読み込みと反映

    private func reload() async {
        switch model.step {
        case .welcome:
            break
        case .accessGrant:
            grants = await VolumeAccessStore.shared.grantedAccess()
        case .appAssociations:
            // 代表として `cbz` の候補を採る——コミック形式はどれも同種の
            // アプリが開くので、8 つ分を合成して重複を除く必要が無い。
            var list = AppAssociationStore.shared.candidates(for: "cbz")
            let current = await AppAssociationStore.shared.primary(for: "cbz")
            // **候補一覧に現れない既定アプリを補う** [code-review の指摘]。
            // 「その他…」で選んだアプリが `public.cbz-archive` を宣言して
            // いないと候補に出ず、足さないと選択肢から消えて「完了」で黙って
            // 上書きされる（`AssociationPreferencesTab.options(for:)` と
            // 同じ手当て）。
            if let current, !list.contains(where: { $0.bundleID == current.bundleID }) {
                list.append(current)
            }
            viewerCandidates = list
            // **一度読み込んだら解決し直さない** [code-review の指摘]。
            // 戻って進むたびに解決すると、明示的に選んだ「システムの既定」が
            // qooViewer へ戻る。
            if viewerSelection == .notLoaded {
                let resolved = SetupViewerChoice.resolve(candidates: list,
                                                         current: current?.bundleID)
                viewerSelection = resolved
                initialViewerSelection = resolved
            }
        }
    }

    /// 選んだアプリを 8 拡張子すべてへ割り当てる [AS-03]。
    ///
    /// **変わっていなければ 1 バイトも書かない** [code-review の指摘]。
    /// `setPrimary(nil, for:)` は既存の関連付けを**消す**書き込みなので、
    /// 読み込み前や利用者が触っていない状態で走らせると、環境設定で設定した
    /// pdf/epub の関連付けが黙って消える。
    private func applyViewerSelection() {
        guard SetupViewerChoice.shouldApply(viewerSelection,
                                            initial: initialViewerSelection) else { return }
        let bundleID = viewerSelection.bundleID
        Task {
            for ext in ComicFormats.extensions {
                do {
                    try await AppAssociationStore.shared.setPrimary(bundleID, for: ext)
                } catch {
                    await NotificationRouter.shared.presentError(
                        error,
                        whatHappened: AppStrings.text("error.operationFailed", locale: locale))
                    return
                }
            }
        }
    }
}
