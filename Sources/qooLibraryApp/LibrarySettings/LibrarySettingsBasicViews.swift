//
//  ライブラリ設定 — 基本・対象拡張子・区切り文字・保護文字列 [15.1 節]。
//
import QooKit
import SwiftUI

// MARK: - 共通の見出し

/// 各設定項目の見出しと一行説明。**説明を必ず添える**——このアプリの設定は
/// 「何を書けばよいか分からない」ことが最大の障壁（要件定義書 R-04）なので、
/// 項目名だけを並べても設定しきれない。
struct SettingsSectionHeader: View {
    let title: LocalizedStringKey
    let explanation: LocalizedStringKey

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.spacing.xs) {
            Text(title).font(.system(size: Tokens.fontSize.title3, weight: .semibold))
            Text(explanation)
                .font(.system(size: Tokens.fontSize.caption))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 基本設定

struct LibraryBasicsSettingsView: View {
    @Binding var draft: LibrarySettingsDraft

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.spacing.l) {
            SettingsSectionHeader(title: "librarySettings.section.basics",
                                  explanation: "librarySettings.basics.explanation")
            // **入力欄には必ず `.editableFieldChrome()` を付ける** [ユーザー指摘、
            // 2 度目]。`Form` の中の素の `TextField` は、値が右端に寄った
            // ただのテキストにしか見えず、**そこが入力できる場所だと気づけない**
            // ——実機で「ライブラリタイプ名を入力するボックスがわからなかった」と
            // 報告された。地の色が付いて初めて欄だと分かる（`EditableFieldChrome`
            // の型コメント参照）。
            Form {
                LabeledContent {
                    TextField("", text: $draft.displayName)
                        .labelsHidden()
                        .editableFieldChrome()
                } label: {
                    Text("librarySettings.basics.displayName")
                }
                LabeledContent {
                    VStack(alignment: .leading, spacing: Tokens.spacing.xs) {
                        TextField("", text: $draft.libraryTypeName)
                            .labelsHidden()
                            .editableFieldChrome()
                        // 実蔵書との突き合わせで、ここの食い違いが 146 件の未解決を
                        // 生んだ実例がある（同人CG の印は `(同人CG集)` だった）。
                        Text("librarySettings.basics.typeNameHint")
                            .font(.system(size: Tokens.fontSize.caption))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } label: {
                    Text("librarySettings.basics.typeName")
                }
                Toggle("librarySettings.basics.caseSensitive", isOn: $draft.caseSensitive)
                Toggle("librarySettings.basics.thumbnailsAlwaysHidden",
                       isOn: $draft.thumbnailsAlwaysHidden)
                LabeledContent {
                    TextField("", text: $draft.seriesTitleCompositionFormat)
                        .labelsHidden()
                        .font(.system(size: Tokens.fontSize.body, design: .monospaced))
                        .editableFieldChrome()
                } label: {
                    Text("librarySettings.basics.seriesComposition")
                }
            }
            .formStyle(.grouped)
            .frame(maxWidth: 560)
        }
    }
}

// MARK: - 対象拡張子

struct LibraryExtensionsSettingsView: View {
    @Binding var draft: LibrarySettingsDraft

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.spacing.l) {
            SettingsSectionHeader(title: "librarySettings.section.extensions",
                                  explanation: "librarySettings.extensions.explanation")
            ExtensionListEditor(title: "librarySettings.extensions.target",
                                hint: "librarySettings.extensions.targetHint",
                                defaults: AppDefaults.Library.targetExtensions.sorted(),
                                extensions: $draft.targetExtensions)
            ExtensionListEditor(title: "librarySettings.extensions.image",
                                hint: "librarySettings.extensions.imageHint",
                                defaults: nil,
                                extensions: $draft.imageExtensions)
        }
    }
}

/// 拡張子の並びを 1 行の入力欄で編集する。
///
/// **入力の揺れはこちらで吸収する**——先頭の `.`、大文字、余分な空白、全角の
/// 読点はどれも普通に打たれる。矯正を求めず、受け取ってから正す。
private struct ExtensionListEditor: View {
    let title: LocalizedStringKey
    let hint: LocalizedStringKey
    /// 「既定に戻す」で入れ直す値。既定を持たない一覧では `nil`。
    let defaults: [String]?
    @Binding var extensions: [String]

    @State private var text: String = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.spacing.xs) {
            Text(title).font(.system(size: Tokens.fontSize.body, weight: .medium))
            TextField("", text: $text)
                .labelsHidden()
                .editableFieldChrome()
                .focused($isFocused)
                .onSubmit { commit() }
                .onChange(of: isFocused) { if !isFocused { commit() } }
                .frame(maxWidth: 560)
            HStack(spacing: Tokens.spacing.xs) {
                Text(hint)
                Spacer(minLength: 0)
                if let defaults {
                    Button("librarySettings.extensions.restoreDefaults") {
                        extensions = defaults
                        text = defaults.joined(separator: ", ")
                    }
                    .buttonStyle(.link)
                }
            }
            .font(.system(size: Tokens.fontSize.caption))
            .foregroundStyle(.secondary)
            .frame(maxWidth: 560, alignment: .leading)
        }
        .task(id: extensions) {
            guard !isFocused else { return }
            text = extensions.joined(separator: ", ")
        }
    }

    private func commit() {
        let parts = text
            .replacingOccurrences(of: "、", with: ",")
            .replacingOccurrences(of: "，", with: ",")
            .split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\n" || $0 == "\t" })
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .map { $0.hasPrefix(".") ? String($0.dropFirst()) : $0 }
            .filter { !$0.isEmpty }
        var seen = Set<String>()
        extensions = parts.filter { seen.insert($0).inserted }.sorted()
        text = extensions.joined(separator: ", ")
    }
}

