import Foundation
import GRDB
import QooKit
import Testing
@testable import QooPersistence

//
//  右ペインからの書き込み [RP-10〜RP-12][CV-02〜CV-08]。
//
//  上位（`TitleAndCoverTests`）はモデル経由の振る舞いを試す。ここはリポジトリ
//  自身が守る**不変条件**——上位が正しく呼んでいる限り表からは見えないが、
//  崩れると掃除や照合が静かに壊れるもの——を直に固定する。
//

@Suite("カバーとタイトルの書き込み [RP-10〜RP-12][CV-06]")
struct CoverAndTitleRepositoryTests {

    @Test("タイトルと保護を書ける [RP-10][PR-03]")
    func writesTitleAndProtection() async throws {
        let f = try await Fixture.make()
        let id = try await f.files.upsert(f.snapshot(inode: 1, path: "作品.cbz"))
        try await f.files.setFields(FileFieldEdit(
            title: "手で付けた題", seriesName: "作品",
            volume: .numeric(1, raw: "第01巻"), authorName: "著者"),
            id: id, protectedScopes: [.basic])
        let row = try #require(try await f.files.row(id: id))
        #expect(row.title == "手で付けた題")
        #expect(row.protectedScopes == [.basic], "値と保護は同じ書き込みで入る")
        #expect(row.authorName == "著者")
        #expect(row.volume == .numeric(1, raw: "第01巻"))
    }

    /// **保護されていれば `applyParsedFields` は基本情報 4 つとも据え置く**
    /// [PR-01][PR-02]。置き換える前はタイトルだけを守っており、手で直した
    /// シリーズ名は次の走査で黙って自動値へ戻っていた。
    @Test("保護された基本情報は走査で上書きされない [PR-01]")
    func protectedBasicFieldsAreNotOverwritten() async throws {
        let f = try await Fixture.make()
        let id = try await f.files.upsert(f.snapshot(inode: 1, path: "作品.cbz"))
        try await f.files.setFields(FileFieldEdit(
            title: "手の題", seriesName: "手のシリーズ",
            volume: .numeric(9, raw: "第09巻"), authorName: "手の著者"),
            id: id, protectedScopes: [.basic])

        try await f.files.applyParsedFields(
            ParsedFileFields(matchedFormatID: UUID(), title: "自動の題",
                             seriesName: "自動のシリーズ",
                             volume: .numeric(1, raw: "第01巻"), authorName: "自動の著者",
                             labelValues: [:], spans: []),
            to: id)

        let row = try #require(try await f.files.row(id: id))
        #expect(row.title == "手の題")
        #expect(row.seriesName == "手のシリーズ")
        #expect(row.volume.number == 9)
        #expect(row.authorName == "手の著者")
    }

    /// **走査の観測結果は保護されていても更新する** [PR-01 の注記]。止めると、
    /// 未整理一覧 [UR3-01] の判定が保護済みのファイルだけ古いまま凍る。
    @Test("保護されていても、当たったフォーマットの記録は更新される")
    func protectionDoesNotFreezeTheParsedFormat() async throws {
        let f = try await Fixture.make()
        let id = try await f.files.upsert(f.snapshot(inode: 1, path: "作品.cbz"))
        try await f.files.setFields(FileFieldEdit(title: "手の題", seriesName: nil,
                                                  volume: .none, authorName: nil),
                                    id: id, protectedScopes: [.basic])
        let formatID = UUID()
        try await f.files.applyParsedFields(
            ParsedFileFields(matchedFormatID: formatID, title: "自動", seriesName: nil,
                             volume: .none, authorName: nil, labelValues: [:],
                             spans: []),
            to: id)
        let stored = try await f.database.writer.read { db in
            try Row.fetchOne(db, sql: """
                SELECT lastParsedFormatID FROM managedFile WHERE id = ?
                """, arguments: [id.rawValue])
        }
        #expect(stored?["lastParsedFormatID"] == formatID.uuidString)
    }

    /// **`.userSpecified` 以外では参照を消す。**
    ///
    /// 上位（`CoverEditorModel.revert()`）は常に `ref` が `nil` の割り当てを
    /// 渡すので、この不変条件は普段は表に出ない——**だから直に試す**
    /// （変異検証で、上位経由のテストだけでは空振りすると分かった）。
    /// 残ると「自動に戻したのに複製が参照されたまま」になり、起動時の掃除
    /// [CV-06] がその複製を永久に捨てられない。
    @Test("自動へ戻すときは参照を消す [CV-07]")
    func revertingClearsTheReferenceEvenIfOneIsPassed() async throws {
        let f = try await Fixture.make()
        let id = try await f.files.upsert(f.snapshot(inode: 1, path: "作品.cbz"))
        try await f.files.setCover(.userSpecified(ref: "cover.png"), id: id)
        #expect(try await f.files.row(id: id)?.coverImageRef == "cover.png")

        try await f.files.setCover(CoverAssignment(source: .auto, ref: "残ってはいけない"), id: id)
        let row = try #require(try await f.files.row(id: id))
        #expect(row.coverImageSource == .auto)
        #expect(row.coverImageRef == nil)
    }

    /// 起動時の掃除 [CV-06] の入力。**ユーザー指定のものだけ**を返さないと、
    /// 参照されていない複製をいつまでも捨てられない。
    @Test("参照一覧はユーザー指定のものだけを返す [CV-06]")
    func userCoverRefsListsOnlyUserSpecified() async throws {
        let f = try await Fixture.make()
        let user = try await f.files.upsert(f.snapshot(inode: 1, path: "指定あり.cbz"))
        let auto = try await f.files.upsert(f.snapshot(inode: 2, path: "自動.cbz"))
        try await f.files.setCover(.userSpecified(ref: "a.png"), id: user)
        try await f.files.setCover(.automatic, id: auto)
        #expect(try await f.files.userCoverRefs(libraryID: f.libraryID) == ["a.png"])
    }

    /// **走査は `coverImageSource`/`coverImageRef` に触れない**（`updateInPlace`
    /// の SQL に列が無い）。触ると差し替えたカバーが再スキャンで消える。
    @Test("再スキャンはカバーの指定を消さない [CV-02]")
    func rescanKeepsTheCover() async throws {
        let f = try await Fixture.make()
        let snapshot = f.snapshot(inode: 1, path: "作品.cbz")
        let id = try await f.files.upsert(snapshot)
        try await f.files.setCover(.userSpecified(ref: "a.png"), id: id)
        _ = try await f.files.upsert(snapshot)          // 2 回目の走査
        let row = try #require(try await f.files.row(id: id))
        #expect(row.coverImageSource == .userSpecified)
        #expect(row.coverImageRef == "a.png")
    }
}
