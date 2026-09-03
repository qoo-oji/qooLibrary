//
//  シリーズの提案が使うリポジトリ API [SS-02][SS-05][SS-08]（ステージ 10）。
//
//  **検出そのもの（組み方）は `QooKit` の純粋関数のテストで固定してある。**
//  ここが見るのは「どの本を候補として渡すか」と「無視印の往復」だけ。
//
import Testing
import Foundation
import GRDB
import QooKit
@testable import QooPersistence

@Suite("シリーズの提案の候補と無視印 [SS-02][SS-05][SS-08]")
struct SeriesSuggestionRepositoryTests {

    struct Setup {
        let f: Fixture
        let circleField: LabelGroupSummary

        static func make() async throws -> Setup {
            let f = try await Fixture.make(preset: "builtin.doujinshi-a")
            // 同人誌プリセットの `@circle` は 2 番のフィールド [RWI-02]。
            let circle = try #require(try await f.labels.group(libraryID: f.libraryID, index: 2))
            return Setup(f: f, circleField: circle)
        }

        @discardableResult
        func add(inode: UInt64, path: String, title: String?,
                 author: String? = "著者値1", series: String? = nil,
                 scopes: Set<ProtectionScope> = []) async throws -> FileID {
            let id = try await f.files.upsert(f.snapshot(inode: inode, path: path))
            try await f.files.setFields(
                FileFieldEdit(title: title, seriesName: series,
                              volume: .none, authorName: author),
                id: id, protectedScopes: scopes)
            return id
        }

        func candidates() async throws -> [SeriesSuggestionCandidate] {
            try await f.files.seriesSuggestionCandidates(libraryID: f.libraryID,
                                                         circleFieldID: circleField.id)
        }
    }

    // MARK: - 候補の絞り込み [SS-08]

    @Test("シリーズ名が入っている本は候補にしない [SS-01][SS-08]")
    func skipsBooksThatAlreadyHaveASeries() async throws {
        let s = try await Setup.make()
        try await s.add(inode: 1, path: "作品タイトル1.cbz", title: "作品タイトル1")
        try await s.add(inode: 2, path: "作品タイトル2.cbz", title: "作品タイトル2",
                        series: "作品タイトル")

        let ids = try await s.candidates().map(\.id)
        #expect(ids.count == 1)
    }

    @Test("基本情報を保護済みの本は候補にしない [SS-08]")
    func skipsProtectedBooks() async throws {
        let s = try await Setup.make()
        try await s.add(inode: 1, path: "作品タイトル1.cbz", title: "作品タイトル1")
        try await s.add(inode: 2, path: "作品タイトル2.cbz", title: "作品タイトル2",
                        scopes: [.basic])

        #expect(try await s.candidates().count == 1)
    }

    @Test("保管庫の本は候補にしない [SS-08]")
    func skipsArchivedBooks() async throws {
        let s = try await Setup.make()
        try await s.add(inode: 1, path: "作品タイトル1.cbz", title: "作品タイトル1")
        let archived = try await s.add(inode: 2, path: "作品タイトル2.cbz", title: "作品タイトル2")
        try await s.f.files.setArchived(
            [VaultMove(id: archived, relativePath: ".qooarchive/作品タイトル2.cbz",
                       previousPath: "作品タイトル2.cbz")],
            archived: true)

        #expect(try await s.candidates().count == 1)
    }

    @Test("実体が見つからない本は候補にしない（別の画面の担当）")
    func skipsNonActiveBooks() async throws {
        let s = try await Setup.make()
        try await s.add(inode: 1, path: "作品タイトル1.cbz", title: "作品タイトル1")
        let gone = try await s.add(inode: 2, path: "作品タイトル2.cbz", title: "作品タイトル2")
        try await s.f.files.setState(.orphaned, ids: [gone])

        #expect(try await s.candidates().count == 1)
    }

    @Test("タイトルが無い本は候補にしない")
    func skipsBooksWithoutATitle() async throws {
        let s = try await Setup.make()
        try await s.add(inode: 1, path: "作品タイトル1.cbz", title: "作品タイトル1")
        try await s.add(inode: 2, path: "なぞ.cbz", title: nil)

        #expect(try await s.candidates().count == 1)
    }

    // MARK: - 鍵の作り方 [SS-02]

