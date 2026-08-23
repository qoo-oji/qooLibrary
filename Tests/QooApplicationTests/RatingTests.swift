import Foundation
import QooKit
import Testing
@testable import QooApplication

//
//  評価 [RA-01〜RA-08]。
//
//  DB を実際に開いて確かめる——`SetRatingCommand` が守っているのは
//  「変更前の値を 1 件ずつ持って戻す」という**書き込みの性質**なので、
//  リポジトリを偽物に差し替えると肝心の部分が試せない。
//  `ServicesWorkspace`（`LibraryServicesTests.swift`）を共有する。
//

@Suite("評価 [RA-01〜RA-08]", .serialized)
struct RatingCommandTests {

    /// 同人誌(A) はシリーズを持たないフォーマットなので、シリーズを試すには
    /// 一般コミック(A) を使う——**主張を検証するには、その主張が成り立ちうる
    /// 前提を先に用意する**（2-19 で 4 件落として学んだ形）。
    @MainActor
    private func workspace(files: [String], preset: String = "builtin.general-comic-a")
        async throws -> (ServicesWorkspace, LibraryID, [URL])
    {
        let w = try ServicesWorkspace()
        await w.bootstrap()
        for name in files { try w.write(name) }
        let id = try await w.enable(preset)
        _ = try await w.services.scan(libraryID: id, root: w.libraryRoot)
        return (w, id, files.map { w.libraryRoot.appendingPathComponent($0) })
    }

    // MARK: - 引き当て

    /// **同一性で引く**ので、パスの綴り（NFD/NFC）に依存しない。
    @Test("選択中のファイルの行を引ける")
    @MainActor
    func findsTheRowForAURL() async throws {
        let (w, _, urls) = try await workspace(files: ["(一般コミック) [著者値A] 作品名A 第01巻.cbz"])
        let library = try #require(w.services.library(registrationUUID: w.registrationUUID))
        let row = try #require(try await w.services.fileRow(at: urls[0], in: library))
        #expect(row.filename == "(一般コミック) [著者値A] 作品名A 第01巻.cbz")
        #expect(row.rating == 0)
    }

    @Test("DB に無いファイルでは nil")
    @MainActor
    func returnsNilForAFileOutsideTheLibrary() async throws {
        let (w, _, _) = try await workspace(files: ["(一般コミック) [著者値A] 作品名A 第01巻.cbz"])
        try w.write("メモ.txt")               // 対象拡張子ではない [AL-11]
        let library = try #require(w.services.library(registrationUUID: w.registrationUUID))
        let url = w.libraryRoot.appendingPathComponent("メモ.txt")
        #expect(try await w.services.fileRow(at: url, in: library) == nil)
    }

    // MARK: - コマンド

    @Test("星を付けて ⌘Z で戻せる [RA-01][UD-01]")
    @MainActor
    func setAndUndo() async throws {
        let (w, _, urls) = try await workspace(files: ["(一般コミック) [著者値A] 作品名A 第01巻.cbz"])
        let library = try #require(w.services.library(registrationUUID: w.registrationUUID))
        let row = try #require(try await w.services.fileRow(at: urls[0], in: library))

        let stack = CommandStack()
        let command = SetRatingCommand(
            targets: [RatingTarget(id: row.id, url: urls[0], previousStars: row.rating)],
            stars: 4, subjectName: row.filename, services: w.services)
        #expect(command.isUndoable)
        _ = try await stack.run(command)
        #expect(try await w.services.fileRow(at: urls[0], in: library)?.rating == 4)

        _ = await stack.undo()
        #expect(try await w.services.fileRow(at: urls[0], in: library)?.rating == 0)
        _ = await stack.redo()
        #expect(try await w.services.fileRow(at: urls[0], in: library)?.rating == 4)
    }

