//
//  ラベル保管庫の整理ウインドウ [LAW-01〜LAW-03][LA-01][LA-06][LA-08][15.3 節]。
//
//  **`qooLibraryApp` ではなく `QooApplication` に置く**——アプリターゲットの
//  コードは `swift test` から触れないため、判定（グループごとの整理・並べ替え・
//  検索・既定で選ぶライブラリ）を自動テストで固定できなくなる
//  （`LabelGroupEditorModel` / `LabelEditorModel` と同じ理由）。SwiftUI に依存しない。
//
//  ## ラベル編集ウインドウとの棲み分け［ユーザー判断］
//  このウインドウで触れるのは **LAW-01〜03 の 3 つだけ**——戻す・一括で戻す・
//  削除（コンテキストメニューのみ）。改名・統合・色・ピンはラベル編集ウインドウ
//  [LE-01〜12] の仕事で、そちらへ飛ぶ導線だけを置く。**同じ編集を 2 箇所に
//  実装しない**——このリポジトリはそれで 3 度取り残しを作っている。
//
//  ## それでもこのウインドウが要る理由
//  ラベル編集ウインドウも保管庫の中身を見せる [LE-06][LA-06] が、あちらは
//  **グループを 1 つ選んでから**でないと見えない。「どこかへ送ったが、どの
//  グループだったか思い出せない」を解けるのはこちらだけ——横断して一覧する
//  ことがこの画面の存在理由である。
//
//  ## 一覧の形
//  §15.3 が「グループごとに整理」と定めているので**セクション**にする。
//  並べ替え [ユーザー判断で採択] は**セクションの中**へ適用する——グループを
//  またいで混ぜるとその整理が消えるため。セクションどうしの順序はラベル
//  フィルタと同じ `displayOrder`（ライブラリ単位の永続設定 [ST-23]）。
//
import Foundation
import Observation
import QooKit

@MainActor
@Observable
public final class LabelVaultModel {

    /// 一覧の 1 区画＝ラベルグループ 1 つ [15.3 節「グループごとに整理」]。
    public struct Section: Sendable, Hashable, Identifiable {
        public let group: LabelGroupSummary
        /// そのグループの**アーカイブ済み**ラベル。並べ替えと検索を適用済み。
        public let rows: [LabelGroupEditorModel.Row]
        public var id: LabelGroupID { group.id }

        public init(group: LabelGroupSummary, rows: [LabelGroupEditorModel.Row]) {
            self.group = group
            self.rows = rows
        }
    }

    public enum State: Sendable, Equatable {
        case notReady
        case loading
        /// ライブラリが 1 件も無い（`LabelGroupEditorModel` の `.noSelection` と
        /// 違い、こちらは「選べるものが無い」の意味）。
        case noLibrary
        case ready
        case failed(String)
    }

    public private(set) var state: State = .notReady
    public private(set) var libraries: [LibrarySummary] = []
    /// ライブラリごとのアーカイブ済みラベル件数。**左ペインのグレーアウト**
    /// [15.3 節] と、既定で選ぶライブラリの決定に使う。0 件はキーごと現れない。
    public private(set) var archivedCounts: [LibraryID: Int] = [:]
    public private(set) var groups: [LabelGroupSummary] = []
    /// 選択中ライブラリのアーカイブ済みラベル（グループごと）。
    public private(set) var archivedLabels: [LabelGroupID: [LabelSummary]] = [:]

    public var selectedLibraryID: LibraryID? {
        didSet { guard oldValue != selectedLibraryID else { return }; selection = [] }
    }
    /// 一括で戻す [LAW-03] と削除 [LAW-02] のための選択。
    public var selection: Set<LabelID> = []
    /// 並べ替え［ユーザー判断で採択］。**ラベル編集ウインドウと同じ型を使う**
    /// ——同じ意味のものに列挙型を 2 つ作らない。
    public var sortOrder: LabelGroupEditorModel.SortOrder = .name
    public var searchText: String = ""

