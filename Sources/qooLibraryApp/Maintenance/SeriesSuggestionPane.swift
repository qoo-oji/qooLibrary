//
//  メンテナンスウインドウの「シリーズの提案」タブ [SS-01〜SS-08][19章 §19.5]。
//
//  シリーズ名の抽出はユーザー定義のフォーマットに頼っており、どうやっても
//  漏れが出る——特に同人誌では「1 冊目にだけ番号が無い」形が頻出する。
//  ここはその**救済**で、**勝手には設定しない** [SS-01]。
//
//  ## 単位はグループ [SS-05]
//  適用も無視もグループ単位。メンバーを部分的に外す手段は作らない [P2]
//  ——誤検出が 1 冊混ざっていれば、そのグループごと無視して手で直す。
//
//  ## 「見つからないファイル」「保管庫」タブとの違い — **オンラインを要らない**
//  適用（シリーズ名 ＋ 保護）も無視も **DB だけを書く**ので、ボリュームが
//  繋がっていなくても操作できる（保管庫の「戻す」は実ファイルを動かすので
//  要る [SB-05]）。
//
//  判定（無視の出し分け・検索・適用の下ごしらえ）は `SeriesSuggestionModel`
//  が持ち、ここは描くだけ。**この分担を崩さないこと**。
//
import QooApplication
import QooKit
import SwiftUI

