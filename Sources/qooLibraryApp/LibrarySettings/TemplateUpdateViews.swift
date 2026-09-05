//
//  プリセット改訂の差分ビュー [LT-13〜LT-16]。
//
//  ## 全適用ボタンを設けない [LT-14]
//  要件が名指しで禁じている。既定の選択は項目ごとに決まっていて、
//  **ローカル編集を上書きするものだけ外れている** [LT-15]——全部外すと
//  「全部押す」作業を強い、全部入れると上書きが既定になる。
//
//  ## 1 件も選ばずに確定できる [LT-16]
//  見送る手段が無いと、適用したくない改訂の通知が永久に消えない。
//  そのときボタンの文言は「変更せずに確認済みにする」に変わる——
//  「適用」のまま押させると、何が起きたのか読み取れない。
//
import QooApplication
import QooKit
import SwiftUI

// MARK: - 設定ウインドウの案内カード [LT-13]

/// 改訂があるときだけ出す。**無いときは何も描かない**——常設して
/// 「更新はありません」と言うと、見るべきものが無い画面に行が増えるだけ。
struct TemplateUpdateCard: View {
    let pending: TemplateUpdateModel.Pending?
    let onReview: () -> Void

    var body: some View {
        if let pending {
            HStack(spacing: Tokens.spacing.m) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: Tokens.spacing.xs) {
                    Text(String(format: String(localized: "librarySettings.templateUpdate.available"),
                                pending.presetName))
                    Text("librarySettings.templateUpdate.hint")
                        .font(.system(size: Tokens.fontSize.caption))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("librarySettings.templateUpdate.review", action: onReview)
            }
            .padding(Tokens.spacing.m)
            .background(RoundedRectangle(cornerRadius: Tokens.radius.m)
                .fill(Color(nsColor: .controlBackgroundColor)))
        }
    }
}

// MARK: - 差分ビュー [LT-13][LT-14][LT-15]

struct TemplateUpdateDialog: View {
    @Environment(\.locale) private var locale
    @Environment(\.dialogDismiss) private var dismiss

    let pending: TemplateUpdateModel.Pending
    /// **差分は呼び出し側が読み込んで固定して渡す。** ダイアログを開いている
    /// 間に設定が変わると、利用者が見て選んだ集合と適用先がずれる
    /// （巻数の確認ダイアログと同じ判断）。
    @Bindable var model: TemplateUpdateModel
    let onApply: () -> Void

    var body: some View {
        DialogScaffold(
            width: 640,
            confirm: DialogButton(title: confirmTitle) {
                onApply()
                dismiss()
            },
            cancel: DialogButton(title: String(localized: "common.cancel", locale: locale),
                                 role: .cancel) { dismiss() }
        ) {
            VStack(alignment: .leading, spacing: Tokens.spacing.m) {
                Text(String(format: String(localized: "librarySettings.templateUpdate.summary",
                                           locale: locale),
                            pending.presetName, pending.fromVersion, pending.toVersion))
                    .fixedSize(horizontal: false, vertical: true)

                if let diff = model.diff, !diff.isEmpty {
                    list(diff)
                    if model.overwritesLocalEdits {
                        Label("librarySettings.templateUpdate.overwriteWarning",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: Tokens.fontSize.caption))
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    // **改訂はあるが、このライブラリに効く違いが無い場合。**
                    // 版だけが上がった（説明文の修正など）ときに起きる。
                    Text("librarySettings.templateUpdate.noEffectiveChange")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var confirmTitle: String {
        model.selectedCount == 0
            ? String(localized: "librarySettings.templateUpdate.acknowledge", locale: locale)
            : String(format: String(localized: "librarySettings.templateUpdate.apply",
                                    locale: locale), model.selectedCount)
    }

    @ViewBuilder
    private func list(_ diff: TemplateDiff) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(diff.items) { item in
                    row(item)
                    Divider()
                }
            }
        }
        // 件数にあわせて縮める。上限は残す——何十件もあるときに
        // ダイアログが画面を埋めないため（巻数の確認と同じ扱い）。
        .frame(height: min(CGFloat(diff.items.count) * 46 + 10, 300))
        .background(RoundedRectangle(cornerRadius: Tokens.radius.s)
            .fill(Color(nsColor: .textBackgroundColor)))
    }

    private func row(_ item: TemplateDiff.Item) -> some View {
        HStack(alignment: .top, spacing: Tokens.spacing.s) {
            Toggle("", isOn: Binding(
                get: { item.isSelected },
                set: { model.setSelected(item.id, $0) }))
                .labelsHidden()
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Tokens.spacing.xs) {
                    Text(categoryTitle(item))
                        .font(.system(size: Tokens.fontSize.caption))
                        .foregroundStyle(.secondary)
                    if item.isLocallyEdited {
                        Text("librarySettings.templateUpdate.locallyEdited")
                            .font(.system(size: Tokens.fontSize.caption))
                            .foregroundStyle(.orange)
                    }
                }
                Text(item.subject)
                    .font(.system(size: Tokens.fontSize.body, design: .monospaced))
                    .textSelection(.enabled)
                if let previous = item.previous {
                    Text(String(format: String(localized: "librarySettings.templateUpdate.previous",
                                               locale: locale), previous))
                        .font(.system(size: Tokens.fontSize.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Tokens.spacing.s)
        .padding(.vertical, Tokens.spacing.xs)
    }

    /// 「何の、どんな変更か」を 1 行で。**訳語はここで付ける**——`QooKit` の
    /// 差分は表示言語を知らないので、値そのものしか持たない [A-01]。
    private func categoryTitle(_ item: TemplateDiff.Item) -> String {
        let category: String.LocalizationValue = switch item.category {
        case .field:               "librarySettings.templateUpdate.category.field"
        case .filenameFormat:      "librarySettings.templateUpdate.category.filenameFormat"
        case .filenameFormatOrder: "librarySettings.templateUpdate.category.formatOrder"
        case .volumeFormat:        "librarySettings.templateUpdate.category.volumeFormat"
        case .folderLevel:         "librarySettings.templateUpdate.category.folderLevel"
        }
        let change: String.LocalizationValue = switch item.change {
        case .added:     "librarySettings.templateUpdate.change.added"
        case .removed:   "librarySettings.templateUpdate.change.removed"
        case .modified:  "librarySettings.templateUpdate.change.modified"
        case .reordered: "librarySettings.templateUpdate.change.reordered"
        }
        return String(localized: category, locale: locale)
            + " · " + String(localized: change, locale: locale)
    }
}
