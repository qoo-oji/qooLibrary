//
//  ラベルグループ編集ウインドウ [LE-01〜LE-12][15.2 節]。
//
//  **`qooLibraryApp` ではなく `QooApplication` に置く**——アプリターゲットの
//  コードは `swift test` から触れないため、判定（並べ替え・検索・0 件の赤字・
//  保管庫の見せ方・統合できる相手）を自動テストで固定できなくなる
//  （`LabelEditorModel` / `RatingEditorModel` と同じ理由）。SwiftUI には依存しない。
//
//  ## 右ペインだけがこのモデルの担当
//  §15.2 の 3 ペインのうち、左（ライブラリ一覧）と中央（ラベルグループの改名・
//  予約語紐づけ）は**ライブラリ設定ウインドウと同じ経路を共有する**［ユーザー判断］
//  ——同じ編集を 2 箇所に実装すると、片方だけ直して取り残す（このリポジトリで
//  3 度踏んでいる形）。このモデルが持つのは**ラベルそのもの**の編集だけ。
//
import Foundation
import Observation
import QooKit

@MainActor
@Observable
public final class LabelGroupEditorModel {

    /// 一覧の並べ方 [LE-12]。
    public enum SortOrder: String, Sendable, CaseIterable, Identifiable {
        /// 名前順。`localizedStandardCompare` の自然順（アプリの他の一覧と同じ）。
        case name
        /// 件数の多い順。**同数は名前順で決める**——並びが実行のたびに変わると、
        /// 同じ操作を繰り返したときに違う行を選んでしまう。
        case fileCount

        public var id: String { rawValue }
    }

    /// 一覧の 1 行。表示の判断まで済ませて View へ渡す。
    public struct Row: Sendable, Hashable, Identifiable {
        public let label: LabelSummary
        public var id: LabelID { label.id }
        public var name: String { label.name }
        /// バッジに出す件数 [LE-03]。**生きている実体の数だけ**を数える
        /// [LA3-01]——0 なら自動的に非表示になるので、ここで別の数を出すと
        /// 「3 件と出ているのに一覧では非表示」という食い違いになる
        /// [LE-05 撤回][§19.13 #1]。
        public var fileCount: Int { label.fileCount }
        /// 一覧で控えめに見せるか [LA3-03]。**手動の印と実体 0 件の両方**が対象
        /// ——どちらもフィルタから消えているという点で同じ状態だから。
        public var isHidden: Bool { !label.isVisible }
        /// 手動で非表示にした印 [LA3-02]。「表示に戻す」を出すかの判断に使う。
        public var isManuallyHidden: Bool { label.isHidden }
        public var isPinned: Bool { label.isPinned }
        /// `nil` ならグループ色を継承 [CO-06]。
        public var colorHex: String? { label.colorHex }

        public init(label: LabelSummary) { self.label = label }
    }

    public enum State: Sendable, Equatable {
        case notReady
        case loading
        /// ライブラリはあるがグループが選ばれていない。
        case noSelection
        case ready
        case failed(String)
    }

    public private(set) var state: State = .notReady
    public private(set) var libraries: [LibrarySummary] = []
    public private(set) var groups: [LabelGroupSummary] = []
    /// 選択中のグループのラベル。**非表示のものも含む** [LA3-03]
    /// ——実体 0 件・手動非表示のラベルを整理できる唯一の場所。
    public private(set) var allLabels: [LabelSummary] = []

    public var selectedLibraryID: LibraryID? {
        didSet { guard oldValue != selectedLibraryID else { return }; selectedGroupID = nil }
    }
    public var selectedGroupID: LabelGroupID?
    /// 一覧で選んでいるラベル。非表示の切り替えと削除は複数まとめて扱える [LE-07]。
    public var selection: Set<LabelID> = []
    public var sortOrder: SortOrder = .name
    public var searchText: String = ""

    private let commands: CommandStack
    private var services: LibraryServices?

    public init(commands: CommandStack = .shared) {
        self.commands = commands
    }

    // MARK: - 表示（純粋関数）

    /// 並べ替えと検索を適用した一覧 [LE-12]。
    public var rows: [Row] { Self.rows(from: allLabels, sortedBy: sortOrder, matching: searchText) }

