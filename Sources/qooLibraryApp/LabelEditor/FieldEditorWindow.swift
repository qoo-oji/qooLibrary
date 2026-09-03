//
//  ラベルフィールドの編集ウインドウ [LE-01〜LE-12][15.2 節]。
//
//  3 ペイン: 左＝ライブラリ一覧／中央＝ラベルフィールド一覧／右＝ラベル一覧。
//  `LibrarySettingsWindow` と同じ `NavigationSplitView` で見た目を揃える [CP-01]。
//
//  ## 中央ペインは設定ウインドウと同じ実装［ユーザー判断］
//  フィールドの改名・予約語紐づけ [LE-01][LE-02] は `LibraryFieldsSettingsView`
//  が持っており、ここはそれに選択を足して埋め込むだけ。**同じ編集を 2 箇所に
//  書かない**——このリポジトリはそれで 3 度取り残しを作っている。
//
//  ## 保存の意味が 2 通りある（承知のうえ）
//  中央（フィールド）は**草案を編集して保存**する形（保存で `settingsRevision` が
//  上がり、再スキャンを促す）。右（ラベル）は**即座に DB へ書いて ⌘Z で戻す**形。
//  混ざると分かりにくいので、中央には保存ボタンと未保存の印を必ず出す。
//
import QooApplication
import QooKit
import SwiftUI

