import Foundation
import QooInfrastructure
import QooKit
import Testing
@testable import QooApplication

//
//  未解決ファイルの整理ウインドウ [AL-30〜AL-34][UR-01〜UR-06][15.6 節]。
//
//  絞り込み・既定で選ぶライブラリ・500 件超の案内は**純粋関数**なので DB を
//  開かずに固定できる。無視の切り替えと ⌘Z、再マッチングだけ
//  `ServicesWorkspace` を使う（`OrphanCleanupModelTests` と同じ分け方）。
//

@Suite("未解決一覧の絞り込みと選択 [15.6 節]")
struct UnresolvedSelectionTests {

    private func library(_ name: String, id: Int64, online: Bool = true) -> LibrarySummary {
        LibrarySummary(id: LibraryID(rawValue: id), uuid: UUID(), displayName: name,
                       resolvedPath: "/Volumes/\(name)", volumeUUID: "VOL\(id)",
                       libraryTypeID: LibraryTypeID(rawValue: 1), libraryTypeName: "同人誌",
                       isOnline: online, isReadOnlyDueToFS: false, fileCount: 0,
                       settingsRevision: 0)
    }

    private func file(_ path: String, id: Int64, ignored: Bool = false,
                      mismatch: Bool = false) -> UnresolvedFile {
        UnresolvedFile(
            row: FileRow(id: FileID(rawValue: id), libraryID: LibraryID(rawValue: 1),
                         relativePath: path,
                         filename: (path as NSString).lastPathComponent, fileSize: 100,
                         createdAt: Date(timeIntervalSinceReferenceDate: 0),
                         modifiedAt: Date(timeIntervalSinceReferenceDate: 0),
                         title: nil, seriesName: nil, volume: .none, rating: 0,
                         state: .active, isArchived: false, isBookFolder: false),
            isIgnored: ignored, detectedAt: Date(timeIntervalSinceReferenceDate: 0),
            libraryTypeMismatch: mismatch)
    }

    // MARK: - 絞り込み

    @Test("検索語が空なら全件を通す")
    func emptyQueryKeepsEverything() {
        let files = [file("A/一.cbz", id: 1), file("B/二.cbz", id: 2)]
        #expect(UnresolvedFileModel.filter(files, matching: "   ").count == 2)
    }

    /// 未解決では「どのフォルダがまるごと当たっていないか」が手がかりになる
    /// ——フォルダ階層の割り当て [AL-20〜23] が合っていないと枝ごと全滅する。
    @Test("ファイル名だけでなく相対パスにも当たる")
    func matchesAgainstThePathAsWell() {
        let files = [file("旧形式/一.cbz", id: 1), file("新形式/二.cbz", id: 2)]
        #expect(UnresolvedFileModel.filter(files, matching: "旧形式").map(\.row.id)
                == [FileID(rawValue: 1)])
    }

    /// **入力の幅までユーザーに合わせさせない**（CLAUDE.md 冒頭の大原則）。
    @Test("全角で打っても半角のファイル名に当たる")
    func matchingIgnoresCharacterWidth() {
        let files = [file("A/STUDIO abc.cbz", id: 1)]
        #expect(UnresolvedFileModel.filter(files, matching: "ＳＴＵＤＩＯ").count == 1)
    }

    // MARK: - 既定で選ぶライブラリ

    @Test("指定されたライブラリが最優先（0 件でも見せる）")
    func preferredWins() {
        let libs = [library("A", id: 1), library("B", id: 2)]
        #expect(UnresolvedFileModel.defaultLibrary(from: libs, counts: [LibraryID(rawValue: 2): UnresolvedCounts(pending: 3, ignored: 0)],
                                                   preferring: LibraryID(rawValue: 1))
                == LibraryID(rawValue: 1))
    }

    @Test("指定が無ければ未解決を持つ最初のライブラリを選ぶ")
    func picksAPopulatedLibrary() {
        let libs = [library("A", id: 1), library("B", id: 2)]
        #expect(UnresolvedFileModel.defaultLibrary(from: libs, counts: [LibraryID(rawValue: 2): UnresolvedCounts(pending: 3, ignored: 0)],
                                                   preferring: nil)
                == LibraryID(rawValue: 2))
    }

    /// **オンラインかどうかを見ない**（孤立側との違い）。未解決は実体を
    /// 1 度も見ない照合の結果なので、オフラインでも正しく一覧できる。
    @Test("オフラインのライブラリも既定の候補になる")
    func offlineLibrariesAreEligible() {
        let libs = [library("A", id: 1, online: true), library("B", id: 2, online: false)]
        #expect(UnresolvedFileModel.defaultLibrary(from: libs, counts: [LibraryID(rawValue: 2): UnresolvedCounts(pending: 3, ignored: 0)],
                                                   preferring: nil)
                == LibraryID(rawValue: 2))
    }

    @Test("どこにも未解決が無ければ先頭を選ぶ（行き止まりにしない）")
    func fallsBackToTheFirstLibrary() {
        let libs = [library("A", id: 1), library("B", id: 2)]
        #expect(UnresolvedFileModel.defaultLibrary(from: libs, counts: [:], preferring: nil)
                == LibraryID(rawValue: 1))
        #expect(UnresolvedFileModel.defaultLibrary(from: [], counts: [:], preferring: nil) == nil)
    }

    // MARK: - 500 件超の案内 [UR2-08][OB-08]

    @Test("500 件までは手で片付けられる規模とみなす")
    func doesNotOfferFormatFirstBelowTheThreshold() {
        #expect(UnresolvedFileModel.shouldOfferFormatFirst(count: 0) == false)
        #expect(UnresolvedFileModel.shouldOfferFormatFirst(count: 500) == false)
    }

    @Test("500 件を超えたらフォーマットの追加を最初に勧める [UR2-08]")
    func offersFormatFirstAboveTheThreshold() {
        #expect(UnresolvedFileModel.shouldOfferFormatFirst(count: 501))
    }
}

