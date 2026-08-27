//
//  ファイル保管庫の整理ウインドウ [FAW-01〜FAW-05][15.4 節]。
//
//  **`qooLibraryApp` ではなく `QooApplication` に置く**——アプリターゲットの
//  コードは `swift test` から触れないため、判定（元フォルダごとの整理・
//  並べ替え・検索・既定で選ぶライブラリ・オフラインでの出し分け）を自動
//  テストで固定できなくなる（`LabelVaultModel` と同じ理由）。
//
//  ## ラベル保管庫（§15.3）との違い
//  あちらは DB の印を切り替えるだけなので**オフラインでも書ける**。こちらは
//  **戻す＝実ファイルを `.qooarchive` から出す**ので、ボリュームが要る。
//  一覧はどちらも DB だけで作れるので、オフラインでも「何がしまってあるか」は
//  見える——**見えるが触れない**、という状態を明示する。
//
//  ## 一覧の形
//  §15.4 が「元フォルダごとに整理」と定めているので**セクション**にする。
//  並べ替え [FAW-05] は**セクションの中**へ適用する（ラベル保管庫と同じ）。
//
//  ## フォルダ丸ごとでもファイル単位 [FAW-01][FDA-05]
//  `.qooarchive` の中は元の階層をそのまま写している [FA-03] ので、「どの
//  フォルダから来たか」はパスから読める。フォルダという単位を別に持たない。
//
import Foundation
import QooInfrastructure
import Observation
import QooKit

@MainActor
@Observable
public final class FileVaultModel {

    /// 一覧の 1 区画＝元のフォルダ 1 つ [15.4 節「元フォルダごとに整理」]。
    public struct Section: Sendable, Hashable, Identifiable {
        /// ライブラリ根からの相対パス。空文字はライブラリ直下。
        public let folder: String
        public let rows: [ArchivedFile]
        public var id: String { folder }

        public init(folder: String, rows: [ArchivedFile]) {
            self.folder = folder
            self.rows = rows
        }
    }

    public enum State: Sendable, Equatable {
        case notReady
        case loading
        case noLibrary
        case ready
        case failed(String)
    }

    /// 並べ替え [FAW-05]。**保管した日時での並べ替えは要件が名指ししている。**
    public enum SortOrder: String, Sendable, CaseIterable, Identifiable {
        case name
        case archivedAt
        public var id: String { rawValue }
    }

    public private(set) var state: State = .notReady
    public private(set) var libraries: [LibrarySummary] = []
    /// ライブラリごとの保管庫の件数。左ペインのグレーアウトと、既定で選ぶ
    /// ライブラリの決定に使う。0 件はキーごと現れない。
    public private(set) var archivedCounts: [LibraryID: Int] = [:]
    public private(set) var files: [ArchivedFile] = []

    public var selectedLibraryID: LibraryID? {
        didSet { guard oldValue != selectedLibraryID else { return }; selection = [] }
    }
    /// 一括で戻す [FAW-04] と削除 [FAW-03] のための選択。
    public var selection: Set<FileID> = []
    public var sortOrder: SortOrder = .name
    public var searchText: String = ""

    private let commands: CommandStack
    private var services: LibraryServices?

    public init(commands: CommandStack = .shared) {
        self.commands = commands
    }

    // MARK: - 表示（純粋関数）

    public var sections: [Section] {
        Self.sections(files: files, sortedBy: sortOrder, matching: searchText)
    }

