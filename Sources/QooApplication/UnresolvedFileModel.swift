//
//  未解決ファイルの整理ウインドウ [AL-30〜AL-34][UR-01〜UR-06][15.6 節]。
//
//  **`qooLibraryApp` ではなく `QooApplication` に置く**——アプリターゲットの
//  コードは `swift test` から触れないため、判定（既定で選ぶライブラリ・検索・
//  無視の出し分け・500 件超の案内 [UR2-08]）を自動テストで固定できなくなる
//  （`OrphanCleanupModel` / `FileVaultModel` と同じ理由）。SwiftUI に依存しない。
//
//  ## 「見つからないファイル」（§15.7）との違い
//  形は 2 ペインで同じだが、**実体を見るかどうかが逆**である。孤立は
//  「実体が見つからない」という実体についての判断なのでオフラインでは
//  一覧できない [OR2-06] が、未解決は**ファイル名とフォーマットの照合結果**
//  なので実体を 1 度も見ない——ラベル保管庫と同じく、オフラインでも開けて
//  読めて書ける。外付けが無い間にフォーマットを直したい、はむしろ普通の場面。
//
import Foundation
import Observation
import QooKit

@MainActor
@Observable
public final class UnresolvedFileModel {

    public enum State: Sendable, Equatable {
        case notReady
        case loading
        /// ライブラリが 1 件も無い。
        case noLibrary
        case ready
        case failed(String)
    }

    public private(set) var state: State = .notReady
    public private(set) var libraries: [LibrarySummary] = []
    /// ライブラリごとの未解決の内訳 [AL-33]。0 件のライブラリはキーごと現れない。
    public private(set) var unresolvedCounts: [LibraryID: UnresolvedCounts] = [:]
    /// 選択中ライブラリの未解決ファイル（相対パス順）。`includeIgnored` に従う。
    public private(set) var files: [UnresolvedFile] = []
    /// 直近の再マッチングの結果 [AL-34]。画面に「N 件が解決しました」と出す。
    public private(set) var lastRematch: RematchOutcome?

    public var selectedLibraryID: LibraryID? {
        didSet {
            guard oldValue != selectedLibraryID else { return }
            selection = []
            // **直近の結果も捨てる。** 残すと「12 件が解決しました」が
            // 切り替えた先のライブラリの下端に出て、そちらに対して実行した
            // ように読める。
            lastRematch = nil
        }
    }
    /// 一括適用 [UR-06][AL-32] のための選択。
    public var selection: Set<FileID> = []
    /// 一覧の絞り込み。全角で打っても半角に当たる（`NameFilter`）。
    public var searchText: String = ""
    /// 無視したもの [AL-33] も見せるか。**既定は偽**——無視は「一覧から
    /// 消したい」という意思表示なので、既定で出すと意味が無い。ただし
    /// **戻す手段が要る**ので切り替えは出す [UR2-04]。
    public var includeIgnored: Bool = false {
        didSet { guard oldValue != includeIgnored else { return }; needsReload = true }
    }
    /// `includeIgnored` の変化を View が拾って読み直すための印。
    public private(set) var needsReload = false

    private let commands: CommandStack
    private var services: LibraryServices?

    public init(commands: CommandStack = .shared) {
        self.commands = commands
    }

    // MARK: - 表示（純粋関数）

    public var visibleFiles: [UnresolvedFile] {
        Self.filter(files, matching: searchText)
    }

