//
//  右ペインのラベル設定 [RL-01〜RL-07][RP-02]。
//
//  **`qooLibraryApp` ではなく `QooApplication` に置く**——アプリターゲットの
//  コードは `swift test` から触れないため、判定（三状態の畳み込み、アーカイブ
//  済みラベルの出し分け [LA-03][RL-05]、自動／手動の区別 [RL-06]、DB に行が
//  無いものの扱い）を自動テストで固定できなくなる（`RatingEditorModel` と
//  同じ理由）。SwiftUI には依存しない。
//
import Foundation
import Observation
import QooKit

/// 右ペインが 1 つ持つ、選択中のファイルのラベル。
@MainActor
@Observable
public final class LabelEditorModel {
    /// ラベル欄の状態。
    public enum State: Sendable, Equatable {
        /// ライブラリ経由で開いていない、またはライブラリ機能が使えない。
        /// **欄ごと出さない** [LF-01 と同じ判断]。
        case notApplicable
        case loading
        /// 選択したもののうち 1 件も DB に無い。**理由を出す**［ユーザー判断］
        /// ——黙って消すと「付けられない」のか「壊れている」のか区別が付かない
        /// （評価と同じ）。
        case notInLibrary
        case ready(Subject)
        case failed(String)
    }

    /// 編集の対象。単一選択でも複数選択でも同じ型で表す [RP-02]。
    public struct Subject: Sendable, Equatable {
        /// DB に行があったものだけ。`urls` と同順。
        public let fileIDs: [FileID]
        /// 診断ログ用の絶対パス [LG2-06]。`fileIDs` と同順。
        public let urls: [URL]
        /// 選択した総数。**DB に行が無いものも数える**——差を出すため。
        public let selectedCount: Int
        /// コマンドの表示名に使う呼び名。
        public let displayName: String

        public var targetCount: Int { fileIDs.count }
        /// DB に行が無くて対象から外れた件数 [RP-02]。0 でなければ画面に出す
        /// ——「10 件選んだのに 8 件にしか付かなかった」を黙って起こさない。
        public var skippedCount: Int { max(0, selectedCount - fileIDs.count) }

        public init(fileIDs: [FileID], urls: [URL], selectedCount: Int, displayName: String) {
            self.fileIDs = fileIDs
            self.urls = urls
            self.selectedCount = selectedCount
            self.displayName = displayName
        }
    }

    /// 1 つのラベルが、選択したファイルにどう付いているか。
    public struct Assignment: Sendable, Equatable {
        /// 付いている件数（`manuallyRemoved` は「付いていない」）。
        public let assignedCount: Int
        public let targetCount: Int
        /// **付いているものがすべて自動付与か** [RL-06]。混在なら偽——手動で
        /// 付けたものが含まれるのに「自動」の印を出すと、再スキャンで消える
        /// ものだと読めてしまう。
        public let isAutomatic: Bool

        public var checkState: CheckState {
            if assignedCount == 0 { return .none }
            return assignedCount == targetCount ? .all : .some
        }

        public init(assignedCount: Int, targetCount: Int, isAutomatic: Bool) {
            self.assignedCount = assignedCount
            self.targetCount = targetCount
            self.isAutomatic = isAutomatic
        }
    }

    /// チェックボックスの三状態 [RP-02]。
    public enum CheckState: Sendable, Equatable {
        case none, some, all
    }

    public private(set) var state: State = .notApplicable

    /// 追加ダイアログでグループを選ばせるための全グループ [RL-02]。
    /// **ラベル 0 件のグループも含める**——新しいラベルを作る先として要る
    /// （常設の一覧に出すかどうかは `displayGroups` が別に決める）。
    public private(set) var allGroups: [LabelGroupSummary] = []

    /// 常設の一覧に並べるグループ [RL-04]。
    public private(set) var displayGroups: [LabelGroupSummary] = []

    /// グループごとのラベル。**アーカイブ済みも読む**——付与済みなら出す
    /// 必要がある [RL-05] ので、読んでから出し分ける。
    public private(set) var labels: [LabelGroupID: [LabelSummary]] = [:]

    /// 展開しているグループ。
    public var expandedGroups: Set<LabelGroupID> = []
    /// 「もっと見る」で全ラベルを出しているグループ [PN-02][PN-05]。
    public var revealedGroups: Set<LabelGroupID> = []
    /// 「もっと見る」の中のインクリメンタル検索 [PN-05]。
    public var searchText: [LabelGroupID: String] = [:]