// MARK: - 区切り文字

struct LibraryDelimitersSettingsView: View {
    @Binding var draft: LibrarySettingsDraft

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.spacing.l) {
            SettingsSectionHeader(title: "librarySettings.section.delimiters",
                                  explanation: "librarySettings.delimiters.explanation")

            VStack(alignment: .leading, spacing: Tokens.spacing.xs) {
                Text("librarySettings.delimiters.pairs")
                    .font(.system(size: Tokens.fontSize.body, weight: .medium))
                ForEach(DelimiterSet.availablePairs, id: \.open) { candidate in
                    Toggle(isOn: pairBinding(open: candidate.open, close: candidate.close)) {
                        Text(verbatim: "\(candidate.open) \(candidate.close)")
                            .font(.system(size: Tokens.fontSize.body, design: .monospaced))
                    }
                }
            }

            VStack(alignment: .leading, spacing: Tokens.spacing.xs) {
                Text("librarySettings.delimiters.separators")
                    .font(.system(size: Tokens.fontSize.body, weight: .medium))
                // [DL-13] セパレータ型は「タイトル中の文字」と見分けが付かない
                // ため既定で無効。有効にする影響を必ず添える。
                Text("librarySettings.delimiters.separatorWarning")
                    .font(.system(size: Tokens.fontSize.caption))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(DelimiterSet.availableSeparators()) { candidate in
                    Toggle(isOn: separatorBinding(canonical: candidate.canonical,
                                                  variants: candidate.variants)) {
                        Text(verbatim: candidate.variantsByLengthDesc.joined(separator: "  "))
                            .font(.system(size: Tokens.fontSize.body, design: .monospaced))
                    }
                }
            }
        }
        .frame(maxWidth: 560, alignment: .leading)
    }

    private func pairBinding(open: Character, close: Character) -> Binding<Bool> {
        Binding(
            get: { draft.delimiters.pairs.contains { $0.open == open && $0.close == close && $0.isEnabled } },
            set: { enabled in
                if let i = draft.delimiters.pairs.firstIndex(where: { $0.open == open && $0.close == close }) {
                    draft.delimiters.pairs[i].isEnabled = enabled
                } else if enabled {
                    draft.delimiters.pairs.append(PairDelimiter(open: open, close: close))
                }
            })
    }

    private func separatorBinding(canonical: String, variants: Set<String>) -> Binding<Bool> {
        Binding(
            get: { draft.delimiters.separators.contains { $0.canonical == canonical && $0.isEnabled } },
            set: { enabled in
                if let i = draft.delimiters.separators.firstIndex(where: { $0.canonical == canonical }) {
                    draft.delimiters.separators[i].isEnabled = enabled
                } else if enabled {
                    draft.delimiters.separators.append(
                        SeparatorDelimiter(canonical: canonical, variants: variants, isEnabled: true))
                }
            })
    }
}

// MARK: - 保護文字列

struct LibraryProtectedTokensSettingsView: View {
    @Binding var draft: LibrarySettingsDraft
    @State private var newText: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.spacing.l) {
            SettingsSectionHeader(title: "librarySettings.section.protectedTokens",
                                  explanation: "librarySettings.protectedTokens.explanation")

            VStack(spacing: 0) {
                ForEach($draft.protectedTokens) { $token in
                    HStack(spacing: Tokens.spacing.s) {
                        Toggle("", isOn: $token.isEnabled).labelsHidden()
                        Text(verbatim: token.text)
                            .font(.system(size: Tokens.fontSize.body, design: .monospaced))
                        Spacer(minLength: Tokens.spacing.m)
                        FixedWidthPopUp(items: ProtectedToken.Position.popUpItems,
                                        selection: $token.position)
                            .frame(width: 130)
                        Button {
                            draft.protectedTokens.removeAll { $0.id == token.id }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                    .padding(.vertical, Tokens.spacing.xs)
                    Divider()
                }
                HStack(spacing: Tokens.spacing.s) {
                    TextField("librarySettings.protectedTokens.placeholder", text: $newText)
                        .labelsHidden()
                        .editableFieldChrome()
                        .onSubmit(add)
                    Button("librarySettings.add", action: add)
                        .disabled(newText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(.top, Tokens.spacing.s)
            }
            .frame(maxWidth: 560, alignment: .leading)
        }
    }

    private func add() {
        let text = newText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        guard !draft.protectedTokens.contains(where: { $0.text == text }) else {
            newText = ""
            return
        }
        draft.protectedTokens.append(ProtectedToken(text: text))
        newText = ""
    }
}

extension ProtectedToken.Position {
    /// 位置条件の選択肢 [PT-05]。
    static var popUpItems: [FixedWidthPopUp<Self>.Item] {
        [.init(title: String(localized: "librarySettings.protectedTokens.anywhere"), tag: .anywhere),
         .init(title: String(localized: "librarySettings.protectedTokens.prefix"), tag: .prefix),
         .init(title: String(localized: "librarySettings.protectedTokens.suffix"), tag: .suffix)]
    }
}
