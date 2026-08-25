//
//  ラベル保管庫の整理ウインドウ [LAW-01〜LAW-03][LA-06][LA-08][15.3 節]。
//
//  2 ペイン: 左＝ライブラリ一覧（保管庫が空ならグレーアウト）／
//  右＝アーカイブ済みラベル（グループごとに整理）。
//  `LabelGroupEditorWindow` と同じ `NavigationSplitView` で見た目を揃える [CP-01]。
//
//  ## 触れるのは 3 つだけ［ユーザー判断］
//  戻す [LAW-01]・一括で戻す [LAW-03]・削除（コンテキストメニューのみ）[LAW-02]。
//  改名・統合・色・ピンはラベル編集ウインドウの仕事で、そちらへ飛ぶ導線だけ置く
//  ——**同じ編集を 2 箇所に実装しない**。
//
//  判定（セクションの組み立て・並べ替え・検索・既定のライブラリ）は
//  `LabelVaultModel` が持ち、ここは描くだけ。**この分担を崩さないこと**
//  ——View に判定を書くと `swift test` から触れなくなる。
//
import QooApplication
import QooKit
import SwiftUI

struct LabelVaultWindow: View {
    @Environment(\.locale) private var locale
    @Environment(\.openWindow) private var openWindow
    @State private var model = LabelVaultModel()
    @State private var errorText: String?

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            libraryList
                .navigationSplitViewColumnWidth(min: 170, ideal: 210, max: 280)
        } detail: {
            detailPane
                .navigationSplitViewColumnWidth(min: 420, ideal: 520)
        }
        .navigationTitle(Text("labelVault.windowTitle"))
        .frame(minWidth: 680, minHeight: 460)
        .task { await prepare(preferring: LabelVaultNavigation.shared.pendingLibraryID) }
        .onChange(of: LabelVaultNavigation.shared.pendingLibraryID) {
            guard let pending = LabelVaultNavigation.shared.pendingLibraryID else { return }
            LabelVaultNavigation.shared.pendingLibraryID = nil
            Task { await prepare(preferring: pending) }
        }
        // **起動と同時に状態復元で開かれると、DB の準備より先に `.notReady` で
        // 確定する。** `Window(id:)` は `WindowGroup` と違い
        // `.restorationBehavior(.disabled)` が付いていないので、この経路は実在する
        // ——しかも一度確定すると再試行する契機が無い。準備完了そのものに乗る
        // （設定ウインドウ・ラベル編集ウインドウで踏んだ競合と同じ形だが、
        // あちらは「一覧の変化」に乗っており、**ライブラリが 0 件のまま
        // 準備が終わった場合は救えない**）。
        .onChange(of: LibraryServices.shared.isReady) { _, ready in
            guard ready else { return }
            Task { await prepare(preferring: nil) }
        }
        .onChange(of: model.selectedLibraryID) { _, _ in
            Task { await model.reload() }
        }
        // ⌘Z / ⇧⌘Z は View を通らずに DB を変える。含めないと、取り消した
        // 結果（戻したラベルが保管庫へ戻ってくる等）が画面に出ない
        // ——右ペインの評価・ラベル設定・ラベル編集ウインドウと同じ。
        .onChange(of: CommandStack.shared.operationHistory.count) { _, _ in
            Task { await model.reload() }
        }
    }

    private func prepare(preferring libraryID: LibraryID?) async {
        LabelVaultNavigation.shared.pendingLibraryID = nil
        await model.prepare(services: LibraryServices.shared, preferring: libraryID)
    }

    // MARK: - 左: ライブラリ一覧

    /// **保管庫が空のライブラリはグレーアウトする** [15.3 節]。選べなくは
    /// しない——「空だった」を確かめに来ることがあるため（押せない項目に
    /// するとその確認ができない）。
    private var libraryList: some View {
        List(selection: $model.selectedLibraryID) {
            Section("librarySettings.librariesHeader") {
                ForEach(model.libraries, id: \.id) { library in
                    let count = model.archivedCounts[library.id] ?? 0
                    Label {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(library.displayName)
                            Text(String(format: String(localized: "labelVault.archivedCount",
                                                       locale: locale), count))
                                .font(.system(size: Tokens.fontSize.caption))
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "archivebox")
                            .foregroundStyle(count > 0 ? Color.accentColor : .secondary)
                    }
                    .opacity(count > 0 ? 1 : 0.5)
                    .tag(library.id)
                }
            }
        }
        .overlay {
            if model.libraries.isEmpty {
                ContentUnavailableView {
                    Label("librarySettings.noLibraries", systemImage: "books.vertical")
                } description: {
                    Text("librarySettings.noLibrariesHint")
                }
            }
        }
    }

    // MARK: - 右: アーカイブ済みラベル

    private var detailPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            toolbar
            Divider()
            content
            Divider()
            footer
        }
    }

    /// 並べ替えと検索［ユーザー判断で両方採択］。
    ///
    /// **並べ替えはセクションの中へ効く**——グループをまたいで混ぜると
    /// §15.3 が定める「グループごとに整理」が消える。
    private var toolbar: some View {
        HStack(spacing: Tokens.spacing.m) {
            Picker("", selection: $model.sortOrder) {
                Text("labelEditor.sort.name").tag(LabelGroupEditorModel.SortOrder.name)
                Text("labelEditor.sort.count").tag(LabelGroupEditorModel.SortOrder.fileCount)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 180)

            TextField("labelEditor.searchPlaceholder", text: $model.searchText)
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
            // 縮む側。フッターが伸びたら**一覧が譲る**——譲らないと中身全体が
            // ウインドウからはみ出す（有効化ウインドウで 3 度直している形）。
            list.frame(minHeight: 60)
        }
    }

    private func placeholder(_ key: LocalizedStringKey, systemImage: String) -> some View {
        ContentUnavailableView { Label(key, systemImage: systemImage) }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var list: some View {
        List(selection: $model.selection) {
            ForEach(model.sections) { section in
                Section(section.group.name) {
                    ForEach(section.rows) { row in
                        vaultRow(row, in: section.group)
                            .tag(row.id)
                            .contextMenu { rowMenu(row) }
                    }
                }
            }
        }
        .overlay {
            if model.sections.isEmpty { emptyState }
        }
    }

    /// **「保管庫は空」と「検索に一致しない」を分ける。** 次の一手が違う
    /// ——前者は閉じる、後者は検索語を消す。
    @ViewBuilder
    private var emptyState: some View {
        if model.vaultIsEmpty {
            ContentUnavailableView {
                Label("labelVault.empty", systemImage: "archivebox")
            } description: {
                Text("labelVault.emptyHint")
            }
        } else {
            ContentUnavailableView { Label("labelEditor.noMatches", systemImage: "tag") }
        }
    }

    /// 1 行 [LAW-01]。**行の右端に「保管庫から戻す」ボタン**を置く。
    ///
    /// チップの描画は `LabelRowView` を共有する——保管庫のバッジ・0 件の赤字・
    /// グループ色の継承がそのまま効く。
    private func vaultRow(_ row: LabelGroupEditorModel.Row,
                          in group: LabelGroupSummary) -> some View {
        HStack(spacing: Tokens.spacing.s) {
            LabelRowView(row: row, groupColor: LabelColor(hexLight: group.colorHexLight,
                                                          hexDark: group.colorHexDark))
            Button("labelEditor.restoreFromVault") {
                perform { try await model.restore([row.label]) }
            }
            .buttonStyle(.borderless)
            .font(.system(size: Tokens.fontSize.caption))
            .help("labelVault.restoreHelp")
        }
    }

    /// **削除はコンテキストメニューからのみ** [LAW-02]。押しやすい場所に
    /// 置かないことがこの要件の趣旨なので、フッターにもボタンを置かない。
    @ViewBuilder
    private func rowMenu(_ row: LabelGroupEditorModel.Row) -> some View {
        // **選択には触らない。** `restore(_:)` は引数のラベルだけを見るので、
        // ここで `selection` を潰すと複数選択が壊れる（`LabelListPane` からの
        // 写しだが、あちらは `setSelectedArchived` が `selection` を読むため
        // 代入が要った）。行のインラインボタンとも挙動が揃う。
        Button("labelEditor.restoreFromVault", systemImage: "archivebox") {
            perform { try await model.restore([row.label]) }
        }
        Divider()
        Button("labelEditor.delete", systemImage: "trash", role: .destructive) {
            model.selection = [row.id]
            confirmDelete()
        }
    }

    /// 下端の操作群。**高さを増やさない**——理由が 1 行増えただけで中身全体が
    /// ウインドウからはみ出す（`LabelListPane` と同じ扱い）。
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
                Button("labelVault.editInLabelEditor") { openLabelEditor() }
                    .disabled(model.selectedLibraryID == nil)
                // 一括で戻す [LAW-03]。
                Button("labelEditor.restoreFromVault") {
                    perform { try await model.restoreSelected() }
                }
                .disabled(model.selection.isEmpty)
            }
        }
        .padding(Tokens.spacing.m)
        .layoutPriority(1)
    }

    // MARK: - 導線と確認

    /// ラベル編集ウインドウへ渡す [15.2 節の入口表に 4 つ目として足す]。
    /// 改名・統合・色・ピンはあちらの仕事なので、行き止まりにしない。
    private func openLabelEditor() {
        guard let id = model.selectedLibraryID else { return }
        LabelEditorNavigation.open(libraryID: id, openWindow: openWindow)
    }

    /// **削除は取り消せるが、確認は挟む** [LE-08]。何件のファイルから外れるかを
    /// 見せる——`DeleteLabelsDialog` をラベル編集ウインドウと共有する
    /// （同じ破壊力の操作に確認を 2 種類作らない）。
    private func confirmDelete() {
        let targets = model.selectedLabels
        guard !targets.isEmpty else { return }
        DialogWindowPresenter.shared.present(
            title: String(localized: "labelEditor.deleteTitle", locale: locale)
        ) { _ in
            DeleteLabelsDialog(labels: targets) {
                perform { try await model.deleteSelected() }
            }
        }
    }

    private func perform(_ work: @escaping () async throws -> Void) {
        Task {
            do {
                try await work()
                errorText = nil
            } catch let error as LabelEditError {
                errorText = LabelListPane.message(for: error, locale: locale)
            } catch {
                errorText = error.localizedDescription
            }
        }
    }
}

/// ウインドウを開く要求を受け渡す [15章 §15.3]。
///
/// `LabelEditorNavigation` と同じ形——`Window(id:)` は同じ id で `openWindow` を
/// 呼び直してもビューを作り直さないので、「開いているウインドウが前面に来た
/// だけ」の場合にも要求が届くようにする。
@MainActor
@Observable
final class LabelVaultNavigation {
    static let shared = LabelVaultNavigation()
    var pendingLibraryID: LibraryID?
    private init() {}

    /// 開く経路はここ 1 つ [CP-02]。**フォルダツリーの登録ルート行 2 種と
    /// ラベル編集ウインドウ**から呼ぶ。
    @MainActor
    static func open(libraryID: LibraryID, openWindow: OpenWindowAction) {
        shared.pendingLibraryID = libraryID
        openWindow(id: "labelVault")
    }
}