    /// **判定はここ 1 箇所。** View に書くとテストで固定できず、`load` に埋めると
    /// 並べ替えや検索のたびに DB を読み直すことになる。
    ///
    /// 検索は `NameFilter`——**全角で打っても半角のラベルに当たる**。日本語入力を
    /// オンにしたまま英字を打つのはごく普通のことで、幅までユーザーに合わせさせない
    /// （CLAUDE.md 冒頭の大原則。ツールバーの検索と同じ判定を使う）。
    nonisolated public static func rows(from labels: [LabelSummary],
                                        sortedBy order: SortOrder,
                                        matching searchText: String) -> [Row] {
        let filtered = labels.filter { NameFilter.matches(name: $0.name, query: searchText) }
        let sorted: [LabelSummary]
        switch order {
        case .name:
            sorted = filtered.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .fileCount:
            // **同数は名前順で決める。** ここを 1 つの三項演算子で書くと
            // Swift の型検査が現実的な時間で終わらない（このコードベースで
            // 繰り返し起きている形）ので、素直な関数に分ける。
            sorted = filtered.sorted(by: Self.byFileCountThenName)
        }
        return sorted.map(Row.init)
    }

    /// **並べ替えはバッジと同じ件数で決める。** 一覧に出ている数字と並び順が
    /// 食い違うと、何を基準に並んでいるのか読めなくなる（件数の意味が
    /// 1 つになった [§19.13 #1] ので、取り違えようが無くなった）。
    nonisolated private static func byFileCountThenName(_ a: LabelSummary,
                                                       _ b: LabelSummary) -> Bool {
        if a.fileCount != b.fileCount { return a.fileCount > b.fileCount }
        return a.name.localizedStandardCompare(b.name) == .orderedAscending
    }