    /// ラベルを**付けた**ときに、同じ Undo 単位で一緒に走らせる操作 [UD-04]。
    ///
    /// 未解決ファイルの整理ウインドウが「以後無視する」を立てるために使う
    /// [AL-30]①③［ユーザー判断、2026-08］——手で片付けたのに一覧に残り
    /// 続けるのを避ける。**右ペイン（インスペクタ）では設定しない**：
    /// 蔵書のどのファイルにラベルを付けても未解決の判断が動いてはならない。
    ///
    /// **返した操作は `CompositeCommand` で束ねる**ので、⌘Z 1 回で両方戻る
    /// ——別々に積むと「ラベルは戻ったが一覧に出てこない」半端な状態を
    /// 経由することになる。変える必要が無ければ `nil` を返すこと。
    @ObservationIgnored
    public var onAssign: ((_ fileIDs: [FileID]) -> (any Command)?)?

    private let commands: CommandStack
    private var services: LibraryServices?
    private var library: LibrarySummary?
    /// ファイルごとの紐づけ。`undo()` へ渡す「変更前の状態」の出どころ。
    private var assignmentsByFile: [FileID: [LabelID: LabelOrigin]] = [:]
    /// `fileIDs` と同順の URL 対応。
    private var urlByFile: [FileID: URL] = [:]
    /// 直近で読み込んだ対象。**同じ対象の読み直しではスピナーへ戻さない**
    /// ——ラベルを 1 つ付けるたび、また無関係なファイル操作のたびに読み直しが
    /// 走るので、そのたびに一覧が消えると激しくちらつく。
    private var loadedKey: [URL]?

    public init(commands: CommandStack = .shared) {
        self.commands = commands
    }

    // MARK: - 問い合わせ

    /// そのラベルの付き方 [RL-04][RL-06]。
    public func assignment(of label: LabelSummary) -> Assignment {
        guard case .ready(let subject) = state else {
            return Assignment(assignedCount: 0, targetCount: 0, isAutomatic: false)
        }
        var assigned = 0
        var allAuto = true
        for id in subject.fileIDs {
            guard let origin = assignmentsByFile[id]?[label.id], origin != .manuallyRemoved else {
                continue
            }
            assigned += 1
            if origin != .auto { allAuto = false }
        }
        return Assignment(assignedCount: assigned, targetCount: subject.targetCount,
                          isAutomatic: assigned > 0 && allAuto)
    }

    /// 1 件でも付いているか。一覧に出すかどうかの判定に使う [RL-05]。
    public func isAssigned(_ label: LabelSummary) -> Bool {
        assignment(of: label).assignedCount > 0
    }

    /// そのグループで実際に並べるラベル [RL-04][RL-05][LA-03]。
    ///
    /// 並べ方は `PinnedLabelListing`——**ラベルフィルタと同じ規則**で並べる
    /// ことを RL-04 が名指しで要求している。ここが渡すのは「付与済みは必ず
    /// 含める」[RL-05] だけ。
    ///
    /// **アーカイブ済みは候補に出さないが、付与済みなら出す** [LA-03][RL-05]。
    /// 出さないと「画面に無いのに付いている」ラベルができ、外す手段が消える。
    public func visibleLabels(in group: LabelGroupSummary) -> [LabelSummary] {
        PinnedLabelListing.visible(
            candidates(in: group),
            collapsedLimit: AppLimits.LabelFilter.collapsedLabelCount,
            isRevealed: revealedGroups.contains(group.id),
            searchText: searchText[group.id] ?? "",
            mustInclude: { self.isAssigned($0) })
    }

    public func hasMoreLabels(in group: LabelGroupSummary) -> Bool {
        PinnedLabelListing.hasMore(
            candidates(in: group),
            collapsedLimit: AppLimits.LabelFilter.collapsedLabelCount,
            isRevealed: revealedGroups.contains(group.id),
            mustInclude: { self.isAssigned($0) })
    }

    /// 追加ダイアログで既存ラベルとして選べるもの [RL-02][LA-03]。
    public func addableLabels(in group: LabelGroupSummary) -> [LabelSummary] {
        Self.addable(from: labels[group.id] ?? [])
    }

    private func candidates(in group: LabelGroupSummary) -> [LabelSummary] {
        Self.candidates(from: labels[group.id] ?? [], isAssigned: { self.isAssigned($0) })
    }

    /// 常設の一覧に出す候補 [LA-03][RL-05]。
    ///
    /// **アーカイブ済みは出さないが、付与済みなら出す。** 出さないと「画面に
    /// 無いのに付いている」ラベルができ、外す手段が消える——`LA-03` が禁じて
    /// いるのは*追加候補*に出すことであって、既に付いているものを隠すことでは
    /// ない。**この 1 行が LA-03 と RL-05 の境目そのもの**なので、View にも
    /// `load` にも埋めずここに置く（`starsAfterTapping` と同じ理由）。
    nonisolated public static func candidates(
        from all: [LabelSummary], isAssigned: (LabelSummary) -> Bool
    ) -> [LabelSummary] {
        all.filter { !$0.isArchived || isAssigned($0) }
    }

