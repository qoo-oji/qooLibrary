//
//  右ペインの評価 [RA-01〜RA-08]。
//
//  判定は `RatingEditorModel`（`QooApplication`）が持つ。この View は描くだけ
//  ——`LabelFilterPane` と同じ分け方で、そうしないと RA-02（同じ星で解除）や
//  RA-07（シリーズ名が無ければ無効）を自動テストで固定できない。
//
import QooApplication
import QooKit
import SwiftUI

struct InspectorRatingSection: View {
    let model: RatingEditorModel

    @Environment(\.locale) private var locale

    var body: some View {
        switch model.state {
        case .notApplicable:
            // ライブラリ経由で開いていない。**枠ごと出さない** [LF-01 と同じ判断]。
            EmptyView()
        case .loading:
            section { ProgressView().controlSize(.small) }
        case .notInLibrary:
            section {
                // **無効の星だけを出す**。黙って枠ごと消すと「星を付けられない」
                // のか「壊れている」のか区別が付かない［ユーザー判断］が、
                // 理由の文は置かない［ユーザー指摘、2026-09-02］。
                RatingStars(filled: 0, tint: .secondary, isEnabled: false) { _ in }
            }
        case .failed(let reason):
            section {
                RatingStars(filled: 0, tint: .secondary, isEnabled: false) { _ in }
                Text(reason)
                    .font(.system(size: Tokens.fontSize.caption))
                    .foregroundStyle(Tokens.Colors.dangerText)
                    .lineLimit(3)
            }
        case .ready(let subject):
            section {
                RatingStars(filled: subject.stars) { star in
                    Task { await setStars(star) }
                }
                seriesRow(subject)
            }
        }
    }

    // MARK: - 部品

    /// **見出しは置かない**［ユーザー指摘、2026-09-02］——星が並んでいれば
    /// 評価だと分かる。区切りは `Divider` だけで足りる。
    @ViewBuilder
    private func section(@ViewBuilder _ content: () -> some View) -> some View {
        Divider()
        VStack(alignment: .leading, spacing: Tokens.spacing.xs) {
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .font(.system(size: Tokens.fontSize.caption))
    }

    /// 「このシリーズ全巻に適用」[RA-04][RA-05][RA-07]。
    ///
    /// **件数はボタンの文言に出す**［設計判断］。RA-05 が求めているのは
    /// 「対象件数を実行前に表示する」ことで、確認ダイアログとは書いていない。
    /// ⌘Z で戻せる操作に毎回ダイアログを挟むと、本当に見てほしい 1 枚まで
    /// 読み飛ばされるようになる（走査結果の提示で同じ判断をしている）。
    ///
    /// **効果があるときだけ出す**（`canApplyToSeries`）［実機検証で発見］。
    /// 未評価のまま「全巻の評価を解除」を常駐させると、何もしていない状態の
    /// 一番目立つ位置に、押すと他の巻の星が消える導線が座ることになる。
    @ViewBuilder
    private func seriesRow(_ subject: RatingEditorModel.Subject) -> some View {
        if subject.canApplyToSeries, let count = subject.seriesCount {
            Button {
                Task { await applyToSeries() }
            } label: {
                Text(String(format: String(localized: subject.stars == 0
                                           ? "inspector.rating.clearSeries"
                                           : "inspector.rating.applySeries", locale: locale),
                            "\(count)"))
                    .font(.system(size: Tokens.fontSize.caption))
            }
            .buttonStyle(.link)
        }
        // [RA-07] シリーズ名が無いときは**何も出さない**［ユーザー指摘、
        // 2026-09-02］——星の下に「シリーズ名がありません」と書くと、
        // 評価とシリーズ名に何の関係があるのか読み取れない。
    }

    // MARK: - 操作

    private func setStars(_ star: Int) async {
        do {
            try await model.setStars(tapped: star)
        } catch {
            await NotificationRouter.shared.presentError(
                error, whatHappened: String(localized: "error.setRatingFailed", locale: locale))
        }
    }

    private func applyToSeries() async {
        do {
            try await model.applyToSeries()
        } catch {
            await NotificationRouter.shared.presentError(
                error, whatHappened: String(localized: "error.setRatingFailed", locale: locale))
        }
    }
}