    /// 統合先に選べる相手 [LB-07][LE-11]。
    ///
    /// **同じグループの、自分以外。** グループをまたぐ統合はリポジトリが断る
    /// ので、そもそも選ばせない（押せるのに必ず失敗する項目を出さない）。
    /// 非表示のものも相手にできる——統合は表記ゆれの是正で、片方が非表示なのは
    /// むしろ普通の状況。
    nonisolated public static func mergeTargets(from labels: [LabelSummary],
                                                excluding source: LabelID) -> [LabelSummary] {
        labels.filter { $0.id != source }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public var selectedLabels: [LabelSummary] {
        allLabels.filter { selection.contains($0.id) }
    }

    /// 「非表示にする」を出すか「表示に戻す」を出すか [LA3-02][LA3-03]。
    ///
    /// **選択が混ざっていたら「非表示にする」。** 一部が非表示のとき、揃える先
    /// として自然なのは隠すほう（三状態のチェックボックスで `.some` を押したら
    /// 全部に付ける、としたのと同じ考え方 [RP-02]）。
    ///
    /// **何も選んでいないときも「非表示にする」**［実機検証で発見］。ボタンは
    /// 押せないが、何も選んでいない画面に「表示に戻す」と出ていると、まれで
    /// 逆向きの操作をこの画面の主目的だと読ませてしまう。
    ///
    /// 見るのは**手動の印だけ** [LA3-02]——実体 0 件による非表示 [LA3-01] は
    /// 導出なので、「表示に戻す」で解けるものではない。
    public var hideActionHides: Bool {
        selectedLabels.isEmpty || !selectedLabels.allSatisfy(\.isHidden)
    }

    // MARK: - 読み込み

    public func prepare(services: LibraryServices, preferring libraryID: LibraryID? = nil) async {
        self.services = services
        guard services.isReady else { state = .notReady; return }
        state = .loading
        libraries = services.libraries
        if let libraryID, libraries.contains(where: { $0.id == libraryID }) {
            selectedLibraryID = libraryID
        }
        syncSelection()
        await reload()
    }

    /// 一覧が遅れて届いたときに選択を合わせる。
    ///
    /// **起動と同時に状態復元で開かれると、DB の準備より先に「未選択」で
    /// 確定してしまう**——`RegisteredFolderStore.ensureLoaded` や設定ウインドウで
    /// 実際に踏んだ競合なので、変化にも乗せる。
    public func syncSelection() {
        if let id = selectedLibraryID, libraries.contains(where: { $0.id == id }) { return }
        selectedLibraryID = libraries.first?.id
    }

    public func reload() async {
        guard let services, services.isReady else { state = .notReady; return }
        libraries = services.libraries
        syncSelection()
        guard let libraryID = selectedLibraryID else {
            groups = []; allLabels = []; state = .noSelection; return
        }
        do {
            groups = try await services.labelGroups(libraryID: libraryID)
            if selectedGroupID == nil || !groups.contains(where: { $0.id == selectedGroupID }) {
                selectedGroupID = groups.first?.id
            }
            guard let groupID = selectedGroupID else {
                allLabels = []; state = .noSelection; return
            }
            // **非表示のものも読む** [LA3-03]。この画面が、実体 0 件・手動非表示の
            // ラベルを整理できる唯一の場所である。
            allLabels = try await services.labels(groupID: groupID)
            selection = selection.filter { id in allLabels.contains { $0.id == id } }
            state = .ready
        } catch {
            // **取り消しは失敗ではない**［2-9 の実機検証でユーザーが発見］。
            // `.task(id:)` は鍵が変わると前のタスクを取り消すので、選択を
            // 素早く変えたり読み直しの合図（`LibraryGeneration`）が
            // 続けて来たりすると、ここへ
            // `CancellationError` が届く。そのまま出すと画面に
            // 「タイトル: CancellationError()」という、利用者にとって
            // 意味の無い赤字が残る——**直後に新しい読み込みが正しい値を
            // 入れる**ので、出しても一瞬で消える（あるいは消えない）という
            // 最も分かりにくい形になる。状態は次の読み込みが上書きする。
            guard !CommandStack.isCancellation(error) else { return }
            state = .failed(String(describing: error))
        }
    }

    // MARK: - 操作（すべて CommandStack を通す）

    /// 改名 [LB-06][LE-07]。衝突したら `LabelEditError.nameAlreadyExists` が飛ぶ
    /// ——呼び出し側が「代わりに統合しますか」を出せる [LE-11]。
    public func rename(_ label: LabelSummary, to name: String) async throws {
        guard let services else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != label.name else { return }
        _ = try await commands.run(RenameLabelCommand(
            labelID: label.id, previousName: label.name, newName: trimmed, services: services))
        await reload()
    }

    /// 新しいラベルを作る [LE-07]。既に同じ正規化名があればそれを選ぶだけ [LB-01]。
    public func createLabel(named name: String) async throws {
        guard let services, let groupID = selectedGroupID else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // **作成は Undo に載せない**［設計判断］。紐づけを持たない空のラベルが
        // 増えるだけで、消したければ削除（Undo 可）で片付く。載せると
        // 「作る → ⌘Z で消える → ⇧⌘Z で別 ID で復活」という、ID の安定性を
        // 崩す経路を新しく作ることになる。
        let id = try await services.ensureLabel(groupID: groupID, name: trimmed)
        await reload()
        selection = [id]
    }

    public func setColor(_ label: LabelSummary, hex: String?) async throws {
        guard let services, label.colorHex != hex else { return }
        _ = try await commands.run(SetLabelColorCommand(
            labelID: label.id, labelName: label.name,
            previousHex: label.colorHex, newHex: hex, services: services))
        await reload()
    }

    public func setPinned(_ label: LabelSummary, _ pinned: Bool) async throws {
        guard let services, label.isPinned != pinned else { return }
        _ = try await commands.run(SetLabelPinnedCommand(
            labelID: label.id, labelName: label.name, pinned: pinned, services: services))
        await reload()
    }

    /// 選択したものを手動で非表示にする／表示に戻す [LA3-02][LE-09]。
    public func setSelectedHidden(_ hidden: Bool) async throws {
        guard let services else { return }
        let previous = selectedLabels.map {
            SetLabelHiddenCommand.Previous(id: $0.id, name: $0.name, isHidden: $0.isHidden)
        }
        guard previous.contains(where: { $0.isHidden != hidden }) else { return }
        _ = try await commands.run(SetLabelHiddenCommand(
            previous: previous, hidden: hidden, services: services))
        await reload()
    }

    /// 選択したものを削除する [LE-07][LE-08]。**確認は呼び出し側**——
    /// 何件のファイルから外れるかを見せてから決めさせる。
    public func deleteSelected() async throws {
        guard let services else { return }
        let targets = selectedLabels
        guard !targets.isEmpty else { return }
        _ = try await commands.run(DeleteLabelsCommand(
            labelIDs: targets.map(\.id), labelNames: targets.map(\.name), services: services))
        // **この 1 行は変異検証では空振りする**——`reload()` が「一覧に無い
        // 選択を落とす」ので、消しても幸せな経路では結果が同じになる。
        // それでも残すのは、`reload()` が読み取りに失敗したときは
        // （`state = .failed` で早期に返るため）その後始末に届かず、
        // **消えたラベルを指したままの選択が残る**から。壊れるのは失敗経路
        // だけなので、通ることを理由に外さないこと。
        selection = []
        await reload()
    }

    /// 統合 [LB-07][LE-11]。
    public func merge(_ source: LabelSummary, into target: LabelSummary) async throws {
        guard let services, source.id != target.id else { return }
        _ = try await commands.run(MergeLabelsCommand(
            source: source.id, sourceName: source.name,
            target: target.id, targetName: target.name, services: services))
        selection = [target.id]
        await reload()
    }
}
