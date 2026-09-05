//
//  操作履歴ウインドウ [OH-01〜OH-06][HS-01〜HS-04][15章 §15.13]。
//
//  2 ペイン: 左＝種別 [OH-02]／右＝一覧 [OH-01] と詳細 [OH-04]。
//  判定（絞り込み・期間の解釈・空状態の出し分け）は `OperationLogModel` が
//  持ち、ここは描くだけ——**この分担を崩さないこと**。View に判定を書くと
//  `swift test` から触れなくなる。
//
//  ## 通知履歴（§15.11）と形が違う点
//  - **左ペインが 1 本。** あちらは区分と対象ライブラリの 2 軸だが、こちらは
//    ファイル操作のコマンドが自分のライブラリを知らないので軸が 1 つしかない
//    （`OperationLogEntry.libraryUUID` のコメント参照）。
//  - **削除が無い。** 「読み終えた知らせを捨てる」あちらと違い、こちらは
//    「何をしたか」の記録である（`OperationLogStore` の型コメント参照）。
//
import QooApplication
import QooKit
import SwiftUI
import UniformTypeIdentifiers

struct OperationHistoryWindow: View {
    @Environment(\.locale) private var locale
    @State private var model = OperationLogModel()
    @State private var errorText: String?

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            sidebar
                .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 300)
        } detail: {
            detailPane
                .navigationSplitViewColumnWidth(min: 520, ideal: 660)
        }
        .navigationTitle(Text("operations.windowTitle"))
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
        // 新しい操作が記録された [HS-01]。開いたままの一覧が古いものを
        // 見続けないようにする。
        .onChange(of: OperationLogRecorder.shared.revision) { _, _ in
            Task { await model.reload() }
        }
    }

    // MARK: - 左ペイン [OH-02]

    private var sidebar: some View {
        List(selection: groupBinding) {
            Section("operations.kindHeader") {
                row(for: nil).tag(GroupTag.all)
                ForEach(OperationLogGroup.allCases) { group in
                    row(for: group).tag(GroupTag.some(group))
                }
            }
        }
    }

    /// 種別の 1 行。件数は出さない——絞り込むたびに数え直すことになり、
    /// しかも「0 件の種別」を見せる意味が薄い（通知履歴と同じ判断）。
    private func row(for group: OperationLogGroup?) -> some View {
        Label(Self.groupLabel(group), systemImage: Self.groupIcon(group))
    }

    // 選択のタグ。`nil`（すべて）を `Optional` のまま `tag` に渡すと
    // SwiftUI が「タグ無し」と解釈して選択できないので、明示的な型で包む。
    private enum GroupTag: Hashable { case all, some(OperationLogGroup) }

    private var groupBinding: Binding<GroupTag?> {
        Binding(
            get: { model.group.map(GroupTag.some) ?? .all },
            set: { tag in
                // 選択を外す操作（⌘クリック）でも「すべて」へ戻す
                // ——一覧が空になるだけの状態を作らない。
                if case .some(.some(let group)) = tag {
                    model.group = group
                } else {
                    model.group = nil
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

    /// 期間とキーワード [OH-02]。
    private var toolbar: some View {
        HStack(spacing: Tokens.spacing.m) {
            Picker("", selection: $model.period) {
                Text("operations.period.all").tag(OperationLogModel.Period.all)
                Text("operations.period.today").tag(OperationLogModel.Period.today)
                Text("operations.period.last7").tag(OperationLogModel.Period.last7Days)
                Text("operations.period.last30").tag(OperationLogModel.Period.last30Days)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 300)

            TextField("operations.searchPlaceholder", text: $model.keyword)
                .editableFieldChrome()
                .frame(minWidth: 140)
        }
        .padding(Tokens.spacing.m)
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .notReady:
            placeholder("operations.notReady", systemImage: "externaldrive.badge.xmark")
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

    /// 一覧 [OH-01]。列: 日時 / 種別 / 対象 / 内容。
    private var table: some View {
        Table(model.rows, selection: $model.selection) {
            TableColumn("operations.column.date") { row in
                Text(Self.dateFormatter.string(from: row.date))
            }
            .width(min: 130, ideal: 150)
            TableColumn("operations.column.kind") { row in
                Label(Self.kindLabel(row.kind), systemImage: Self.groupIcon(row.kind.group))
            }
            .width(min: 88, ideal: 108)
            TableColumn("operations.column.target") { row in
                // **1 件ならファイル名、複数なら件数** [OH-01]。絶対パスを
                // そのまま並べると列が読めない——全体は下の詳細で見る。
                Text(row.targetsDisplayName(pluralized: { count in
                    String(format: String(localized: "operations.targetCount", locale: locale),
                           count)
                }))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .width(min: 90, ideal: 140)
            TableColumn("operations.column.summary") { row in
                // **改行はここで潰す**——`lineLimit(1)` は最初の行しか出さない
                // ので、潰さないと 2 行目以降が読めなくなる（通知履歴と同じ）。
                Text(row.summary.replacingOccurrences(of: "\n", with: " "))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
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
                Label("operations.noMatches", systemImage: "clock.badge.questionmark")
            }
        } else {
            ContentUnavailableView {
                Label("operations.empty", systemImage: "clock")
            } description: {
                Text("operations.emptyHint")
            }
        }
    }

    /// 詳細 [OH-04]。
    ///
    /// **高さの上限を切る。** 固定サイズのウインドウで可変高さの領域を 2 つ
    /// 持つと、片方が伸びたときにもう片方が黙って潰れる（有効化ウインドウの
    /// 不備メッセージで踏んだ形）。
    @ViewBuilder
    private var detailSection: some View {
        if let detail = model.detail {
            ScrollView {
                VStack(alignment: .leading, spacing: Tokens.spacing.s) {
                    Text(detail.summary)
                        .font(.system(size: Tokens.fontSize.body, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    if let text = detail.detail, !text.isEmpty {
                        Text(text)
                            .font(.system(size: Tokens.fontSize.caption))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    // **対象は全部並べる。** 一覧の列は読みやすさのために
                    // 畳んでいるので、「どのファイルか」を確かめる場所が
                    // ここしかない。
                    ForEach(detail.targets, id: \.self) { path in
                        Text(path)
                            .font(.system(size: Tokens.fontSize.caption))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    if detail.truncatedTargets > 0 {
                        Text(String(format: String(localized: "operations.truncatedTargets",
                                                   locale: locale), detail.truncatedTargets))
                            .font(.system(size: Tokens.fontSize.caption))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Tokens.spacing.m)
            }
            .frame(maxHeight: 132)
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
                Text(String(format: String(localized: "operations.rowCount", locale: locale),
                            model.rows.count))
                    .font(.system(size: Tokens.fontSize.caption))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("operations.exportCSV") { exportCSV() }
                    .disabled(model.rows.isEmpty)
            }
        }
        .padding(Tokens.spacing.m)
        .layoutPriority(1)
    }

    // MARK: - 操作

    /// CSV 書き出し [OH-02]。**いま一覧に出ているものを書き出す**
    /// ——絞り込んでから書き出せないと棚卸しに使えない。
    private func exportCSV() {
        let rows = model.rows
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "qooLibrary-operations.csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let header = [
            String(localized: "operations.column.date", locale: locale),
            String(localized: "operations.column.kind", locale: locale),
            String(localized: "operations.column.summary", locale: locale),
            String(localized: "operations.column.target", locale: locale),
            String(localized: "operations.column.detail", locale: locale),
        ]
        let formatter = Self.csvDateFormatter
        let data = OperationLogCSV.encode(
            rows, header: header,
            kindName: { Self.kindName($0, locale: locale) },
            dateFormatter: { formatter.string(from: $0) },
            truncationNote: {
                String(format: String(localized: "operations.truncatedTargets", locale: locale), $0)
            })
        do {
            try data.write(to: url, options: .atomic)
            errorText = nil
        } catch {
            errorText = error.localizedDescription
        }
    }

    // MARK: - 表示のための小道具

    /// 種別の表示名の**鍵**。`nil` は「すべて」。
    ///
    /// 文字列そのものではなく鍵を返すのは、`Label` は `LocalizedStringKey` を、
    /// CSV は `String(localized:locale:)` を要求するため——**同じ綴りを 2 箇所に
    /// 書かない**ためにここへ集約している（通知履歴と同じ形）。
    static func groupKey(_ group: OperationLogGroup?) -> String {
        switch group {
        case .none: return "operations.kind.all"
        case .some(.executed): return "operations.kind.executed"
        case .some(.undone): return "operations.kind.undone"
        case .some(.unsuccessful): return "operations.kind.unsuccessful"
        case .some(.cancelled): return "operations.kind.cancelled"
        case .some(.scan): return "operations.kind.scan"
        }
    }

    static func groupLabel(_ group: OperationLogGroup?) -> LocalizedStringKey {
        LocalizedStringKey(groupKey(group))
    }

    static func groupIcon(_ group: OperationLogGroup?) -> String {
        switch group {
        case .none: return "clock"
        case .some(.executed): return "checkmark.circle"
        case .some(.undone): return "arrow.uturn.backward"
        case .some(.unsuccessful): return "exclamationmark.triangle"
        case .some(.cancelled): return "xmark.circle"
        case .some(.scan): return "arrow.clockwise"
        }
    }

    /// 一覧と CSV に出す種別の名前。**区画より細かい**——「取り消し」と
    /// 「部分的に取り消し」は結果が違うので、行では区別できないと困る。
    static func kindKey(_ kind: OperationLogKind) -> String {
        switch kind {
        case .executed: return "operations.kind.executed"
        case .failed: return "operations.kind.failed"
        case .cancelled: return "operations.kind.cancelled"
        case .undone: return "operations.kind.undone"
        case .undonePartially: return "operations.kind.undonePartially"
        case .undoFailed: return "operations.kind.undoFailed"
        case .redone: return "operations.kind.redone"
        case .redoFailed: return "operations.kind.redoFailed"
        case .scan: return "operations.kind.scan"
        }
    }

    static func kindLabel(_ kind: OperationLogKind) -> LocalizedStringKey {
        LocalizedStringKey(kindKey(kind))
    }

    static func kindName(_ kind: OperationLogKind, locale: Locale) -> String {
        String(localized: String.LocalizationValue(kindKey(kind)), locale: locale)
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

/// ウインドウを開く要求を受け渡す [15章 §15.13]。
///
/// 開く経路は**ウインドウメニュー** [13章 §13.7.2] と**通知履歴ウインドウ**
/// [OH-06] の 2 つ。`NotificationHistoryNavigation` と同じ形。
@MainActor
enum OperationHistoryNavigation {
    static func open(openWindow: OpenWindowAction) {
        openWindow(id: "operationHistory")
    }
}