    /// **判定はここ 1 箇所。** View に書くとテストで固定できず、`reload` に
    /// 埋めると並べ替えや検索のたびに DB を読み直すことになる。
    ///
    /// - **保管庫にあるものだけを通す。** 呼び出し側が絞って渡す前提だが、
    ///   この関数が不変条件を自分で守るほうが安全側に倒れる——保管庫の画面に
    ///   保管庫外のファイルが混ざるのは、意味そのものが壊れた状態になる。
    /// - **行が 0 件になった区画は落とす。** 検索で全部消えた見出しだけが
    ///   残ると、何のための区画か読めない。
    /// - 検索は `NameFilter` なので**全角で打っても半角のファイル名に当たる**
    ///   [LE-12 と同じ判定]。元のパスも対象にする——「どのフォルダから来たか」
    ///   で探すのは自然な引き方。
    nonisolated public static func sections(files: [ArchivedFile],
                                            sortedBy order: SortOrder,
                                            matching searchText: String) -> [Section] {
        let matched = files.filter { file in
            guard file.row.isArchived else { return false }
            guard !searchText.isEmpty else { return true }
            return NameFilter.matches(name: file.row.filename, query: searchText)
                || NameFilter.matches(name: file.originalFolder, query: searchText)
        }
        let grouped = Dictionary(grouping: matched, by: \.originalFolder)
        return grouped.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { folder in
                Section(folder: folder, rows: sorted(grouped[folder] ?? [], by: order))
            }
    }

    /// 区画の中の並べ替え [FAW-05]。
    ///
    /// **日時が無い行は末尾へ。** 外部で `.qooarchive` へ入れられたものは
    /// 記録を持たない [FA-04] ——先頭に集めると「いつ保管したか分からない
    /// もの」が最初に目に入る。同点はファイル名の自然順で安定させる
    /// （順序が実行ごとに変わると、一括操作が毎回違うものを指しうる）。
    nonisolated static func sorted(_ rows: [ArchivedFile], by order: SortOrder) -> [ArchivedFile] {
        switch order {
        case .name:
            return rows.sorted {
                $0.row.filename.localizedStandardCompare($1.row.filename) == .orderedAscending
            }
        case .archivedAt:
            return rows.sorted { lhs, rhs in
                switch (lhs.archivedAt, rhs.archivedAt) {
                case (nil, nil):
                    return lhs.row.filename.localizedStandardCompare(rhs.row.filename)
                        == .orderedAscending
                case (nil, _): return false
                case (_, nil): return true
                case (let l?, let r?):
                    if l == r {
                        return lhs.row.filename.localizedStandardCompare(rhs.row.filename)
                            == .orderedAscending
                    }
                    return l > r   // 新しいものから
                }
            }
        }
    }

    /// 既定で選ぶライブラリ。**指定されたものが最優先**——その登録の保管庫を
    /// 見に来たのだから、空でもそのライブラリを見せる（「空だった」も答え）。
    /// 指定が無ければ**中身のある最初のライブラリ**［`LabelVaultModel` と同じ］。
    nonisolated public static func defaultLibrary(from libraries: [LibrarySummary],
                                                  archivedCounts: [LibraryID: Int],
                                                  preferring preferred: LibraryID?) -> LibraryID? {
        if let preferred, libraries.contains(where: { $0.id == preferred }) { return preferred }
        if let populated = libraries.first(where: { (archivedCounts[$0.id] ?? 0) > 0 }) {
            return populated.id
        }
        return libraries.first?.id
    }

    public var selectedLibrary: LibrarySummary? {
        libraries.first { $0.id == selectedLibraryID }
    }

    /// 戻す・削除ができるか。**どちらも実ファイルを動かす**ので、ボリュームが
    /// 繋がっていなければ押させない [SB-05]。一覧は出し続ける——「何がしまって
    /// あるか」は DB だけで答えられるし、そこで行き止まりにする理由が無い。
    public var canModify: Bool { selectedLibrary?.isOnline == true }

    public var selectedFiles: [ArchivedFile] {
        files.filter { selection.contains($0.id) }
    }

