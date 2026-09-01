//
//  ShelfRepository の SQLite 実装 [SH-01〜SH-11]。
//
//  **削除の Undo が同じ行 ID へ戻せること**がこの一連の要（ラベルの削除・統合と
//  同じ）——別 ID で作り直すと、シェルフを指していた選択や照合が黙って外れる。
//
import Testing
import Foundation
import GRDB
import QooKit
@testable import QooPersistence

@Suite("シェルフ [SH-01〜SH-11]")
struct ShelfRepositoryTests {
    struct Setup {
        let f: Fixture
        let shelves: SQLiteShelfRepository

        static func make() async throws -> Setup {
            let f = try await Fixture.make()
            return Setup(f: f, shelves: SQLiteShelfRepository(database: f.database))
        }
    }

    private func condition(_ ids: [Int64], stars: Int? = nil,
                           search: String? = nil) -> ShelfCondition {
        ShelfCondition(labelIDs: ids.map { LabelID(rawValue: $0) },
                       rating: stars.map { FileQuery.RatingFilter(stars: $0) },
                       searchText: search)
    }

    @Test("保存すると末尾へ並ぶ [SH-01][SH-10]")
    func createAppendsInOrder() async throws {
        let s = try await Setup.make()
        _ = try await s.shelves.create(libraryID: s.f.libraryID, name: "未読",
                                       condition: condition([1]))
        _ = try await s.shelves.create(libraryID: s.f.libraryID, name: "お気に入り",
                                       condition: condition([], stars: 4))

        let list = try await s.shelves.shelves(libraryID: s.f.libraryID)
        #expect(list.map(\.name) == ["未読", "お気に入り"])
        #expect(list.map(\.displayOrder) == [0, 1])
        #expect(list[1].condition.rating?.stars == 4)
    }

    @Test("条件がそのまま往復する [SH-02]")
    func conditionRoundTrips() async throws {
        let s = try await Setup.make()
        let original = ShelfCondition(
            labelIDs: [LabelID(rawValue: 7), LabelID(rawValue: 2)],
            rating: .init(stars: 3, mode: .exact), searchText: "作品",
            sort: .init(key: .volume, ascending: false), displayMode: .libraryFlat)
        _ = try await s.shelves.create(libraryID: s.f.libraryID, name: "X", condition: original)

        let stored = try #require(try await s.shelves.shelves(libraryID: s.f.libraryID).first)
        #expect(stored.condition == original)
    }

    @Test("上書き保存は条件だけを差し替える [SH-04]")
    func updateKeepsNameAndOrder() async throws {
        let s = try await Setup.make()
        _ = try await s.shelves.create(libraryID: s.f.libraryID, name: "先", condition: condition([1]))
        let id = try await s.shelves.create(libraryID: s.f.libraryID, name: "後",
                                            condition: condition([2]))

        try await s.shelves.updateCondition(id, condition([3, 4], stars: 5))

        let list = try await s.shelves.shelves(libraryID: s.f.libraryID)
        let target = try #require(list.first { $0.id == id })
        #expect(target.name == "後")
        #expect(target.displayOrder == 1)
        #expect(target.condition.labelIDs.map(\.rawValue) == [3, 4])
        #expect(target.condition.rating?.stars == 5)
    }

    @Test("改名しても同名を拒まない [SH-03]——自分自身との衝突判定を持たない")
    func renameAllowsDuplicateNames() async throws {
        let s = try await Setup.make()
        let a = try await s.shelves.create(libraryID: s.f.libraryID, name: "A",
                                           condition: condition([1]))
        _ = try await s.shelves.create(libraryID: s.f.libraryID, name: "B", condition: condition([2]))

        try await s.shelves.rename(a, to: "B")          // 既にある名前
        try await s.shelves.rename(a, to: "B")          // 自分自身と同じ名前

        #expect(try await s.shelves.shelves(libraryID: s.f.libraryID).map(\.name) == ["B", "B"])
    }

    @Test("並べ替えは渡された順に 0 から振り直す [SH-10]")
    func setOrderRenumbers() async throws {
        let s = try await Setup.make()
        var ids: [ShelfID] = []
        for name in ["1", "2", "3"] {
            ids.append(try await s.shelves.create(libraryID: s.f.libraryID, name: name,
                                                  condition: condition([1])))
        }
        try await s.shelves.setOrder([ids[2], ids[0], ids[1]])
        #expect(try await s.shelves.shelves(libraryID: s.f.libraryID).map(\.name) == ["3", "1", "2"])
    }

    // MARK: - Undo [SH-11]

    @Test("削除を同じ行 ID で戻せる [SH-11]")
    func restoreKeepsRowID() async throws {
        let s = try await Setup.make()
        let id = try await s.shelves.create(libraryID: s.f.libraryID, name: "戻す",
                                            condition: condition([5], stars: 2, search: "語"))
        let snapshot = try await s.shelves.snapshot(ids: [id])
        #expect(snapshot.count == 1)

        try await s.shelves.delete([id])
        #expect(try await s.shelves.shelves(libraryID: s.f.libraryID).isEmpty)

        try await s.shelves.restore(snapshot)
        let restored = try #require(try await s.shelves.shelves(libraryID: s.f.libraryID).first)
        #expect(restored.id == id, "別 ID で作り直すと、シェルフの同一性が取り消しの前後で切れる")
        #expect(restored.name == "戻す")
        #expect(restored.condition == snapshot[0].condition)
        #expect(restored.displayOrder == snapshot[0].displayOrder)
    }

    @Test("存在しない ID の写しは黙って飛ばす")
    func snapshotIgnoresMissingIDs() async throws {
        let s = try await Setup.make()
        let id = try await s.shelves.create(libraryID: s.f.libraryID, name: "A",
                                            condition: condition([1]))
        #expect(try await s.shelves.snapshot(ids: [id, ShelfID(rawValue: 9999)]).count == 1)
    }

    // MARK: - 壊れた行・連鎖削除

    @Test("読めない条件でも行は消さない——名前が見えれば片付けられる")
    func brokenConditionFallsBackToEmpty() async throws {
        let s = try await Setup.make()
        _ = try await s.shelves.create(libraryID: s.f.libraryID, name: "壊れ",
                                       condition: condition([1]))
        try await s.f.database.writer.write { db in
            try db.execute(sql: "UPDATE shelf SET conditionJSON = ?", arguments: ["{ではない"])
        }
        let list = try await s.shelves.shelves(libraryID: s.f.libraryID)
        #expect(list.count == 1)
        #expect(list[0].name == "壊れ")
        #expect(!list[0].condition.isActive)
    }

    @Test("ライブラリを消すと連鎖で消える——孤児を残さない [PT-08 の轍]")
    func cascadesWithLibrary() async throws {
        let s = try await Setup.make()
        _ = try await s.shelves.create(libraryID: s.f.libraryID, name: "A", condition: condition([1]))
        try await s.f.libraries.unregister(id: s.f.libraryID, keepLabels: false)

        let remaining = try await s.f.database.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM shelf") ?? -1
        }
        #expect(remaining == 0)
        // 外部キー検査でも整合が取れていること。
        let violations = try await s.f.database.writer.read { db in
            try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").count
        }
        #expect(violations == 0)
    }
}