@Suite("未解決一覧の操作 [AL-33][AL-34][UR-05]", .serialized)
struct UnresolvedFileModelIntegrationTests {

    /// `ServicesWorkspace` はモデルより長生きしなければならない（`deinit` が
    /// 一時ストアを消すので、捨てると以後の書き込みが「disk I/O error」になる）。
    @MainActor
    final class Bench {
        let workspace: ServicesWorkspace
        let model: UnresolvedFileModel
        let commands: CommandStack
        let libraryID: LibraryID
        init(workspace: ServicesWorkspace, model: UnresolvedFileModel,
             commands: CommandStack, libraryID: LibraryID) {
            self.workspace = workspace
            self.model = model
            self.commands = commands
            self.libraryID = libraryID
        }
    }

    /// 一致するもの 1 件と、しないもの 2 件を取り込む。
    @MainActor
    private func bench() async throws -> Bench {
        let w = try ServicesWorkspace()
        await w.bootstrap()
        try w.write("(同人誌) [サークル値1 (著者値1)] 作品タイトル1 (ジャンル値1).cbz")
        try w.write("独自形式＿サークル値9＿作品タイトル9.cbz")
        try w.write("まったく別の形式.cbz")
        let id = try await w.enable("builtin.doujinshi-a")
        _ = try await w.services.scan(libraryID: id, root: w.libraryRoot)

        let commands = CommandStack()
        let m = UnresolvedFileModel(commands: commands)
        await m.prepare(services: w.services)
        return Bench(workspace: w, model: m, commands: commands, libraryID: id)
    }

