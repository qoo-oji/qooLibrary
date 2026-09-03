//
//  シェルフの JSON 入出力 [SH-12][MG-22][JS-04]。
//
//  **ラベルは行 ID ではなく `groupIndex` + 名前で往復する**——行 ID は環境依存
//  なので、別のマシンで取り込むと無関係なラベルを指す。
//
import Testing
import Foundation
import GRDB
import QooKit
@testable import QooPersistence

@Suite("シェルフのバックアップ [SH-12][MG-22]")
struct ShelfBackupTests {
    struct Setup {
        let f: Fixture
        let backup: SQLiteBackupRepository
        let shelves: SQLiteShelfRepository
        let circleGroup: FieldSummary
        let labelA: LabelID
        let labelB: LabelID

        static func make() async throws -> Setup {
            let f = try await Fixture.make(preset: "builtin.doujinshi-a")
            let fields = try await f.labels.fields(libraryID: f.libraryID)
            let circle = try #require(fields.first { $0.name == "サークル" })
            return Setup(f: f,
                         backup: SQLiteBackupRepository(database: f.database),
                         shelves: SQLiteShelfRepository(database: f.database),
                         circleGroup: circle,
                         labelA: try await f.labels.ensureLabel(fieldID: circle.id, name: "サークル値A"),
                         labelB: try await f.labels.ensureLabel(fieldID: circle.id, name: "サークル値B"))
        }
    }

    @Test("ラベルは groupIndex + 名前で書き出す [JS-04]——行 ID を書かない")
    func exportsLabelsByNameNotRowID() async throws {
        let s = try await Setup.make()
        _ = try await s.shelves.create(
            libraryID: s.f.libraryID, name: "お気に入りサークル",
            condition: ShelfCondition(labelIDs: [s.labelA, s.labelB],
                                      rating: .init(stars: 4, mode: .atLeast),
                                      searchText: "作品",
                                      sort: .init(key: .title, ascending: false)))

        let document = try await s.backup.export(scope: .everything, appVersion: nil)
        let shelves = try #require(document.libraries.first?.shelves)
        #expect(shelves.count == 1)
        #expect(shelves[0].name == "お気に入りサークル")
        #expect(shelves[0].labels.map(\.labelName).sorted() == ["サークル値A", "サークル値B"])
        #expect(shelves[0].labels.allSatisfy { $0.groupIndex == s.circleGroup.index })
        #expect(shelves[0].ratingStars == 4)
        #expect(shelves[0].ratingMode == "atLeast")
        #expect(shelves[0].searchText == "作品")
        #expect(shelves[0].sortKey == "title")
        #expect(shelves[0].sortAscending == false)

        // 行 ID がどこにも現れないこと（環境依存の値を持ち出さない）。
        let json = String(decoding: try BackupCoding.encode(document), as: UTF8.self)
        #expect(!json.contains("\"labelIDs\""))
    }

    @Test("消しても取り込みで戻る——条件ごと復元される [SH-12][MG-22]")
    func roundTripRestoresShelves() async throws {
        let s = try await Setup.make()
        let original = ShelfCondition(labelIDs: [s.labelA],
                                      rating: .init(stars: 2, mode: .exact),
                                      searchText: "語",
                                      sort: .init(key: .rating, ascending: true))
        _ = try await s.shelves.create(libraryID: s.f.libraryID, name: "復元する",
                                       condition: original)
        let document = try await s.backup.export(scope: .everything, appVersion: nil)

        try await s.shelves.delete(try await s.shelves.shelves(libraryID: s.f.libraryID).map(\.id))
        #expect(try await s.shelves.shelves(libraryID: s.f.libraryID).isEmpty)

        _ = try await s.backup.import(document)

        let restored = try #require(try await s.shelves.shelves(libraryID: s.f.libraryID).first)
        #expect(restored.name == "復元する")
        #expect(restored.condition == original, "ラベル・評価・検索語・並び順が往復すること")
    }

    @Test("同じ名前のシェルフは重ねる——取り込みで二重にしない [JS-06]")
    func importMergesByName() async throws {
        let s = try await Setup.make()
        _ = try await s.shelves.create(libraryID: s.f.libraryID, name: "重ねる",
                                       condition: ShelfCondition(labelIDs: [s.labelA]))
        let document = try await s.backup.export(scope: .everything, appVersion: nil)
        _ = try await s.backup.import(document)
        _ = try await s.backup.import(document)

        #expect(try await s.shelves.shelves(libraryID: s.f.libraryID).count == 1)
    }

