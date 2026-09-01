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
    /// 未整理ビューを見ているか [UR3-01]。行のハイライトに使う。
    let isShowingUnresolved: Bool
    /// 未整理ビューの出入り。実体は `WindowState.toggleUnresolvedFiles()`。
    let onToggleUnresolved: () -> Void
    /// 保存した絞り込み [SH-01]。読み込みの駆動は `MainWindowView` の
    /// `.task(id:)`（`model` と同じ形）。
    let shelves: ShelfModel
    /// **シェルフはライブラリ表示モードでしか出さない** [SH-09]［ユーザー指定］
    /// ——覚えている条件には並び順と表示モードも含まれ [SH-02]、フォルダ
    /// 表示モードで押すと「実体の一覧」の見え方まで変わってしまう。
    let isLibraryDisplayMode: Bool
    /// いまの絞り込み [SH-01]。保存と、どのシェルフと同じかの照合 [SH-08] に使う。
    /// **並び順と検索語はここでは作れない**ので、持ち主から受け取る
    /// （`ShelfModel` の型コメント参照）。
    let currentShelfCondition: ShelfCondition?
    /// シェルフを復元する [SH-06]。表示モードと並び順まで動かすので、
    /// `WindowState` を知っている側に任せる。
    let onApplyShelf: (ShelfSummary) -> Void

    @Environment(\.locale) private var locale

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            // **最下部に独立して置く**［ユーザー指定、2026-08-29］。ラベル
            // フィルタの中（セクションの 1 つ）にしないのは、これが絞り込みでは
            // なく**別の一覧への切り替え**だから——同じ List に混ぜると、
            // チェックを入れる操作と一覧を切り替える操作が並ぶことになる。
            unresolvedSection
        }
    }

    // MARK: - 未整理のファイル [UR3-01][UR3-05]

    /// **ライブラリを見ているときは常設する**（0 件でも消さない）。件数が
    /// 出ていること自体が「片付けるものは無い」という答えになる——消えると
    /// 「そんな機能は無い」と読める。
    @ViewBuilder
    private var unresolvedSection: some View {
        if model.library != nil {
            Divider()
            let pending = model.unresolvedCounts?.pending ?? 0
            Button(action: onToggleUnresolved) {
                HStack(spacing: Tokens.spacing.xs) {
                    Image(systemName: "tray.full")
                        .foregroundStyle(pending > 0 ? Color.accentColor : .secondary)
                    Text("labelFilter.unresolvedTitle")
                    Spacer(minLength: Tokens.spacing.xs)
                    Text(pending.formatted(.number.locale(locale)))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: Tokens.fontSize.caption))
                .padding(.horizontal, Tokens.spacing.m)
                .padding(.vertical, Tokens.spacing.xs)
                // **行全体を当たり判定にする**——文字の幅しか押せないと、
                // 右端の件数の隣が死んだ領域になる（1-6 で `List` の行に対して
                // 踏んだのと同じ形）。
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(isShowingUnresolved
                        ? Color(nsColor: .selectedContentBackgroundColor) : Color.clear)
            .foregroundStyle(isShowingUnresolved
                             ? Color(nsColor: .alternateSelectedControlTextColor) : Color.primary)
            .help(String(localized: "labelFilter.unresolvedHint", locale: locale))
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
        } else {
            List {
                if model.groups.isEmpty {
                    // [LF-02] ラベルが 1 件も無いライブラリ（走査前・未解決
                    // ばかりの場合）。**`List` ごと差し替えない**［code-review
                    // の指摘］——差し替えるとシェルフ節まで消え、検索語だけで
                    // 保存したシェルフが**見えないうえ辿り着けなくなる**
                    // （メニューバーからの保存は評価やラベルが無くても通る）。
                    Text("labelFilter.noLabels")
                        .font(.system(size: Tokens.fontSize.caption))
                        .foregroundStyle(.secondary)
                } else {
                    ratingSection
                    ForEach(model.groups) { group in
                        groupSection(group)
                    }
                    // [LF-03] ドラッグで並べ替え。順序はライブラリ単位で
                    // 永続化し、全ウインドウで共有する [LG-07][ST-23]。
                    .onMove { indices, destination in
                        var ordered = model.groups
                        ordered.move(fromOffsets: indices, toOffset: destination)
                        Task { await model.reorderGroups(ordered, services: services) }
                    }
                }
                // **フィールドの下**［ユーザー指定］。絞り込みの仲間なので
                // 同じ一覧に入れる——最下部の「未整理のファイル」だけは
                // 絞り込みではなく別の一覧への切り替えなので、外に置いたまま。
                shelfSection
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

    // MARK: - シェルフ [SH-01〜SH-12]

    /// 保存した絞り込み。**ライブラリ表示モードのときだけ**出す [SH-09]。
    ///
    /// **0 件でも見出しは出す**——「まだ 1 つも保存していない」ことと
    /// 「そんな機能は無い」を取り違えさせないため（「未整理のファイル」を
    /// 0 件でも常設するのと同じ判断 [UR3-01]。先行実装〈Calibre の保存済み
    /// 検索〉が、全部消すと区画ごと消えて再起動まで戻らないという形で
    /// 実際に壊していた箇所でもある）。
    @ViewBuilder
    private var shelfSection: some View {
        if isLibraryDisplayMode {
            Section {
                if shelves.shelves.isEmpty {
                    Text("labelFilter.shelfEmpty")
                        .font(.system(size: Tokens.fontSize.caption))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(shelves.shelves) { shelf in
                        shelfRow(shelf)
                    }
                    .onMove { indices, destination in
                        var ordered = shelves.shelves
                        ordered.move(fromOffsets: indices, toOffset: destination)
                        Task { await shelves.reorder(ordered, services: services) }
                    }
                }
                if let failure = shelves.loadFailure {
                    Text(failure)
                        .font(.system(size: Tokens.fontSize.caption))
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                }
            } header: {
                HStack(spacing: Tokens.spacing.xs) {
                    Text("labelFilter.shelfTitle")
                    Spacer()
                    // [SH-01] いまの絞り込みを保存する。**条件が 1 つも
                    // 入っていなければ押せない** [SH-07]——押しても何も
                    // 絞られないシェルフを作らせない。
                    Button {
                        presentSaveShelfDialog()
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .disabled(currentShelfCondition?.isActive != true)
                    .help(String(localized: "labelFilter.shelfSaveHint", locale: locale))
                }
            }
        }
    }

    private func shelfRow(_ shelf: ShelfSummary) -> some View {
        // [SH-08] いまの絞り込みと同じなら選択表示にする。復元した直後に
        // それが分かり、条件を 1 つ変えれば外れることで「もうこのシェルフでは
        // ない」ことも同時に伝わる。
        let isCurrent = currentShelfCondition
            .map { $0 == model.resolvable(shelf.condition) } ?? false
        return Button {
            onApplyShelf(shelf)
        } label: {
            HStack(spacing: Tokens.spacing.xs) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .foregroundStyle(isCurrent ? Color.accentColor : .secondary)
                Text(shelf.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .font(.system(size: Tokens.fontSize.caption))
            // 行全体を当たり判定にする（`unresolvedSection` と同じ理由）。
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fontWeight(isCurrent ? .semibold : .regular)
        .contextMenu {
            // [SH-04] 上書き保存。**いまの絞り込みが空なら出さない**
            // ——空で上書きすると、押しても何も絞らないシェルフが残る。
            if let condition = currentShelfCondition, condition.isActive, !isCurrent {
                Button("labelFilter.shelfUpdate") {
                    run(UpdateShelfCommand(shelfID: shelf.id, shelfName: shelf.name,
                                           previousCondition: shelf.condition,
                                           newCondition: condition,
                                           services: services),
                        "labelFilter.shelfUpdate")
                }
            }
            Button("labelFilter.shelfRenameMenu") {
                ShelfDialogs.presentRename(shelf, services: services, locale: locale)
            }
            Divider()
            // 削除は ⌘Z で戻せる [SH-11] ので確認は挟まない
            // （RA-05 と同じ判断——戻せる操作に毎回 1 枚挟むと、本当に
            // 見てほしい 1 枚まで読み飛ばされる）。
            Button("labelFilter.shelfDelete", role: .destructive) {
                run(DeleteShelfCommand(shelfID: shelf.id, shelfName: shelf.name,
                                       services: services),
                    "labelFilter.shelfDelete")
            }
        }
    }

    /// [SH-01] 保存。実装は `ShelfDialogs`（メニューバーと共有）。
    private func presentSaveShelfDialog() {
        guard let library = model.library, let condition = currentShelfCondition else { return }
        ShelfDialogs.presentSave(libraryID: library.id, condition: condition,
                                 services: services, locale: locale)
    }

    /// 実行は `ShelfDialogs.run`（メニューバーと共有。失敗の提示もそこ）。
    private func run(_ command: some Command, _ whatHappened: String.LocalizationValue) {
        ShelfDialogs.run(command, whatHappened: String(localized: whatHappened, locale: locale))
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
            fieldBand(group)
            // フィールドそのものの手入れ（ラベルの追加・削除・リネーム）は
            // 左ペインから [RL3-04]——本に対する操作（付け外し）は中央ペインと
            // 役割を分ける。編集ウインドウを**そのフィールドを選んだ状態で**開く。
            .contextMenu {
                Button(String(format: String(localized: "labelFilter.editFieldEllipsis",
                                             locale: locale), group.name),
                       systemImage: "tag") {
                    LabelEditorNavigation.open(libraryID: group.libraryID,
                                               groupID: group.id, openWindow: openWindow)
                }
            }
        }
    }

    /// フィールドの帯。**左ペインの幅いっぱいに敷く**［ユーザー要望:
    /// フォルダツリーのハイライトのように］。
    ///
    /// ラベル 1 件ぶんのチップ（内容幅）と違い、フィールドは**この一覧の見出し**
    /// なので、幅いっぱいのほうが階層が読める。選択件数は帯の右端に入れる
    /// ——外に出すと帯の縁が揃わない。
    ///
    /// 文字色は背景から計算する [CO-03][CO-05]——利用者がラベル固有色を選べる
    /// [CO-06] 以上、既定色が一様であることに寄りかからない。
    private func fieldBand(_ group: LabelGroupSummary) -> some View {
        let color = LabelColor(hexLight: group.colorHexLight, hexDark: group.colorHexDark)
        let hex = colorScheme == .dark ? color.hexDark : color.hexLight
        let background = Color(labelHex: hex) ?? Color.secondary.opacity(0.2)
        let foreground = LabelColorPalette.readableForeground(on: hex)
            .flatMap { Color(labelHex: $0) } ?? Color.primary
        return HStack(spacing: Tokens.spacing.xs) {
            Text(group.name)
                .font(.system(size: Tokens.fontSize.caption))
                .lineLimit(1)
            Spacer(minLength: Tokens.spacing.xs)
            if let selected = model.selection[group.id], !selected.isEmpty {
                Text("\(selected.count)")
                    .font(.system(size: Tokens.fontSize.caption))
                    .monospacedDigit()
            }
        }
        .foregroundStyle(foreground)
        .padding(.horizontal, Tokens.spacing.s)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background)
        .clipShape(RoundedRectangle(cornerRadius: Tokens.radius.s))
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
                // ラベルの属するフィールドを選んだ状態で開く [RL3-04]。
                LabelEditorNavigation.open(libraryID: group.libraryID,
                                           groupID: group.id, openWindow: openWindow)
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
    /// ラベルの帯の幅を揃える［ユーザー要望: 一番長い文字列に合わせる］。
    ///
    /// **フィールド名は数えない**——フィールドは幅いっぱいの帯になった
    /// ［ユーザー要望］ので、長いフィールド名がラベルの帯まで広げてしまう。
    private var uniformChipWidth: CGFloat {
        let font = NSFont.systemFont(ofSize: Tokens.fontSize.caption)
        var names: [String] = []
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