    /// **これが崩れると ⌘Z が元の評価を壊す。** 一律に 0 へ戻す実装だと、
    /// 全巻適用の前にばらばらだった評価が全部消える——しかも「戻した」ように
    /// 見えるので気づきにくい。
    @Test("全巻適用の取り消しは、巻ごとの元の値へ戻す [RA-06]")
    @MainActor
    func undoRestoresPerFilePreviousValues() async throws {
        let (w, _, urls) = try await workspace(files: [
            "(一般コミック) [著者値A] 作品名A 第01巻.cbz", "(一般コミック) [著者値A] 作品名A 第02巻.cbz", "(一般コミック) [著者値A] 作品名A 第03巻.cbz",
        ])
        let library = try #require(w.services.library(registrationUUID: w.registrationUUID))
        var rows: [FileRow] = []
        for url in urls { rows.append(try #require(try await w.services.fileRow(at: url, in: library))) }
        // 巻ごとに違う評価を入れておく。
        try await w.services.setRating(1, ids: [rows[0].id])
        try await w.services.setRating(5, ids: [rows[1].id])
        // rows[2] は 0 のまま

        let previous = [1, 5, 0]
        let stack = CommandStack()
        let command = SetRatingCommand(
            targets: zip(zip(rows, urls), previous).map { pair, prev in
                RatingTarget(id: pair.0.id, url: pair.1, previousStars: prev)
            },
            stars: 3, subjectName: rows[0].filename, seriesName: "作品名A",
            services: w.services)
        _ = try await stack.run(command)
        for url in urls {
            #expect(try await w.services.fileRow(at: url, in: library)?.rating == 3)
        }

        _ = await stack.undo()
        for (url, expected) in zip(urls, previous) {
            #expect(try await w.services.fileRow(at: url, in: library)?.rating == expected)
        }
    }

    @Test("Undo/Redo メニューに出る名前 [UD-06]")
    @MainActor
    func displayNames() async throws {
        let w = try ServicesWorkspace()
        let url = w.libraryRoot.appendingPathComponent("(一般コミック) [著者値A] 作品名A 第01巻.cbz")
        let target = RatingTarget(id: FileID(rawValue: 1), url: url, previousStars: 0)
        let single = SetRatingCommand(targets: [target], stars: 3,
                                      subjectName: "(一般コミック) [著者値A] 作品名A 第01巻.cbz", services: w.services)
        #expect(single.displayName
                == "「(一般コミック) [著者値A] 作品名A 第01巻.cbz」の評価を★3に設定")

        let cleared = SetRatingCommand(targets: [target], stars: 0,
                                       subjectName: "(一般コミック) [著者値A] 作品名A 第01巻.cbz", services: w.services)
        #expect(cleared.displayName
                == "「(一般コミック) [著者値A] 作品名A 第01巻.cbz」の評価を解除")

        let series = SetRatingCommand(targets: [target, target], stars: 4,
                                      subjectName: "x", seriesName: "作品名A",
                                      services: w.services)
        #expect(series.displayName == "「作品名A」2 冊の評価を★4に設定")
    }

    /// 診断ログの匿名化が拾えるのは絶対パスと `Log.redactable` の印だけ
    /// [LG2-06]。素のファイル名を書くと書き出しバンドルに残る。
    @Test("診断ログの説明は絶対パスで書く [LG2-06]")
    @MainActor
    func logDescriptionUsesAbsolutePaths() async throws {
        let w = try ServicesWorkspace()
        let url = w.libraryRoot.appendingPathComponent("(一般コミック) [著者値A] 作品名A 第01巻.cbz")
        let command = SetRatingCommand(
            targets: [RatingTarget(id: FileID(rawValue: 1), url: url, previousStars: 0)],
            stars: 3, subjectName: "(一般コミック) [著者値A] 作品名A 第01巻.cbz", services: w.services)
        let text = command.logDescription
        #expect(text.contains(url.path))
        #expect(!text.contains("「(一般コミック) [著者値A] 作品名A 第01巻.cbz」"),
                "`displayName` をそのまま流用していない")
    }
}

@Suite("評価の判定 [RA-02][RA-07]")
struct RatingEditorModelTests {

    @Test("同じ星をもう一度押すと解除 [RA-02]")
    func tappingTheSameStarClears() {
        #expect(RatingEditorModel.starsAfterTapping(3, current: 3) == 0)
        #expect(RatingEditorModel.starsAfterTapping(3, current: 0) == 3)
        #expect(RatingEditorModel.starsAfterTapping(1, current: 5) == 1)
        #expect(RatingEditorModel.starsAfterTapping(5, current: 4) == 5)
    }

