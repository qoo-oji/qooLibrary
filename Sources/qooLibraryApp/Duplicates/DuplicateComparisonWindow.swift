//
//  重複の比較ウインドウ [DU-20〜DU-29][15.14 節]。
//
//  一覧で `×N` の付いた行 [DU-06] から開き、**同じ作品のファイルを並べて
//  比べて、残す 1 件を決めて残りを捨てる**。
//
//  ## 他の整理ウインドウ（§15.3/15.4/15.6/15.7）と違う点
//  あちらは「ライブラリを選んでその中を片付ける」2〜3 ペインだが、こちらは
//  **1 つの組だけ**を扱うので単一ペインにしてある——左に一覧を置いても
//  選ぶものが無い。
//
//  **この画面だけが実ファイルを消す**ので、①何が失われるかを実行前に出す
//  [DU-27] ②既定はゴミ箱 [DU-24] ③ゴミ箱を使えないときは「取り消せません」と
//  言う [PD-05] の 3 つを崩さないこと。判断はすべて `DuplicateResolutionModel`
//  が持ち、ここは描くだけ。
//
import QooApplication
import QooKit
import SwiftUI

struct DuplicateComparisonWindow: View {
    @Environment(\.locale) private var locale
    @State private var model = DuplicateResolutionModel()
    @State private var pendingPlan: DuplicateDeletePlan?
    @State private var inheritMetadata = true
    @State private var errorText: String?

    var body: some View {
        VStack(spacing: 0) {
            content
            Divider()
            footer
        }
        .navigationTitle(Text("duplicates.windowTitle"))
        .frame(minWidth: 760, minHeight: 460)
        .task { await prepare() }
        .onChange(of: DuplicateComparisonNavigation.shared.pending?.file) {
            Task { await prepare() }
        }
        // 起動と同時に状態復元で開かれると DB の準備より先に確定してしまう
        // ——`Window(id:)` は `.restorationBehavior(.disabled)` を持たない
        // （§15.3/15.4 と同じ配線）。
        .onChange(of: LibraryServices.shared.isReady) { _, ready in
            guard ready else { return }
            Task { await prepare() }
        }
        .sheet(item: $pendingPlan) { plan in
            DuplicateDeleteConfirmationSheet(
                plan: plan, inheritMetadata: $inheritMetadata,
                onConfirm: { Task { await performDelete(plan) } },
                onCancel: { pendingPlan = nil })
        }

    }

