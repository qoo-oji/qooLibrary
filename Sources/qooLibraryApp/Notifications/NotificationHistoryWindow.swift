//
//  通知履歴ウインドウ [NW-01〜NW-07][NT-02〜NT-05][15章 §15.11]。
//
//  2 ペイン: 左＝区分と対象ライブラリ [NW-01]／右＝一覧 [NW-02] と詳細 [NW-04]。
//  判定（絞り込み・既読の粒度・期間の解釈）は `NotificationHistoryModel` が
//  持ち、ここは描くだけ——**この分担を崩さないこと**。View に判定を書くと
//  `swift test` から触れなくなる。
//
//  ## 左ペインが 2 つの `List` に分かれている理由［設計判断］
//  NW-01 は「区分**と**対象ライブラリ」を左ペインに置くと定めるが、この 2 つは
//  **独立した絞り込み**である（「エラー かつ ライブラリA」を表せなければならない）。
//  SwiftUI の `List(selection:)` は 1 本につき 1 つの選択しか持てないので、
//  セクションを 2 つ並べると片方を選んだ瞬間にもう片方の選択が外れる
//  ——`List` を 2 本置くのが、要件を満たしたまま独立を保てる唯一の形だった。
//
import QooApplication
import QooKit
import SwiftUI
import UniformTypeIdentifiers

