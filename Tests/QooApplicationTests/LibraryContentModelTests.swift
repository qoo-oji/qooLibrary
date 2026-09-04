import Foundation
import QooKit
import Testing
@testable import QooApplication

//
//  ライブラリ表示モードの一覧 [VM-10〜VM-16][LV-04][IV-05][IV-07][FI-05]。
//
//  組み立て（純粋関数）は素の値で、一覧そのものは**実際に DB を開いて**
//  確かめる——このモデルが守っているのは「どの行が出るか・どう並ぶか・
//  次を読むべきか」という**問い合わせの性質**なので、リポジトリを偽物に
//  差し替えると肝心の部分が試せない（`RatingCommandTests` と同じ判断）。
//  `ServicesWorkspace`（`LibraryServicesTests.swift`）を共有する。
//

@Suite("ライブラリ表示モードの一覧 [VM-10〜VM-16]", .serialized)
struct LibraryContentModelTests {

    @MainActor
    private func workspace(files: [String], preset: String = "builtin.general-comic-a")
        async throws -> (ServicesWorkspace, LibrarySummary)
    {
        let w = try ServicesWorkspace()
        await w.bootstrap()
        for name in files { try w.write(name) }
        let id = try await w.enable(preset)
        _ = try await w.services.scan(libraryID: id, root: w.libraryRoot)
        let library = try #require(w.services.library(registrationUUID: w.registrationUUID))
        return (w, library)
    }

    /// **巻ごとの一覧を前提にするテスト用**のモデル [VM3-05]。
    ///
    /// シリーズスタックは既定 ON なので、`作品名A 第01巻`〜`第03巻` のような
    /// 標本はそのままだと 1 行へ畳まれる——ここで試したいのはフラット表示
    /// [VM-10] とページング [FI-05] であって畳み方ではないので、切って使う。
    /// スタック側の性質は `SeriesStackModelTests` が固定している。
    @MainActor
    private func flatModel() -> LibraryContentModel {
        let model = LibraryContentModel()
        model.setSeriesStacking(false)
        return model
    }

    private static func file(_ name: String) -> String {
        "(一般コミック) [著者値A] \(name).cbz"
    }

    // MARK: - 組み立て（純粋関数）

    /// **配下をフラットに出す** [VM-10]。直下だけに絞るとサブフォルダの本が
    /// 1 冊も出ない。
    @Test("問い合わせは必ず再帰で、フラット表示の印を立てる [VM-10][VM-12]")
    func queryIsAlwaysRecursive() {
        let q = LibraryContentModel.makeQuery(
            libraryID: LibraryID(rawValue: 1), relativePath: "作品A",
            labelSelection: [:], ratingFilter: nil, searchText: nil,
            sort: .byFilename, offset: 0)
        guard case .folder(let path, let recursive) = q.scope else {
            Issue.record("scope がフォルダではない"); return
        }
        #expect(path == "作品A")
        #expect(recursive)
        #expect(q.mode == .libraryFlat)
        #expect(q.limit == AppLimits.Query.defaultPageSize)   // [FI-05]
    }

    @Test("空白だけの検索文字列は条件にしない")
    func blankSearchTextIsDropped() {
        let q = LibraryContentModel.makeQuery(
            libraryID: LibraryID(rawValue: 1), relativePath: "",
            labelSelection: [:], ratingFilter: nil, searchText: "   ",
            sort: .byFilename, offset: 0)
        #expect(q.searchText == nil)
    }

    // MARK: - 未整理ビュー [UR3-01][UR3-02]

    @Test("既定では絞らない（通常の一覧を変えない）")
    func unresolvedFilterIsOffByDefault() {
        let q = LibraryContentModel.makeQuery(
            libraryID: LibraryID(rawValue: 1), relativePath: "",
            labelSelection: [:], ratingFilter: nil, searchText: nil,
            sort: .byFilename, offset: 0)
        #expect(q.unresolvedFilter == nil)
    }

