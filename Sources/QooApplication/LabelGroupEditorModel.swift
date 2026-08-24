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
        /// バッジに出す件数 [LE-03]。**保管庫のファイルも数える** [LE-05]
        /// ——紐づけは維持されているので、保管庫へ入れただけで「0 件」に
        /// 見えてはならない（`fileCount` はフィルタ用で数えない [FA-05]）。
        public var fileCount: Int { label.fileCountIncludingArchived }
        /// 紐づけが 0 件 [LE-04][RC-07]。**再計算で 0 になっても自動削除しない**
        /// ので、赤字で「消してよさそう」だと分かるようにする。
        public var isOrphaned: Bool { label.fileCountIncludingArchived == 0 }
        /// 保管庫にある [LE-06]。グレー文字＋バッジ。
        public var isArchived: Bool { label.isArchived }
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
    /// 選択中のグループのラベル。**アーカイブ済みも含む** [LE-06][LA-06]
    /// ——この画面と保管庫の整理ウインドウだけが、それを見せてよい場所。
    public private(set) var allLabels: [LabelSummary] = []

    public var selectedLibraryID: LibraryID? {
        didSet { guard oldValue != selectedLibraryID else { return }; selectedGroupID = nil }
    }
    public var selectedGroupID: LabelGroupID?
    /// 一覧で選んでいるラベル。保管庫と削除は複数まとめて扱える [LE-07]。
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

    /// **並べ替えはバッジと同じ件数で決める** [LE-05]。一覧に出ている数字と
    /// 並び順が食い違うと、何を基準に並んでいるのか読めなくなる
    /// （`fileCount` はフィルタ用で保管庫を数えない [FA-05]）。
    nonisolated private static func byFileCountThenName(_ a: LabelSummary,
                                                       _ b: LabelSummary) -> Bool {
        if a.fileCountIncludingArchived != b.fileCountIncludingArchived {
            return a.fileCountIncludingArchived > b.fileCountIncludingArchived
        }
        return a.name.localizedStandardCompare(b.name) == .orderedAscending
    }

    /// 統合先に選べる相手 [LB-07][LE-11]。
    ///
    /// **同じグループの、自分以外。** グループをまたぐ統合はリポジトリが断る
    /// ので、そもそも選ばせない（押せるのに必ず失敗する項目を出さない）。
    /// 保管庫にあるものも相手にできる——統合は表記ゆれの是正で、片方が保管庫に
    /// あるのはむしろ普通の状況。
    nonisolated public static func mergeTargets(from labels: [LabelSummary],
                                                excluding source: LabelID) -> [LabelSummary] {
        labels.filter { $0.id != source }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public var selectedLabels: [LabelSummary] {
        allLabels.filter { selection.contains($0.id) }
    }

    /// 保管庫へ「移す」を出すか「戻す」を出すか [LA-01][LA-08]。
    ///
    /// **選択が混ざっていたら「移す」。** 一部が保管庫にあるとき、揃える先として
    /// 自然なのは移すほう（三状態のチェックボックスで `.some` を押したら全部に
    /// 付ける、としたのと同じ考え方 [RP-02]）。
    ///
    /// **何も選んでいないときも「移す」**［実機検証で発見］。ボタンは押せないが、
    /// 何も選んでいない画面に「保管庫から戻す」と出ていると、まれで逆向きの
    /// 操作をこの画面の主目的だと読ませてしまう。
    public var archiveActionArchives: Bool {
        selectedLabels.isEmpty || !selectedLabels.allSatisfy(\.isArchived)
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
            // **アーカイブ済みも読む** [LE-06]。この画面は保管庫の中身を
            // 見せてよい数少ない場所のひとつ [LA-06]。
            allLabels = try await services.labels(groupID: groupID, includeArchived: true)
            selection = selection.filter { id in allLabels.contains { $0.id == id } }
            state = .ready
        } catch {
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

    /// 選択したものを保管庫へ移す／戻す [LA-01][LA-08][LE-09]。
    public func setSelectedArchived(_ archived: Bool) async throws {
        guard let services else { return }
        let previous = selectedLabels.map {
            SetLabelArchivedCommand.Previous(id: $0.id, name: $0.name, isArchived: $0.isArchived)
        }
        guard previous.contains(where: { $0.isArchived != archived }) else { return }
        _ = try await commands.run(SetLabelArchivedCommand(
            previous: previous, archived: archived, services: services))
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
