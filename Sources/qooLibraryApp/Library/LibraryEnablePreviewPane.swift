//
//  草案を実ファイル名へ当てた結果を見せるプレビュー [HP-05、ユーザー要望]。
//
//  ユーザー指摘:「登録済みフォルダに対してライブラリを有効化する際に、
//  ユーザーはその選択肢で何がどう変化するのかわからない」。**これがその
//  答え**——テンプレートの中身を並べても、自分の蔵書がどう解釈されるかは
//  分からない。
//
//  **登録ウィザードのステップ 3・4 が使う**（`LibraryRegistrationWizard`）。
//  かつては旧「有効化ウインドウ」（`LibraryEnableView`）とも共有していたが、
//  そちらは §19.8 の処分表どおりウィザードへ改組して廃止した。
//
import QooApplication
import QooKit
import SwiftUI


/// 草案を実ファイル名へ当てた結果 [HP-05]。
///
/// **これが「何がどう変化するのか」への答え。** テンプレートの中身を並べても、
/// 自分の蔵書がどう解釈されるかは分からない。
struct LibraryEnablePreviewPane: View {
    @Environment(\.locale) private var locale
    @Environment(\.colorScheme) private var colorScheme
    let model: LibraryEnableModel

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.spacing.s) {
            summaryRow
            Divider()
            if model.isSampling {
                HStack(spacing: Tokens.spacing.xs) {
                    ProgressView().controlSize(.small)
                    Text("libraryEnable.preview.sampling")
                        .font(.system(size: Tokens.fontSize.caption))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, Tokens.spacing.m)
            } else if let failure = model.samplingFailure {
                Text(failure)
                    .font(.system(size: Tokens.fontSize.caption))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Tokens.spacing.m)
            } else if model.sampleNames.isEmpty {
                Text("libraryEnable.preview.noFiles")
                    .font(.system(size: Tokens.fontSize.caption))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Tokens.spacing.m)
            } else {
                itemList
            }
        }
        .padding(.vertical, Tokens.spacing.s)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var summaryRow: some View {
        let outcome = model.preview
        return HStack(spacing: Tokens.spacing.m) {
            Text("libraryEnable.preview.title")
                .font(.system(size: Tokens.fontSize.body, weight: .semibold))
            if !model.isSampling && !model.sampleNames.isEmpty {
                Text(String(format: String(localized: "libraryEnable.preview.summary",
                                           locale: locale),
                            outcome.total, outcome.matched, outcome.unresolved))
                    .font(.system(size: Tokens.fontSize.caption))
                    .foregroundStyle(outcome.unresolved == 0 ? .secondary : .primary)
                if outcome.excluded > 0 {
                    // 対象拡張子で外した件数 [AL-11]。出さないと、有効化した
                    // 後の走査結果と数が合わない理由が分からない。
                    Text(String(format: String(localized: "libraryEnable.preview.excluded",
                                               locale: locale), outcome.excluded))
                        .font(.system(size: Tokens.fontSize.caption))
                        .foregroundStyle(.secondary)
                }
                if outcome.truncated {
                    Text(String(format: String(localized: "libraryEnable.preview.truncated",
                                               locale: locale), outcome.total))
                        .font(.system(size: Tokens.fontSize.caption))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Tokens.spacing.m)
    }

    private var itemList: some View {
        // **未解決が先頭に来る**（`LibraryPreview.run` が並べ替え済み）。
        // 調整が要るのはそこなので、探させない。
        // 行の余白を詰めて件数を稼ぐ [ユーザー要望]。1 件 2 行（ファイル名と
        // 分解）は変えない——分解が見えないと「どう解釈されたか」が分からず、
        // 件数だけ増やしても意味が無い。
        List(model.preview.items) { item in
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: Tokens.spacing.xs) {
                    Image(systemName: icon(for: item))
                        .foregroundStyle(color(for: item))
                    Text(item.filename)
                        .font(.system(size: Tokens.fontSize.caption, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if item.matched {
                    Text(fieldSummary(item))
                        .font(.system(size: Tokens.fontSize.caption))
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("libraryEnable.preview.unresolvedHint")
                        .font(.system(size: Tokens.fontSize.caption))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 0)
            .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
        }
        .listStyle(.inset)
        .environment(\.defaultMinListRowHeight, 8)
    }

    private func icon(for item: LibraryPreview.Item) -> String {
        if !item.matched { return "questionmark.circle.fill" }
        return "checkmark.circle.fill"
    }

    private func color(for item: LibraryPreview.Item) -> Color {
        if !item.matched { return .orange }
        return .green
    }

    /// 「タイトル: ○○ ・ サークル: ○○」の形にする。**ラベルグループは
    /// 番号ではなく名前で出す**——`@labelgroup3` と言われても何のことか分からない。
    ///
    /// ラベルへ流れる値には**フィールドの色を敷く** [§19.10 ステージ 2]。
    /// どの値がどのフィールドのラベルになるかが一目で分かり、色はそのまま
    /// カスタマイズ（フィールドの色）へ追随する。1 本の `AttributedString` に
    /// するのは、行数の多い一覧でチップの部品を並べるより軽く、自然に
    /// 折り返せるため。
    private func fieldSummary(_ item: LibraryPreview.Item) -> AttributedString {
        var out = AttributedString()
        for (offset, field) in item.fields.enumerated() {
            if offset > 0 { out += AttributedString("  ") }
            var label = AttributedString(
                "\(FormatMatchPreview.label(for: field.ref, draft: model.draft)): ")
            label.foregroundColor = .secondary
            out += label
            var value = AttributedString(field.value)
            if let hex = FormatMatchPreview.colorHex(for: field.ref, draft: model.draft,
                                                     darkMode: colorScheme == .dark),
               let background = Color(labelHex: hex) {
                value.backgroundColor = background
                if let fgHex = LabelColorPalette.readableForeground(on: hex),
                   let foreground = Color(labelHex: fgHex) {
                    value.foregroundColor = foreground
                }
            }
            out += value
        }
        return out
    }
}