    @Test("当たらなかったファイルだけが一覧に出る [UR-01]")
    @MainActor
    func listsUnresolvedOnly() async throws {
        let b = try await bench()
        #expect(b.model.state == .ready)
        #expect(Set(b.model.files.map(\.row.filename))
                == ["独自形式＿サークル値9＿作品タイトル9.cbz", "まったく別の形式.cbz"])
        #expect(b.model.unresolvedCounts[b.libraryID]?.pending == 2)
    }

    @Test("無視すると一覧からも件数からも消え、⌘Z で戻る [AL-33][UR-05]")
    @MainActor
    func ignoreHidesAndUndoRestores() async throws {
        let b = try await bench()
        let target = try #require(b.model.files.first)
        try await b.model.setIgnored([target], true)

        #expect(b.model.files.count == 1)
        #expect(b.model.unresolvedCounts[b.libraryID]?.pending == 1)

        _ = await b.commands.undo()
        await b.model.reload()
        #expect(b.model.files.count == 2)
    }

    /// **変更前の値を 1 件ずつ持つ**（`SetRatingCommand` と同じ理由）。
    /// 一律に戻すと、⌘Z が「無視していなかったもの」まで無視にしてしまう。
    @Test("一括で無視したあとの ⌘Z が、元から無視だったものを解かない")
    @MainActor
    func undoRestoresPerFileValues() async throws {
        let b = try await bench()
        let first = try #require(b.model.files.first)
        try await b.model.setIgnored([first], true)

        // 片方だけ無視した状態から「全部無視する」
        b.model.includeIgnored = true
        await b.model.reload()
        #expect(b.model.files.count == 2)
        try await b.model.setIgnored(b.model.files, true)
        #expect(b.model.files.filter(\.isIgnored).count == 2)

        _ = await b.commands.undo()
        await b.model.reload()
        let ignored = Set(b.model.files.filter(\.isIgnored).map(\.row.id))
        #expect(ignored == [first.row.id], "元から無視だったものは無視のまま")
    }

    @Test("値が変わらない操作は ⌘Z の履歴を埋めない")
    @MainActor
    func noOpDoesNotStackUndo() async throws {
        let b = try await bench()
        let before = b.commands.canUndo
        try await b.model.setIgnored(b.model.files, false)   // 既に全件 false
        #expect(b.commands.canUndo == before)
    }

    @Test("無視したものは切り替えで見えるようになる [UR2-04]")
    @MainActor
    func ignoredBecomeVisibleWhenAsked() async throws {
        let b = try await bench()
        try await b.model.setIgnored([try #require(b.model.files.first)], true)
        #expect(b.model.files.count == 1)

        b.model.includeIgnored = true
        #expect(b.model.needsReload, "View が読み直す合図が立つ")
        await b.model.reload()
        #expect(b.model.files.count == 2)
        #expect(!b.model.needsReload)
    }

    // MARK: - 手動ラベルで一覧から消える [AL-30]①③［ユーザー判断、2026-08］

    /// ラベルを付けるまでの下ごしらえ。未解決の 1 件を選んだ `LabelEditorModel` を返す。
    @MainActor
    private func labelBench(_ b: Bench) async throws -> (LabelEditorModel, LabelSummary) {
        let labels = LabelEditorModel(commands: b.commands)
        labels.onAssign = { [weak model = b.model] in model?.ignoreCommandForAssigned($0) }
        let target = try #require(b.model.files.first)
        b.model.selection = [target.row.id]
        await labels.load(rows: [target.row], library: b.model.selectedLibrary,
                          services: b.workspace.services)
        let groups = try await b.workspace.services.labelGroups(libraryID: b.libraryID)
        let circle = try #require(groups.first { $0.name == "サークル" })
        let all = try await b.workspace.services.labels(groupID: circle.id, includeArchived: true)
        return (labels, try #require(all.first))
    }

    /// **`isUnresolved` はパース結果だけを見る** [EM-03] ので、手で付けた
    /// ラベルは判定を動かさない。これが無いと [AL-30]① で片付けたつもりの
    /// ファイルが一覧に残り続け、③（無視）を続けて使うしか無くなる。
    @Test("手でラベルを付けると「以後無視する」も立ち、一覧から消える [AL-30]")
    @MainActor
    func assigningALabelAlsoIgnores() async throws {
        let b = try await bench()
        let (labels, label) = try await labelBench(b)
        let target = try #require(b.model.files.first)

        try await labels.add(label)
        await b.model.reload()

        #expect(!b.model.files.contains { $0.row.id == target.row.id })
        #expect(b.model.hiddenIgnoredCount == 1)
    }

    /// **⌘Z 1 回で両方戻る** [UD-04]。別々に積むと「ラベルは戻ったが一覧に
    /// 出てこない」半端な状態を経由する。
    @Test("⌘Z 1 回でラベルと無視の両方が戻る [UD-04]")
    @MainActor
    func oneUndoRestoresBothTheLabelAndTheIgnore() async throws {
        let b = try await bench()
        let (labels, label) = try await labelBench(b)
        let target = try #require(b.model.files.first)
        try await labels.add(label)
        await b.model.reload()
        #expect(b.model.files.count == 1)

        _ = await b.commands.undo()
        await b.model.reload()

        #expect(b.model.files.contains { $0.row.id == target.row.id }, "一覧へ戻る")
        #expect(b.model.hiddenIgnoredCount == 0, "無視も解ける")
        let assignments = try await b.workspace.services
            .labelAssignments(fileIDs: [target.row.id])
        #expect(assignments[target.row.id]?[label.id] == nil, "ラベルも外れる")
    }

    /// **ラベルを外したときに一覧から消してはならない。**
    @Test("ラベルを外したときは無視を立てない")
    @MainActor
    func unassigningDoesNotIgnore() async throws {
        let b = try await bench()
        let (labels, label) = try await labelBench(b)
        try await labels.add(label)
        await b.model.reload()

        // 無視を解いて一覧へ戻し、同じラベルを外す。
        b.model.includeIgnored = true
        await b.model.reload()
        let target = try #require(b.model.files.first { $0.isIgnored })
        try await b.model.setIgnored([target], false)
        b.model.includeIgnored = false
        await b.model.reload()
        let before = b.model.files.count

        b.model.selection = [target.row.id]
        await labels.load(rows: [target.row], library: b.model.selectedLibrary,
                          services: b.workspace.services)
        try await labels.toggle(label)   // 付いているので外れる
        await b.model.reload()
        #expect(b.model.files.count == before, "外しても一覧から消えない")
    }

    /// **右ペイン（インスペクタ）は `onAssign` を設定しない**——蔵書のどの
    /// ファイルにラベルを付けても未解決の判断が動いてはならない。
    @Test("onAssign を設定しなければ無視は立たない（右ペインの経路）")
    @MainActor
    func withoutTheHookNothingIsIgnored() async throws {
        let b = try await bench()
        let labels = LabelEditorModel(commands: b.commands)   // onAssign を渡さない
        let target = try #require(b.model.files.first)
        await labels.load(rows: [target.row], library: b.model.selectedLibrary,
                          services: b.workspace.services)
        let groups = try await b.workspace.services.labelGroups(libraryID: b.libraryID)
        let circle = try #require(groups.first { $0.name == "サークル" })
        let label = try #require(try await b.workspace.services
            .labels(groupID: circle.id, includeArchived: true).first)

        try await labels.add(label)
        await b.model.reload()
        #expect(b.model.files.contains { $0.row.id == target.row.id })
        #expect(b.model.hiddenIgnoredCount == 0)
    }

    @Test("フォーマットをその場で足すと、続けて再マッチングまで走る [UR-04][AL-34]")
    @MainActor
    func addFormatRematchesImmediately() async throws {
        let b = try await bench()
        try await b.model.addFormat(source: "独自形式＿@labelgroup2＿@title")

        #expect(b.model.lastRematch?.resolved == 1)
        #expect(b.model.files.map(\.row.filename) == ["まったく別の形式.cbz"])
        #expect(b.model.unresolvedCounts[b.libraryID]?.pending == 1)
    }

    @Test("空のフォーマットは足さない（設定を無意味に書き換えない）")
    @MainActor
    func emptyFormatIsRejected() async throws {
        let b = try await bench()
        let before = try #require(try await b.workspace.services
            .settingsDraft(libraryID: b.libraryID)).filenameFormats.count
        try await b.model.addFormat(source: "   ")
        let after = try #require(try await b.workspace.services
            .settingsDraft(libraryID: b.libraryID)).filenameFormats.count
        #expect(before == after)
    }

    /// 残すと「12 件が解決しました」が切り替えた先のライブラリの下端に出て、
    /// そちらに対して実行したように読める。
    @Test("ライブラリを切り替えたら直近の再マッチング結果を捨てる")
    @MainActor
    func switchingLibraryClearsTheLastRematch() async throws {
        let b = try await bench()
        try await b.model.rematch()
        #expect(b.model.lastRematch != nil)

        b.model.selectedLibraryID = nil
        #expect(b.model.lastRematch == nil)
    }

    /// コマンドは変わるものだけを書き換えるのに、名前を選択全件から取ると
    /// Undo メニューだけが過大に出る [UD-06]。
    @Test("Undo メニューの件数が「実際に変わったもの」と一致する")
    @MainActor
    func undoTitleCountsOnlyWhatChanged() async throws {
        let b = try await bench()
        let first = try #require(b.model.files.first)
        try await b.model.setIgnored([first], true)

        // 片方だけ無視した状態から「全部無視する」——変わるのは 1 件だけ。
        b.model.includeIgnored = true
        await b.model.reload()
        #expect(b.model.files.count == 2)
        try await b.model.setIgnored(b.model.files, true)

        let title = try #require(b.commands.undoTitle)
        #expect(!title.contains("2 件"), "変わらなかったものまで数えている: \(title)")
    }

    /// **無視して空にしただけのときに「すべて一致しています」と言わない。**
    /// 実機検証で見つけた——事実でないうえ、戻す手段（「無視したものも表示」）
    /// へ誘導もしない。
    @Test("無視して空になったときは、隠している件数が分かる")
    @MainActor
    func emptyStateDistinguishesIgnoredFromResolved() async throws {
        let b = try await bench()
        #expect(b.model.hiddenIgnoredCount == 0)

        try await b.model.setIgnored(b.model.files, true)
        #expect(b.model.hasNoUnresolved)
        #expect(b.model.hiddenIgnoredCount == 2)   // bench は未解決 2 件

        // 「無視したものも表示」中は隠していないので 0 に戻る。
        b.model.includeIgnored = true
        await b.model.reload()
        #expect(b.model.hiddenIgnoredCount == 0)
    }

    @Test("未解決が無ければ一覧は空（検索で 0 件になった場合と区別できる）")
    @MainActor
    func reportsAnEmptyListDistinctly() async throws {
        let b = try await bench()
        b.model.searchText = "存在しない語"
        #expect(b.model.visibleFiles.isEmpty)
        #expect(!b.model.hasNoUnresolved, "検索の結果と、そもそも 0 件であることは別")
    }
}