    @Test("ライブラリ経由でなければ欄を出さない [LF-01 と同じ判断]")
    @MainActor
    func notApplicableOutsideALibrary() async throws {
        let w = try ServicesWorkspace()
        await w.bootstrap()
        let model = RatingEditorModel(commands: CommandStack())
        await model.load(url: w.libraryRoot.appendingPathComponent("a.cbz"),
                         library: nil, services: w.services)
        #expect(model.state == .notApplicable)
    }

    @Test("DB に行が無ければ理由を出す［ユーザー判断］")
    @MainActor
    func showsAReasonWhenTheFileIsNotInTheLibrary() async throws {
        let w = try ServicesWorkspace()
        await w.bootstrap()
        try w.write("メモ.txt")
        let id = try await w.enable("builtin.general-comic-a")
        _ = try await w.services.scan(libraryID: id, root: w.libraryRoot)
        let library = try #require(w.services.library(registrationUUID: w.registrationUUID))

        let model = RatingEditorModel(commands: CommandStack())
        await model.load(url: w.libraryRoot.appendingPathComponent("メモ.txt"),
                         library: library, services: w.services)
        #expect(model.state == .notInLibrary)
    }

    @Test("星を押すと DB に入り、状態も追随する [RA-01]")
    @MainActor
    func setStarsWritesThrough() async throws {
        let w = try ServicesWorkspace()
        await w.bootstrap()
        try w.write("(一般コミック) [著者値A] 作品名A 第01巻.cbz")
        let id = try await w.enable("builtin.general-comic-a")
        _ = try await w.services.scan(libraryID: id, root: w.libraryRoot)
        let library = try #require(w.services.library(registrationUUID: w.registrationUUID))
        let url = w.libraryRoot.appendingPathComponent("(一般コミック) [著者値A] 作品名A 第01巻.cbz")

        let model = RatingEditorModel(commands: CommandStack())
        await model.load(url: url, library: library, services: w.services)
        guard case .ready(let subject) = model.state else {
            Issue.record("評価できる状態にならない: \(model.state)")
            return
        }
        #expect(subject.stars == 0)

        try await model.setStars(tapped: 4)
        guard case .ready(let updated) = model.state else {
            Issue.record("状態が追随していない")
            return
        }
        #expect(updated.stars == 4)
        #expect(try await w.services.fileRow(at: url, in: library)?.rating == 4)

        // 同じ星をもう一度で解除 [RA-02]
        try await model.setStars(tapped: 4)
        #expect(try await w.services.fileRow(at: url, in: library)?.rating == 0)
    }

    /// **`.task` の読み直しを待たずに全巻適用が押されても、⌘Z が正しく戻る。**
    /// 「変更前の値」を読み込み時の一覧から取ると、直前に押した星が反映されて
    /// おらず、⌘Z が**いま持っていない値**へ戻してしまう。
    @Test("星を押した直後に全巻適用しても、取り消しが正しい値へ戻る")
    @MainActor
    func applyToSeriesUsesFreshPreviousValues() async throws {
        let w = try ServicesWorkspace()
        await w.bootstrap()
        let names = ["(一般コミック) [著者値A] 作品名A 第01巻.cbz",
                     "(一般コミック) [著者値A] 作品名A 第02巻.cbz"]
        for name in names { try w.write(name) }
        let id = try await w.enable("builtin.general-comic-a")
        _ = try await w.services.scan(libraryID: id, root: w.libraryRoot)
        let library = try #require(w.services.library(registrationUUID: w.registrationUUID))
        let urls = names.map { w.libraryRoot.appendingPathComponent($0) }

        let stack = CommandStack()
        let model = RatingEditorModel(commands: stack)
        await model.load(url: urls[0], library: library, services: w.services)

        // 読み直し（`.task(id:)`）を挟まずに続けて操作する。
        try await model.setStars(tapped: 3)      // 1 巻目だけ ★3
        try await model.applyToSeries()          // 全巻 ★3
        #expect(try await w.services.fileRow(at: urls[1], in: library)?.rating == 3)

        _ = await stack.undo()                   // 全巻適用を取り消す
        #expect(try await w.services.fileRow(at: urls[0], in: library)?.rating == 3,
                "1 巻目は ★3 のまま——全巻適用の前の値へ戻る")
        #expect(try await w.services.fileRow(at: urls[1], in: library)?.rating == 0)