struct FieldEditorWindow: View {
    @Environment(\.locale) private var locale
    @Environment(\.openWindow) private var openWindow
    @State private var model = FieldEditorModel()
    @State private var settings = LibrarySettingsModel()
    /// 中央ペインで選んでいるフィールド（草案側の識別子）。
    @State private var selectedFieldDraftID: UUID?

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            libraryList
                .navigationSplitViewColumnWidth(min: 150, ideal: 180, max: 260)
        } content: {
            groupPane
                // **中央は共有した `LibraryFieldsSettingsView` が入る。**
                // あの表は 参照名 90 ＋ 名前 120 ＋ 色 24 ＋ 予約語 130 ＋
                // 自動付与 60 ＋ − 22 と間隔で 500pt 強を要る[実測]ので、
                // 設定ウインドウの詳細ペイン（min 420）並みの幅を確保する
                // ——狭いと表がペインからはみ出し、**分割ビュー全体が
                // ウインドウより広くなって左右が見切れる**（実機で踏んだ）。
                .navigationSplitViewColumnWidth(min: 480, ideal: 580, max: 720)
        } detail: {
            LabelListPane(model: model)
                .navigationSplitViewColumnWidth(min: 380, ideal: 460)
        }
        .navigationTitle(Text("labelEditor.windowTitle"))
        // **保管庫の整理ウインドウへの導線は無くなった** [§19.12]。非表示の
        // ラベルはこのウインドウの一覧にそのまま並ぶ [LA3-03] ので、別の場所へ
        // 見に行く必要が無い。
        .frame(minWidth: 1040, minHeight: 540)
        // **読んだら消費する（`nil` に戻す）。** 残したままだと、次に同じ
        // ライブラリで開く要求が来ても `.onChange` が変化を見ず、フィールドの
        // 選択 [RL3-04] が適用されない。
        .task {
            let pending = LabelEditorNavigation.shared.pendingLibraryID
            LabelEditorNavigation.shared.pendingLibraryID = nil
            await prepare(preferring: pending)
        }
        // 起動と同時に状態復元で開かれると、DB の準備より先に「未選択」で
        // 確定する——設定ウインドウで実際に踏んだ競合なので変化にも乗せる。
        .onChange(of: model.libraries.map(\.id)) { _, _ in
            guard model.selectedLibraryID == nil else { return }
            model.syncSelection()
        }
        .onChange(of: LabelEditorNavigation.shared.pendingLibraryID) {
            guard let pending = LabelEditorNavigation.shared.pendingLibraryID else { return }
            LabelEditorNavigation.shared.pendingLibraryID = nil
            Task { await prepare(preferring: pending) }
        }
        .onChange(of: model.selectedLibraryID) { _, _ in
            Task { await reloadBoth() }
        }
        .onChange(of: selectedFieldDraftID) { _, _ in
            model.selectedFieldID = persistentFieldID(for: selectedFieldDraftID)
            Task { await model.reload() }
        }
        // ⌘Z / ⇧⌘Z は View を通らずに DB を変える。含めないと取り消した結果が
        // 画面に出ない（右ペインの評価・ラベル設定と同じ）。
        .onChange(of: LibraryGeneration.shared.value) { _, _ in
            Task { await model.reload() }
        }
    }

    private func prepare(preferring libraryID: LibraryID?) async {
        await model.prepare(services: LibraryServices.shared, preferring: libraryID)
        await reloadBoth()
    }

    private func reloadBoth() async {
        settings.selectedLibraryID = model.selectedLibraryID
        await settings.prepare(preferring: model.selectedLibraryID)
        syncFieldSelection()
        consumePendingFieldSelection()
        model.selectedFieldID = persistentFieldID(for: selectedFieldDraftID)
        await model.reload()
    }

    /// 開いた導線が指すフィールドを選ぶ [RL3-04]。
    ///
    /// 草案が読み込まれた後（`reloadBoth` の中）でしか対応付けられないので、
    /// ここで消費する。見つからなければ（保存前に消えた等）既定の選択のまま。
    private func consumePendingFieldSelection() {
        guard let pending = LabelEditorNavigation.shared.pendingFieldID else { return }
        LabelEditorNavigation.shared.pendingFieldID = nil
        guard let draft = draftFields.first(where: { $0.persistentID == pending.rawValue })
        else { return }
        selectedFieldDraftID = draft.id
    }

    /// 中央ペインの選択が消えていたら選び直す。
    ///
    /// **ラベルを持つ最初のフィールドを選ぶ**［設計判断］。素直に先頭を選ぶと、
    /// ラベルが 1 つも無いフィールド（`LG-04` の無効状態で、ラベルフィルタにも
    /// 出ない）に着地して右ペインが空になる——「ラベルを編集」で開いた直後に
    /// 見せる画面としては行き止まりで、必ずもう 1 クリック要る。
    /// どのフィールドにもラベルが無ければ先頭へ落とす。
    private func syncFieldSelection() {
        let ids = draftFields.map(\.id)
        if let current = selectedFieldDraftID, ids.contains(current) { return }
        let populated = draftFields.first { draft in
            guard let persistent = draft.persistentID else { return false }
            return model.fields.first { $0.id.rawValue == persistent }?.labelCount ?? 0 > 0
        }
        selectedFieldDraftID = populated?.id ?? ids.first
    }

    /// 草案側の識別子から DB の行 ID を引く。
    ///
    /// **新しく足したフィールドはまだ行を持たない**（`persistentID == nil`）ので
    /// `nil` を返す——右ペインは「保存すると編集できます」を出す。
    private func persistentFieldID(for draftID: UUID?) -> FieldID? {
        guard let draftID,
              let draft = draftFields.first(where: { $0.id == draftID }),
              let persistent = draft.persistentID else { return nil }
        return FieldID(rawValue: persistent)
    }

    /// 草案は Optional なので、共有するエディタには非 Optional の束縛だけを見せる
    /// （設定ウインドウと同じ扱い）。
    private var boundDraft: Binding<LibrarySettingsDraft> {
        Binding(get: { settings.draft ?? LibrarySettingsDraft() },
                set: { settings.draft = $0 })
    }

    private var draftFields: [FieldDraft] { settings.draft?.fields ?? [] }

    // MARK: - 左: ライブラリ一覧


    /// 同名ライブラリの注記 [RG3-31]。衝突している行にだけパスが付く。
    private var nameAnnotations: [LibraryID: String] {
        LibraryNameDisambiguation.annotations(for: model.libraries)
    }

    private var libraryList: some View {
        List(selection: Binding(
            get: { model.selectedLibraryID },
            set: { requestLibrarySwitch(to: $0) })
        ) {
            Section("librarySettings.librariesHeader") {
                ForEach(model.libraries, id: \.id) { library in
                    Label {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(library.displayName)
                            // 同名のライブラリはパスで区別する [RG3-31]。
                            LibraryPathCaption(annotation: nameAnnotations[library.id])
                            Text(String(format: String(localized: "librarySettings.fileCount",
                                                       locale: locale), library.fileCount))
                                .font(.system(size: Tokens.fontSize.caption))
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: library.isOnline
                              ? "books.vertical" : "books.vertical.circle")
                            .foregroundStyle(library.isOnline ? Color.accentColor : .secondary)
                    }
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

    /// 未保存の草案があるまま別のライブラリへ移ると編集が黙って消える。
    /// **黙って捨てない**——設定ウインドウと同じ扱いにする。
    private func requestLibrarySwitch(to id: LibraryID?) {
        guard id != model.selectedLibraryID else { return }
        guard settings.isDirty else {
            model.selectedLibraryID = id
            return
        }
        DialogWindowPresenter.shared.present(
            title: String(localized: "librarySettings.unsavedTitle", locale: locale)
        ) { _ in
            UnsavedChangesDialog(
                libraryName: settings.selectedLibraryName,
                onDiscard: {
                    settings.revert()
                    model.selectedLibraryID = id
                },
                onSave: {
                    Task {
                        if await settings.save() { model.selectedLibraryID = id }
                    }
                })
        }
    }

    // MARK: - 中央: ラベルフィールド

    private var groupPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                LibraryFieldsSettingsView(
                    draft: boundDraft,
                    selection: $selectedFieldDraftID,
                    showsHeader: false)
                    .padding(Tokens.spacing.l)
            }
            Divider()
            groupFooter
        }
    }

    /// **保存ボタンは必ず出す。** フィールドの編集は草案なので、押すまで DB には
    /// 入らない——右ペインが即座に反映されるのと意味が違うことを画面に出す。
    private var groupFooter: some View {
        HStack(spacing: Tokens.spacing.m) {
            if settings.isDirty {
                Image(systemName: "pencil.circle.fill").foregroundStyle(Color("WarningBadge"))
                Text("labelEditor.unsavedGroups")
                    .font(.system(size: Tokens.fontSize.caption))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("librarySettings.revert") { settings.revert() }
                .disabled(!settings.isDirty)
            Button("librarySettings.save") {
                Task {
                    if await settings.save() { await reloadBoth() }
                }
            }
            .keyboardShortcut("s", modifiers: .command)
            .disabled(!settings.isDirty)
        }
        .padding(Tokens.spacing.m)
    }
}

