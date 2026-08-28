//
//  「見つからないファイル」の整理ウインドウ [OR-01][OR-04][ID-07][15.7 節]。
//
//  **触れるのは一覧と削除だけ**［ユーザー判断、2026-08］。実体を結び直す手段は
//  ここに置かない——同じ inode で復活すれば走査が自動で戻し [ID-02]、名前が
//  同じで inode が違えば**一括の確認ダイアログ** [ID-05] が引き受ける。
//
//  2 ペイン: 左＝ライブラリ一覧（孤立件数／オフラインはグレーアウト）／
//  右＝孤立レコードの一覧。`LabelVaultWindow` と同じ `NavigationSplitView` で
//  見た目を揃える [CP-01]。
//
//  ## ラベル保管庫との違い
//  形は同じでも扱うものの性質が逆で、**オフラインのライブラリでは一覧を
//  出さない** [OR2-06][ID-08][SB-05]。ラベルは実体に依らないので保管庫は
//  オフラインでも開けるが、孤立は実体についての判断なので、見えない状態で
//  「見つからない」を確定させてはならない。
//
//  判定（絞り込み・既定のライブラリ・オフラインの出し分け）は
//  `OrphanCleanupModel` が持ち、ここは描くだけ。**この分担を崩さないこと**
//  ——View に判定を書くと `swift test` から触れなくなる。
//
import QooApplication
import QooKit
import SwiftUI