@Suite("未解決の無視コマンド [AL-33][UD-03]")
@MainActor
struct SetUnresolvedIgnoredCommandTests {

    /// 診断ログの匿名化が拾えるのは絶対パスと `Log.redactable` の印だけ
    /// [LG2-06]。素のファイル名を書くと書き出しバンドルに実名が残る。
    @Test("logDescription がファイル名を伏字の印で包む")
    func logDescriptionWrapsNames() {
        let command = SetUnresolvedIgnoredCommand(
            previous: [.init(fileID: FileID(rawValue: 1), isIgnored: false)],
            ignored: true, names: ["謎の名前.cbz"], services: LibraryServices.shared)
        #expect(command.logDescription.contains(Log.redactable("謎の名前.cbz")))
        #expect(!command.logDescription.contains(" 謎の名前.cbz"))
    }

    /// Undo メニューは「〜を取り消す」を後ろに付けるので、名詞句でなければ
    /// 助詞が重なる [UD-06]。
    @Test("displayName が名詞句になっている")
    func displayNameIsANounPhrase() {
        let one = SetUnresolvedIgnoredCommand(
            previous: [.init(fileID: FileID(rawValue: 1), isIgnored: false)],
            ignored: true, names: ["謎の名前.cbz"], services: LibraryServices.shared)
        #expect(one.displayName == "「謎の名前.cbz」の以後無視する設定")

        let many = SetUnresolvedIgnoredCommand(
            previous: [.init(fileID: FileID(rawValue: 1), isIgnored: true),
                       .init(fileID: FileID(rawValue: 2), isIgnored: true)],
            ignored: false, names: ["一.cbz", "二.cbz"], services: LibraryServices.shared)
        #expect(many.displayName == "2 件のファイルの無視の解除")
    }

    @Test("取り消せる操作として宣言する [UD-03]")
    func isUndoable() {
        let command = SetUnresolvedIgnoredCommand(
            previous: [], ignored: true, names: [], services: LibraryServices.shared)
        #expect(command.isUndoable)
    }
}