struct NotificationHistoryWindow: View {
    @Environment(\.locale) private var locale
    @Environment(\.openWindow) private var openWindow
    @State private var model = NotificationHistoryModel()
    @State private var errorText: String?

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            sidebar
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 300)
        } detail: {
            detailPane
                .navigationSplitViewColumnWidth(min: 520, ideal: 640)
        }
        .navigationTitle(Text("notifications.windowTitle"))
        .frame(minWidth: 760, minHeight: 480)
        .task { await model.prepare(services: LibraryServices.shared) }
        // **起動と同時に状態復元で開かれると、DB の準備より先に `.notReady` で
        // 確定する。** `Window(id:)` は `WindowGroup` と違い
        // `.restorationBehavior(.disabled)` を持たないのでこの経路は実在し、
        // 一度確定すると再試行の契機が無い（ラベル保管庫で踏んだ形）。
        .onChange(of: LibraryServices.shared.isReady) { _, ready in
            guard ready else { return }
            Task { await model.prepare(services: LibraryServices.shared) }
        }
        // 新しい通知が届いた・既読になった・消えた [NT-01]。開いたままの
        // 一覧が古いものを見続けないようにする。
        .onChange(of: NotificationRouter.shared.historyRevision) { _, _ in
            Task { await model.reload() }
        }
        // 行を選んだらその行だけ既読 [NW-03]。**ウインドウを開いただけでは
        // 既読にしない**——理由は `markSelectedRead()` の doc。
        .onChange(of: model.selection) { _, _ in
            Task { await model.markSelectedRead() }
        }
    }

    // MARK: - 左ペイン [NW-01]

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: categoryBinding) {
                Section("notifications.categoryHeader") {
                    row(for: nil).tag(CategoryTag.all)
                    ForEach(NotificationItem.Category.allCases, id: \.self) { category in
                        row(for: category).tag(CategoryTag.some(category))
                    }
                }
            }
            // 4 行 ＋ 見出し。**固定にする**——伸ばしても情報が増えないのに、
            // 下のライブラリ一覧を押し潰す。
            .frame(height: 132)
            Divider()
            List(selection: libraryBinding) {
                Section("notifications.libraryHeader") {
                    Label("notifications.allLibraries", systemImage: "books.vertical")
                        .tag(LibraryTag.all)
                    ForEach(model.libraries, id: \.uuid) { library in
                        Label(library.displayName, systemImage: "book.closed")
                            .tag(LibraryTag.some(library.uuid))
                    }
                }
            }
        }
    }

    /// 区分の 1 行。件数は出さない——絞り込むたびに数え直すことになり、
    /// しかも「0 件の区分」を見せる意味が薄い。
    private func row(for category: NotificationItem.Category?) -> some View {
        Label(Self.categoryLabel(category), systemImage: Self.categoryIcon(category))
    }

    // 選択のタグ。`nil`（すべて）を `Optional` のまま `tag` に渡すと
    // SwiftUI が「タグ無し」と解釈して選択できないので、明示的な型で包む。
    private enum CategoryTag: Hashable { case all, some(NotificationItem.Category) }
    private enum LibraryTag: Hashable { case all, some(UUID) }

    private var categoryBinding: Binding<CategoryTag?> {
        Binding(
            get: { model.category.map(CategoryTag.some) ?? .all },
            set: { tag in
                // 選択を外す操作（⌘クリック）でも「すべて」へ戻す
                // ——一覧が空になるだけの状態を作らない。
                if case .some(.some(let category)) = tag {
                    model.category = category
                } else {
                    model.category = nil
                }
            })
    }

    private var libraryBinding: Binding<LibraryTag?> {
        Binding(
            get: { model.libraryUUID.map(LibraryTag.some) ?? .all },
            set: { tag in
                if case .some(.some(let uuid)) = tag {
                    model.libraryUUID = uuid
                } else {
                    model.libraryUUID = nil
                }
            })
    }

    // MARK: - 右ペイン

    private var detailPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            toolbar
            Divider()
            content
            Divider()
            detailSection
            Divider()
            footer
        }
    }

    /// 期間とキーワード [NW-05]。
    private var toolbar: some View {
        HStack(spacing: Tokens.spacing.m) {
            Picker("", selection: $model.period) {
                Text("notifications.period.all").tag(NotificationHistoryModel.Period.all)
                Text("notifications.period.today").tag(NotificationHistoryModel.Period.today)
                Text("notifications.period.last7").tag(NotificationHistoryModel.Period.last7Days)
                Text("notifications.period.last30").tag(NotificationHistoryModel.Period.last30Days)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 300)

            TextField("notifications.searchPlaceholder", text: $model.keyword)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 140)
        }
        .padding(Tokens.spacing.m)
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .notReady:
            placeholder("notifications.notReady", systemImage: "externaldrive.badge.xmark")
        case .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let reason):
            placeholder(LocalizedStringKey(reason), systemImage: "exclamationmark.triangle")
        case .ready:
            // 縮む側。詳細とフッターが伸びたら**一覧が譲る**——譲らないと
            // 中身全体がウインドウからはみ出す（有効化ウインドウで 3 度直した形）。
            table.frame(minHeight: 120)
        }
    }

    private func placeholder(_ key: LocalizedStringKey, systemImage: String) -> some View {
        ContentUnavailableView { Label(key, systemImage: systemImage) }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 一覧 [NW-02]。列: 日時 / 区分 / 対象 / 本文。
    private var table: some View {
        Table(model.rows, selection: $model.selection) {
            TableColumn("notifications.column.date") { row in
                Text(Self.dateFormatter.string(from: row.date))
                    .fontWeight(row.isUnread ? .bold : .regular)
            }
            .width(min: 130, ideal: 150)
            TableColumn("notifications.column.category") { row in
                Label(Self.categoryLabel(row.category),
                      systemImage: Self.categoryIcon(row.category))
                    .fontWeight(row.isUnread ? .bold : .regular)
            }
            .width(min: 76, ideal: 92)
            TableColumn("notifications.column.target") { row in
                Text(row.target?.displayName ?? "")
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .fontWeight(row.isUnread ? .bold : .regular)
            }
            .width(min: 90, ideal: 130)
            TableColumn("notifications.column.body") { row in
                // 題と本文を 1 列に畳む。列を 5 つにすると 1 つずつが狭くなり、
                // **どの列も読めない**——一覧で知りたいのは「何が起きたか」の
                // 1 行で、詳しくは下の詳細で読む [NW-04]。
                Text(Self.summary(of: row))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .fontWeight(row.isUnread ? .bold : .regular)
            }
        }
        .contextMenu(forSelectionType: NotificationID.self) { ids in
            Button("notifications.delete", systemImage: "trash", role: .destructive) {
                if !ids.isEmpty { model.selection = ids }
                Task { await model.deleteSelected() }
            }
            .disabled(ids.isEmpty && model.selection.isEmpty)
        }
        .overlay {
            if model.rows.isEmpty { emptyState }
        }
    }

    /// **「履歴が無い」と「一致しない」を分ける。** 次の一手が違う——前者は
    /// 閉じる、後者は絞り込みを緩める。
    @ViewBuilder
    private var emptyState: some View {
        if model.isFiltering {
            ContentUnavailableView {
                Label("notifications.noMatches", systemImage: "bell.slash")
            }
        } else {
            ContentUnavailableView {
                Label("notifications.empty", systemImage: "bell")
            } description: {
                Text("notifications.emptyHint")
            }
        }
    }

    /// 詳細と関連画面への遷移 [NW-04][NT-05]。
    ///
    /// **高さの上限を切る。** 固定サイズのウインドウで可変高さの領域を 2 つ
    /// 持つと、片方が伸びたときにもう片方が黙って潰れる（有効化ウインドウの
    /// 不備メッセージで踏んだ形）。
    @ViewBuilder
    private var detailSection: some View {
        if let detail = model.detail {
            ScrollView {
                VStack(alignment: .leading, spacing: Tokens.spacing.s) {
                    Text(detail.title)
                        .font(.system(size: Tokens.fontSize.body, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    if !detail.body.isEmpty {
                        Text(detail.body).fixedSize(horizontal: false, vertical: true)
                    }
                    if let technical = detail.technicalDetail, !technical.isEmpty {
                        Text(technical)
                            .font(.system(size: Tokens.fontSize.caption))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let path = detail.target?.path, !path.isEmpty {
                        Text(path)
                            .font(.system(size: Tokens.fontSize.caption))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                    links(for: detail)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Tokens.spacing.m)
            }
            .frame(maxHeight: 132)
        }
    }

    /// **押しても何も起きないボタンを残さない。** 対象のライブラリが登録解除
    /// されていれば無効にする——履歴は登録が消えたあとも残る [NT-04]。
    @ViewBuilder
    private func links(for detail: StoredNotification) -> some View {
        if !detail.links.isEmpty {
            HStack(spacing: Tokens.spacing.s) {
                ForEach(detail.links, id: \.actionID) { link in
                    let library = NotificationRouteAction.library(for: detail.target,
                                                                  in: model.libraries)
                    Button(link.title) {
                        guard let library else { return }
                        NotificationRouteAction.perform(actionID: link.actionID,
                                                        libraryID: library.id,
                                                        locale: locale, openWindow: openWindow)
                    }
                    .disabled(!NotificationRouteAction.canPerform(link, target: detail.target,
                                                                  in: model.libraries))
                }
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: Tokens.spacing.s) {
            if let errorText {
                Text(errorText)
                    .font(.system(size: Tokens.fontSize.caption))
                    .foregroundStyle(Color("DangerText"))
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: Tokens.spacing.s) {
                Text(String(format: String(localized: "labelEditor.selectedCount", locale: locale),
                            model.selection.count))
                    .font(.system(size: Tokens.fontSize.caption))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("notifications.markAllRead") {
                    Task { await model.markAllRead() }
                }
                .disabled(NotificationRouter.shared.unreadCount == 0)
                Button("notifications.exportCSV") { exportCSV() }
                    .disabled(model.rows.isEmpty)
                Button("notifications.deleteAll", role: .destructive) { confirmDeleteAll() }
                    .disabled(model.rows.isEmpty)
            }
        }
        .padding(Tokens.spacing.m)
        .layoutPriority(1)
    }

    // MARK: - 操作

    /// 全削除の確認 [NW-06]。
    ///
    /// **Undo に載せていない**（`NotificationHistoryModel.deleteSelected` の doc）
    /// ので、取り返しのつかない側の安全網はこの確認だけ。**選択削除には
    /// 挟まない**——選んだ数件を消すのは可逆でなくとも被害が小さく、
    /// 毎回確認を出すと本当に見てほしい 1 枚まで読み飛ばされる。
    private func confirmDeleteAll() {
        DialogWindowPresenter.shared.present(
            title: String(localized: "notifications.deleteAllTitle", locale: locale)
        ) { _ in
            DeleteAllNotificationsDialog(count: model.rows.count) {
                Task { await model.deleteAll() }
            }
        }
    }

    /// CSV 書き出し [NW-07]。**いま一覧に出ているものを書き出す**
    /// ——絞り込んでから書き出せないと棚卸しに使えない。
    private func exportCSV() {
        let rows = model.rows
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "qooLibrary-notifications.csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let header = [
            String(localized: "notifications.column.date", locale: locale),
            String(localized: "notifications.column.category", locale: locale),
            String(localized: "notifications.column.target", locale: locale),
            String(localized: "notifications.column.title", locale: locale),
            String(localized: "notifications.column.body", locale: locale),
            String(localized: "notifications.column.detail", locale: locale),
        ]
        let formatter = Self.csvDateFormatter
        let data = NotificationCSV.encode(
            rows, header: header,
            categoryName: { Self.categoryName($0, locale: locale) },
            dateFormatter: { formatter.string(from: $0) })
        do {
            try data.write(to: url, options: .atomic)
            errorText = nil
        } catch {
            errorText = error.localizedDescription
        }
    }

    // MARK: - 表示のための小道具

    /// 区分の表示名の**鍵**。`nil` は「すべて」。
    ///
    /// 文字列そのものではなく鍵を返すのは、`Label` は `LocalizedStringKey` を、
    /// CSV は `String(localized:locale:)` を要求するため——**同じ綴りを 2 箇所に
    /// 書かない**ためにここへ集約している。
    static func categoryKey(_ category: NotificationItem.Category?) -> String {
        switch category {
        case .none: return "notifications.category.all"
        case .some(.error): return "notifications.category.error"
        case .some(.warning): return "notifications.category.warning"
        case .some(.info): return "notifications.category.info"
        }
    }

    static func categoryLabel(_ category: NotificationItem.Category?) -> LocalizedStringKey {
        LocalizedStringKey(categoryKey(category))
    }

    static func categoryName(_ category: NotificationItem.Category, locale: Locale) -> String {
        String(localized: String.LocalizationValue(categoryKey(category)), locale: locale)
    }

    static func categoryIcon(_ category: NotificationItem.Category?) -> String {
        switch category {
        case .none: return "tray.full"
        case .some(.error): return "exclamationmark.octagon"
        case .some(.warning): return "exclamationmark.triangle"
        case .some(.info): return "info.circle"
        }
    }

    /// 一覧の「本文」列に出す 1 行。題と本文を「 — 」で繋ぐ。
    /// **本文の改行はここで潰す**——`lineLimit(1)` は最初の行しか出さないので、
    /// 潰さないと 2 行目以降（走査結果の内訳など）が読めなくなる。
    static func summary(of row: StoredNotification) -> String {
        let body = row.body
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        guard !body.isEmpty else { return row.title }
        guard !row.title.isEmpty else { return body }
        return "\(row.title) — \(body)"
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    /// CSV は**並べ替えできる形**にする。`dateStyle` に任せるとロケールごとに
    /// 桁の順序が変わり、表計算で日付として読めないことがある。
    private static let csvDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()
}

/// 全削除の確認 [NW-06]。
struct DeleteAllNotificationsDialog: View {
    @Environment(\.locale) private var locale
    @Environment(\.dialogDismiss) private var dismiss

    let count: Int
    let onConfirm: () -> Void

    var body: some View {
        DialogScaffold(
            width: 420,
            confirm: DialogButton(title: String(localized: "notifications.deleteAll", locale: locale),
                                  role: .destructive) {
                onConfirm()
                dismiss()
            },
            cancel: DialogButton(title: String(localized: "common.cancel", locale: locale),
                                 role: .cancel) { dismiss() }
        ) {
            VStack(alignment: .leading, spacing: Tokens.spacing.s) {
                Text(String(format: String(localized: "notifications.deleteAllBody", locale: locale),
                            count))
                    .fixedSize(horizontal: false, vertical: true)
                Text("notifications.deleteAllIrreversible")
                    .font(.system(size: Tokens.fontSize.caption))
                    .foregroundStyle(Color("DangerText"))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// ウインドウを開く要求を受け渡す [15章 §15.11]。
///
/// 開く経路は**ステータスバーの通知バッジ** [NT-02] と**ウインドウメニュー**
/// [13章 §13.7.2] の 2 つ。`LabelVaultNavigation` と同じ形。
@MainActor
enum NotificationHistoryNavigation {
    static func open(openWindow: OpenWindowAction) {
        openWindow(id: "notificationHistory")
    }
}