    /// 選択中のライブラリの保管庫が空か。**検索で 0 件になった場合と区別する**
    /// ため、`sections` ではなく読み込んだ生データを見る——「保管庫は空です」と
    /// 「一致しません」は次の一手が違う。
    public var vaultIsEmpty: Bool { files.isEmpty }

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
            archivedCounts = [:]; files = []
            selectedLibraryID = nil
            state = .noLibrary
            return
        }
        do {
            archivedCounts = try await services.archivedFileCounts()
            let current = selectedLibraryID
            if preferred != nil || current == nil
                || !libraries.contains(where: { $0.id == current }) {
                selectedLibraryID = Self.defaultLibrary(from: libraries,
                                                        archivedCounts: archivedCounts,
                                                        preferring: preferred)
            }
            guard let libraryID = selectedLibraryID else {
                files = []; state = .noLibrary; return
            }
            files = try await services.archivedFiles(libraryID: libraryID)
            selection = selection.filter { id in files.contains { $0.id == id } }
            state = .ready
        } catch {
            // **取り消しは失敗ではない**［2-9 の実機検証でユーザーが発見］。
            guard !CommandStack.isCancellation(error) else { return }
            state = .failed(String(describing: error))
        }
    }

    // MARK: - 操作（すべて CommandStack を通す）

    /// 保管庫から戻す [FAW-02][FAW-04][FA-07]。
    public func restore(_ targets: [ArchivedFile]) async throws {
        guard let library = selectedLibrary, library.isOnline, !targets.isEmpty else { return }
        _ = try await commands.run(SetFileArchivedCommand(
            targets: targets.map {
                SetFileArchivedCommand.Target(
                    id: $0.id, relativePath: $0.row.relativePath,
                    archivedFromPath: $0.archivedFromPath, archivedAt: $0.archivedAt)
            },
            archived: false,
            root: URL(fileURLWithPath: library.resolvedPath)))
        await reload()
    }

    public func restoreSelected() async throws {
        try await restore(selectedFiles)
    }

    /// 削除の下ごしらえ [FAW-03][NV4-01]。
    ///
    /// **ゴミ箱があるかを、確認ダイアログを出す「前」に確かめる**
    /// ［実機検証で発見］。`FolderOperations.moveToTrash` が同じことをしている
    /// のに、こちらは `TrashCommand` を直に呼んでいた——**ゴミ箱を持たない
    /// 場所では削除が丸ごと失敗し、「『すぐに削除』をお使いください」と
    /// 案内されるのに、この画面にはその項目が無い**という行き止まりだった。
    ///
    /// **これは共有だけの話ではない。** `TrashAvailability` は `.trashDirectory`
    /// を `create: false` で尋ねるので、**まだ一度も何も捨てていない外付け
    /// ボリュームでも「ゴミ箱なし」になる**（1-17 の実測、8章 §8.7.1）。
    public func planDelete() async -> DeletePlan? {
        guard let library = selectedLibrary, library.isOnline else { return nil }
        let targets = selectedFiles
        guard !targets.isEmpty else { return nil }
        let root = URL(fileURLWithPath: library.resolvedPath)
        let urls = targets.map { root.appendingPathComponent($0.row.relativePath) }
        // 判定は実測 0.01 秒だが実 I/O なので、メインスレッドでは行わない
        // [NV6-02]——無応答の共有では 30 秒ブロックしうる。
        let usesTrash = await FileIO.perform { TrashAvailability.hasTrash(forAll: urls) }
        return DeletePlan(files: targets, usesTrash: usesTrash)
    }

    /// 削除 [FAW-03]。**実ファイルを捨て、記録も消す**［ユーザー判断］。
    ///
    /// 記録だけ消すと、`.qooarchive` は走査の対象 [SY-10] なので**次の走査で
    /// 必ず復活する**——しかもラベルを失った状態で。「保管庫から削除した」の
    /// 意味は「本当に捨てる」であって、記録の付け替えではない。
    ///
    /// ゴミ箱がある場所なら Finder から取り戻せるし ⌘Z も効く。無ければ
    /// 完全削除へ振り替える [NV4-01]——**`isUndoable == false` の子が入るので、
    /// `CompositeCommand` 全体も自動的に取り消せなくなる**（`allSatisfy`）。
    /// 確認ダイアログがそれを先に伝える責任を持つ。
    ///
    /// **確認は呼び出し側**——何件のラベルが外れるかを見せてから決めさせる。
    public func deleteSelected(_ plan: DeletePlan) async throws {
        guard let services, let library = selectedLibrary, library.isOnline else { return }
        let targets = plan.files
        guard !targets.isEmpty else { return }
        let root = URL(fileURLWithPath: library.resolvedPath)
        let urls = targets.map { root.appendingPathComponent($0.row.relativePath) }
        let name = targets.count == 1
            ? "「\(targets[0].row.filename)」を削除"
            : "\(targets.count) 件のファイルを削除"
        // **実体を捨てる → 記録を消す、の順**。逆にすると、捨てるほうに
        // 失敗したときに記録だけが消えて実体が保管庫に残る（次の走査で
        // ラベルを失った行として戻ってくる）。`CompositeCommand` は子が
        // 投げるとそこで止めるので、この順序が守られている限り
        // 「記録だけ消えた」は起こらない。
        // **サイドカーのカバー画像も一緒に捨てる**［実機検証で発見］。
        // 保管庫へは連れて行く [FA-14] のに捨てるときだけ置き去りにすると、
        // **一覧が「保管庫は空です」と言っているのに `.qooarchive` には
        // 画像が残る**——誰も参照しておらず、画面からは見えず、片付ける手段も
        // 無い。同じコマンドに入れるので ⌘Z でも一緒に戻る。
        let sidecars = await FileIO.perform {
            urls.compactMap { SidecarCoverLocator.locate(for: $0) }
        }
        let command = Self.makeDeleteCommand(
            plan: plan, displayName: name, items: urls + sidecars, services: services)
        _ = try await commands.run(command)
        // `reload()` も一覧に無い選択を落とすが、読み取りに失敗すると
        // （`state = .failed` で早期に返るため）そこへ届かない。失敗経路のために残す。
        selection = []
        await reload()
    }
}