    /// 追加の候補 [LA-03]。**付与済みでも、アーカイブ済みなら候補に出さない。**
    nonisolated public static func addable(from all: [LabelSummary]) -> [LabelSummary] {
        all.filter { !$0.isArchived }
    }

    // MARK: - 読み込み

    /// 選択中のファイルのラベルを読む。
    ///
    /// - Parameters:
    ///   - urls: 選択中の項目。空なら欄を出さない。
    ///   - library: それらが属するライブラリ。ボリューム経由で開いている場合は
    ///     `nil`（**URL から逆算しない**——判定は呼び出し側の責務）。
    public func load(urls: [URL], library: LibrarySummary?, services: LibraryServices) async {
        self.services = services
        self.library = library
        let sorted = urls.sorted { $0.path < $1.path }
        guard !sorted.isEmpty, let library, services.isReady else {
            loadedKey = nil
            state = .notApplicable
            return
        }
        beginLoading(key: sorted)
        do {
            let rows = try await services.fileRows(at: sorted, in: library)
            // **選んだ順（パス順）を保つ。** 辞書の列挙順に任せると、読み直す
            // たびに一覧の中身が同じでも別の並びになりうる。
            let ordered = sorted.compactMap { url in rows[url].map { (url, $0) } }
            try await finishLoading(ordered: ordered, selectedCount: sorted.count,
                                    library: library, services: services)
        } catch {
            handleLoadFailure(error)
        }
    }

    /// **DB の行から直接読み込む。** 実体を stat しないので、ボリュームが
    /// オフラインでも動く。
    ///
    /// 未解決ファイルの整理ウインドウ [UR-03][UR-06] がこれを使う——あちらは
    /// 実体を 1 度も見ない画面なので、`load(urls:)`（`fileRows(at:in:)` が
    /// inode を読むため実体が要る）を使うと**オフラインのときだけラベルを
    /// 付けられない**という、画面からは説明の付かない差が出る。
    ///
    /// `url` は診断ログの匿名化 [LG2-06] と表示名にしか使わないので、
    /// `library.resolvedPath` と相対パスから組み立てた値で足りる。
    public func load(rows: [FileRow], library: LibrarySummary?,
                     services: LibraryServices) async {
        self.services = services
        self.library = library
        guard !rows.isEmpty, let library, services.isReady else {
            loadedKey = nil
            state = .notApplicable
            return
        }
        let root = URL(fileURLWithPath: library.resolvedPath)
        let ordered = rows
            .map { (root.appendingPathComponent($0.relativePath), $0) }
            .sorted { $0.0.path < $1.0.path }
        beginLoading(key: ordered.map(\.0))
        do {
            try await finishLoading(ordered: ordered, selectedCount: ordered.count,
                                    library: library, services: services)
        } catch {
            handleLoadFailure(error)
        }
    }

    /// 同じ対象を読み直すときはスピナーへ戻さない——読み直しの合図
    /// （`operationHistory.count` 等）が来るたびにちらつくため。
    private func beginLoading(key: [URL]) {
        if loadedKey != key {
            state = .loading
            loadedKey = key
        }
    }

    /// 行が揃ってからの共通部分。**`load(urls:)` と `load(rows:)` の両方が
    /// ここを通る**——同じ「ラベル欄の組み立て」を 2 箇所に書くと、片方だけ
    /// 直して取り残す。
    private func finishLoading(ordered: [(URL, FileRow)], selectedCount: Int,
                               library: LibrarySummary,
                               services: LibraryServices) async throws {
        guard !ordered.isEmpty else {
            assignmentsByFile = [:]
            state = .notInLibrary
            return
        }
        let fileIDs = ordered.map { $0.1.id }
        urlByFile = Dictionary(uniqueKeysWithValues: ordered.map { ($0.1.id, $0.0) })
        assignmentsByFile = try await services.labelAssignments(fileIDs: fileIDs)

        let groups = try await services.labelGroups(libraryID: library.id)
        var loaded: [LabelGroupID: [LabelSummary]] = [:]
        for group in groups {
            loaded[group.id] = try await services.labels(groupID: group.id,
                                                         includeArchived: true)
        }
        allGroups = groups
        labels = loaded
        state = .ready(Subject(
            fileIDs: fileIDs, urls: ordered.map(\.0), selectedCount: selectedCount,
            displayName: Self.displayName(for: ordered.map(\.0))))
        // 判定に `state` を使うので、`state` を入れてから絞る。
        displayGroups = groups.filter { group in
            !candidates(in: group).isEmpty
        }
    }