struct SeriesSuggestionPane: View {
    @Environment(\.locale) private var locale
    @Bindable var model: SeriesSuggestionModel
    @State private var errorText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            toolbar
            Divider()
            content
            Divider()
            footer
        }
    }

    private var toolbar: some View {
        HStack(spacing: Tokens.spacing.m) {
            Toggle("seriesSuggestions.showIgnored", isOn: $model.showsIgnored)
                .toggleStyle(.checkbox)
            TextField("seriesSuggestions.searchPlaceholder", text: $model.searchText)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 140)
        }
        .padding(Tokens.spacing.m)
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .notReady:
            placeholder("labelEditor.notReady", systemImage: "externaldrive.badge.xmark")
        case .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .noLibrary:
            placeholder("librarySettings.noLibraries", systemImage: "books.vertical")
        case .failed(let reason):
            placeholder(LocalizedStringKey(reason), systemImage: "exclamationmark.triangle")
        case .ready:
            // 縮む側。フッターが伸びたら**一覧が譲る**（`FileVaultPane` と同じ）。
            list.frame(minHeight: 60)
        }
    }

    private func placeholder(_ key: LocalizedStringKey, systemImage: String) -> some View {
        ContentUnavailableView { Label(key, systemImage: systemImage) }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var list: some View {
        List(selection: $model.selection) {
            ForEach(model.visibleGroups) { group in
                // **`.tag()` は `DisclosureGroup` 自身に付ける**（ラベルでは
                // ない）——ラベルに付けると選択が先頭行へ吸われる
                // ［CLAUDE.md の既記録の教訓］。
                DisclosureGroup {
                    ForEach(group.suggestion.members) { member in
                        memberRow(member)
                            // **メンバー行は選べない**［code-review の指摘］。
                            // `ForEach` が `Identifiable` から暗黙のタグを
                            // 付けるので、放っておくと `FileID` の選択へ
                            // 混ざる——グループに一致しない選択でフッターの
                            // ボタンが有効になり（押しても何も起きない）、
                            // たまたま最小 ID のメンバーならグループ全体が
                            // 適用される。
                            .selectionDisabled()
                    }
                } label: {
                    groupHeader(group)
                }
                .tag(group.id)
                .contextMenu { rowMenu(group) }
            }
        }
        .overlay {
            if model.visibleGroups.isEmpty { emptyState }
        }
    }

    /// 提案 1 件の見出し [SS-01]。シリーズ名・冊数・どのフォルダの話か。
    private func groupHeader(_ group: SeriesSuggestionModel.Group) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: Tokens.spacing.s) {
                Text(group.suggestion.seriesName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if group.isIgnored {
                    // 無視中は**印で示す**。行を出さないのではなく淡く出す
                    // ので、押し間違いを取り消せる。
                    Label("seriesSuggestions.ignoredBadge", systemImage: "eye.slash")
                        .labelStyle(.iconOnly)
                        .foregroundStyle(.secondary)
                        .help(Text("seriesSuggestions.ignoredBadge"))
                }
            }
            HStack(spacing: Tokens.spacing.s) {
                Text(String(format: String(localized: "seriesSuggestions.bookCount",
                                           locale: locale),
                            group.suggestion.members.count))
                Text(folderLabel(group.suggestion.folderPath))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .font(.system(size: Tokens.fontSize.caption))
            .foregroundStyle(.secondary)
        }
        .opacity(group.isIgnored ? 0.5 : 1)
        // **2 行の行には縦の余白を明示する**［`FileVaultPane` と同じ教訓］。
        .padding(.vertical, 3)
    }

    /// メンバー 1 冊。**巻なしを明示する** [SS-07]——空欄にすると「まだ
    /// 決まっていない」のか「巻を持たない」のか読み取れない。
    private func memberRow(_ member: SeriesSuggestion.Member) -> some View {
        HStack(spacing: Tokens.spacing.s) {
            Text(member.title)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: Tokens.spacing.s)
            Text(volumeLabel(member.volume))
                .foregroundStyle(.secondary)
        }
        .font(.system(size: Tokens.fontSize.caption))
    }

    private func volumeLabel(_ volume: VolumeValue) -> String {
        guard volume.kind == .numeric, let raw = volume.raw else {
            return String(localized: "seriesSuggestions.noVolume", locale: locale)
        }
        return String(format: String(localized: "seriesSuggestions.volume", locale: locale), raw)
    }

    private func folderLabel(_ folder: String) -> String {
        folder.isEmpty ? String(localized: "fileVault.libraryRoot", locale: locale) : folder
    }

    /// **「提案はありません」と「検索に一致しない」と「無視で隠れている」を
    /// 分ける。** 次の一手が違う——最後のものは「無視したものも表示」を
    /// 押せばよい（未整理タブで、1 つに畳むと文言が嘘になるのを実機で踏んだ）。
    @ViewBuilder
    private var emptyState: some View {
        if !model.searchText.isEmpty {
            ContentUnavailableView { Label("seriesSuggestions.noMatches", systemImage: "doc") }
        } else if model.hiddenIgnoredCount > 0 {
            ContentUnavailableView {
                Label("seriesSuggestions.empty", systemImage: "books.vertical")
            } description: {
                Text(String(format: String(localized: "seriesSuggestions.hiddenIgnored",
                                           locale: locale), model.hiddenIgnoredCount))
            }
        } else {
            ContentUnavailableView {
                Label("seriesSuggestions.empty", systemImage: "books.vertical")
            } description: {
                Text("seriesSuggestions.emptyHint")
            }
        }
    }

    @ViewBuilder
    private func rowMenu(_ group: SeriesSuggestionModel.Group) -> some View {
        // **選択には触らない**（`FileVaultPane` と同じ）——ここで潰すと
        // 複数選択が壊れる。
        Button("seriesSuggestions.apply", systemImage: "checkmark.circle") {
            perform { try await model.apply([group]) }
        }
        .disabled(group.isIgnored || !model.canModify)
        Divider()
        if group.isIgnored {
            Button("seriesSuggestions.unignore", systemImage: "eye") {
                perform { try await model.setIgnored([group], false) }
            }
            .disabled(!model.canModify)
        } else {
            Button("seriesSuggestions.ignore", systemImage: "eye.slash") {
                perform { try await model.setIgnored([group], true) }
            }
            .disabled(!model.canModify)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: Tokens.spacing.m) {
            if let errorText {
                ScrollView {
                    Text(errorText)
                        .font(.system(size: Tokens.fontSize.caption))
                        .foregroundStyle(Color("DangerText"))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 44)
            }
            HStack(spacing: Tokens.spacing.s) {
                Text(String(format: String(localized: "labelEditor.selectedCount", locale: locale),
                            model.selection.count))
                    .font(.system(size: Tokens.fontSize.caption))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("seriesSuggestions.ignore") {
                    perform { try await model.ignoreSelected() }
                }
                .disabled(model.selection.isEmpty || !model.canModify)
                Button("seriesSuggestions.apply") {
                    perform { try await model.applySelected() }
                }
                .disabled(model.selection.isEmpty || !model.canModify)
            }
        }
        .padding(Tokens.spacing.m)
        .layoutPriority(1)
    }

    private func perform(_ work: @escaping () async throws -> Void) {
        Task {
            do {
                try await work()
                errorText = nil
            } catch {
                errorText = error.localizedDescription
            }
        }
    }
}
