import Foundation
import QooKit
import Testing
@testable import QooApplication

//
//  シリーズスタックの判定 [VM3-01〜VM3-06]。
//
//  **「いつ畳むか」がこの機能の要点**——絞り込んでいる間に畳むと、せっかく
//  一致した本がスタックの中に隠れる [VM3-06]。判定は
//  `LibraryContentModel.load` 1 箇所に集約してあるので、実際に DB を開いて
//  結果の `foldsIntoSeriesStacks` を見る（`LibraryContentModelTests` と同じ
//  `ServicesWorkspace` を共有する）。
//

@Suite("シリーズスタックの判定 [VM3-01〜VM3-06]", .serialized)
struct SeriesStackModelTests {

    /// 一般コミック(A) は `VS-Full` を持つのでファイル名からシリーズ名と巻数が
    /// 取れる——同人誌(A) は巻数フォーマットを持たず、シリーズが 1 件も
    /// 生まれないので、このスイートでは使えない [CLAUDE.md に既記録の罠]。
    private static func file(_ series: String, _ volume: Int) -> String {
        String(format: "(一般コミック) [著者値A] %@ 第%02d巻.cbz", series, volume)
    }

    @MainActor
    private func workspace(_ files: [String]) async throws -> (ServicesWorkspace, LibrarySummary) {
        let w = try ServicesWorkspace()
        await w.bootstrap()
        for name in files { try w.write(name) }
        let id = try await w.enable("builtin.general-comic-a")
        _ = try await w.services.scan(libraryID: id, root: w.libraryRoot)
        let library = try #require(w.services.library(registrationUUID: w.registrationUUID))
        return (w, library)
    }

    @MainActor
    private func load(_ model: LibraryContentModel, _ w: ServicesWorkspace,
                      _ library: LibrarySummary,
                      labels: [FieldID: Set<LabelID>] = [:],
                      rating: FileQuery.RatingFilter? = nil,
                      search: String? = nil) async {
        await model.load(library: library, relativePath: "",
                         labelSelection: labels, ratingFilter: rating,
                         searchText: search, services: w.services)
    }

    // MARK: - 畳み方 [VM3-01][VM3-02][VM3-04]

    @MainActor
    @Test("既定で畳み、シリーズ名と冊数を持つ行になる [VM3-01][VM3-02][VM3-05]")
    func stacksByDefault() async throws {
        let (w, library) = try await workspace([
            Self.file("作品名A", 1), Self.file("作品名A", 2), Self.file("作品名B", 1),
        ])
        let model = LibraryContentModel()
        #expect(model.seriesStacking, "既定 ON [VM3-05]")
        await load(model, w, library)

        #expect(model.foldsIntoSeriesStacks)
        #expect(model.totalCount == 2)
        let stack = try #require(model.rows.first { $0.isSeriesStack })
        guard case .series(let count, let name) = stack.group else {
            Issue.record("スタックになっていない"); return
        }
        #expect(count == 2)
        #expect(name == "作品名A")
        #expect(stack.displayName == "作品名A", "スタックはシリーズ名で出す [VM3-02]")
    }

    @MainActor
    @Test("切ると巻ごとに並ぶ [VM3-05]")
    func turningStackingOffShowsEveryVolume() async throws {
        let (w, library) = try await workspace([
            Self.file("作品名A", 1), Self.file("作品名A", 2),
        ])
        let model = LibraryContentModel()
        model.setSeriesStacking(false)
        await load(model, w, library)
        #expect(!model.foldsIntoSeriesStacks)
        #expect(model.totalCount == 2)
        #expect(model.rows.allSatisfy { !$0.isSeriesStack })
    }

    // MARK: - 絞り込み中は畳まない [VM3-06]

    @MainActor
    @Test("検索している間は畳まない [VM3-06]")
    func searchingSuppressesStacking() async throws {
        let (w, library) = try await workspace([
            Self.file("作品名A", 1), Self.file("作品名A", 2),
        ])
        let model = LibraryContentModel()
        await load(model, w, library, search: "作品名A")
        #expect(!model.foldsIntoSeriesStacks, "一致した本がスタックに隠れてはならない")
        #expect(model.totalCount == 2)
    }

    @MainActor
    @Test("評価で絞っている間は畳まない [VM3-06]")
    func ratingFilterSuppressesStacking() async throws {
        let (w, library) = try await workspace([
            Self.file("作品名A", 1), Self.file("作品名A", 2),
        ])
        let model = LibraryContentModel()
        await load(model, w, library, rating: FileQuery.RatingFilter(stars: 0, mode: .exact))
        #expect(!model.foldsIntoSeriesStacks)
        #expect(model.totalCount == 2)
    }