    @Test("未整理ビューの絞り込みが問い合わせへ届く [UR3-01]")
    func unresolvedFilterReachesTheQuery() {
        let q = LibraryContentModel.makeQuery(
            libraryID: LibraryID(rawValue: 1), relativePath: "",
            labelSelection: [:], ratingFilter: nil, searchText: nil,
            sort: .byFilename, offset: 0, unresolvedFilter: .pending)
        #expect(q.unresolvedFilter == .pending)
        // **他の条件は変わらない**——未整理は絞り込みであって別の一覧ではない。
        #expect(q.mode == .libraryFlat)
    }

    @MainActor
    @Test("ライブラリの外へ出ると未整理ビューも解ける [UR3-01]")
    func clearingAlsoLeavesTheUnresolvedView() {
        let model = LibraryContentModel()
        model.setUnresolvedFilter(.pending)
        #expect(model.showsUnresolvedOnly)
        // `clear()` はフォルダ表示への切り替えとライブラリの外への移動で走る。
        // 戻さないと、戻ってきたときに一覧が黙って絞られたままになる。
        model.clear()
        #expect(!model.showsUnresolvedOnly)
        #expect(model.unresolvedFilter == nil)
    }

    // MARK: - 表示名 [IV-05][IV-07]

    @Test("タイトルがあればタイトル、無ければファイル名 [IV-05][IV-07]")
    func displayNameFallsBackToFilename() {
        let base = Self.row(filename: "作品.cbz", title: nil)
        #expect(base.displayName == "作品.cbz")
        #expect(Self.row(filename: "作品.cbz", title: "作品名A").displayName == "作品名A")
        // **空白だけのタイトルも「無い」として扱う**——手動編集で入り得るし、
        // そのまま出すと行が消えたように見える。
        #expect(Self.row(filename: "作品.cbz", title: "  ").displayName == "作品.cbz")
    }

    /// ブックフォルダは実体がディレクトリだが `managedFile` の 1 行 [IF-10]。
    @Test("ブックフォルダの URL はディレクトリとして組み立てる [IF-10]")
    func bookFolderURLIsADirectory() {
        let rows = LibraryContentModel.rows(
            from: [Self.fileRow(relativePath: "作品A/第01巻", filename: "第01巻",
                                isBookFolder: true),
                   Self.fileRow(relativePath: "作品A/第02巻.cbz", filename: "第02巻.cbz",
                                isBookFolder: false)],
            libraryRootPath: "/tmp/lib", userCoverURL: { _ in nil })
        #expect(rows[0].url.hasDirectoryPath)
        #expect(!rows[1].url.hasDirectoryPath)
        #expect(rows[0].url.path == "/tmp/lib/作品A/第01巻")
    }

    // MARK: - モード切替 [VM-20〜VM-23]

    /// **`Set` の側から取ると実行のたびに変わる。** 「複数選択なら先頭ファイル」
    /// [VM-22] は一覧の表示順で決めなければ意味を持たない。
    @Test("複数選択では一覧の表示順で先頭のものを選ぶ [VM-22]")
    func firstSelectedFollowsTheDisplayOrder() {
        let rows = ["c.cbz", "a.cbz", "b.cbz"].map {
            LibraryContentModel.Row(
                file: Self.fileRow(relativePath: $0, filename: $0),
                url: URL(fileURLWithPath: "/lib/\($0)"))
        }
        let all = Set(rows.map(\.url))
        // 一覧の並びは c, a, b。`Set` の順序ではなくこの並びの先頭が返る。
        #expect(LibraryContentModel.firstSelected(in: rows, selection: all)?.file.filename == "c.cbz")
        // 選択が一覧の途中だけなら、そのうち最初に現れるもの。
        let later: Set<URL> = [rows[2].url, rows[1].url]
        #expect(LibraryContentModel.firstSelected(in: rows, selection: later)?.file.filename == "a.cbz")
    }