/// ウインドウを開く要求を受け渡す [15章 §15.2]。
///
/// `PreferencesNavigation` / `LibrarySettingsNavigation` と同じ形——`Window(id:)`
/// は同じ id で `openWindow` を呼び直してもビューを作り直さないので、
/// 「開いているウインドウが前面に来ただけ」の場合にも要求が届くようにする。
@MainActor
@Observable
final class LabelEditorNavigation {
    static let shared = LabelEditorNavigation()
    var pendingLibraryID: LibraryID?
    /// 開いたときに選ぶフィールド [RL3-04]。ライブラリと組でしか意味を
    /// 持たないので、`open` だけが設定する。
    var pendingFieldID: FieldID?
    private init() {}

    /// 開く経路はここ 1 つ [CP-02]。**フォルダツリー・ラベルフィルタ・右ペイン・
    /// メニューバー「ライブラリ」から呼ぶ**ので、受け皿へ置く順序を各所で
    /// 書き直さない——「同じに見える操作に独立した経路を作って片方だけ直す」を
    /// 避ける。
    @MainActor
    static func open(libraryID: LibraryID, fieldID: FieldID? = nil,
                     openWindow: OpenWindowAction) {
        // フィールドを先に置く——ウインドウ側は `pendingLibraryID` の変化で
        // 動くので、逆順だとフィールドの無いまま読み込みが始まりうる。
        shared.pendingFieldID = fieldID
        shared.pendingLibraryID = libraryID
        openWindow(id: "labelEditor")
    }
}
