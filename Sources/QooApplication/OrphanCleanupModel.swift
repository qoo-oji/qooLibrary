//
//  「見つからないファイル」の整理ウインドウ [OR-01][OR-04][ID-07][15.7 節]。
//
//  **触れるのは一覧と削除だけ**［ユーザー判断、2026-08］。実体を結び直す手段は
//  ここに置かない——同じ inode で復活すれば走査が自動で戻し [ID-02]、名前が
//  同じで inode が違えば**一括の確認ダイアログ** [ID-05] が引き受ける。
//  ここに再紐づけを置くと、同じ操作が 2 箇所に生まれる（OR-02/OR-03 は撤回）。
//
//  **`qooLibraryApp` ではなく `QooApplication` に置く**——アプリターゲットの
//  コードは `swift test` から触れないため、判定（既定で選ぶライブラリ・検索・
//  オフラインの出し分け）を自動テストで固定できなくなる（`LabelVaultModel` /
//  `LabelGroupEditorModel` と同じ理由）。SwiftUI に依存しない。
//
//  ## ラベル保管庫との違い
//  形は 2 ペインで同じだが、**扱うものの性質が逆**である。ラベルは実体に
//  依らないので保管庫はオフラインでも開けるが、孤立は「実体が見つからない」
//  という実体についての判断なので、**オフラインのライブラリでは正しさを
//  判定できない** [OR2-06][ID-08][SB-05]。一覧からライブラリごと消すのではなく
//  グレーアウトして理由を書く［ユーザー判断］——消すと「孤立が無い」のか
//  「見られない」のか区別が付かない。
//
import Foundation
import Observation
import QooKit

@MainActor
@Observable
public final class OrphanCleanupModel {

    public enum State: Sendable, Equatable {
        case notReady
        case loading
        /// ライブラリが 1 件も無い。
        case noLibrary
        /// 選択中のライブラリがオフライン [OR2-06]。一覧は出さない。
        case offline
        case ready
        case failed(String)
    }

    public private(set) var state: State = .notReady
    public private(set) var libraries: [LibrarySummary] = []
    /// ライブラリごとの孤立件数。**左ペインの出し分け**と、既定で選ぶ
    /// ライブラリの決定に使う。0 件はキーごと現れない。
    public private(set) var orphanCounts: [LibraryID: Int] = [:]
    /// 選択中ライブラリの孤立レコード（相対パス順）。
    public private(set) var files: [OrphanedFile] = []

    public var selectedLibraryID: LibraryID? {
        didSet { guard oldValue != selectedLibraryID else { return }; selection = [] }
    }
    /// 一括で削除する [OR-04] ための選択。
    public var selection: Set<FileID> = []
    /// 一覧の絞り込み。**要件には無いが付ける**［実装判断］——ボリュームの
    /// 中身が入れ替わると全件が孤立しうるので、数千件の中から目当ての 1 件を
    /// 探せないと [OR-04] が実行できない。全角で打っても半角に当たる
    /// （`NameFilter`）。
    public var searchText: String = ""

    private let commands: CommandStack
    private var services: LibraryServices?

    public init(commands: CommandStack = .shared) {
        self.commands = commands
    }

    // MARK: - 表示（純粋関数）

    public var visibleFiles: [OrphanedFile] {
        Self.filter(files, matching: searchText)
    }

