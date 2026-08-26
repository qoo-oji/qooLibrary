//
//  同一性の確認ダイアログ [ID-05][ID-09〜ID-12][15.7.1]。
//
//  **走査完了の通知からも、ライブラリの設定ウインドウからも同じ実装を呼ぶ**
//  ——同じに見える操作に独立した経路を作ると、片方だけ直して取り残す
//  （`VolumeDecisionAction` と同じ扱い）。
//
//  提示は `DialogWindowPresenter`（`NSApp.keyWindow` へ重ねる）で行い、
//  **View の環境値を経由しない**。走査は非同期に終わるので、要求を View 越しに
//  回すと「メインウインドウが閉じていると黙って何も起きない」形になる。
//
import QooApplication
import QooKit
import SwiftUI

@MainActor
enum IdentityDecisionAction {

    /// 確認待ちを読み込んでダイアログを出す。**0 件なら何もしない。**
    static func present(libraryID: LibraryID, locale: Locale,
                        onFinished: (@MainActor () -> Void)? = nil) {
        Task {
            let pending: [OrphanedFile]
            do {
                pending = try await LibraryServices.shared
                    .identityMatchesAwaitingDecision(libraryID: libraryID)
            } catch {
                await NotificationRouter.shared.presentError(
                    error, whatHappened: String(localized: "identityDecision.failed",
                                                locale: locale))
                return
            }
            let sections = IdentityDecision.sections(from: pending)
            guard !sections.isEmpty else { return }
            // **一覧は開く時点で固定する。** 開いている間に走査が走って件数が
            // 変わると、利用者が見て選んだ集合と適用先がずれる。
            DialogWindowPresenter.shared.present(
                title: String(localized: "identityDecision.title", locale: locale)
            ) { _ in
                IdentityDecisionDialog(sections: sections) { selected in
                    Task {
                        await apply(sections, selected: selected, locale: locale)
                        onFinished?()
                    }
                }
            }
        }
    }

    private static func apply(_ sections: [IdentityDecision.Section],
                              selected: Set<FileID>, locale: Locale) async {
        let (accepted, rejected) = IdentityDecision.split(sections, selected: selected)
        guard !accepted.isEmpty || !rejected.isEmpty else { return }
        do {
            _ = try await CommandStack.shared.run(ApplyIdentityDecisionsCommand(
                accepted: accepted, rejected: rejected, services: .shared))
        } catch {
            await NotificationRouter.shared.presentError(
                error, whatHappened: String(localized: "identityDecision.failed", locale: locale))
        }
    }
}

struct IdentityDecisionDialog: View {
    @Environment(\.locale) private var locale
    @Environment(\.dialogDismiss) private var dismiss

    let sections: [IdentityDecision.Section]
    let onConfirm: (Set<FileID>) -> Void

    @State private var selected: Set<FileID> = []
    @State private var didInitialize = false

    var body: some View {
        DialogScaffold(
            width: 660,
            confirm: DialogButton(title: String(localized: "common.apply", locale: locale)) {
                onConfirm(selected)
                dismiss()
            },
            cancel: DialogButton(title: String(localized: "common.cancel", locale: locale),
                                 role: .cancel) { dismiss() }
        ) {
            VStack(alignment: .leading, spacing: Tokens.spacing.m) {
                Text("identityDecision.explanation")
                    .fixedSize(horizontal: false, vertical: true)
                // **外したものがどうなるかを先に言う** [ER-03 の精神]。
                // 「今は決めない」はキャンセルで表せる、ということも含めて。
                Text("identityDecision.unchecked")
                    .font(.system(size: Tokens.fontSize.caption))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: Tokens.spacing.s) {
                    Button("identityDecision.selectAll") { selected = allIDs }
                    Button("identityDecision.selectNone") { selected = [] }
                    Spacer()
                    Text(String(format: String(localized: "identityDecision.selectedCount",
                                               locale: locale), selected.count, allIDs.count))
                        .font(.system(size: Tokens.fontSize.caption))
                        .foregroundStyle(.secondary)
                }

                list
            }
            .task {
                // **一度だけ。** 再評価のたびに既定へ戻すと、外したチェックが
                // 勝手に戻る（`.task` は id を持たない限り 1 回きりだが、
                // 明示的に印を持たせて意図を残す）。
                guard !didInitialize else { return }
                didInitialize = true
                selected = IdentityDecision.defaultSelection(sections)
            }
        }
    }

    private var allIDs: Set<FileID> {
        Set(sections.flatMap { $0.rows.map(\.id) })
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(sections) { section in
                    sectionHeader(section)
                    ForEach(section.rows) { row in
                        self.row(row)
                        Divider()
                    }
                }
            }
        }
        // **件数にあわせて縮める。**固定の高さにすると 1 件のときに大きな
        // 空白が残る。上限は残す——何十件もあるときに画面を埋めないため。
        .frame(height: min(CGFloat(totalRows) * 46 + CGFloat(sections.count) * 26 + 10, 300))
        .background(RoundedRectangle(cornerRadius: Tokens.radius.s)
            .fill(Color(nsColor: .textBackgroundColor)))
    }

    private var totalRows: Int { sections.reduce(0) { $0 + $1.rows.count } }

    /// 区画の見出し [ID-09]。**確信度の違いを言葉で書く**——「同じ場所」
    /// 「別の場所」だけでは、なぜ分かれているのかが読み取れない。
    private func sectionHeader(_ section: IdentityDecision.Section) -> some View {
        HStack(spacing: Tokens.spacing.xs) {
            Image(systemName: section.kind == .samePath
                  ? "arrow.triangle.2.circlepath" : "arrow.turn.down.right")
            Text(section.kind == .samePath
                 ? "identityDecision.section.samePath" : "identityDecision.section.elsewhere")
            Spacer()
        }
        .font(.system(size: Tokens.fontSize.caption, weight: .semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, Tokens.spacing.s)
        .padding(.vertical, Tokens.spacing.xs)
    }

    private func row(_ row: IdentityDecision.Row) -> some View {
        Toggle(isOn: Binding(
            get: { selected.contains(row.id) },
            set: { isOn in
                if isOn { selected.insert(row.id) } else { selected.remove(row.id) }
            }
        )) {
            VStack(alignment: .leading, spacing: 1) {
                Text(row.file.row.filename)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: Tokens.spacing.s) {
                    // 同じ場所なら行き先を繰り返さない——同じ文字列が 2 度
                    // 並ぶと、何が変わったのか読み取りにくくなる。
                    Text(row.candidate.samePath
                         ? row.file.row.relativePath
                         : "\(row.file.row.relativePath) → \(row.candidate.relativePath)")
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(sizeChange(row))
                    if row.carriedLabels > 0 {
                        Text(String(format: String(localized: "identityDecision.carries",
                                                   locale: locale), row.carriedLabels))
                    }
                }
                .font(.system(size: Tokens.fontSize.caption))
                .foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.checkbox)
        .padding(.horizontal, Tokens.spacing.s)
        .padding(.vertical, Tokens.spacing.xs)
    }

    /// 大きさの変化。**これが「中身が違う」ことの唯一の手がかり**なので出す。
    private func sizeChange(_ row: IdentityDecision.Row) -> String {
        let formatter = ByteCountFormatter()
        return "\(formatter.string(fromByteCount: row.file.row.fileSize)) → "
            + formatter.string(fromByteCount: row.candidate.fileSize)
    }
}
