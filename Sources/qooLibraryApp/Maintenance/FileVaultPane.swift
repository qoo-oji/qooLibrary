//
//  メンテナンスウインドウの「保管庫」タブ [FAW-01〜FAW-05][15章 §15.4]。
//
//  ## ステージ 4 で専用ウインドウから移した [19章 §19.6]
//  左のライブラリ一覧と読み直しの合図は `MaintenanceWindow` が持つ。
//  **この移設で入口が復活した**——Stage P の右クリック最小化以降、保管庫の
//  整理ウインドウはどこからも開けなくなっていた（`FileVaultNavigation` の
//  参照が自ウインドウ内にしか無い状態が続いていた）。
//
//  ## 「見つからないファイル」タブ（§15.7）との違い — **オンラインの要否**
//  戻す・削除がどちらも実ファイルを動かすので**ボリュームが要る**が、
//  一覧そのものは DB だけで答えられる——**一覧は出し続け、操作だけを
//  無効にする**（「何がしまってあるか」を見に来た人をそこで行き止まりに
//  する理由が無い）。孤立タブは逆に一覧ごと伏せる [OR2-06]。
//
//  判定（区画の組み立て・並べ替え・検索・操作の可否）は `FileVaultModel` が
//  持ち、ここは描くだけ。**この分担を崩さないこと**。
//
import QooApplication
import QooKit
import SwiftUI

struct FileVaultPane: View {
    @Environment(\.locale) private var locale
    @Bindable var model: FileVaultModel
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

    /// 並べ替え [FAW-05] と検索。**並べ替えは区画の中へ効く**——元フォルダを
    /// またいで混ぜると §15.4 が定める「元フォルダごとに整理」が消える。
    private var toolbar: some View {
        HStack(spacing: Tokens.spacing.m) {
            Picker("", selection: $model.sortOrder) {
                Text("fileVault.sort.name").tag(FileVaultModel.SortOrder.name)
                Text("fileVault.sort.archivedAt").tag(FileVaultModel.SortOrder.archivedAt)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            // 実測: 日本語で 168 pt、**英語で 193.6 pt**（`NSFont.systemFont` の
            // 文字幅 ＋ セグメントの余白の見積もり）。200 pt では英語の余りが
            // 6 pt しか無く、余白の見積もりが少し外れれば切り詰められる
            // ——**目測ではなく測ってから決める**［CLAUDE.md の教訓］。
            // 右の検索欄は `minWidth: 140` で、詳細ペインの最小 460 pt に対して
            // まだ余裕がある。
            .frame(width: 240)

            TextField("fileVault.searchPlaceholder", text: $model.searchText)
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
                Section(sectionTitle(section)) {
                    ForEach(section.rows) { row in
                        vaultRow(row)
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

    /// 区画の見出し＝元のフォルダ [15.4 節]。ライブラリ直下は専用の文言にする
    /// ——空文字の見出しは、区画が無いのと区別が付かない。
    private func sectionTitle(_ section: FileVaultModel.Section) -> String {
        section.folder.isEmpty
            ? String(localized: "fileVault.libraryRoot", locale: locale)
            : section.folder
    }

    /// **「保管庫は空」と「検索に一致しない」を分ける。** 次の一手が違う
    /// ——前者は閉じる、後者は検索語を消す。
    @ViewBuilder
    private var emptyState: some View {
        if model.vaultIsEmpty {
            ContentUnavailableView {
                Label("fileVault.empty", systemImage: "archivebox")
            } description: {
                Text("fileVault.emptyHint")
            }
        } else {
            ContentUnavailableView { Label("fileVault.noMatches", systemImage: "doc") }
        }
    }

    /// 1 行 [FAW-01][FAW-02]。**ファイル名の右に「保管庫から戻す」ボタン**。
    private func vaultRow(_ row: ArchivedFile) -> some View {
        HStack(spacing: Tokens.spacing.s) {
            VStack(alignment: .leading, spacing: 1) {
                Text(row.row.filename)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: Tokens.spacing.s) {
                    // [FAW-05] 保管した日時。記録が無いのは外部で
                    // `.qooarchive` へ入れられたもの [FA-04]。
                    Text(row.archivedAt.map { Self.dateFormatter.string(from: $0) }
                        ?? String(localized: "fileVault.archivedAtUnknown", locale: locale))
                    if row.labelCount > 0 {
                        Text(String(format: String(localized: "fileVault.labelCount",
                                                   locale: locale), row.labelCount))
                    }
                }
                .font(.system(size: Tokens.fontSize.caption))
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: Tokens.spacing.s)
            Button("folder.restoreFromVault") {
                perform { try await model.restore([row]) }
            }
            .buttonStyle(.borderless)
            .font(.system(size: Tokens.fontSize.caption))
            .disabled(!model.canModify)
        }
        // **2 行の行には縦の余白を明示する**［実機検証で発見］。無いと
        // `List` が計算する行の高さが中身より低くなり、**選択したときに
        // 2 行目（保管した日時 [FAW-05] とラベル件数）が選択の帯に切られて
        // 読めなくなる**——一括で戻す [FAW-04] には選択が要るので、
        // いちばん見たいときに見えなくなる形だった。
        .padding(.vertical, 3)
    }

    /// **削除はコンテキストメニューからのみ** [FAW-03]。押しやすい場所に
    /// 置かないことがこの要件の趣旨なので、フッターにもボタンを置かない。
    @ViewBuilder
    private func rowMenu(_ row: ArchivedFile) -> some View {
        // **選択には触らない**（`LabelVaultWindow` と同じ）——ここで潰すと
        // 複数選択が壊れ、行のインラインボタンとも挙動がずれる。
        Button("folder.restoreFromVault", systemImage: "archivebox") {
            perform { try await model.restore([row]) }
        }
        .disabled(!model.canModify)
        Divider()
        Button("labelEditor.delete", systemImage: "trash", role: .destructive) {
            model.selection = [row.id]
            confirmDelete()
        }
        .disabled(!model.canModify)
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
                // 一括で戻す [FAW-04]。
                Button("folder.restoreFromVault") {
                    perform { try await model.restoreSelected() }
                }
                .disabled(model.selection.isEmpty || !model.canModify)
            }
        }
        .padding(Tokens.spacing.m)
        .layoutPriority(1)
    }

    // MARK: - 確認

    /// **削除は取り消せるが、確認は挟む。** 何件のラベルが外れるかと、
    /// **実ファイルがゴミ箱へ行く**ことを見せる［ユーザー判断］。
    private func confirmDelete() {
        Task {
            // **ゴミ箱があるかを先に確かめる** [NV4-01]。文言も、取り消せるか
            // どうかも変わるので、ダイアログを出す前に決める必要がある。
            guard let plan = await model.planDelete() else { return }
            DialogWindowPresenter.shared.present(
                title: String(localized: "fileVault.deleteTitle", locale: locale)
            ) { _ in
                DeleteVaultFilesDialog(plan: plan) {
                    perform { try await model.deleteSelected(plan) }
                }
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

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}