    @MainActor
    @Test("ラベルで絞っている間は畳まない [VM3-06]")
    func labelFilterSuppressesStacking() async throws {
        let (w, library) = try await workspace([
            Self.file("作品名A", 1), Self.file("作品名A", 2),
        ])
        let fields = try await w.services.fields(libraryID: library.id)
        let author = try #require(fields.first { $0.index == 1 })
        let labels = try await w.services.labels(fieldID: author.id)
        let label = try #require(labels.first)

        let model = LibraryContentModel()
        await load(model, w, library, labels: [author.id: [label.id]])
        #expect(!model.foldsIntoSeriesStacks)
        #expect(model.totalCount == 2)
    }

    @MainActor
    @Test("未整理ビューでは畳まない [VM3-06]")
    func unresolvedViewSuppressesStacking() async throws {
        let (w, library) = try await workspace([
            Self.file("作品名A", 1), Self.file("作品名A", 2),
        ])
        let model = LibraryContentModel()
        model.setUnresolvedFilter(.pending)
        await load(model, w, library)
        #expect(!model.foldsIntoSeriesStacks)
    }

    @MainActor
    @Test("「重複のみ」の間は畳まない [VM3-06][DU-11]")
    func duplicatesOnlySuppressesStacking() async throws {
        let (w, library) = try await workspace([
            Self.file("作品名A", 1), Self.file("作品名A", 2),
        ])
        let model = LibraryContentModel()
        model.setDuplicatesOnly(true)
        await load(model, w, library)
        #expect(!model.foldsIntoSeriesStacks)
    }

    // MARK: - ドリルイン [VM3-03]

    @MainActor
    @Test("スタックを開くとその巻だけが並び、畳まれない [VM3-03]")
    func drillingInShowsTheVolumes() async throws {
        let (w, library) = try await workspace([
            Self.file("作品名A", 1), Self.file("作品名A", 2), Self.file("作品名B", 1),
        ])
        let model = LibraryContentModel()
        model.enterSeries("作品名A")
        #expect(model.isInsideSeriesStack)
        await load(model, w, library)

        #expect(!model.foldsIntoSeriesStacks, "同じシリーズを見ているので畳まない")
        #expect(model.totalCount == 2)
        #expect(model.rows.allSatisfy { $0.file.seriesName == "作品名A" })

        model.exitSeries()
        await load(model, w, library)
        #expect(model.foldsIntoSeriesStacks)
        #expect(model.totalCount == 2, "作品名A のスタック ＋ 作品名B")
    }