    @Test("著者名は正規化して鍵にする [SS-02]")
    func authorIsNormalized() async throws {
        let s = try await Setup.make()
        try await s.add(inode: 1, path: "a.cbz", title: "作品タイトル1", author: "ＳＴＵＤＩＯ Ａ")

        let keys = try #require(try await s.candidates().first?.groupingKeys)
        #expect(keys == ["studio a"])
    }

    @Test("サークルのラベルも鍵になる [SS-02]")
    func circleLabelsBecomeKeys() async throws {
        let s = try await Setup.make()
        let id = try await s.add(inode: 1, path: "a.cbz", title: "作品タイトル1", author: nil)
        let label = try await s.f.labels.ensureLabel(groupID: s.circleField.id,
                                                    name: "サークル値A")
        try await s.f.labels.assign(fileID: id, labelID: label)

        let keys = try #require(try await s.candidates().first?.groupingKeys)
        #expect(keys == [TextNormalizer.normalize("サークル値A")])
    }

    @Test("サークルのフィールドを渡さなければ著者だけを見る")
    func circleIsOptional() async throws {
        let s = try await Setup.make()
        let id = try await s.add(inode: 1, path: "a.cbz", title: "作品タイトル1", author: nil)
        let label = try await s.f.labels.ensureLabel(groupID: s.circleField.id, name: "サークル値A")
        try await s.f.labels.assign(fileID: id, labelID: label)

        let out = try await s.f.files.seriesSuggestionCandidates(libraryID: s.f.libraryID,
                                                                circleFieldID: nil)
        #expect(out.first?.groupingKeys.isEmpty == true)
    }

    @Test("同じフォルダかどうかは相対パスの親で決める [SS-02]")
    func folderPathIsTheParent() async throws {
        let s = try await Setup.make()
        try await s.add(inode: 1, path: "作者A/a.cbz", title: "作品タイトル1")
        try await s.add(inode: 2, path: "b.cbz", title: "作品タイトル2")

        let folders = try await s.candidates()
            .sorted { $0.id.rawValue < $1.id.rawValue }.map(\.folderPath)
        #expect(folders == ["作者A", ""])
    }

    // MARK: - 無視印 [SS-05]

    @Test("無視印は往復し、⌘Z のために変更前の値を引ける [SS-05]")
    func ignoreMarkRoundTrips() async throws {
        let s = try await Setup.make()
        let id = try await s.add(inode: 1, path: "a.cbz", title: "作品タイトル1")

        #expect(try await s.f.files.seriesSuggestionIgnoredTitles(ids: [id]).isEmpty)
        try await s.f.files.updateSeriesSuggestionIgnored(set: [id: "作品タイトル1"], clear: [])
        #expect(try await s.f.files.seriesSuggestionIgnoredTitles(ids: [id]) == [id: "作品タイトル1"])
        #expect(try await s.candidates().first?.isIgnored == true)

        try await s.f.files.updateSeriesSuggestionIgnored(set: [:], clear: [id])
        #expect(try await s.f.files.seriesSuggestionIgnoredTitles(ids: [id]).isEmpty)
        #expect(try await s.candidates().first?.isIgnored == false)
    }

    @Test("タイトルが変われば無視は解ける [SS-05]")
    func renamingClearsTheIgnoreMark() async throws {
        let s = try await Setup.make()
        let id = try await s.add(inode: 1, path: "a.cbz", title: "作品タイトル1")
        try await s.f.files.updateSeriesSuggestionIgnored(set: [id: "作品タイトル1"], clear: [])
        #expect(try await s.candidates().first?.isIgnored == true)

        // 名前を直した＝「どのシリーズにも属さない」と決めた前提が消える。
        try await s.f.files.setFields(
            FileFieldEdit(title: "別の作品タイトル", seriesName: nil,
                          volume: .none, authorName: "著者値1"),
            id: id, protectedScopes: [])
        #expect(try await s.candidates().first?.isIgnored == false)
        // **記録そのものは残す**——名前を戻せば無視も戻る。
        #expect(try await s.f.files.seriesSuggestionIgnoredTitles(ids: [id]).count == 1)
    }

    // MARK: - 移行 [SS-05]

    @Test("v13 で無視印の列が増える")
    func migrationAddsTheColumn() async throws {
        let db = try QooDatabase.inMemory()
        let columns = try await db.writer.read { db in
            try db.columns(in: "managedFile").map(\.name)
        }
        #expect(columns.contains("seriesSuggestionIgnoredTitle"))
        #expect(QooMigrations.identifiers.contains("v13_seriesSuggestionIgnore"))
    }
}