    private let commands: CommandStack
    private var services: LibraryServices?

    public init(commands: CommandStack = .shared) {
        self.commands = commands
    }

    // MARK: - 表示（純粋関数）

    public var sections: [Section] {
        Self.sections(groups: groups, labels: archivedLabels,
                      sortedBy: sortOrder, matching: searchText)
    }

    /// **判定はここ 1 箇所。** View に書くとテストで固定できず、`reload` に
    /// 埋めると並べ替えや検索のたびに DB を読み直すことになる。
    ///
    /// - **アーカイブ済みだけを通す。** 呼び出し側が絞って渡す前提だが、
    ///   この関数が不変条件を自分で守るほうが安全側に倒れる——保管庫の画面に
    ///   保管庫外のラベルが混ざるのは、意味そのものが壊れた状態になる。
    /// - **行が 0 件になったグループは落とす。** 検索で全部消えたグループの
    ///   見出しだけが残ると、何のための区画か読めない。
    /// - 並べ替えと検索は `LabelGroupEditorModel.rows` に委ねる——**同じ
    ///   一覧の作り方を 2 つ持たない**（検索は `NameFilter` なので全角で
    ///   打っても半角のラベルに当たる）。
    nonisolated public static func sections(
        groups: [LabelGroupSummary],
        labels: [LabelGroupID: [LabelSummary]],
        sortedBy order: LabelGroupEditorModel.SortOrder,
        matching searchText: String
    ) -> [Section] {
        groups.compactMap { group in
            let archived = (labels[group.id] ?? []).filter(\.isArchived)
            let rows = LabelGroupEditorModel.rows(from: archived,
                                                  sortedBy: order, matching: searchText)
            return rows.isEmpty ? nil : Section(group: group, rows: rows)
        }
    }

    /// 既定で選ぶライブラリ [15.3 節]。
    ///
    /// **明示的に指定されたものが最優先**——その登録の保管庫を見に来たのだから、
    /// 空でもそのライブラリを見せる（「空だった」という答えも答えである）。
    ///
    /// 指定が無ければ**アーカイブ済みラベルを持つ最初のライブラリ**［設計判断］。
    /// 素直に先頭を選ぶと保管庫が空のライブラリに着地して行き止まりになる
    /// ——ラベル編集ウインドウが「ラベルを持つ最初のグループ」を選ぶのと同じ理由。
    /// どのライブラリにも無ければ先頭へ落とす。
    nonisolated public static func defaultLibrary(from libraries: [LibrarySummary],
                                                  archivedCounts: [LibraryID: Int],
                                                  preferring preferred: LibraryID?) -> LibraryID? {
        if let preferred, libraries.contains(where: { $0.id == preferred }) { return preferred }
        if let populated = libraries.first(where: { (archivedCounts[$0.id] ?? 0) > 0 }) {
            return populated.id
        }
        return libraries.first?.id
    }

    public var selectedLabels: [LabelSummary] {
        archivedLabels.values.flatMap { $0 }.filter { selection.contains($0.id) }
    }

    /// 選択中のライブラリの保管庫が空か。空状態の出し分けに使う。
    ///
    /// **検索で 0 件になった場合と区別する**ため、`sections` ではなく
    /// 読み込んだ生データを見る——「保管庫は空です」と「一致しません」は
    /// 次の一手が違う（前者は閉じる、後者は検索語を消す）。
    public var vaultIsEmpty: Bool {
        archivedLabels.values.allSatisfy { $0.isEmpty }
    }

    // MARK: - 読み込み

    public func prepare(services: LibraryServices, preferring libraryID: LibraryID? = nil) async {
        self.services = services
        guard services.isReady else { state = .notReady; return }
        state = .loading
        await reload(preferring: libraryID)
    }