    /// [VM-23] 選択が無ければ何も返さない（呼び出し側は現在のフォルダに留まる）。
    @Test("選択が無ければ対象は無い [VM-23]")
    func noSelectionMeansNoTarget() {
        let rows = [LibraryContentModel.Row(
            file: Self.fileRow(relativePath: "a.cbz", filename: "a.cbz"),
            url: URL(fileURLWithPath: "/lib/a.cbz"))]
        #expect(LibraryContentModel.firstSelected(in: rows, selection: []) == nil)
        // 一覧に無い URL が選ばれていても拾わない（モードを切り替えた直後など）。
        #expect(LibraryContentModel.firstSelected(
            in: rows, selection: [URL(fileURLWithPath: "/lib/other.cbz")]) == nil)
    }

    // MARK: - 一覧（DB を実際に開く）

    /// **サブフォルダの中の本も出る** [VM-10]。フォルダ表示モードと決定的に
    /// 違うところで、ここが崩れるとライブラリ表示モードの意味が無くなる。
    @Test("配下の本をフラットに出す [VM-10]")
    @MainActor
    func listsFilesUnderTheFolderFlat() async throws {
        let (w, library) = try await workspace(files: [
            "作品A/\(Self.file("作品名A 第01巻"))",
            "作品A/\(Self.file("作品名A 第02巻"))",
            "作品B/\(Self.file("作品名B 第01巻"))",
        ])
        let model = flatModel()
        await model.load(library: library, relativePath: "", services: w.services)
        #expect(model.state == .ready)
        #expect(model.rows.count == 3)
        #expect(model.totalCount == 3)
        #expect(!model.hasMore)
    }

    /// [VM-11] 対象は**現在のフォルダ配下のみ**。ライブラリ全体ではない。
    @Test("現在のフォルダ配下だけを出す [VM-11]")
    @MainActor
    func limitsToTheCurrentFolder() async throws {
        let (w, library) = try await workspace(files: [
            "作品A/\(Self.file("作品名A 第01巻"))",
            "作品A/\(Self.file("作品名A 第02巻"))",
            "作品B/\(Self.file("作品名B 第01巻"))",
        ])
        let model = flatModel()
        await model.load(library: library, relativePath: "作品A", services: w.services)
        #expect(model.rows.count == 2)
        #expect(model.rows.allSatisfy { $0.file.relativePath.hasPrefix("作品A/") })
    }

    /// 対象拡張子外は `managedFile` に載らない [AL-11]——**実体の一覧を絞る
    /// フォルダ表示モードと違い、ここでは自動的に落ちる** [VM-10]。
    @Test("対象拡張子でないファイルは出ない [VM-10][AL-11]")
    @MainActor
    func excludesNonTargetExtensions() async throws {
        let (w, library) = try await workspace(files: [
            Self.file("作品名A 第01巻"),
            "メモ.txt",
        ])
        let model = LibraryContentModel()
        await model.load(library: library, relativePath: "", services: w.services)
        #expect(model.rows.count == 1)
        #expect(model.rows.first?.file.filename.hasSuffix(".cbz") == true)
    }

    @Test("並べ替えは SQL に委ねる [VM-15]")
    @MainActor
    func sortIsAppliedByTheQuery() async throws {
        let (w, library) = try await workspace(files: [
            Self.file("作品名A 第01巻"),
            Self.file("作品名A 第02巻"),
            Self.file("作品名A 第03巻"),
        ])
        let model = LibraryContentModel()
        model.setSort(FileQuery.SortSpec(key: .filename, ascending: false))
        await model.load(library: library, relativePath: "", services: w.services)
        let names = model.rows.map(\.file.filename)
        #expect(names == names.sorted(by: >))
    }

    /// ライブラリが決まらないときは `.inactive`。**空の `.ready` と区別する**
    /// ——「1 冊も無い」と「そもそも出す場面ではない」は別の意味。
    @Test("ライブラリが無ければ inactive")
    @MainActor
    func inactiveWithoutALibrary() async throws {
        let w = try ServicesWorkspace()
        await w.bootstrap()
        let model = LibraryContentModel()
        await model.load(library: nil, relativePath: "", services: w.services)
        #expect(model.state == .inactive)
        #expect(model.rows.isEmpty)
    }

    /// **失敗を空と取り違えない** [ER-01]。DB を開いていない状態で問うと
    /// `notReady` が返る。
    @Test("問い合わせに失敗したら failed で、空の ready にはしない")
    @MainActor
    func failureIsDistinctFromEmpty() async throws {
        let w = try ServicesWorkspace()          // bootstrap しない
        let library = LibrarySummary(
            id: LibraryID(rawValue: 1), uuid: UUID(), displayName: "x",
            resolvedPath: w.libraryRoot.path, volumeUUID: "v",
            libraryTypeID: LibraryTypeID(rawValue: 1),
            isOnline: true, isReadOnlyDueToFS: false, fileCount: 0, settingsRevision: 1)
        let model = LibraryContentModel()
        await model.load(library: library, relativePath: "", services: w.services)
        guard case .failed = model.state else {
            Issue.record("failed になっていない: \(model.state)"); return
        }
    }

    @Test("clear で inactive に戻る")
    @MainActor
    func clearResetsTheList() async throws {
        let (w, library) = try await workspace(files: [Self.file("作品名A 第01巻")])
        let model = LibraryContentModel()
        await model.load(library: library, relativePath: "", services: w.services)
        #expect(model.rows.count == 1)
        model.clear()
        #expect(model.state == .inactive)
        #expect(model.rows.isEmpty)
        #expect(model.totalCount == 0)
    }

    /// **取り消しを失敗として見せない**［2-9 の実機検証でユーザーが発見］。
    /// `.task(id:)` は鍵が変わると前のタスクを取り消すので、この経路には
    /// `CancellationError` が普通に届く——それを `.failed` にすると画面に
    /// 「CancellationError()」という赤字が出る。
    @Test("取り消しは失敗にしない")
    @MainActor
    func cancellationIsNotAFailure() async throws {
        let (w, library) = try await workspace(files: [Self.file("作品名A 第01巻")])
        let model = LibraryContentModel()
        await model.load(library: library, relativePath: "", services: w.services)
        #expect(model.state == .ready)

        // 取り消された読み込みが `.failed` を残さないこと。**状態も行も
        // 触らない**（次の読み込みが上書きする）。
        let task = Task { @MainActor in
            await model.load(library: library, relativePath: "", services: w.services)
        }
        task.cancel()
        _ = await task.value
        guard case .failed = model.state else { return }
        Issue.record("取り消しで .failed になった: \(model.state)")
    }

    // MARK: - ページング [FI-05][PF-10]

    /// **1 ページに収まらない件数**を用意しないと、この主張は空振りする
    /// （「主張を検証するには、その主張が成り立ちうる前提を先に用意する」）。
    @Test("1 ページを超えたら続きを読める [FI-05][PF-10]")
    @MainActor
    func loadsAdditionalPages() async throws {
        let count = AppLimits.Query.defaultPageSize + 5
        let names = (1...count).map { Self.file(String(format: "作品名A 第%03d巻", $0)) }
        let (w, library) = try await workspace(files: names)

        let model = flatModel()
        await model.load(library: library, relativePath: "", services: w.services)
        #expect(model.rows.count == AppLimits.Query.defaultPageSize)
        #expect(model.totalCount == count)
        #expect(model.hasMore)

        await model.loadNextPage(library: library, services: w.services)
        #expect(model.rows.count == count)
        #expect(!model.hasMore)
        #expect(!model.isLoadingMore)
    }

    /// 末尾の行はスクロールのたびに現れるので、**何度呼ばれても壊れない**
    /// ことが要る。行が二重に入ると `Identifiable` の id が衝突する。
    @Test("続きを読み終えた後に呼んでも重複しない")
    @MainActor
    func loadingMorePastTheEndIsHarmless() async throws {
        let count = AppLimits.Query.defaultPageSize + 3
        let names = (1...count).map { Self.file(String(format: "作品名A 第%03d巻", $0)) }
        let (w, library) = try await workspace(files: names)

        let model = flatModel()
        await model.load(library: library, relativePath: "", services: w.services)
        await model.loadNextPage(library: library, services: w.services)
        await model.loadNextPage(library: library, services: w.services)
        await model.loadNextPage(library: library, services: w.services)
        #expect(model.rows.count == count)
        #expect(Set(model.rows.map(\.url)).count == count)   // 重複なし
    }

    /// **ページの境目で行が増える状況を実際に作る。** 走査は一覧を見ている
    /// 最中にも走る [SY-01] ので、`offset` を頼りに続きを読むと同じ行が
    /// 二度入り得る（`Identifiable` の id が衝突すると SwiftUI が実行時に
    /// 文句を言う）。**この前提を用意しないと、重複除去も総数の更新も
    /// 変異させたまま通ってしまう**（実際に空振りして分かった）。
    @Test("読んでいる最中に行が増えても、重複せず総数も追いつく [FI-05]")
    @MainActor
    func rowsInsertedBetweenPagesDoNotDuplicate() async throws {
        let count = AppLimits.Query.defaultPageSize + 5
        let names = (1...count).map { Self.file(String(format: "作品名B 第%03d巻", $0)) }
        let (w, library) = try await workspace(files: names)

        let model = flatModel()
        await model.load(library: library, relativePath: "", services: w.services)
        #expect(model.rows.count == AppLimits.Query.defaultPageSize)
        #expect(model.totalCount == count)

        // 名前順で**先頭に来る**ファイルを足す。これで 2 ページ目の `offset`
        // が 1 つずれ、素朴に継ぎ足すと 1 ページ目の末尾と重なる。
        try w.write(Self.file("作品名A 第001巻"))
        let id = try #require(w.services.library(registrationUUID: w.registrationUUID)?.id)
        _ = try await w.services.scan(libraryID: id, root: w.libraryRoot)

        await model.loadNextPage(library: library, services: w.services)
        #expect(Set(model.rows.map(\.url)).count == model.rows.count)  // 重複なし
        #expect(model.totalCount == count + 1)                          // 総数が追いつく
    }

    // MARK: - 標本

    private static func fileRow(relativePath: String, filename: String,
                                title: String? = nil,
                                isBookFolder: Bool = false,
                                coverRef: String? = nil,
                                coverSource: CoverSource = .auto) -> FileRow {
        FileRow(id: FileID(rawValue: 1), libraryID: LibraryID(rawValue: 1),
                relativePath: relativePath, filename: filename,
                fileSize: 1, createdAt: .distantPast, modifiedAt: .distantPast,
                title: title, seriesName: nil, volume: VolumeValue.none,
                rating: 0, coverImageRef: coverRef, coverImageSource: coverSource,
                state: .active, isArchived: false, isBookFolder: isBookFolder)
    }

    // MARK: - 一覧のカバー画像 [IV-02①]

    /// **参照があるときだけ場所を組み立てる。** `.auto`／`.sidecar` の行にも
    /// 参照が残っていることがある（`setCover` は `.userSpecified` 以外で消すが、
    /// 過去の版で書かれた行や取り込んだ JSON では残り得る）ので、
    /// `coverImageSource` を見ずに `coverImageRef` だけで判定すると、
    /// **自動へ戻したはずの本に古い複製が出続ける**。
    @Test("ユーザー指定のときだけ複製の場所を持つ [IV-02①][CV-06]")
    func onlyUserSpecifiedRowsCarryACoverURL() {
        let rows = LibraryContentModel.rows(
            from: [Self.fileRow(relativePath: "1.cbz", filename: "1.cbz",
                                coverRef: "a.png", coverSource: .userSpecified),
                   Self.fileRow(relativePath: "2.cbz", filename: "2.cbz",
                                coverRef: "b.png", coverSource: .auto),
                   Self.fileRow(relativePath: "3.cbz", filename: "3.cbz")],
            libraryRootPath: "/tmp/lib",
            userCoverURL: { URL(fileURLWithPath: "/covers/\($0)") })
        #expect(rows[0].userCoverURL?.path == "/covers/a.png")
        #expect(rows[1].userCoverURL == nil, "自動なのに複製を指してはいけない")
        #expect(rows[2].userCoverURL == nil)
    }

    private static func row(filename: String, title: String?) -> LibraryContentModel.Row {
        LibraryContentModel.Row(
            file: fileRow(relativePath: filename, filename: filename, title: title),
            url: URL(fileURLWithPath: "/tmp/\(filename)"))
    }
}