    /// **取り消しは失敗ではない**［2-9 の実機検証でユーザーが発見］。
    /// `.task(id:)` は鍵が変わると前のタスクを取り消すので、選択を素早く
    /// 変えたり読み直しの合図（`operationHistory.count`・`contentRevision`）が
    /// 続けて来たりすると、ここへ `CancellationError` が届く。そのまま出すと
    /// 画面に「タイトル: CancellationError()」という、利用者にとって意味の
    /// 無い赤字が残る——**直後に新しい読み込みが正しい値を入れる**ので、
    /// 出しても一瞬で消える（あるいは消えない）という最も分かりにくい形になる。
    private func handleLoadFailure(_ error: any Error) {
        guard !CommandStack.isCancellation(error) else { return }
        state = .failed(String(describing: error))
    }

    /// コマンドの表示名に使う呼び名。
    ///
    /// `Command.displayName` は Undo メニューに出るが、`QooApplication` の他の
    /// コマンドと同じく日本語を直書きしている——この層のコマンド名の翻訳は
    /// 一括で片付ける課題として残っているので、ここだけ別の形にしない。
    nonisolated static func displayName(for urls: [URL]) -> String {
        urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) 項目"
    }

    // MARK: - 操作

    /// チェックボックスを押す [RL-01][RL-03][RL-07][RP-02]。
    ///
    /// **`.some`（一部に付いている）を押したら全部に付ける。** 一般的な三状態
    /// チェックボックスの慣習で、しかも安全側——押して外れると、まだ付けて
    /// いなかったファイルではなく**付いていたファイルの側**が変わる。
    public func toggle(_ label: LabelSummary) async throws {
        let assigning = assignment(of: label).checkState != .all
        try await apply(label, assigning: assigning)
    }

    /// 既存ラベルを付ける [RL-02]。
    public func add(_ label: LabelSummary) async throws {
        try await apply(label, assigning: true)
    }

    /// 新しいラベルを作って付ける [RL-02]。
    ///
    /// 同じ正規化名のラベルが既にあればそれを使う [LB-01][N-03]——`ensureLabel`
    /// がその判断を持つので、ここで重複を調べない。
    public func createAndAdd(groupID: LabelGroupID, name: String) async throws {
        guard case .ready = state, let services else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let id = try await services.ensureLabel(groupID: groupID, name: trimmed)
        try await applyID(id, name: trimmed, assigning: true)
    }

    private func apply(_ label: LabelSummary, assigning: Bool) async throws {
        try await applyID(label.id, name: label.name, assigning: assigning)
    }

    private func applyID(_ labelID: LabelID, name: String, assigning: Bool) async throws {
        guard case .ready(let subject) = state, let services else { return }
        // 変更前の拾い方と no-op の判定は `AssignLabelCommand.toggling` に
        // 一本化してある [RL3-03]——中央ペインのメニュー（`LabelMenuModel`）と
        // 2 箇所に書かない。
        let files = subject.fileIDs.map { id in
            (id: id, url: urlByFile[id] ?? subject.urls.first ?? URL(fileURLWithPath: "/"))
        }
        guard let assign = AssignLabelCommand.toggling(
            labelID: labelID, labelName: name, files: files,
            assignments: assignmentsByFile, assigning: assigning,
            subjectName: subject.displayName, services: services) else { return }
        let target: LabelOrigin = assigning ? .manual : .manuallyRemoved
        // **付けたときだけ**——外したときに一覧から消してはならない。
        if assigning, let extra = onAssign?(subject.fileIDs) {
            // 表示名はラベル側のものを使う。付随する操作まで Undo メニューへ
            // 書くと、利用者が意図した操作（ラベルを付けた）が読み取りにくくなる。
            _ = try await commands.run(CompositeCommand(displayName: assign.displayName,
                                                        children: [assign, extra]))
        } else {
            _ = try await commands.run(assign)
        }
        // 画面をすぐ合わせる。`.task` の読み直しは後から届く。
        for id in subject.fileIDs {
            assignmentsByFile[id, default: [:]][labelID] = target
        }
    }

    /// 書き込みのあと、ラベルの一覧と件数を読み直す。
    ///
    /// 新しく作ったラベルは一覧に無く、`fileCount` も変わっているため。
    public func reload() async {
        guard let services, let library else { return }
        await load(urls: loadedKey ?? [], library: library, services: services)
    }
}
