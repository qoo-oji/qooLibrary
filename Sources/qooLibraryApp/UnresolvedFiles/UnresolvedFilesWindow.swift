//
//  ファイル名フォーマットに一致しないファイルの整理ウインドウ
//  [AL-30〜AL-34][UR-01〜UR-06][15.6 節]。
//
//  **表示は「ファイル名フォーマットに一致しないファイル」**［ユーザー判断、
//  2026-08］。要件 ID・`unresolvedFile` テーブル・型名は「未解決」のまま
//  ——要件との対応が切れると追えなくなる（「孤立ファイル」→「見つからない
//  ファイル」[15.7] と同じ扱い）。
//
//  3 ペイン: 左＝ライブラリ一覧（未解決件数）／中央＝未解決ファイルの一覧／
//  右＝選択したファイルのラベル。`LabelGroupEditorWindow` と同じ
//  `NavigationSplitView` で見た目を揃える [CP-01]。
//
//  ## 右ペインは右ペイン（インスペクタ）と同じ実装を共有する
//  ラベルの付け外し [UR-03][UR-06] は `LabelEditorModel` ＋
//  `InspectorLabelSection` がそのまま使える——三状態のチェックボックス
//  [RP-02] が「複数選択して同じラベルを一括で付ける」[AL-32] そのものなので、
//  ここに別の UI を作る理由が無い。**同じ操作に独立した経路を 2 つ作らない。**
//
//  ## 「見つからないファイル」（§15.7）との違い
//  形は似ているが、**オフラインでも一覧できて書ける**。未解決は
//  「ファイル名がどのフォーマットにも一致しなかった」という照合の結果で、
//  実体を 1 度も見ない——孤立 [OR2-06] とは前提が逆なので、着脱に追随して
//  一覧を伏せる配線は**入れない**（写すときは何を守っているかまで写す）。
//
//  判定（絞り込み・既定のライブラリ・500 件超の案内）は `UnresolvedFileModel`
//  が持ち、ここは描くだけ。**この分担を崩さないこと**——View に判定を書くと
//  `swift test` から触れなくなる。
//
import QooApplication
import QooKit
import SwiftUI