    @MainActor
    @Test("畳むのをやめるとドリルインも解ける [VM3-03][VM3-05]")
    func turningStackingOffLeavesTheStack() async throws {
        let model = LibraryContentModel()
        model.enterSeries("作品名A")
        model.setSeriesStacking(false)
        #expect(!model.isInsideSeriesStack,
                "スタックが無いのに「1 つのシリーズだけ」が残ると抜ける導線が宙に浮く")
    }

    // MARK: - 重複グループ化との併用［ユーザー判断］

    /// **外側はシリーズ、中で重複を畳む。** 二重に畳むと SQL も費用も積になる。
    @MainActor
    @Test("畳んでいる間は重複グループ化を効かせない [VM3-01]")
    func stackingSuppressesDuplicateGrouping() async throws {
        let (w, library) = try await workspace([Self.file("作品名A", 1)])
        var draft = try #require(try await w.services.settingsDraft(libraryID: library.id))
        draft.duplicateGrouping = .byTitle
        try await w.services.updateSettings(draft, libraryID: library.id)
        await w.services.refreshLibraries()
        let updated = try #require(w.services.library(registrationUUID: w.registrationUUID))

        let model = LibraryContentModel()
        await load(model, w, updated)
        #expect(model.foldsIntoSeriesStacks)
        #expect(model.grouping == .off, "スタックへ畳んでいる間は重複を畳まない")

        // ドリルインすれば重複グループ化が戻る（＝スタックの中で畳む）。
        model.enterSeries("作品名A")
        await load(model, w, updated)
        #expect(!model.foldsIntoSeriesStacks)
        #expect(model.grouping == .byTitle)
    }

    /// **シリーズ名を 1 件も持たないライブラリで重複グループ化が死なないこと**
    /// [code-review の指摘]。永続化層は事前確認 [VM3S-04] で畳まずに返すのに、
    /// モデルが「シリーズで畳んだつもり」で `grouping` を落としていると、
    /// **重複が恒久的に畳まれなくなる**——「重複のみを表示」も「重複を比較…」も
    /// 画面から消え、降りるスタックも無いので復帰手段が残らない。
    @MainActor
    @Test("シリーズが 1 件も無いライブラリでは重複グループ化が生きる [DU-01][VM3S-04]")
    func duplicateGroupingSurvivesWhenNoBookHasASeries() async throws {
        // 同人誌(A) は巻数フォーマットを持たないのでシリーズ名が 1 件も出ない
        // ——プリセットがシリーズを取らないライブラリ（成年コミック等）と同じ形。
        let w = try ServicesWorkspace()
        await w.bootstrap()
        for i in 1...2 {
            try w.write("(同人誌) [サークル値A (著者値1)] 同じ題 (ジャンル値1)\(i).cbz")
        }
        let id = try await w.enable("builtin.doujinshi-a")
        _ = try await w.services.scan(libraryID: id, root: w.libraryRoot)
        var draft = try #require(try await w.services.settingsDraft(libraryID: id))
        draft.duplicateGrouping = .byTitle
        try await w.services.updateSettings(draft, libraryID: id)
        await w.services.refreshLibraries()
        let library = try #require(w.services.library(registrationUUID: w.registrationUUID))

        let model = LibraryContentModel()
        #expect(model.seriesStacking, "希望は立っている（既定 ON）")
        await load(model, w, library)

        #expect(!model.foldsIntoSeriesStacks, "シリーズが無いので実際には畳まない")
        #expect(model.grouping == .byTitle, "重複グループ化が生きていること")
    }

    // MARK: - 状態の後始末

    @MainActor
    @Test("clear() はドリルインを解くが、畳むかどうかの選択は保つ [VM3-05][ST-20]")
    func clearForgetsTheDrillButKeepsThePreference() {
        let model = LibraryContentModel()
        model.enterSeries("作品名A")
        model.clear()
        #expect(!model.isInsideSeriesStack)
        #expect(model.seriesStacking, "利用者が選んだ見え方はフォルダを移っても保つ")

        model.setSeriesStacking(false)
        model.clear()
        #expect(!model.seriesStacking)
    }

    // MARK: - 行の組み立て（純粋関数）

    @Test("シリーズ名の無い行はスタックにならない [VM3-04]")
    func rowsWithoutASeriesAreNeverStacks() {
        let id = FileID(rawValue: 7)
        let row = Self.fileRow(id: id, seriesName: nil)
        let group = LibraryContentModel.group(for: row, counts: [id: 3], asSeriesStacks: true)
        #expect(group == .none)
    }

    @Test("空白だけのシリーズ名もスタックにならない [VM3-04]")
    func blankSeriesNamesAreNeverStacks() {
        let id = FileID(rawValue: 7)
        let row = Self.fileRow(id: id, seriesName: "   ")
        let group = LibraryContentModel.group(for: row, counts: [id: 3], asSeriesStacks: true)
        #expect(group == .none)
    }

    @Test("件数の器は 1 つで、意味は問い合わせた側が決める [DU-06][VM3-02]")
    func theSameCountsBecomeDuplicatesOrStacks() {
        let id = FileID(rawValue: 7)
        let row = Self.fileRow(id: id, seriesName: "作品名A")
        #expect(LibraryContentModel.group(for: row, counts: [id: 3], asSeriesStacks: false)
                == .duplicate(count: 3))
        #expect(LibraryContentModel.group(for: row, counts: [id: 3], asSeriesStacks: true)
                == .series(count: 3, name: "作品名A"))
        #expect(LibraryContentModel.group(for: row, counts: [id: 1], asSeriesStacks: true)
                == .none, "1 件の組は畳んでいない")
    }

    private static func fileRow(id: FileID, seriesName: String?) -> FileRow {
        FileRow(id: id, libraryID: LibraryID(rawValue: 1), relativePath: "a.cbz",
                filename: "a.cbz", fileSize: 1, createdAt: .distantPast,
                modifiedAt: .distantPast, title: "題", seriesName: seriesName,
                volume: .none, rating: 0, state: .active, isArchived: false,
                isBookFolder: false)
    }
}
