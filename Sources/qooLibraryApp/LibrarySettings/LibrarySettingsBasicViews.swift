//
//  ライブラリ設定 — 基本・対象拡張子・区切り文字・保護文字列 [15.1 節]。
//
import QooApplication
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

/// 基本設定 [§19.7]。通常時に最初に見えるセクション。
///
/// ## 表示名の欄は無い [RG3-31]
/// 「ライブラリの表示名」という概念自体を持たない——名前を変えたければ
/// フォルダ自体をリネームする（ツリーも DB も自動で追随する）。ここに欄を
/// 残すと、**フォルダ名と食い違った名前を作れてしまう**。
///
/// ## 埋め込みメタデータはここに統合されている [§19.7]
/// 独立したセクションだったものを基本の中の節にした。単独で 1 セクションを
/// 占めるほどの分量が無く、「このライブラリをどう読むか」という基本の性格と
/// 揃っている。
struct LibraryBasicsSettingsView: View {
    @Binding var draft: LibrarySettingsDraft
    /// 巻数の判断待ち [EM-35]。埋め込みメタデータの節を取り込んだので、その
    /// 導線もここへ移った。登録前（ウィザード）は判断待ちが存在しないので既定の空。
    var pending: [VolumeDecisionCandidate] = []
    var onReview: () -> Void = {}
    /// プリセットの改訂 [LT-13]。登録前（ウィザード）には存在しないので既定は `nil`。
    var templateUpdate: TemplateUpdateModel.Pending? = nil
    var onReviewTemplateUpdate: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.spacing.l) {
            SettingsSectionHeader(title: "librarySettings.section.basics",
                                  explanation: "librarySettings.basics.explanation")
            // **ブックタイプ名の入力欄は撤去した** [TY-01、2026-09-04]。本の種別は
            // 本の属性であってライブラリの属性ではないので、ライブラリが固有値を
            // 持つ理由が無い——`@booktype` はプリセットの語彙とこのライブラリの
            // 「本の種別」ラベルで照合し、切り出した値はそのフィールドのラベルに
            // なる。**入力欄には必ず `.editableFieldChrome()` を付ける**という
            // 作法は他の欄でそのまま生きている [ユーザー指摘、2 度目]。
            Form {
                Section {
                    Toggle("librarySettings.basics.thumbnailsAlwaysHidden",
                           isOn: $draft.thumbnailsAlwaysHidden)
                    // [DU-01][DU-02] 同じ作品のファイルを 1 行に畳むか。**既定は
                    // 無効**——畳むのは表示を減らす操作なので、頼まれていないのに
                    // 始めない。判定キーの違いは「同じタイトルの別の巻を同じ組と
                    // 見るかどうか」だけ。
                    //
                    // 丸が右端へ飛ぶのを防ぐ [CP-07]。`Form` は選択肢 1 行ずつを
                    // 「ラベル＋操作」の行として扱うので、`LabeledContent` で
                    // 包まないと丸だけが数百 pt 離れた右端へ行く［実測］。
                    LabeledContent {
                        Picker("", selection: $draft.duplicateGrouping) {
                            Text("librarySettings.basics.duplicateGrouping.off")
                                .tag(DuplicateGrouping.off)
                            Text("librarySettings.basics.duplicateGrouping.byTitleAndVolume")
                                .tag(DuplicateGrouping.byTitleAndVolume)
                            Text("librarySettings.basics.duplicateGrouping.byTitle")
                                .tag(DuplicateGrouping.byTitle)
                        }
                        .labelsHidden()
                        .pickerStyle(.radioGroup)
                    } label: {
                        Text("librarySettings.basics.duplicateGrouping")
                    }
                } footer: {
                    Text("librarySettings.basics.duplicateGroupingHint")
                        .font(.system(size: Tokens.fontSize.caption))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                EmbeddedMetadataFormSections(draft: $draft)
            }
            .formStyle(.grouped)
            .frame(maxWidth: 560)
            // 判断待ちのカードは `Form` の外に置く——中に入れると 1 行として
            // 描かれ、枠と余白が二重になる（`Form` に `Divider()` を置けない
            // のと同じ事情。`LibraryEmbeddedMetadataViews` のコメント参照）。
            EmbeddedMetadataPendingCard(pending: pending, onReview: onReview)
                .frame(maxWidth: 560)
            TemplateUpdateCard(pending: templateUpdate, onReview: onReviewTemplateUpdate)
                .frame(maxWidth: 560)
        }
    }
}

// MARK: - シリーズ名の組み立て（高度）

/// シリーズ名の組み立て [SE-33]。一覧やインスペクタに出す「シリーズ名 巻数」の
/// 書式で、既定は `@series @volume`。
///
/// **高度な設定に置いてある** [§19.7 の判断、ユーザー判断]——予約語を並べる
/// 記法を書く欄で、性質は巻数フォーマットと同類。全プリセットが既定値のまま
/// 使っており、変える動機を持つ人は限られる。
struct LibrarySeriesTitleSettingsView: View {
    @Binding var draft: LibrarySettingsDraft

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.spacing.l) {
            SettingsSectionHeader(title: "librarySettings.section.seriesTitle",
                                  explanation: "librarySettings.seriesTitle.explanation")
            Form {
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

// MARK: - ブックフォルダの開き方（高度）

/// ブックフォルダをダブルクリックしたときの動き [IF-18][AS-06]。
///
/// **偽が既定**でフォルダを開く（配下の画像一覧を表示する）。ライブラリ単位に
/// してあるのは、画像フォルダ中心のライブラリとアーカイブ中心のライブラリで
/// 期待が違うため［ユーザー判断］。**高度な設定へ移した** [§19.7]——一度
/// 決めたら触らない類の設定で、日常的に切り替えるものではない。
struct LibraryBookFolderOpeningSettingsView: View {
    @Binding var draft: LibrarySettingsDraft

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.spacing.l) {
            SettingsSectionHeader(title: "librarySettings.section.bookFolderOpening",
                                  explanation: "librarySettings.bookFolderOpening.explanation")
            Form {
                Section {
                    Toggle("librarySettings.basics.opensBookFolderWithApp",
                           isOn: $draft.opensBookFolderWithApp)
                } footer: {
                    Text("librarySettings.basics.opensBookFolderWithAppHint")
                        .font(.system(size: Tokens.fontSize.caption))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
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
                        // **編集できるようにする。** 正規表現になった以上、
                        // 打ち間違いを消して入れ直すしかないのは辛い。
                        TextField("", text: $token.pattern)
                            .labelsHidden()
                            .font(.system(size: Tokens.fontSize.body, design: .monospaced))
                            .editableFieldChrome()
                        if let finding = Self.firstFinding(for: token) {
                            Image(systemName: finding.isError
                                  ? "exclamationmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(finding.isError ? .red : .orange)
                                .help(Text(verbatim: finding.message))
                        }
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
        guard !draft.protectedTokens.contains(where: { $0.pattern == text }) else {
            newText = ""
            return
        }
        draft.protectedTokens.append(ProtectedToken(pattern: text))
        newText = ""
    }

    /// 行に出す 1 件。**静的検査だけ**を使う（`body` は入力のたびに評価される）。
    static func firstFinding(for token: ProtectedToken) -> RegexSafetyFinding? {
        guard !token.pattern.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        let findings = RegexSafety.staticFindings(token.pattern)
        return findings.first(where: \.isError) ?? findings.first
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