        _ = await stack.undo()                   // 星付けも取り消す
        #expect(try await w.services.fileRow(at: urls[0], in: library)?.rating == 0)
    }

    /// 未評価のまま「全巻の評価を解除」を常駐させると、何もしていない状態の
    /// 一番目立つ位置に、押すと他の巻の星が消える導線が座る［実機検証で発見］。
    @Test("シリーズ全巻への適用は、効果があるときだけ出す")
    @MainActor
    func seriesActionAppearsOnlyWhenItWouldChangeSomething() async throws {
        let w = try ServicesWorkspace()
        await w.bootstrap()
        let names = ["(一般コミック) [著者値A] 作品名A 第01巻.cbz",
                     "(一般コミック) [著者値A] 作品名A 第02巻.cbz"]
        for name in names { try w.write(name) }
        let id = try await w.enable("builtin.general-comic-a")
        _ = try await w.services.scan(libraryID: id, root: w.libraryRoot)
        let library = try #require(w.services.library(registrationUUID: w.registrationUUID))
        let urls = names.map { w.libraryRoot.appendingPathComponent($0) }

        let model = RatingEditorModel(commands: CommandStack())
        await model.load(url: urls[0], library: library, services: w.services)
        guard case .ready(let fresh) = model.state else {
            Issue.record("評価できる状態にならない: \(model.state)")
            return
        }
        #expect(fresh.seriesCount == 2)
        #expect(!fresh.canApplyToSeries, "シリーズが丸ごと未評価なら出さない")

        // 星を付ければ「適用」に意味が出る。読み直しを待たずに反映されること。
        try await model.setStars(tapped: 3)
        guard case .ready(let rated) = model.state else { return }
        #expect(rated.canApplyToSeries)

        // 解除しても、シリーズの他の巻に星があれば「解除」に意味が残る。
        try await model.applyToSeries()
        try await model.setStars(tapped: 3)          // 同じ星 → 解除 [RA-02]
        await model.load(url: urls[0], library: library, services: w.services)
        guard case .ready(let cleared) = model.state else { return }
        #expect(cleared.stars == 0)
        #expect(cleared.canApplyToSeries, "2 巻目に星が残っているので「解除」は有効")
    }

    @Test("シリーズ全巻に適用できる [RA-04][RA-05]")
    @MainActor
    func appliesToTheWholeSeries() async throws {
        let w = try ServicesWorkspace()
        await w.bootstrap()
        let names = ["(一般コミック) [著者値A] 作品名A 第01巻.cbz", "(一般コミック) [著者値A] 作品名A 第02巻.cbz", "(一般コミック) [著者値B] 作品名B 第01巻.cbz"]
        for name in names { try w.write(name) }
        let id = try await w.enable("builtin.general-comic-a")
        _ = try await w.services.scan(libraryID: id, root: w.libraryRoot)
        let library = try #require(w.services.library(registrationUUID: w.registrationUUID))
        let urls = names.map { w.libraryRoot.appendingPathComponent($0) }

        let model = RatingEditorModel(commands: CommandStack())
        await model.load(url: urls[0], library: library, services: w.services)
        guard case .ready(let subject) = model.state else {
            Issue.record("評価できる状態にならない: \(model.state)")
            return
        }
        #expect(subject.seriesName == "作品名A")
        #expect(subject.seriesCount == 2, "件数は実行前に出す [RA-05]")

        try await model.setStars(tapped: 5)
        try await model.applyToSeries()
        #expect(try await w.services.fileRow(at: urls[0], in: library)?.rating == 5)
        #expect(try await w.services.fileRow(at: urls[1], in: library)?.rating == 5)
        #expect(try await w.services.fileRow(at: urls[2], in: library)?.rating == 0,
                "別のシリーズを巻き込まない")
    }
}
