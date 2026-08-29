//
//  メンテナンスウインドウの「見つからないファイル」タブ
//  [OR-01][OR-04][ID-07][15章 §15.7]。
//
//  **触れるのは一覧と削除だけ**［ユーザー判断、2026-08］。実体を結び直す手段は
//  ここに置かない——同じ inode で復活すれば走査が自動で戻す [ID-02]。
//
//  ## ステージ 4 で専用ウインドウから移した [19章 §19.6]
//  左のライブラリ一覧と、読み直しの合図（着脱・⌘Z・準備完了）は
//  `MaintenanceWindow` が持つ。**このペインは選ばれたライブラリの一覧を
//  描いて操作するだけ**にする——ライブラリ選択をタブ間で共有するのが統合の
//  眼目で、ペインごとに持つと切り替えのたびに選び直すことになる。
//
//  ## 保管庫タブ（§15.4）との違い — **オンラインの要否**
//  孤立は実体についての判断なので、**オフラインのライブラリでは一覧を出さない**
//  [OR2-06][ID-08][SB-05]（見えない状態で「見つからない」を確定させてはならない）。
//  保管庫は DB だけで答えられるので一覧は出し、操作だけを無効にする。
//  **形が同じでも守っているものが違う**ので、片方に揃えないこと。
//
//  判定（絞り込み・既定のライブラリ・オフラインの出し分け）は
//  `OrphanCleanupModel` が持ち、ここは描くだけ。**この分担を崩さないこと**
//  ——View に判定を書くと `swift test` から触れなくなる。
//
import QooApplication
import QooKit
import SwiftUI

struct OrphanCleanupPane: View {
    @Environment(\.locale) private var locale
    @Bindable var model: OrphanCleanupModel
    @State private var errorText: String?

    // MARK: - 一覧と操作

    var body: some View {
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