extension FileVaultModel {
    /// 削除の 1 単位を組み立てる [FAW-03][NV4-01]。
    ///
    /// **切り出してあるのは、`isUndoable` がゴミ箱の有無で変わるから**
    /// ——`CompositeCommand.isUndoable` は子の `allSatisfy` なので、完全削除
    /// [PD-05] が混ざると自動的に取り消せなくなる。確認ダイアログが
    /// 「取り消せません」と言うのはその性質に基づいており、**両者がずれると
    /// いちばん取り返しのつかない場面で嘘をつく**ことになる。テストで固定する。
    static func makeDeleteCommand(plan: DeletePlan, displayName: String,
                                  items: [URL], services: LibraryServices) -> CompositeCommand {
        let removal: any Command = plan.usesTrash
            ? TrashCommand(items: items)
            : DeletePermanentlyCommand(items: items)
        return CompositeCommand(displayName: displayName, children: [
            removal,
            DeleteOrphanedFilesCommand(fileIDs: plan.files.map(\.id),
                                       names: plan.files.map { $0.row.filename },
                                       services: services),
        ])
    }
}

/// 削除の下ごしらえの結果 [FAW-03][NV4-01]。
///
/// **確認ダイアログの文言を決めるのはこれ。** 取り消せるかどうかが変わるので、
/// 「ゴミ箱へ移します」と「完全に削除します。取り消せません」を言い分ける。
public struct DeletePlan: Sendable, Equatable {
    public let files: [ArchivedFile]
    /// ゴミ箱を経由できるか。`false` なら完全削除になり、**⌘Z は効かない** [PD-05]。
    public let usesTrash: Bool

    public init(files: [ArchivedFile], usesTrash: Bool) {
        self.files = files
        self.usesTrash = usesTrash
    }
}
