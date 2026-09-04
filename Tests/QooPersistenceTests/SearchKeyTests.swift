import Foundation
import GRDB
import QooKit
import Testing
@testable import QooPersistence

//
//  ライブラリ表示モードの検索がタイトル名・シリーズ名も対象にする [SR-03]。
//
//  `searchKey` の書き込み口は 4 つある（insert / `updateInPlace` /
//  `applyParsedFields` / `setFields`）。**そのうち 1 つでも取り残されると
//  「直したのに検索に出ない」という、画面からは理由の読み取れない形**になるので、
//  経路ごとに固定する。
//

@Suite("タイトル・シリーズ名での検索 [SR-03][SR-06]")
struct SearchKeyTests {

    private func fields(title: String?, series: String?) -> ParsedFileFields {
        ParsedFileFields(matchedFormatID: UUID(), title: title, seriesName: series,
                         volume: .none, authorName: nil, labelValues: [:],
                         spans: [])
    }

    private func count(_ f: Fixture, _ text: String) async throws -> Int {
        var q = FileQuery(libraryID: f.libraryID)
        q.searchText = text
        return try await f.files.query(q).totalCount
    }

    @Test("走査が入れたタイトル・シリーズ名で見つかる [SR-03]")
    func scanPutsTitleAndSeriesIntoTheKey() async throws {
        let f = try await Fixture.make()
        let id = try await f.files.upsert(f.snapshot(inode: 1, path: "AAA-0001.cbz"))
        try await f.files.applyParsedFields(
            fields(title: "作品名アルファ", series: "連載シリーズベータ"), to: id)

        #expect(try await count(f, "AAA") == 1, "ファイル名は従来どおり")
        #expect(try await count(f, "作品名アルファ") == 1, "タイトルでも当たる")
        #expect(try await count(f, "連載シリーズベータ") == 1, "シリーズ名でも当たる")
        #expect(try await count(f, "存在しない語") == 0)
    }

    @Test("手で直したタイトルはその場で検索に出る [SR-03][RP-10]")
    func manualEditUpdatesTheKeyImmediately() async throws {
        let f = try await Fixture.make()
        let id = try await f.files.upsert(f.snapshot(inode: 1, path: "BBB-0002.cbz"))
        #expect(try await count(f, "手で付けた題") == 0)

        try await f.files.setFields(FileFieldEdit(
            title: "手で付けた題", seriesName: "手で付けたシリーズ",
            volume: .none, authorName: nil), id: id, protectedScopes: [.basic])

        #expect(try await count(f, "手で付けた題") == 1)
        #expect(try await count(f, "手で付けたシリーズ") == 1)
        #expect(try await count(f, "BBB") == 1, "ファイル名を失っていない")
    }

    /// **手動タイトルは `applyParsedFields` で据え置かれる** [RP-11] ので、
    /// 鍵も据え置かれた側の値で作られていなければならない。
    /// 渡された `fields.title` から素朴に組み立てると、ここで手動の題が消える。
    @Test("再走査は保護されたタイトルを鍵から落とさない [PR-01][SR-03]")
    func rescanKeepsTheProtectedTitleInTheKey() async throws {
        let f = try await Fixture.make()
        let id = try await f.files.upsert(f.snapshot(inode: 1, path: "CCC-0003.cbz"))
        try await f.files.setFields(FileFieldEdit(
            title: "手動の題", seriesName: nil,
            volume: .none, authorName: nil), id: id, protectedScopes: [.basic])

        // 再走査。自動抽出は別の題を出すが、保護された題が勝つ [PR-01]。
        try await f.files.applyParsedFields(fields(title: "自動の題", series: nil), to: id)

        #expect(try await f.files.row(id: id)?.title == "手動の題")
        #expect(try await count(f, "手動の題") == 1, "据え置かれた題で鍵ができている")
        #expect(try await count(f, "自動の題") == 0)
    }

    @Test("一致しなくなったフォーマットは鍵からシリーズ名を落とす [SR-03]")
    func clearingParsedFieldsRebuildsTheKey() async throws {
        let f = try await Fixture.make()
        let id = try await f.files.upsert(f.snapshot(inode: 1, path: "DDD-0004.cbz"))
        try await f.files.applyParsedFields(fields(title: nil, series: "消えるシリーズ"), to: id)
        #expect(try await count(f, "消えるシリーズ") == 1)

        try await f.files.applyParsedFields(nil, to: id)

        #expect(try await count(f, "消えるシリーズ") == 0)
        #expect(try await count(f, "DDD") == 1, "ファイル名は残る")
    }

    /// **部品を空白で繋いではならない** [SR-03]。繋ぐと `normalize` の空白畳み込みで
    /// 1 つの文字列になり、ファイル名の末尾とタイトルの先頭にまたがる語が当たる。
    @Test("部品をまたいだ語では当たらない [SR-03]")
    func aTermSpanningTwoPartsDoesNotMatch() async throws {
        let f = try await Fixture.make()
        let id = try await f.files.upsert(f.snapshot(inode: 1, path: "ゼータ.cbz"))
        try await f.files.applyParsedFields(fields(title: "イータ", series: nil), to: id)

        #expect(try await count(f, "ゼータ") == 1)
        #expect(try await count(f, "イータ") == 1)
        #expect(try await count(f, "ゼータ イータ") == 0, "部品をまたいで当たってはいけない")
    }

    @Test("ファイル名を変えても鍵が追随する [ID-02][SR-03]")
    func renameFollowsThroughToTheKey() async throws {
        let f = try await Fixture.make()
        let id = try await f.files.upsert(f.snapshot(inode: 1, path: "旧名EEE.cbz"))
        try await f.files.applyParsedFields(fields(title: "変わらない題", series: nil), to: id)
        #expect(try await count(f, "旧名EEE") == 1)

        // 同じ inode のまま名前が変わった＝ `updateInPlace` の経路 [ID-02]。
        _ = try await f.files.upsert(f.snapshot(inode: 1, path: "新名FFF.cbz"))
        try await f.files.applyParsedFields(fields(title: "変わらない題", series: nil), to: id)

        #expect(try await count(f, "旧名EEE") == 0)
        #expect(try await count(f, "新名FFF") == 1)
        #expect(try await count(f, "変わらない題") == 1)
    }
}
