//
//  右ペインのタイトル編集 [RP-10〜RP-12] とシリーズ名・巻数の表示 [DT-08][DT-09]。
//
//  判定は `TitleEditorModel`（`QooApplication`）が持つ。この View は描くだけ
//  （`InspectorRatingSection`/`InspectorLabelSection` と同じ分け方）。
//
import QooApplication
import QooKit
import SwiftUI

struct InspectorTitleSection: View {
    let model: TitleEditorModel

    @Environment(\.locale) private var locale
    /// 入力中の文字列。**確定するまで DB へ書かない** [RP-10]——1 文字ごとに
    /// 書くと Undo スタックが打鍵の数だけ積み上がる。
    @State private var draft = ""
    /// `draft` がどの対象のものか。対象が変わったら必ず入れ替える。
    @State private var draftURL: URL?
    /// 直近に見たモデル側の値。**外から書き換えられたかを見分けるために持つ**
    /// （下記 `syncDraft`）。
    @State private var lastKnownText = ""
    @FocusState private var isEditing: Bool

    var body: some View {
        switch model.state {
        case .notApplicable:
            // ライブラリ経由で開いていない。**枠ごと出さない** [LF-01 と同じ判断]。
            EmptyView()
        case .loading:
            section { ProgressView().controlSize(.small) }
        case .notInLibrary:
            section {
                Text("inspector.title.notInLibrary")
                    .font(.system(size: Tokens.fontSize.caption))
                    .foregroundStyle(.secondary)
            }
        case .failed(let reason):
            section {
                Text(reason)
                    .font(.system(size: Tokens.fontSize.caption))
                    .foregroundStyle(Tokens.Colors.dangerText)
                    .lineLimit(3)
            }
        case .ready(let subject):
            section { editor(subject) }
                // **入力欄と表示中の値の突き合わせはここ 1 箇所で行う。**
                // `section` が単一のビューを返すので、`onChange` も 1 回しか
                // 走らない（Divider を VStack の外に出すと 2 回走る）。
                .onChange(of: subject, initial: true) { _, newValue in
                    syncDraft(newValue)
                }
            metadataRows(subject)
        }
    }

    // MARK: - 部品

    private func section(@ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: Tokens.spacing.xs) {
            Divider()
            Text("inspector.title.header")
                .font(.system(size: Tokens.fontSize.caption))
                .foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func editor(_ subject: TitleEditorModel.Subject) -> some View {
        // **未設定のときファイル名を欄へ入れない** [設計判断、モデル側の
        // `editableText` 参照]。プレースホルダとして見せるだけにすると、
        // 「何も打たずに確定しただけで手動編集になる」ことが起きない。
        TextField("", text: $draft, prompt: Text(subject.fallbackTitle))
            .editableFieldChrome()
            .focused($isEditing)
            .onSubmit { commit() }
            // フォーカスを失ったときにも確定する（Finder のインライン編集と
            // 同じ）。`isEditing` が落ちる瞬間に確定しないと、打ったのに
            // 反映されないまま別の項目へ移ってしまう。
            .onChange(of: isEditing) { wasEditing, nowEditing in
                if wasEditing && !nowEditing { commit() }
            }
        if subject.canRederive {
            // [RP-12] **手動編集のときだけ出す**（`canRederive`）——自動のままで
            // 押しても何も変わらない導線を常駐させない。
            Button("inspector.title.rederive") {
                Task { await rederive() }
            }
            .buttonStyle(.link)
            .font(.system(size: Tokens.fontSize.caption))
        }
        // **この欄の値がどこから来たか**を出す [RP-11]。手動編集は再スキャンで
        // 上書きされないので、そのことが読み取れないと「なぜ更新されないのか」
        // が分からない。
        if subject.titleOrigin == .manual {
            Label("inspector.title.manual", systemImage: "pencil")
                .font(.system(size: Tokens.fontSize.caption))
                .foregroundStyle(.secondary)
        }
    }

    /// シリーズ名・巻数 [DT-09]。**値があるときだけ出す**——空の行が並ぶと、
    /// 情報が無いのか読み込めていないのか区別が付かない。
    @ViewBuilder
    private func metadataRows(_ subject: TitleEditorModel.Subject) -> some View {
        if let series = subject.seriesName, !series.isEmpty {
            LabeledContent("inspector.seriesName", value: series)
        }
        if let volume = subject.volumeDisplay {
            LabeledContent("inspector.volume", value: volume)
        }
    }

    // MARK: - 操作

    /// 表示中の値と入力欄を突き合わせる。
    ///
    /// ## 「打っている最中」と「外から書き換えられた」を見分ける
    /// この節は ⌘Z や無関係なファイル操作のたびに読み直される（`.task(id:)` の
    /// 鍵に `operationHistory.count` が入っている）。素直に写すと打っている
    /// 最中に消えるが、**編集中は一切写さない**ようにすると今度は ⌘Z が
    /// 効かなくなる——欄に古い草案が残り、**フォーカスを外した瞬間にそれが
    /// 書き戻されて取り消しが取り消される**［実機検証で発見］。
    ///
    /// 見分けは「モデル側の値が前回見たときから変わったか」で付く。打鍵では
    /// モデルは動かないので、動いたなら外からの書き換えである。
    private func syncDraft(_ subject: TitleEditorModel.Subject?) {
        guard let subject else {
            draft = ""
            draftURL = nil
            lastKnownText = ""
            return
        }
        if draftURL != subject.url {
            draft = subject.editableText
            draftURL = subject.url
            lastKnownText = subject.editableText
            return
        }
        if subject.editableText != lastKnownText {
            // 外から変わった（⌘Z・再取得・再スキャン）。**編集中でも写す。**
            draft = subject.editableText
            lastKnownText = subject.editableText
            return
        }
        guard !isEditing, draft != subject.editableText else { return }
        draft = subject.editableText
    }

    private func commit() {
        guard case .ready(let subject) = model.state, draftURL == subject.url else { return }
        // **打っていなければ何もしない** [RP-10]。判定はモデル側が持つ
        // （`TitleEditorModel.shouldCommit` のコメントに理由がある）。
        guard TitleEditorModel.shouldCommit(draft: draft, lastKnown: lastKnownText) else { return }
        lastKnownText = draft
        Task {
            do {
                try await model.commitTitle(draft)
            } catch {
                await NotificationRouter.shared.presentError(
                    error, whatHappened: String(localized: "error.setTitleFailed", locale: locale))
            }
        }
    }

    private func rederive() async {
        do {
            try await model.rederive()
        } catch {
            await NotificationRouter.shared.presentError(
                error, whatHappened: String(localized: "error.setTitleFailed", locale: locale))
        }
    }
}
