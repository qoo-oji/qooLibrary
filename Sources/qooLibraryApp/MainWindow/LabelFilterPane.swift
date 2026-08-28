//
//  左ペイン下半分 — ラベルフィルタ [LF-01〜LF-14][PN-01〜PN-06][RT-01〜RT-03]。
//
//  状態は `LabelFilterModel`（`WindowState` が 1 つ持つ）。この View は描くだけで、
//  読み込みと再計算の駆動は `MainWindowView` の `.task(id:)` が行う——左ペインと
//  中央ペインの**両方**が同じ結果を見る必要があり、片方の View に読み込みを
//  持たせると、もう片方が開かれていないときに走らなくなる。
//
import QooApplication
import QooKit
import AppKit
import SwiftUI

struct LabelFilterPane: View {
    @Bindable var model: LabelFilterModel
    let services: LibraryServices

    @Environment(\.locale) private var locale

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
    }

    // MARK: - 見出し

    private var header: some View {
        HStack(spacing: Tokens.spacing.xs) {
            Text("labelFilter.title")
                .font(.system(size: Tokens.fontSize.caption, weight: .semibold))
                .foregroundStyle(.secondary)
            if model.isActive {
                Text("\(model.selectedLabelCount + (model.ratingFilter == nil ? 0 : 1))")
                    .font(.system(size: Tokens.fontSize.caption))
                    .monospacedDigit()
                    .padding(.horizontal, Tokens.spacing.xs)
                    .background(Color.accentColor.opacity(0.2), in: Capsule())
            }
            Spacer()
            // [LF-07] 一括 OFF。⇧⌘K も同じ経路を呼ぶ（`MainWindowView`）。
            Button {
                model.clearAll()
            } label: {
                Image(systemName: "xmark.circle")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(!model.isActive)
            .help(String(localized: "labelFilter.clearAll", locale: locale))
        }
        .font(.system(size: Tokens.fontSize.caption))
        .padding(.horizontal, Tokens.spacing.m)
        .padding(.vertical, Tokens.spacing.xs)
    }

    // MARK: - 中身

    @ViewBuilder
    private var content: some View {
        if model.library == nil {
            // [LF-01] ライブラリまたはその配下を表示しているときだけ出す。
            emptyState("labelFilter.noLibrary")
        } else if let failure = model.loadFailure {
            emptyState("labelFilter.loadFailed", detail: failure)
        } else if model.groups.isEmpty {
            // [LF-02] ラベルが 1 件も無いライブラリ（走査前・未解決ばかりの場合）。
            emptyState("labelFilter.noLabels")
        } else {
            List {
                ratingSection
                ForEach(model.groups) { group in
                    groupSection(group)
                }
                // [LF-03] ドラッグで並べ替え。順序はライブラリ単位で永続化し、
                // 全ウインドウで共有する [LG-07][ST-23]。
                .onMove { indices, destination in
                    var ordered = model.groups
                    ordered.move(fromOffsets: indices, toOffset: destination)
                    Task { await model.reorderGroups(ordered, services: services) }
                }
            }
            .listStyle(.sidebar)
            Divider()
            footer
        }
    }

    private func emptyState(_ key: LocalizedStringResource, detail: String? = nil) -> some View {
        VStack(spacing: Tokens.spacing.xs) {
            Text(key)
                .font(.system(size: Tokens.fontSize.caption))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let detail {
                Text(detail)
                    .font(.system(size: Tokens.fontSize.caption))
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }
        }
        .padding(Tokens.spacing.m)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 評価フィルタ [RT-01〜RT-03]

    @ViewBuilder
    private var ratingSection: some View {
        Section {
            HStack(spacing: Tokens.spacing.xs) {
                RatingStars(
                    filled: model.ratingFilter?.stars ?? 0,
                    tint: model.ratingFilter == nil ? Color.secondary : Color.accentColor,
                    onSelect: toggleRating)
                Spacer()
                // [RT-03] 「以上」と「ちょうど」の切り替え。
                Menu {
                    Picker("labelFilter.rating", selection: ratingModeBinding) {
                        Text("labelFilter.ratingAtLeast").tag(FileQuery.RatingFilter.Mode.atLeast)
                        Text("labelFilter.ratingExact").tag(FileQuery.RatingFilter.Mode.exact)
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } label: {
                    Text(model.ratingFilter?.mode == .exact
                         ? "labelFilter.ratingExact" : "labelFilter.ratingAtLeast")
                        .font(.system(size: Tokens.fontSize.caption))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(model.ratingFilter == nil)
            }
            .font(.system(size: Tokens.fontSize.body))
        } header: {
            Text("labelFilter.rating")
                .font(.system(size: Tokens.fontSize.caption))
        }
    }

    // 「ちょうど」でも星は左から塗る（`RatingStars` の `filled` にそのまま
    // 星数を渡す）——空の星の間に塗った星が飛び飛びで並ぶ形にすると、何が
    // 選ばれているのか読み取れない。モードは隣のメニューが示す。

    private func toggleRating(_ star: Int) {
        if let current = model.ratingFilter, current.stars == star {
            model.ratingFilter = nil            // 同じ星をもう一度で解除
        } else {
            model.ratingFilter = .init(stars: star, mode: model.ratingFilter?.mode ?? .atLeast)
        }
    }

    private var ratingModeBinding: Binding<FileQuery.RatingFilter.Mode> {
        Binding(
            get: { model.ratingFilter?.mode ?? .atLeast },
            set: { mode in
                guard let current = model.ratingFilter else { return }
                model.ratingFilter = .init(stars: current.stars, mode: mode)
            })
    }

    // MARK: - グループ [LF-04][LF-05][PN-02〜PN-06]

    @ViewBuilder
    private func groupSection(_ group: LabelGroupSummary) -> some View {
        DisclosureGroup(isExpanded: expansionBinding(group)) {
            ForEach(model.visibleLabels(in: group)) { label in
                labelRow(label, in: group)
            }
            if model.hasMoreLabels(in: group) {
                Button {
                    model.revealedGroups.insert(group.id)
                } label: {
                    Text("labelFilter.showMore")
                        .font(.system(size: Tokens.fontSize.caption))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
            } else if model.revealedGroups.contains(group.id) {
                // [PN-05] 展開中はインクリメンタル検索を出す。
                TextField("labelFilter.searchLabels", text: searchBinding(group))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: Tokens.fontSize.caption))
                Button {
                    model.revealedGroups.remove(group.id)
                    model.searchText[group.id] = nil
                } label: {
                    Text("labelFilter.showLess")
                        .font(.system(size: Tokens.fontSize.caption))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
            }
        } label: {
            HStack(spacing: Tokens.spacing.xs) {
                // フィールドもラベルと同じ帯で色分けする［ユーザー要望］。
                // 全フィールドを閉じた一覧が既定色のグラデーションで並ぶ [CO-01]。
                LabelChip(name: group.name,
                          color: LabelColor(hexLight: group.colorHexLight,
                                            hexDark: group.colorHexDark),
                          uniformWidth: uniformChipWidth)
                if let selected = model.selection[group.id], !selected.isEmpty {
                    Text("\(selected.count)")
                        .font(.system(size: Tokens.fontSize.caption))
                        .monospacedDigit()
                        .foregroundStyle(Color.accentColor)
                }
            }
        }
    }

    private func labelRow(_ label: LabelSummary, in group: LabelGroupSummary) -> some View {
        HStack(spacing: Tokens.spacing.xs) {
            // [LF-05] チェックボックスで複数選択。
            Toggle(isOn: Binding(
                get: { model.isSelected(label) },
                set: { _ in model.toggle(label) }
            )) {
                LabelChip(name: label.name,
                          color: labelColor(label, in: group),
                          count: label.fileCount,
                          showsPin: true,
                          isPinned: label.isPinned,
                          onTogglePin: {
                              Task { await model.setPinned(label, !label.isPinned, services: services) }
                          },
                          uniformWidth: uniformChipWidth)
            }
            .toggleStyle(.checkbox)
            // ピンを右端へ押し出すために、行の幅いっぱいまで広げる
            // （`Toggle` のラベルは既定で内容幅なので `Spacer` が効かない）。
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // 改名・統合・保管庫へ送る導線 [LB-06][LB-07][LA-01]。ここから直接
        // 編集させず、**編集ウインドウ（15.2）へ送る**——改名は他のラベルとの
        // 衝突、統合は相手選び、削除は影響件数の確認を伴い、フィルタの
        // 狭い行の中では扱いきれない。
        .contextMenu {
            Button("labelEditor.editLabelsEllipsis", systemImage: "tag") {
                LabelEditorNavigation.open(libraryID: group.libraryID, openWindow: openWindow)
            }
        }
    }

    private func expansionBinding(_ group: LabelGroupSummary) -> Binding<Bool> {
        Binding(
            get: { model.expandedGroups.contains(group.id) },
            set: { expanded in
                if expanded { model.expandedGroups.insert(group.id) }
                else { model.expandedGroups.remove(group.id) }
            })
    }

    private func searchBinding(_ group: LabelGroupSummary) -> Binding<String> {
        Binding(
            get: { model.searchText[group.id] ?? "" },
            set: { model.searchText[group.id] = $0 })
    }

    /// 帯の幅を統一する［ユーザー要望: 一番長い文字列にあわせる］。
    /// フィールド名と全ラベル名の実測幅の最大値。展開状態で幅が動かないよう、
    /// 表示中のものではなく読み込んだ全ラベルで測る。長すぎる名前は
    /// チップ側の中央省略に任せ、上限で止める。
    private var uniformChipWidth: CGFloat {
        let font = NSFont.systemFont(ofSize: Tokens.fontSize.caption)
        var names = model.groups.map(\.name)
        for group in model.groups {
            names += (model.labels[group.id] ?? []).map(\.name)
        }
        let widest = names
            .map { ($0 as NSString).size(withAttributes: [.font: font]).width }
            .max() ?? 0
        return min(max(widest.rounded(.up) + 2, 40), 150)
    }

    /// ラベル固有色が無ければグループ色を継承する [CO-06]。
    private func labelColor(_ label: LabelSummary, in group: LabelGroupSummary) -> LabelColor {
        guard let hex = label.colorHex else {
            return LabelColor(hexLight: group.colorHexLight, hexDark: group.colorHexDark)
        }
        return LabelColor(hexLight: hex, hexDark: hex)
    }

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openWindow) private var openWindow

    // MARK: - 件数 [LF-11]

    private var footer: some View {
        HStack(spacing: Tokens.spacing.xs) {
            if model.isActive {
                Text(conditionSummary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(.secondary)
                    .help(conditionSummary)
                Spacer(minLength: Tokens.spacing.xs)
                Text(countText)
                    .monospacedDigit()
            } else if let total = model.totalCount {
                Spacer()
                Text(String(format: String(localized: "labelFilter.totalCount", locale: locale),
                            total.formatted(.number.locale(locale))))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .font(.system(size: Tokens.fontSize.caption))
        .padding(.horizontal, Tokens.spacing.m)
        .padding(.vertical, Tokens.spacing.xs)
    }

    /// 「現在の絞り込み条件」[LF-11]。グループ名は出さず値だけを並べる——
    /// 幅が狭いので、まず「何で絞っているか」が読めることを優先する。
    private var conditionSummary: String {
        var parts: [String] = []
        for group in model.groups {
            guard let ids = model.selection[group.id], !ids.isEmpty else { continue }
            let names = (model.labels[group.id] ?? [])
                .filter { ids.contains($0.id) }
                .map(\.name)
            if !names.isEmpty { parts.append(names.joined(separator: ", ")) }
        }
        if let rating = model.ratingFilter {
            let mode = String(localized: rating.mode == .exact
                              ? "labelFilter.ratingExact" : "labelFilter.ratingAtLeast",
                              locale: locale)
            parts.append("★\(rating.stars) \(mode)")
        }
        return parts.joined(separator: " · ")
    }

    private var countText: String {
        guard let matched = model.matchedCount else {
            return String(localized: "labelFilter.counting", locale: locale)
        }
        let total = model.totalCount ?? matched
        return String(format: String(localized: "labelFilter.matchedCount", locale: locale),
                      matched.formatted(.number.locale(locale)),
                      total.formatted(.number.locale(locale)))
    }
}