struct UnresolvedFilesWindow: View {
    @Environment(\.locale) private var locale
    @Environment(\.openWindow) private var openWindow
    @State private var model = UnresolvedFileModel()
    @State private var labels = LabelEditorModel()
    @State private var errorText: String?
    /// ラベルを書き換えたら一覧を読み直す（件数と印が動く）。
    @State private var labelRevision = 0

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            libraryList
                .navigationSplitViewColumnWidth(min: 170, ideal: 210, max: 280)
        } content: {
            filePane
                .navigationSplitViewColumnWidth(min: 380, ideal: 460)
        } detail: {
            labelPane
                .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 420)
        }
        .navigationTitle(Text("unresolvedFiles.windowTitle"))
        .frame(minWidth: 900, minHeight: 480)
        .task { await prepare(preferring: UnresolvedFilesNavigation.shared.pendingLibraryID) }
        .onChange(of: UnresolvedFilesNavigation.shared.pendingLibraryID) {
            guard let pending = UnresolvedFilesNavigation.shared.pendingLibraryID else { return }
            UnresolvedFilesNavigation.shared.pendingLibraryID = nil
            Task { await prepare(preferring: pending) }
        }
        // **起動と同時に状態復元で開かれると、DB の準備より先に `.notReady` で
        // 確定する。** `Window(id:)` は `.restorationBehavior(.disabled)` を
        // 持たないのでこの経路は実在し、一度確定すると再試行の契機が無い
        // ——準備完了そのものに乗る（`OrphanCleanupWindow` と同じ）。
        .onChange(of: LibraryServices.shared.isReady) { _, ready in
            guard ready else { return }
            Task { await prepare(preferring: nil) }
        }
        .onChange(of: model.selectedLibraryID) { _, _ in
            // 直近の失敗も捨てる（`lastRematch` はモデル側で捨てている）
            // ——切り替えた先のライブラリの下端に残ると、そちらで起きたように読める。
            errorText = nil
            Task { await model.reload() }
        }
        // 「無視したものも表示」の切り替えは DB から引き直す [UR2-04]。
        .onChange(of: model.needsReload) { _, needs in
            guard needs else { return }
            Task { await model.reload() }
        }
        // ⌘Z / ⇧⌘Z は View を通らずに DB を変える。含めないと、取り消した
        // 結果（無視が戻る・ラベルが外れる）が画面に出ない。
        .onChange(of: CommandStack.shared.operationHistory.count) { _, _ in
            Task { await model.reload() }
        }
        // 選択が変わったら右ペインを読み直す。**URL ではなく DB の行から
        // 読む**——実体を stat しないのでオフラインでも動く（上記）。
        .task(id: LabelLoadKey(fileIDs: model.selection.sorted { $0.rawValue < $1.rawValue },
                               libraryID: model.selectedLibraryID,
                               commandRevision: CommandStack.shared.operationHistory.count,
                               revision: labelRevision)) {
            // **手でラベルを付けたら「以後無視する」も立てる** [AL-30]①③
            // ［ユーザー判断、2026-08］。`isUnresolved` はパース結果しか見ない
            // [EM-03] ので、これが無いと①で片付けたファイルが一覧に残り続け、
            // ③を続けて使うしか無くなる。**同じ Undo 単位**で走る [UD-04]。
            //
            // **右ペイン（インスペクタ）では設定しない**：蔵書のどのファイルに
            // ラベルを付けても未解決の判断が動いてはならない。
            labels.onAssign = { model.ignoreCommandForAssigned($0) }
            await labels.load(rows: model.selectedFiles.map(\.row),
                              library: model.selectedLibrary,
                              services: LibraryServices.shared)
        }
    }

    /// 右ペインを読み直す鍵。
    private struct LabelLoadKey: Hashable {
        let fileIDs: [FileID]
        let libraryID: LibraryID?
        let commandRevision: Int
        let revision: Int
    }

    private func prepare(preferring libraryID: LibraryID?) async {
        UnresolvedFilesNavigation.shared.pendingLibraryID = nil
        await model.prepare(services: LibraryServices.shared, preferring: libraryID)
    }

    // MARK: - 左: ライブラリ一覧 [UR-02]

    /// **未解決が 0 件のライブラリはグレーアウトする**（保管庫・孤立側と同じ扱い）。
    /// 選べなくはしない——「無かった」を確かめに来ることがある。
    ///
    /// **オフラインでも件数を出す**（孤立側との違い）。実体を見ない判断なので、
    /// 接続していなくても数字が正しい。
    private var libraryList: some View {
        List(selection: $model.selectedLibraryID) {
            Section("librarySettings.librariesHeader") {
                ForEach(model.libraries, id: \.id) { library in
                    let count = model.unresolvedCounts[library.id]?.pending ?? 0
                    Label {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(library.displayName)
                            Text(String(format: String(localized: "unresolvedFiles.count",
                                                       locale: locale), count))
                                .font(.system(size: Tokens.fontSize.caption))
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "questionmark.square.dashed")
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

    // MARK: - 中央: 未解決ファイルの一覧 [UR-01]

    private var filePane: some View {
        VStack(alignment: .leading, spacing: 0) {
            toolbar
            Divider()
            if model.offersFormatFirst { bulkBanner; Divider() }
            content
            Divider()
            footer
        }
    }

    private var toolbar: some View {
        HStack(spacing: Tokens.spacing.m) {
            TextField("unresolvedFiles.searchPlaceholder", text: $model.searchText)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 160)
            Spacer(minLength: Tokens.spacing.s)
            // 無視したものを戻す唯一の手段 [UR2-04]。**既定では出さない**
            // ——無視は「一覧から消したい」という意思表示なので。
            Toggle("unresolvedFiles.showIgnored", isOn: $model.includeIgnored)
                .toggleStyle(.checkbox)
                .font(.system(size: Tokens.fontSize.caption))
        }
        .padding(Tokens.spacing.m)
    }

    /// 500 件を超えたときの案内 [UR2-08][OB-08]。
    ///
    /// **1 件ずつラベルを付けて片付けられる規模ではない。** その量の未解決は
    /// ほぼ確実に「フォーマットが 1 本足りない」という単一の原因から来ている
    /// ので、最初の選択肢としてフォーマットの追加を出す。
    private var bulkBanner: some View {
        HStack(spacing: Tokens.spacing.m) {
            Image(systemName: "lightbulb")
                .foregroundStyle(.secondary)
            Text(String(format: String(localized: "unresolvedFiles.bulkHint", locale: locale),
                        model.files.count))
                .font(.system(size: Tokens.fontSize.caption))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Tokens.spacing.s)
            Button("unresolvedFiles.addFormat") { presentFormatEditor() }
        }
        .padding(.horizontal, Tokens.spacing.m)
        .padding(.vertical, Tokens.spacing.s)
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
            ForEach(model.visibleFiles) { file in
                row(file)
                    .tag(file.row.id)
                    .contextMenu { rowMenu(file) }
            }
        }
        .overlay {
            if model.visibleFiles.isEmpty { emptyState }
        }
    }

    /// **「未解決はありません」と「検索に一致しない」を分ける。** 次の一手が
    /// 違う——前者は閉じる、後者は検索語を消す。
    @ViewBuilder
    private var emptyState: some View {
        if model.hasNoUnresolved {
            ContentUnavailableView {
                Label("unresolvedFiles.empty", systemImage: "checkmark.circle")
            } description: {
                // **「すべて一致した」と「無視しただけ」を分ける。**混ぜると、
                // 無視して空にしただけなのに「すべて一致しています」と
                // 事実でないことを言う（実機検証で見つけた）。
                if model.hiddenIgnoredCount > 0 {
                    Text(String(format: String(localized: "unresolvedFiles.emptyIgnoredHint",
                                               locale: locale), model.hiddenIgnoredCount))
                } else {
                    Text("unresolvedFiles.emptyHint")
                }
            }
        } else {
            ContentUnavailableView {
                Label("unresolvedFiles.noMatches", systemImage: "questionmark.square.dashed")
            }
        }
    }

    /// 1 行 [UR-01]。
    ///
    /// 出すのは**なぜ当たらないかの手がかりになるもの**——名前・場所・
    /// 「型が違う」印 [TY-01]・無視の印。
    private func row(_ file: UnresolvedFile) -> some View {
        HStack(spacing: Tokens.spacing.m) {
            VStack(alignment: .leading, spacing: 1) {
                Text(file.row.filename)
                    .foregroundStyle(file.isIgnored ? .secondary : .primary)
                HStack(spacing: Tokens.spacing.s) {
                    Text(file.row.relativePath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    // **未解決の理由ではない**が、当たらない原因としては強い
                    // 手がかり——先頭の印がライブラリタイプ名と食い違っている。
                    if file.libraryTypeMismatch {
                        Text("unresolvedFiles.typeMismatch")
                    }
                }
                .font(.system(size: Tokens.fontSize.caption))
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: Tokens.spacing.s)
            if file.isIgnored {
                Image(systemName: "eye.slash")
                    .foregroundStyle(.secondary)
                    .help(Text("unresolvedFiles.ignoredBadge"))
            }
        }
        .padding(.vertical, 2)
        .opacity(file.isIgnored ? 0.55 : 1)
    }

    @ViewBuilder
    private func rowMenu(_ file: UnresolvedFile) -> some View {
        if file.isIgnored {
            Button("unresolvedFiles.unignore", systemImage: "eye") {
                // **選択を潰さない**——行のメニューから 1 件だけ操作しても、
                // 複数選択したままにしておきたい（保管庫で直した形）。
                perform { try await model.setIgnored([file], false) }
            }
        } else {
            Button("unresolvedFiles.ignore", systemImage: "eye.slash") {
                perform { try await model.setIgnored([file], true) }
            }
        }
    }

    /// 下端の操作群。**高さを増やさない**——理由が 1 行増えただけで中身全体が
    /// ウインドウからはみ出す（`OrphanCleanupWindow` と同じ扱い）。
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
            } else if let outcome = model.lastRematch {
                Text(String(format: String(localized: "unresolvedFiles.rematchResult",
                                           locale: locale),
                            outcome.resolved, outcome.attempted))
                    .font(.system(size: Tokens.fontSize.caption))
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: Tokens.spacing.s) {
                Text(String(format: String(localized: "labelEditor.selectedCount", locale: locale),
                            model.selection.count))
                    .font(.system(size: Tokens.fontSize.caption))
                    .foregroundStyle(.secondary)
                Spacer()
                // 一括で無視する／戻す [UR-05][UR-06]。**選択が空なら
                // 「無視する」側を出す**——何も選んでいない画面の一番目立つ
                // 位置に、まれで逆向きの操作を座らせない（保管庫で直した形）。
                if model.selectedFiles.allSatisfy(\.isIgnored), !model.selection.isEmpty {
                    Button("unresolvedFiles.unignore") {
                        perform { try await model.setSelectedIgnored(false) }
                    }
                } else {
                    Button("unresolvedFiles.ignore") {
                        perform { try await model.setSelectedIgnored(true) }
                    }
                    .disabled(model.selection.isEmpty)
                }
                Button("unresolvedFiles.addFormat") { presentFormatEditor() }
                    .disabled(model.selectedLibrary == nil)
                // [AL-34]。**Undo に積まない**——走査と同じ収束型の処理で、
                // 戻したいのは普通「足したフォーマット」のほうである。
                Button("unresolvedFiles.rematch") {
                    perform { try await model.rematch() }
                }
                .disabled(model.selectedLibrary == nil)
            }
        }
        .padding(Tokens.spacing.m)
        .layoutPriority(1)
    }

    // MARK: - 右: ラベル [UR-03][UR-06]

    private var labelPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Tokens.spacing.m) {
                if model.selection.isEmpty {
                    ContentUnavailableView {
                        Label("unresolvedFiles.noSelection", systemImage: "tag")
                    } description: {
                        Text("unresolvedFiles.noSelectionHint")
                    }
                } else {
                    InspectorLabelSection(model: labels) { labelRevision &+= 1 }
                }
            }
            .padding(Tokens.spacing.m)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - フォーマットの追加 [UR-04]

    /// **その場でフォーマットを足して、続けて再マッチングする** [UR-04][AL-34]。
    ///
    /// 編集ダイアログは設定ウインドウと同じ `FilenameFormatEditorDialog` を
    /// 使う——予約語パレットもサンプル試行も検証も同じものが要るので、
    /// ここに別の編集 UI を作らない [CP-01]。
    private func presentFormatEditor() {
        Task {
            do {
                guard let draft = try await model.settingsDraft() else { return }
                DialogWindowPresenter.shared.present(
                    title: String(localized: "librarySettings.filenameFormats.editorTitle", locale: locale)
                ) { _ in
                    FilenameFormatEditorDialog(source: "", draft: draft) { source in
                        perform { try await model.addFormat(source: source) }
                    }
                }
            } catch {
                errorText = error.localizedDescription
            }
        }
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

/// ウインドウを開く要求を受け渡す [15章 §15.6]。
///
/// `OrphanCleanupNavigation` と同じ形——`Window(id:)` は同じ id で
/// `openWindow` を呼び直してもビューを作り直さないので、「開いているウインドウ
/// が前面に来ただけ」の場合にも要求が届くようにする。
@MainActor
@Observable
final class UnresolvedFilesNavigation {
    static let shared = UnresolvedFilesNavigation()
    var pendingLibraryID: LibraryID?
    private init() {}

    /// 開く経路はここ 1 つ [CP-02]。**フォルダツリーの登録ルート行 2 種**から
    /// 呼ぶ——通常の行と縮退した行は別々に配線が要る（このリポジトリが
    /// 5 度取り残した形）。
    @MainActor
    static func open(libraryID: LibraryID, openWindow: OpenWindowAction) {
        shared.pendingLibraryID = libraryID
        openWindow(id: "unresolvedFiles")
    }
}