struct OrphanCleanupWindow: View {
    @Environment(\.locale) private var locale
    @State private var model = OrphanCleanupModel()
    @State private var errorText: String?

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            libraryList
                .navigationSplitViewColumnWidth(min: 170, ideal: 210, max: 280)
        } detail: {
            detailPane
                .navigationSplitViewColumnWidth(min: 460, ideal: 580)
        }
        .navigationTitle(Text("orphanCleanup.windowTitle"))
        .frame(minWidth: 720, minHeight: 460)
        .task { await prepare(preferring: OrphanCleanupNavigation.shared.pendingLibraryID) }
        .onChange(of: OrphanCleanupNavigation.shared.pendingLibraryID) {
            guard let pending = OrphanCleanupNavigation.shared.pendingLibraryID else { return }
            OrphanCleanupNavigation.shared.pendingLibraryID = nil
            Task { await prepare(preferring: pending) }
        }
        // **起動と同時に状態復元で開かれると、DB の準備より先に `.notReady` で
        // 確定する。** `Window(id:)` は `.restorationBehavior(.disabled)` を
        // 持たないのでこの経路は実在し、一度確定すると再試行の契機が無い
        // ——準備完了そのものに乗る（`LabelVaultWindow` と同じ）。
        .onChange(of: LibraryServices.shared.isReady) { _, ready in
            guard ready else { return }
            Task { await prepare(preferring: nil) }
        }
        .onChange(of: model.selectedLibraryID) { _, _ in
            Task { await model.reload() }
        }
        // **ボリュームの着脱に追随する** [VD-03][VD-05][OR2-06]。
        //
        // 実機検証で見つけた欠陥——外付けを取り出しても、開いたままのこの
        // ウインドウは古い一覧を出し続け、**そこから削除できてしまった**。
        // OR2-06 が防ごうとしている事故そのもの（見えない状態で「見つからない」
        // を確定させる）が、ウインドウを開きっぱなしにするだけで起きる。
        //
        // `LabelVaultWindow` に同じ配線が無いのは、**あちらはオフラインでも
        // 読み書きしてよい**ため（ラベルは実体に依らない）。形が同じでも
        // 前提が逆なので、写すときは何を守っているかまで写すこと。
        .onChange(of: LibraryServices.shared.libraries) { _, _ in
            Task { await model.reload() }
        }
        // ⌘Z / ⇧⌘Z は View を通らずに DB を変える。含めないと、取り消した
        // 結果（戻した孤立が一覧へ戻ってくる等）が画面に出ない。
        .onChange(of: CommandStack.shared.operationHistory.count) { _, _ in
            Task { await model.reload() }
        }
    }

    private func prepare(preferring libraryID: LibraryID?) async {
        OrphanCleanupNavigation.shared.pendingLibraryID = nil
        await model.prepare(services: LibraryServices.shared, preferring: libraryID)
    }

    // MARK: - 左: ライブラリ一覧

    /// **孤立が 0 件のライブラリはグレーアウトする**（`LabelVaultWindow` と
    /// 同じ扱い）。選べなくはしない——「無かった」を確かめに来ることがある。
    ///
    /// **オフラインは件数を出さない** [OR2-06]。0 件と紛らわしくなるので
    /// 理由の語を出す——「孤立が無い」のか「見られない」のかは別のことである。

    /// 同名ライブラリの注記 [RG3-31]。衝突している行にだけパスが付く。
    private var nameAnnotations: [LibraryID: String] {
        LibraryNameDisambiguation.annotations(for: model.libraries)
    }

    private var libraryList: some View {
        List(selection: $model.selectedLibraryID) {
            Section("librarySettings.librariesHeader") {
                ForEach(model.libraries, id: \.id) { library in
                    let online = OrphanCleanupModel.canListOrphans(of: library)
                    let count = model.orphanCounts[library.id] ?? 0
                    Label {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(library.displayName)
                            // 同名のライブラリはパスで区別する [RG3-31]。
                            LibraryPathCaption(annotation: nameAnnotations[library.id])
                            Text(online
                                 ? String(format: String(localized: "orphanCleanup.count",
                                                         locale: locale), count)
                                 : String(localized: "orphanCleanup.offlineShort", locale: locale))
                                .font(.system(size: Tokens.fontSize.caption))
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: online
                              ? "questionmark.folder" : "externaldrive.badge.xmark")
                            .foregroundStyle(online && count > 0 ? Color.accentColor : .secondary)
                    }
                    .opacity(online && count > 0 ? 1 : 0.5)
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

    // MARK: - 右: 孤立レコードの一覧

    private var detailPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            toolbar
            Divider()
            content
            Divider()
            footer
        }
    }

    /// 絞り込み［実装判断］。ボリュームの中身が入れ替わると全件が孤立しうる
    /// ので、数千件から目当ての 1 件を探せないと [OR-04] が実行できない。
    private var toolbar: some View {
        HStack(spacing: Tokens.spacing.m) {
            TextField("orphanCleanup.searchPlaceholder", text: $model.searchText)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 180)
            Spacer()
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
        case .offline:
            // **一覧を出さないことが要件** [OR2-06]。理由を書かずに空にすると
            // 「孤立が無い」と読める。
            ContentUnavailableView {
                Label("orphanCleanup.offlineTitle", systemImage: "externaldrive.badge.xmark")
            } description: {
                Text("orphanCleanup.offlineHint")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    /// **「孤立はありません」と「検索に一致しない」を分ける。** 次の一手が
    /// 違う——前者は閉じる、後者は検索語を消す。
    @ViewBuilder
    private var emptyState: some View {
        if model.hasNoOrphans {
            ContentUnavailableView {
                Label("orphanCleanup.empty", systemImage: "checkmark.circle")
            } description: {
                Text("orphanCleanup.emptyHint")
            }
        } else {
            ContentUnavailableView {
                Label("orphanCleanup.noMatches", systemImage: "questionmark.folder")
            }
        }
    }

    /// 1 行 [OR-01][OR-02]。
    ///
    /// **出すのは「どの本だったか」を思い出せるものだけ**——名前・元の場所・
    /// 覚えていた内容（ラベル件数と評価）。孤立した日時は持っていない
    /// （`archivedAt` は保管庫用の列で、OR にも日時の要件は無い）。
    private func row(_ file: OrphanedFile) -> some View {
        HStack(spacing: Tokens.spacing.m) {
            VStack(alignment: .leading, spacing: 1) {
                Text(file.row.filename)
                HStack(spacing: Tokens.spacing.s) {
                    Text(file.row.relativePath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if file.labelCount > 0 {
                        Text(String(format: String(localized: "orphanCleanup.labelCount",
                                                   locale: locale), file.labelCount))
                    }
                    if file.row.rating > 0 {
                        RatingStars(filled: file.row.rating)
                    }
                }
                .font(.system(size: Tokens.fontSize.caption))
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: Tokens.spacing.s)
        }
        .padding(.vertical, 2)
    }

    /// 行のメニュー。**削除だけ** [OR-04]。結び直す手段はここに置かない
    /// （上のコメント参照）。
    @ViewBuilder
    private func rowMenu(_ file: OrphanedFile) -> some View {
        Button("orphanCleanup.delete", systemImage: "trash", role: .destructive) {
            confirmDelete([file])
        }
    }

    /// 下端の操作群。**高さを増やさない**——理由が 1 行増えただけで中身全体が
    /// ウインドウからはみ出す（`LabelVaultWindow` と同じ扱い）。
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
                // 一括削除 [OR-04]。**確認は必ず挟む**——⌘Z で戻せるとはいえ、
                // 覚えていた内容がまとめて消える操作である。
                Button("orphanCleanup.delete", role: .destructive) {
                    confirmDelete(model.selectedFiles)
                }
                .disabled(model.selection.isEmpty)
            }
        }
        .padding(Tokens.spacing.m)
        .layoutPriority(1)
    }

    // MARK: - 確認

    /// **削除は取り消せるが、確認は挟む。** 何を失うか（覚えていたラベルの
    /// 件数）を見せる——`DeleteLabelsDialog` と同じ考え方。
    private func confirmDelete(_ targets: [OrphanedFile]) {
        guard !targets.isEmpty else { return }
        DialogWindowPresenter.shared.present(
            title: String(localized: "orphanCleanup.deleteTitle", locale: locale)
        ) { _ in
            DeleteOrphansDialog(files: targets) {
                perform { try await model.delete(targets) }
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

/// 削除の確認 [OR-04]。
struct DeleteOrphansDialog: View {
    @Environment(\.locale) private var locale
    @Environment(\.dialogDismiss) private var dismiss

    let files: [OrphanedFile]
    let onConfirm: () -> Void

    /// 覚えていたラベルの延べ件数。**これを出すのが要点**——0 件なら気軽に
    /// 消せるし、多ければ手が止まる（`DeleteLabelsDialog` と同じ）。
    private var affected: Int { files.reduce(0) { $0 + $1.labelCount } }

    var body: some View {
        DialogScaffold(
            width: 460,
            confirm: DialogButton(title: String(localized: "orphanCleanup.delete", locale: locale),
                                  role: .destructive) {
                onConfirm()
                dismiss()
            },
            cancel: DialogButton(title: String(localized: "common.cancel", locale: locale),
                                 role: .cancel) { dismiss() }
        ) {
            VStack(alignment: .leading, spacing: Tokens.spacing.s) {
                Text(files.count == 1
                     ? String(format: String(localized: "orphanCleanup.deleteOne", locale: locale),
                              files[0].row.filename)
                     : String(format: String(localized: "orphanCleanup.deleteMany", locale: locale),
                              files.count))
                    .fixedSize(horizontal: false, vertical: true)

                if affected > 0 {
                    Text(String(format: String(localized: "orphanCleanup.deleteAffects",
                                               locale: locale), affected))
                        .foregroundStyle(Color("DangerText"))
                        .fixedSize(horizontal: false, vertical: true)
                }
                // **実ファイルは消えない**ことを明示する——「削除」という語だけ
                // だと、まだ残っている実体まで消すと読める。
                Text("orphanCleanup.deleteRecordOnly")
                    .font(.system(size: Tokens.fontSize.caption))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("labelEditor.deleteUndoable")
                    .font(.system(size: Tokens.fontSize.caption))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// ウインドウを開く要求を受け渡す [15章 §15.7]。
///
/// `LabelVaultNavigation` と同じ形——`Window(id:)` は同じ id で `openWindow` を
/// 呼び直してもビューを作り直さないので、「開いているウインドウが前面に来た
/// だけ」の場合にも要求が届くようにする。
@MainActor
@Observable
final class OrphanCleanupNavigation {
    static let shared = OrphanCleanupNavigation()
    var pendingLibraryID: LibraryID?
    private init() {}

    /// 開く経路はここ 1 つ [CP-02]。**フォルダツリーの登録ルート行 2 種**から
    /// 呼ぶ——通常の行と縮退した行は別々に配線が要る（このリポジトリが
    /// 4 度取り残した形）。
    @MainActor
    static func open(libraryID: LibraryID, openWindow: OpenWindowAction) {
        shared.pendingLibraryID = libraryID
        openWindow(id: "orphanCleanup")
    }
}
