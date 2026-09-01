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
            // DB に行が無い。**枠ごと出さない**——理由の文は置かない
            //［ユーザー指摘、2026-09-02］。
            EmptyView()
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
        }
    }

    // MARK: - 部品

    /// **見出しは置かない**［ユーザー指摘、2026-09-02］——「タイトル」
    /// 「シリーズ」「巻数」というラベルが並んでいれば、何の節かは読める。
    private func section(@ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: Tokens.spacing.xs) {
            Divider()
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .font(.system(size: Tokens.fontSize.caption))
    }

    @ViewBuilder
    private func editor(_ subject: TitleEditorModel.Subject) -> some View {
        // **ラベルはすべて左に置く**［ユーザー指摘、2026-09-02］。以前は
        // タイトルだけが見出しの下の全幅の欄で、シリーズと巻数だけが
        // 左ラベルだった——同じ「基本情報の編集」なのに 2 通りの形が並ぶ。
        //
        // **未設定のときファイル名を欄へ入れない** [設計判断、モデル側の
        // `editableText` 参照]。プレースホルダとして見せるだけにすると、
        // 「何も打たずに確定しただけで手動編集になる」ことが起きない。
        InspectorRow("inspector.titleField") {
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
        }
        // **シリーズ名と巻数も編集できる** [RP-13][RP-14]。基本情報は 1
        // かたまり [PR-02] なので、どれを直しても同じスコープが保護される。
        InspectorRow("inspector.seriesName") {
            EditableMetadataField(
                value: subject.seriesName ?? "", identity: subject.url,
                commit: { text in Task { await commitSeries(text) } })
        }
        InspectorRow("inspector.volume") {
            EditableMetadataField(
                value: subject.volumeDisplay ?? "", identity: subject.url,
                commit: { text in Task { await commitVolume(text) } })
        }
        // **保護されていることを出す** [PR-03]。走査が触れないので、
        // そのことが読み取れないと「なぜ更新されないのか」が分からない。
        if subject.isBasicProtected {
            HStack(spacing: Tokens.spacing.xs) {
                // **短い語だけ**［ユーザー指摘、2026-09-02］。以前は
                // 「自動更新から保護されています」という文だった。
                Label("inspector.basic.protected", systemImage: "lock.fill")
                    .font(.system(size: Tokens.fontSize.caption))
                    .foregroundStyle(.secondary)
                Spacer()
                // [PR-04] 解除 ＝ 手動編集の破棄。**確認は出さない**
                // ［ユーザー判断］——⌘Z で戻せる操作に毎回 1 枚挟むと、本当に
                // 見てほしいときの 1 枚まで読み飛ばされる [RA-05 と同じ判断]。
                Button("inspector.basic.unprotect") {
                    Task { await rederive() }
                }
                .buttonStyle(.link)
                .font(.system(size: Tokens.fontSize.caption))
            }
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

    private func commitSeries(_ text: String) async {
        do {
            try await model.commitSeriesName(text)
        } catch {
            await NotificationRouter.shared.presentError(
                error, whatHappened: String(localized: "error.setTitleFailed", locale: locale))
        }
    }

    private func commitVolume(_ text: String) async {
        do {
            try await model.commitVolume(text)
        } catch {
            await NotificationRouter.shared.presentError(
                error, whatHappened: String(localized: "error.setTitleFailed", locale: locale))
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

/// 基本情報の 1 項目ぶんの入力欄 [RP-13][RP-14]。
///
/// **タイトル欄と同じ「打っている最中／外から書き換えられた」の見分け**を
/// 持つ（`InspectorTitleSection.syncDraft` のコメントに理由がある）。3 つの
/// 欄でそれぞれ書くと、片方だけ直して取り残す。
private struct EditableMetadataField: View {
    let value: String
    /// 対象が変わったら草案を入れ替えるための鍵。
    let identity: URL
    let commit: (String) -> Void

    @State private var draft = ""
    @State private var draftIdentity: URL?
    @State private var lastKnown = ""
    @FocusState private var isEditing: Bool

    var body: some View {
        TextField("", text: $draft)
            .editableFieldChrome()
            .focused($isEditing)
            .onSubmit { commitIfTyped() }
            .onChange(of: isEditing) { was, now in
                if was && !now { commitIfTyped() }
            }
            .onChange(of: SyncKey(identity: identity, value: value), initial: true) { _, key in
                sync(key)
            }
    }

    private struct SyncKey: Equatable {
        let identity: URL
        let value: String
    }

    private func sync(_ key: SyncKey) {
        if draftIdentity != key.identity {
            draft = key.value
            draftIdentity = key.identity
            lastKnown = key.value
            return
        }
        if key.value != lastKnown {          // ⌘Z・再取得・再スキャン
            draft = key.value
            lastKnown = key.value
            return
        }
        guard !isEditing, draft != key.value else { return }
        draft = key.value
    }

    private func commitIfTyped() {
        guard TitleEditorModel.shouldCommit(draft: draft, lastKnown: lastKnown) else { return }
        lastKnown = draft
        commit(draft)
    }
}