    /// **判定はここ 1 箇所。** View に書くとテストで固定できず、`reload` に
    /// 埋めると打鍵のたびに DB を読み直すことになる。
    ///
    /// 名前だけでなく**相対パスも見る**——孤立の一覧で目印になるのは
    /// 「どのフォルダにあったか」であることが多い（同じ巻数のファイルが
    /// 複数のシリーズに散っているため）。
    nonisolated public static func filter(_ files: [OrphanedFile],
                                          matching searchText: String) -> [OrphanedFile] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return files }
        return files.filter {
            NameFilter.matches(name: $0.row.filename, query: query)
                || NameFilter.matches(name: $0.row.relativePath, query: query)
        }
    }

    /// このライブラリの孤立を一覧してよいか [OR2-06][ID-08][SB-05]。
    ///
    /// **この 1 行が OR2-06 の境目そのもの**なので、View にも `reload` にも
    /// 埋めずここに置く（`LabelEditorModel.candidates` を切り出したのと同じ
    /// 理由）。オフラインでは実体が見えず「見つからない」が本当かどうか
    /// 判定できない——一覧に出すと、外付けを挿し忘れただけのものを
    /// 削除できてしまう [R-01 が防ごうとしている事故そのもの]。
    nonisolated public static func canListOrphans(of library: LibrarySummary) -> Bool {
        library.isOnline
    }

    /// 既定で選ぶライブラリ。
    ///
    /// **明示的に指定されたものが最優先**——その登録の孤立を見に来たのだから、
    /// 0 件でもそのライブラリを見せる（「無かった」も答えである）。指定が
    /// 無ければ**孤立を持つ最初のオンラインのライブラリ**［設計判断］。
    /// 素直に先頭を選ぶと、孤立の無いライブラリやオフラインの登録に着地して
    /// 行き止まりになる（`LabelVaultModel.defaultLibrary` と同じ考え方）。
    nonisolated public static func defaultLibrary(from libraries: [LibrarySummary],
                                                  orphanCounts: [LibraryID: Int],
                                                  preferring preferred: LibraryID?) -> LibraryID? {
        if let preferred, libraries.contains(where: { $0.id == preferred }) { return preferred }
        if let populated = libraries.first(where: {
            canListOrphans(of: $0) && (orphanCounts[$0.id] ?? 0) > 0
        }) {
            return populated.id
        }
        return libraries.first(where: canListOrphans(of:))?.id ?? libraries.first?.id
    }

    public var selectedFiles: [OrphanedFile] {
        files.filter { selection.contains($0.row.id) }
    }

    public var selectedLibrary: LibrarySummary? {
        libraries.first { $0.id == selectedLibraryID }
    }

    /// 孤立が 1 件も無い。**検索で 0 件になった場合と区別する**ため、
    /// `visibleFiles` ではなく読み込んだ生データを見る——「孤立はありません」と
    /// 「一致しません」は次の一手が違う（前者は閉じる、後者は検索語を消す）。
    public var hasNoOrphans: Bool { files.isEmpty }

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
            orphanCounts = [:]; files = []
            selectedLibraryID = nil
            state = .noLibrary
            return
        }
        do {
            orphanCounts = try await services.orphanedFileCounts()
            // 選択が消えていたら（登録解除・無効化）選び直す。
            //
            // **「DB の準備より先に確定してしまう」競合はここでは解けない**
            // （`LabelVaultModel` と同じ）。救っているのはウインドウ側の
            // `.onChange(of: LibraryServices.shared.isReady)` で、**この保護は
            // View にしか無い**——モデルを別の画面から使うときは同じ配線が要る。
            let current = selectedLibraryID
            if preferred != nil || current == nil
                || !libraries.contains(where: { $0.id == current }) {
                selectedLibraryID = Self.defaultLibrary(from: libraries,
                                                        orphanCounts: orphanCounts,
                                                        preferring: preferred)
            }
            guard let library = selectedLibrary else {
                files = []; state = .noLibrary; return
            }
            // **オフラインのライブラリのレコードは出さない** [OR2-06][ID-08]。
            // 実体が見えない状態では「見つからない」が本当かどうか判定できず、
            // ここで一覧に出すと、外付けを挿し忘れただけのものを削除できて
            // しまう [R-01 が防ごうとしている事故そのもの]。
            guard Self.canListOrphans(of: library) else {
                files = []; selection = []; state = .offline; return
            }
            files = try await services.orphanedFiles(libraryID: library.id)
            selection = selection.filter { id in files.contains { $0.row.id == id } }
            state = .ready
        } catch {
            // **取り消しは失敗ではない**——`.task(id:)` は鍵が変わると前の
            // タスクを取り消すので、選択を素早く変えると `CancellationError` が
            // ここへ届く。そのまま出すと画面に意味の無い赤字が残る。
            guard !CommandStack.isCancellation(error) else { return }
            state = .failed(String(describing: error))
        }
    }

    // MARK: - 操作（すべて CommandStack を通す）

    /// 削除 [OR-04]。**確認は呼び出し側**——何件のラベルが外れるかを見せてから
    /// 決めさせる（ラベル削除と同じ）。
    public func delete(_ targets: [OrphanedFile]) async throws {
        guard let services, !targets.isEmpty else { return }
        _ = try await commands.run(DeleteOrphanedFilesCommand(
            fileIDs: targets.map(\.row.id), names: targets.map(\.row.filename),
            services: services))
        // `reload()` も一覧に無い選択を落とすが、読み取りに失敗すると
        // （`state = .failed` で早期に返るため）そこへ届かない——消えた行を
        // 指したままの選択が残る。失敗経路のために残す。
        selection = []
        await reload()
    }

    public func deleteSelected() async throws {
        try await delete(selectedFiles)
    }
}