    /// - Parameter preferred: 入口が指定したライブラリ。**指定があるときだけ
    ///   選択を動かす**——⌘Z のたびに呼ばれる `reload()` が、利用者の選んだ
    ///   ライブラリを勝手に切り替えてはならない。
    public func reload(preferring preferred: LibraryID? = nil) async {
        guard let services, services.isReady else { state = .notReady; return }
        libraries = services.libraries
        guard !libraries.isEmpty else {
            archivedCounts = [:]; groups = []; archivedLabels = [:]
            selectedLibraryID = nil
            state = .noLibrary
            return
        }
        do {
            archivedCounts = try await services.archivedLabelCounts()
            // 選択が消えていたら（登録解除・無効化）選び直す。
            //
            // **「DB の準備より先に確定してしまう」競合はここでは解けない**
            // ［自分のレビューで気づいた]。`libraries` は格納プロパティなので、
            // 準備が終わっても誰かが `reload()` を呼ばない限り `.notReady` の
            // ままである。救っているのは `LabelVaultWindow` 側の
            // `.onChange(of: LibraryServices.shared.isReady)`——**この保護は
            // View にしか無い**ので、モデルを別の画面から使うときは同じ配線が要る。
            let current = selectedLibraryID
            if preferred != nil || current == nil
                || !libraries.contains(where: { $0.id == current }) {
                selectedLibraryID = Self.defaultLibrary(from: libraries,
                                                        archivedCounts: archivedCounts,
                                                        preferring: preferred)
            }
            guard let libraryID = selectedLibraryID else {
                groups = []; archivedLabels = [:]; state = .noLibrary; return
            }
            groups = try await services.labelGroups(libraryID: libraryID)
            var loaded: [LabelGroupID: [LabelSummary]] = [:]
            for group in groups {
                // **アーカイブ済みだけを残す** [LA-06]。この画面と
                // ラベル編集ウインドウだけが保管庫の中身を見せてよい。
                loaded[group.id] = try await services
                    .labels(groupID: group.id, includeArchived: true)
                    .filter(\.isArchived)
            }
            archivedLabels = loaded
            selection = selection.filter { id in loaded.values.contains { $0.contains { $0.id == id } } }
            state = .ready
        } catch {
            // **取り消しは失敗ではない**［2-9 の実機検証でユーザーが発見］。
            // `.task(id:)` は鍵が変わると前のタスクを取り消すので、選択を
            // 素早く変えたり読み直しの合図（`operationHistory.count`・
            // `contentRevision`）が続けて来たりすると、ここへ
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

    /// 保管庫から戻す [LAW-01][LAW-03][LA-08]。
    ///
    /// **変更前の状態を 1 件ずつ渡す**（`SetLabelArchivedCommand` の契約）。
    /// ここへ来るのは必ずアーカイブ済みだが、一律に組み立てると
    /// 「呼び出し側が実際の状態を見ている」という保証が消える。
    public func restore(_ labels: [LabelSummary]) async throws {
        guard let services, !labels.isEmpty else { return }
        let previous = labels.map {
            SetLabelArchivedCommand.Previous(id: $0.id, name: $0.name, isArchived: $0.isArchived)
        }
        guard previous.contains(where: \.isArchived) else { return }
        _ = try await commands.run(SetLabelArchivedCommand(
            previous: previous, archived: false, services: services))
        await reload()
    }

    public func restoreSelected() async throws {
        try await restore(selectedLabels)
    }

    /// 削除 [LAW-02][LE-07][LE-08]。**確認は呼び出し側**——何件のファイルから
    /// 外れるかを見せてから決めさせる（ラベル編集ウインドウと同じ確認を共有する）。
    public func deleteSelected() async throws {
        guard let services else { return }
        let targets = selectedLabels
        guard !targets.isEmpty else { return }
        _ = try await commands.run(DeleteLabelsCommand(
            labelIDs: targets.map(\.id), labelNames: targets.map(\.name), services: services))
        // `reload()` も一覧に無い選択を落とすが、読み取りに失敗すると
        // （`state = .failed` で早期に返るため）そこへ届かない
        // ——消えたラベルを指したままの選択が残る。失敗経路のために残す。
        selection = []
        await reload()
    }
}