    @ViewBuilder private var content: some View {
        switch model.state {
        case .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let reason):
            PlaceholderPane(title: String(localized: "duplicates.loadFailed", locale: locale),
                            subtitle: reason)
        case .ready where model.rows.count < 2:
            // 組が解けた（別の経路で片付いた）ときはここへ来る。
            PlaceholderPane(
                title: String(localized: "duplicates.noLongerDuplicated", locale: locale),
                subtitle: String(localized: "duplicates.noLongerDuplicatedHint", locale: locale))
        case .ready:
            comparisonTable
        }
    }

    private var comparisonTable: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Tokens.spacing.s) {
                ForEach(model.rows) { row in
                    DuplicateComparisonCard(
                        row: row,
                        userCoverURL: userCoverURL(for: row),
                        isKeeper: model.keepID == row.id,
                        onChoose: { model.chooseKeeper(row.id) },
                        onTogglePin: { Task { await togglePin(row) } })
                }
            }
            .padding(Tokens.spacing.m)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: Tokens.spacing.s) {
            // 一括選択規則 [DU-25]。**当てても実行はしない**——結果は上の
            // 一覧に出るだけで、行ごとに選び直せる [DU-26]。
            HStack(spacing: Tokens.spacing.s) {
                Text("duplicates.keepRule")
                    .font(.system(size: Tokens.fontSize.caption))
                    .foregroundStyle(.secondary)
                ForEach(Array(ruleChoices.enumerated()), id: \.offset) { _, choice in
                    Button(choice.title) { model.apply(choice.rule) }
                        .buttonStyle(.bordered)
                }
                Spacer()
            }
            if let errorText {
                Label(errorText, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: Tokens.fontSize.caption))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if let rule = model.appliedRule {
                    Label(ruleTitle(rule), systemImage: "wand.and.stars")
                        .font(.system(size: Tokens.fontSize.caption))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("duplicates.deleteOthers") {
                    Task {
                        inheritMetadata = model.lossReport().hasAnythingToInherit
                        pendingPlan = await model.planDelete()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canDelete)
            }
        }
        .padding(Tokens.spacing.m)
    }

    private var ruleChoices: [(rule: KeepRule, title: LocalizedStringKey)] {
        [(.largestSize, "duplicates.rule.largestSize"),
         (.mostPages, "duplicates.rule.mostPages"),
         (.highestResolution, "duplicates.rule.highestResolution"),
         (.highestRating, "duplicates.rule.highestRating"),
         (.preferFormats(AppDefaults.Duplicates.formatPreference),
          "duplicates.rule.preferFormats")]
    }

    private func ruleTitle(_ rule: KeepRule) -> LocalizedStringKey {
        ruleChoices.first { $0.rule == rule }?.title ?? "duplicates.rule.largestSize"
    }

    /// ユーザー指定カバーの複製の場所 [IV-02①]。参照があるときだけ組み立てる
    /// （`LibraryContentModel.rows` と同じで、ここでは I/O をしない）。
    private func userCoverURL(for row: DuplicateComparisonRow) -> URL? {
        guard row.file.coverImageSource == .userSpecified,
              let ref = row.file.coverImageRef,
              let library = LibraryServices.shared.libraries.first(where: {
                  $0.id == row.file.libraryID
              })
        else { return nil }
        return LibraryServices.shared.userCoverURL(ref: ref, library: library)
    }

    /// 代表の手動固定 [DU-08][DG-04]。**一覧側からは代表しか選べない**ので、
    /// 別の 1 件を代表に指名できるのはこの画面だけ。
    private func togglePin(_ row: DuplicateComparisonRow) async {
        guard let pending = DuplicateComparisonNavigation.shared.pending,
              let library = LibraryServices.shared.libraries.first(where: {
                  $0.id == pending.library
              })
        else { return }
        do {
            try await LibraryServices.shared.setDuplicateRepresentativePinned(
                !row.file.isDuplicateRepresentativePinned, for: row.id,
                mode: library.duplicateGrouping)
            await prepare()
            // 一覧側の代表も入れ替わるので読み直させる。
            SessionState.shared.reloadToken += 1
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func prepare() async {
        // **読み直すたびに古い失敗を消す。** 残すと、成功した削除のあとにも
        // 前回の理由が出たままになり、何が起きているか読めなくなる。
        errorText = nil
        guard let pending = DuplicateComparisonNavigation.shared.pending,
              let library = LibraryServices.shared.libraries.first(where: {
                  $0.id == pending.library
              })
        else { return }
        await model.load(around: pending.file, library: library,
                         services: LibraryServices.shared)
        // ページ数・解像度は開いてから数える [DU-22][MD-03]。
        await model.measurePending(services: LibraryServices.shared)
    }

    private func performDelete(_ plan: DuplicateDeletePlan) async {
        pendingPlan = nil
        let command = DuplicateResolutionModel.makeDeleteCommand(
            plan: plan, inheritMetadata: inheritMetadata,
            services: LibraryServices.shared)
        do {
            _ = try await CommandStack.shared.run(command)
            SessionState.shared.reloadToken += 1
            await prepare()
        } catch {
            errorText = error.localizedDescription
        }
    }
}

/// 開く経路はここ 1 つ [CP-02]。中央ペインの行のコンテキストメニューから呼ぶ。
@MainActor
@Observable
final class DuplicateComparisonNavigation {
    struct Target: Equatable {
        let library: LibraryID
        let file: FileID
    }

    static let shared = DuplicateComparisonNavigation()
    var pending: Target?
    private init() {}

    static func open(file: FileID, library: LibraryID, openWindow: OpenWindowAction) {
        shared.pending = Target(library: library, file: file)
        openWindow(id: "duplicateComparison")
    }
}