    /// **判定はここ 1 箇所。** View に書くとテストで固定できず、`reload` に
    /// 埋めると打鍵のたびに DB を読み直すことになる。
    ///
    /// 名前だけでなく**相対パスも見る**——未解決の一覧では「どのフォルダが
    /// まるごと当たっていないか」が手がかりになることが多い（フォルダ階層の
    /// 割り当て [AL-20〜23] が合っていない場合、その枝だけが全滅する）。
    nonisolated public static func filter(_ files: [UnresolvedFile],
                                          matching searchText: String) -> [UnresolvedFile] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return files }
        return files.filter {
            NameFilter.matches(name: $0.row.filename, query: query)
                || NameFilter.matches(name: $0.row.relativePath, query: query)
        }
    }

    /// 既定で選ぶライブラリ。
    ///
    /// **明示的に指定されたものが最優先**——その登録の未解決を見に来たのだから、
    /// 0 件でもそのライブラリを見せる（「無かった」も答えである）。指定が
    /// 無ければ**未解決を持つ最初のライブラリ**［設計判断］——素直に先頭を
    /// 選ぶと、片付いているライブラリに着地して行き止まりになる。
    ///
    /// **オンラインかどうかは見ない**（孤立側との違い）——未解決は実体を
    /// 1 度も見ない判断なので、オフラインでも正しく一覧できる。
    nonisolated public static func defaultLibrary(from libraries: [LibrarySummary],
                                                  counts: [LibraryID: UnresolvedCounts],
                                                  preferring preferred: LibraryID?) -> LibraryID? {
        if let preferred, libraries.contains(where: { $0.id == preferred }) { return preferred }
        if let populated = libraries.first(where: { (counts[$0.id]?.pending ?? 0) > 0 }) {
            return populated.id
        }
        return libraries.first?.id
    }

    /// 「フォーマットを追加して再マッチング」を最初の選択肢として出すか [UR2-08][OB-08]。
    ///
    /// **1 件ずつラベルを付けて片付けられる規模ではない**ことを、件数で判断する。
    /// 500 件の未解決は、ほぼ確実に「フォーマットが 1 本足りない」という
    /// 1 つの原因から来ている——そこへ手動ラベル付与を勧めるのは害がある。
    nonisolated public static func shouldOfferFormatFirst(count: Int) -> Bool {
        count > AppLimits.Library.unresolvedBulkThreshold
    }

    public var offersFormatFirst: Bool { Self.shouldOfferFormatFirst(count: files.count) }

    public var selectedFiles: [UnresolvedFile] {
        files.filter { selection.contains($0.row.id) }
    }

    public var selectedLibrary: LibrarySummary? {
        libraries.first { $0.id == selectedLibraryID }
    }

    /// 未解決が 1 件も無い。**検索で 0 件になった場合と区別する**ため、
    /// `visibleFiles` ではなく読み込んだ生データを見る——「未解決はありません」と
    /// 「一致しません」は次の一手が違う（前者は閉じる、後者は検索語を消す）。
    public var hasNoUnresolved: Bool { files.isEmpty }

    /// 一覧には出していないが、無視したものが残っている [AL-33]。
    ///
    /// **空状態の文言を分けるために要る。** これを見ないと、無視しただけの
    /// ときに「このライブラリのファイルはすべて、いずれかのファイル名
    /// フォーマットに一致しています」と**事実でないこと**を言ってしまう
    /// （実機検証で見つけた）。
    public var hiddenIgnoredCount: Int {
        guard !includeIgnored, let id = selectedLibraryID else { return 0 }
        return unresolvedCounts[id]?.ignored ?? 0
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
        needsReload = false
        guard let services, services.isReady else { state = .notReady; return }
        libraries = services.libraries
        guard !libraries.isEmpty else {
            unresolvedCounts = [:]; files = []; rebuildIndexes()
            selectedLibraryID = nil
            state = .noLibrary
            return
        }
        do {
            unresolvedCounts = try await services.unresolvedFileCounts()
            // 選択が消えていたら（登録解除・無効化）選び直す。
            //
            // **「DB の準備より先に確定してしまう」競合はここでは解けない**
            // （`OrphanCleanupModel` と同じ）。救っているのはウインドウ側の
            // `.onChange(of: LibraryServices.shared.isReady)` で、**この保護は
            // View にしか無い**——モデルを別の画面から使うときは同じ配線が要る。
            let current = selectedLibraryID
            if preferred != nil || current == nil
                || !libraries.contains(where: { $0.id == current }) {
                selectedLibraryID = Self.defaultLibrary(from: libraries,
                                                        counts: unresolvedCounts,
                                                        preferring: preferred)
            }
            guard let library = selectedLibrary else {
                files = []; rebuildIndexes(); state = .noLibrary; return
            }
            files = try await services.unresolvedFiles(libraryID: library.id,
                                                       includeIgnored: includeIgnored)
            rebuildIndexes()
            // **集合を 1 度作ってから絞る。** 素の `contains` を入れ子にすると
            // 選択数 × 件数になり、⌘A で数万件を選んだ状態の読み直しが
            // MainActor 上で数秒かかる（読み直しは ⌘Z のたびにも走る）。
            let present = Set(files.map(\.row.id))
            selection = selection.intersection(present)
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

    /// 「以後無視する」の切り替え [AL-33][UR-05][UR-06]。
    public func setIgnored(_ targets: [UnresolvedFile], _ ignored: Bool) async throws {
        guard let services, !targets.isEmpty else { return }
        // **変化が無いなら走らせない。** `CommandStack.run` は結果によらず
        // 履歴へ積むので、ここで止めないと「押しても何も起きない操作」で
        // ⌘Z の履歴が埋まる（混在した選択に一括操作を掛けると起こりうる）。
        // **名前も「実際に変わるもの」に揃える。** コマンドは変わるものだけを
        // 書き換えるのに、名前を選択全件から取ると Undo メニューだけが
        // 「5 件のファイルの…」と過大に出る [UD-06]。
        let changing = targets.filter { $0.isIgnored != ignored }
        guard !changing.isEmpty else { return }
        _ = try await commands.run(SetUnresolvedIgnoredCommand(
            previous: targets.map { .init(fileID: $0.row.id, isIgnored: $0.isIgnored) },
            ignored: ignored, names: changing.map(\.row.filename), services: services))
        await reload()
    }

    /// 中央ペインの未整理ビュー [UR3-03] から呼ぶ入口。
    ///
    /// **中央ペインは `FileID` しか持たない**（一覧の源は `LibraryContentModel`
    /// で、行は `FileRow`）。このモデルの `files` は**索引として**使う
    /// ——「その行が無視済みか」はここにしか無く、メニューの向き（無視する／
    /// 戻す）とバッジの出し分けに要る。
    ///
    /// **一覧そのものを二重に持つことになるが、これは意図した重複**である
    /// ——中央ペインが出すのは「未整理という条件で絞った蔵書の一覧」で、
    /// 普段のファイル操作がすべて使える [UR3-02] のが要点。ここが持つのは
    /// `unresolvedFile` テーブルの記録（無視フラグと検出時刻）で、別のもの。
    public func setIgnored(fileIDs: [FileID], _ ignored: Bool) async throws {
        let wanted = Set(fileIDs)
        try await setIgnored(files.filter { wanted.contains($0.row.id) }, ignored)
    }

    /// 「以後無視する」[AL-33] を立てている行 [UR3-03]。
    ///
    /// **`prepareAsIndex` で読んだときだけ全件を答えられる。** 一覧として
    /// 読んだ（`includeIgnored == false`）場合、無視した行は `files` から
    /// 落ちるのでここも空になる——だから索引として使う経路は下の入口に
    /// 一本化してある。
    ///
    /// **`files` から都度作らない**［code-review の指摘］。中央ペインは
    /// **可視行ごとに**これを引くので、5,000 件の未整理 × 100 行で 1 回の
    /// 描画に 50 万回の挿入が走る（このコードベースが既に 2 度直している形）。
    public private(set) var ignoredFileIDs: Set<FileID> = []

    /// ライブラリタイプの型条件を満たさなかった行 [TY-01][UR3-04]。
    ///
    /// **未解決の理由そのものではない**（別のフォーマットに一致すれば解決する）
    /// が、「なぜ当たらないか」の手がかりとしては強いので行に印として出す。
    public private(set) var typeMismatchFileIDs: Set<FileID> = []

    /// 「最も近いフォーマット」のヒント [UR2-05][UR3-04]。行の印のツールチップに使う。
    ///
    /// **`ignoredFileIDs` と同じく索引として持つ**——中央ペインは可視行ごとに
    /// 引くので、`files` から都度組み立てると 1 回の描画で数十万回の走査になる。
    public private(set) var nearestFormatByFileID: [FileID: String] = [:]

    /// 片付ける対象の件数（無視したものを除く）[UR3-05]。
    ///
    /// **`files.count` を使ってはならない**［code-review の指摘］——索引として
    /// 読むと無視済みも含むので、左ペイン・一覧・ヘッダで数字が食い違い、
    /// 500 件の案内 [UR2-08] も早く出る。
    public var pendingCount: Int {
        unresolvedCounts[selectedLibraryID ?? LibraryID(rawValue: -1)]?.pending ?? 0
    }

    /// `files` を入れ替えたときに索引を作り直す。**代入と同じ場所で必ず呼ぶ。**
    private func rebuildIndexes() {
        ignoredFileIDs = Set(files.lazy.filter(\.isIgnored).map(\.row.id))
        typeMismatchFileIDs = Set(files.lazy.filter(\.libraryTypeMismatch).map(\.row.id))
        nearestFormatByFileID = files.reduce(into: [:]) { out, file in
            if let source = file.nearestFormatSource { out[file.row.id] = source }
        }
    }

    /// 中央ペインの未整理ビューが使う索引として読む [UR3-03]。
    ///
    /// **無視したものも必ず含める。** ここが答えるのは「その行が無視済みか」
    /// で、一覧を絞るのは `LibraryContentModel.unresolvedFilter` の仕事
    /// ——呼び出し側に `includeIgnored` の設定を委ねると、忘れたときに
    /// **メニューの向きが常に「無視する」になる**（無視済みの行でも）という
    /// 静かな壊れ方をする［テストで実際に踏んだ］。
    public func prepareAsIndex(services: LibraryServices, libraryID: LibraryID) async {
        includeIgnored = true
        await prepare(services: services, preferring: libraryID)
    }

    public func setSelectedIgnored(_ ignored: Bool) async throws {
        try await setIgnored(selectedFiles, ignored)
    }

    /// 手でラベルを付けたファイルに「以後無視する」も立てる [AL-30]①③
    /// ［ユーザー判断、2026-08］。
    ///
    /// **`LabelEditorModel.onAssign` へ渡して、ラベルと同じ Undo 単位で走らせる**
    /// [UD-04]——別々に積むと ⌘Z を 2 回押さないと戻らない。
    ///
    /// なぜ要るか: `isUnresolved` は**パース結果**だけを見る [EM-03] ので、
    /// 手で付けたラベルは判定を動かさない。そのままだと [AL-30]① で片付けた
    /// つもりのファイルが一覧に残り続け、③（無視）を続けて使うしか無くなる。
    ///
    /// - Returns: 実際に変わるものが無ければ `nil`。
    ///
    /// **`nil` を返さない変異は空振りする**［既知、変異検証で確認］——対象が
    /// 空の `SetUnresolvedIgnoredCommand` は `changing` も空なので何もせず、
    /// `CompositeCommand` に無駄な子が 1 つ増えるだけで観測できる差が出ない。
    /// 通ることを理由にこの `guard` を外さないこと（診断ログの読みやすさと、
    /// 「何もしない操作を積まない」という約束のために置いてある）。
    public func ignoreCommandForAssigned(_ fileIDs: [FileID]) -> (any Command)? {
        guard let services else { return nil }
        let ids = Set(fileIDs)
        // **いま一覧に載っているものだけ。** 一覧の外のファイル（既に無視した、
        // 解決した）に人の判断を新しく立てない。
        let targets = files.filter { ids.contains($0.row.id) && !$0.isIgnored }
        guard !targets.isEmpty else { return nil }
        return SetUnresolvedIgnoredCommand(
            previous: targets.map { .init(fileID: $0.row.id, isIgnored: $0.isIgnored) },
            ignored: true, names: targets.map(\.row.filename), services: services)
    }

    /// フォーマット編集ダイアログへ渡す草案。プレビューの組み立てにしか
    /// 使わないので、多少古くても害は無い（保存は下記で引き直す）。
    public func settingsDraft() async throws -> LibrarySettingsDraft? {
        guard let library = selectedLibrary else { return nil }
        return try await settingsDraft(libraryID: library.id)
    }

    /// 対象を明示する入口 [UR3-03]。
    ///
    /// **中央ペインの未整理ビューはこちらを使う**［code-review の指摘］
    /// ——`selectedLibrary` は `prepareAsIndex` の最初の `await` を抜けるまで
    /// 古いままなので、ライブラリを切り替えた直後に押すと**前のライブラリへ
    /// フォーマットを書き込む**。中央ペインは自分が見ているライブラリを
    /// 知っているのだから、推測させる必要が無い。
    public func settingsDraft(libraryID: LibraryID) async throws -> LibrarySettingsDraft? {
        guard let services else { return nil }
        return try await services.settingsDraft(libraryID: libraryID)
    }

    /// フォーマットをその場で足して、続けて再マッチングする [UR-04][AL-34]。
    ///
    /// **保存の直前に草案を引き直す。** ダイアログを開いている間に設定
    /// ウインドウで別の変更が保存されているかもしれず、開いた時点の草案を
    /// そのまま書き戻すと**その変更を黙って巻き戻す**（`updateSettings` は
    /// 設定を丸ごと置き換える）。評価の全巻適用で踏んだのと同じ形。
    public func addFormat(source: String) async throws {
        guard let library = selectedLibrary else { return }
        try await addFormat(source: source, libraryID: library.id)
    }

    /// 対象を明示する入口 [UR3-03]（上の `settingsDraft(libraryID:)` と同じ理由）。
    public func addFormat(source: String, libraryID: LibraryID) async throws {
        guard let services else { return }
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard var fresh = try await services.settingsDraft(libraryID: libraryID) else { return }
        fresh.filenameFormats.append(FilenameFormatDraft(source: trimmed))
        try await services.updateSettings(fresh, libraryID: libraryID)
        try await rematch(libraryID: libraryID)
    }

    /// 現在の設定でパースし直す [AL-34][UR-04]。
    ///
    /// **Undo に積まない**［設計判断］。走査と同じ収束型の処理で、⌘Z で
    /// 「解決したことを取り消す」のは意味が薄い——戻したいのは普通
    /// 「足したフォーマット」のほうで、それは設定の編集という別の経路にある。
    public func rematch() async throws {
        guard let library = selectedLibrary else { return }
        try await rematch(libraryID: library.id)
    }

    /// 対象を明示する入口 [AL-34]。
    public func rematch(libraryID: LibraryID) async throws {
        guard let services else { return }
        lastRematch = try await services.rematchUnresolved(libraryID: libraryID)
        await reload()
    }

    /// 直近の再マッチング結果を捨てる [UR3-03]。
    ///
    /// **未整理ビューの出入りで呼ぶ**［code-review の指摘］——`lastRematch` は
    /// ライブラリを切り替えたときにしか消えないので、放っておくと
    /// 「N 件のうち M 件が一致するようになりました」がそのライブラリの
    /// ヘッダにセッション中ずっと居座る（走査しても ⌘Z しても消えない）。
    public func clearRematchResult() {
        lastRematch = nil
    }
}