    @Test("文書に無いシェルフは消さない——復旧のつもりで別の絞り込みを失わせない")
    func importDoesNotDeleteOtherShelves() async throws {
        let s = try await Setup.make()
        _ = try await s.shelves.create(libraryID: s.f.libraryID, name: "文書に載る",
                                       condition: ShelfCondition(labelIDs: [s.labelA]))
        let document = try await s.backup.export(scope: .everything, appVersion: nil)
        _ = try await s.shelves.create(libraryID: s.f.libraryID, name: "あとで作った",
                                       condition: ShelfCondition(labelIDs: [s.labelB]))

        _ = try await s.backup.import(document)

        #expect(try await s.shelves.shelves(libraryID: s.f.libraryID).map(\.name).sorted()
                == ["あとで作った", "文書に載る"])
    }

    @Test("この環境に無いラベルの参照は落とす [SH-12]")
    func importDropsUnknownLabelReferences() async throws {
        let s = try await Setup.make()
        _ = try await s.shelves.create(libraryID: s.f.libraryID, name: "X",
                                       condition: ShelfCondition(labelIDs: [s.labelA]))
        var document = try await s.backup.export(scope: .everything, appVersion: nil)
        document.libraries[0].shelves?[0].labels
            .append(ShelfLabelBackup(groupIndex: s.circleGroup.index, labelName: "この環境に無い値"))
        // 参照だけ足し、ラベルそのものは文書から消しておく。
        document.libraries[0].labelGroups = document.libraries[0].labelGroups.map { field in
            var copy = field
            copy.labels.removeAll { $0.name == "この環境に無い値" }
            return copy
        }

        _ = try await s.backup.import(document)

        let restored = try #require(try await s.shelves.shelves(libraryID: s.f.libraryID).first)
        #expect(restored.condition.labelIDs == [s.labelA])
    }

    @Test("`shelves` を持たない古い文書もそのまま読める [IE-14]")
    func decodesDocumentsWrittenBeforeShelvesExisted() async throws {
        let s = try await Setup.make()
        _ = try await s.shelves.create(libraryID: s.f.libraryID, name: "既にある",
                                       condition: ShelfCondition(labelIDs: [s.labelA]))
        let document = try await s.backup.export(scope: .everything, appVersion: nil)
        var json = try #require(try JSONSerialization.jsonObject(
            with: BackupCoding.encode(document)) as? [String: Any])
        var libraries = try #require(json["libraries"] as? [[String: Any]])
        libraries[0].removeValue(forKey: "shelves")
        json["libraries"] = libraries

        let decoded = try BackupCoding.decode(try JSONSerialization.data(withJSONObject: json))
        #expect(decoded.libraries[0].shelves == nil)

        _ = try await s.backup.import(decoded)
        // 取り込みは何もしない——既にあるシェルフを消さない。
        #expect(try await s.shelves.shelves(libraryID: s.f.libraryID).map(\.name) == ["既にある"])
    }

    @Test("読めない列挙の生値は既定へ落とす——文書全体を失わせない")
    func unknownRawValuesFallBackToDefaults() async throws {
        let s = try await Setup.make()
        _ = try await s.shelves.create(libraryID: s.f.libraryID, name: "X",
                                       condition: ShelfCondition(labelIDs: [s.labelA]))
        var document = try await s.backup.export(scope: .everything, appVersion: nil)
        document.libraries[0].shelves?[0].sortKey = "未知のキー"
        document.libraries[0].shelves?[0].displayMode = "未知のモード"
        document.libraries[0].shelves?[0].ratingMode = "未知のモード"
        document.libraries[0].shelves?[0].ratingStars = 3

        _ = try await s.backup.import(document)

        let restored = try #require(try await s.shelves.shelves(libraryID: s.f.libraryID).first)
        #expect(restored.condition.sort == .byFilename)
        #expect(restored.condition.displayMode == .libraryFlat)
        #expect(restored.condition.rating == .init(stars: 3, mode: .atLeast))
    }
}

// MARK: - 同名のシェルフ [SH-03]

extension ShelfBackupTests {
    /// **SH-03 は同名を許す**ので、取り込みは「その名前の最初の行」を毎回
    /// 選んではならない——2 件目が 1 件目を上書きし、条件が静かに失われる
    /// ［code-review の指摘］。
    @Test("同名のシェルフが 2 つあっても、条件を失わずに往復する [SH-03][SH-12]")
    func roundTripKeepsBothShelvesWithTheSameName() async throws {
        let s = try await Setup.make()
        let first = ShelfCondition(labelIDs: [s.labelA])
        let second = ShelfCondition(labelIDs: [s.labelB], rating: .init(stars: 5))
        _ = try await s.shelves.create(libraryID: s.f.libraryID, name: "同じ名前",
                                       condition: first)
        _ = try await s.shelves.create(libraryID: s.f.libraryID, name: "同じ名前",
                                       condition: second)
        let document = try await s.backup.export(scope: .everything, appVersion: nil)

        _ = try await s.backup.import(document)

        let list = try await s.shelves.shelves(libraryID: s.f.libraryID)
        #expect(list.count == 2)
        #expect(list.map(\.condition) == [first, second],
                "同名でも、それぞれの条件がそのまま残ること")
    }
}
