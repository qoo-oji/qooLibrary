import Foundation
import QooKit
import Testing
@testable import QooApplication

//
//  同一性の確認 — 一覧の組み立て [ID-05][ID-09〜ID-12]。
//
//  区画分け・既定の選択・承認と却下の振り分けは**純粋関数**なので、DB を
//  開かずに固定できる（`LabelVaultSectionTests` と同じ分け方）。
//

@Suite("同一性の確認の一覧 [ID-09][ID-10]")
struct IdentityDecisionSectionTests {

    private func orphan(_ path: String, id: Int64, labels: Int = 0, size: Int64 = 100,
                        candidates: [OrphanCandidate] = []) -> OrphanedFile {
        OrphanedFile(
            row: FileRow(id: FileID(rawValue: id), libraryID: LibraryID(rawValue: 1),
                         relativePath: path, filename: (path as NSString).lastPathComponent,
                         fileSize: size,
                         createdAt: Date(timeIntervalSinceReferenceDate: 0),
                         modifiedAt: Date(timeIntervalSinceReferenceDate: 0),
                         title: nil, seriesName: nil, volume: .none, rating: 0,
                         state: .orphaned, isArchived: false, isBookFolder: false),
            labelCount: labels, candidates: candidates)
    }

    private func candidate(_ path: String, id: Int64, samePath: Bool,
                           size: Int64 = 200) -> OrphanCandidate {
        OrphanCandidate(fileID: FileID(rawValue: id), relativePath: path,
                        filename: (path as NSString).lastPathComponent,
                        fileSize: size, samePath: samePath, sizeMatches: false)
    }

    /// **確信度がまったく違うものを混ぜない** [ID-09]。同じ場所の差し替えは
    /// ほぼ確実だが、別の場所の同名ファイルは別作品かもしれない。
    @Test("同じ場所と別の場所を区画で分け、同じ場所を先に置く [ID-09]")
    func splitsIntoSectionsWithSamePathFirst() {
        let sections = IdentityDecision.sections(from: [
            orphan("B/第01巻.cbz", id: 2,
                   candidates: [candidate("別/第01巻.cbz", id: 20, samePath: false)]),
            orphan("A/第01巻.cbz", id: 1,
                   candidates: [candidate("A/第01巻.cbz", id: 10, samePath: true)]),
        ])
        #expect(sections.map(\.kind) == [.samePath, .elsewhere])
        #expect(sections[0].rows.map(\.id) == [FileID(rawValue: 1)])
        #expect(sections[1].rows.map(\.id) == [FileID(rawValue: 2)])
    }

    @Test("候補を持たない行は出さない")
    func dropsRowsWithoutCandidates() {
        let sections = IdentityDecision.sections(from: [orphan("A/消えた.cbz", id: 1)])
        #expect(sections.isEmpty)
    }

    /// **先頭だけを出す。** この画面は二択（同じものか別物か）に絞る。
    @Test("候補が複数あっても最有力の 1 件だけを出す")
    func usesOnlyTheBestCandidate() {
        let sections = IdentityDecision.sections(from: [
            orphan("A/本.cbz", id: 1, candidates: [
                candidate("A/本.cbz", id: 10, samePath: true),
                candidate("別/本.cbz", id: 11, samePath: false),
            ]),
        ])
        #expect(sections.count == 1)
        #expect(sections[0].rows.count == 1)
        #expect(sections[0].rows[0].candidate.fileID == FileID(rawValue: 10))
    }

    /// 順序が実行ごとに変われば、既定でチェックが入る先も毎回変わって見える。
    @Test("区画の中は元のパス順で安定する")
    func rowsAreOrderedByPath() {
        let sections = IdentityDecision.sections(from: [
            orphan("Z/本.cbz", id: 3, candidates: [candidate("Z/本.cbz", id: 30, samePath: true)]),
            orphan("A/本.cbz", id: 1, candidates: [candidate("A/本.cbz", id: 10, samePath: true)]),
        ])
        #expect(sections[0].rows.map(\.file.row.relativePath) == ["A/本.cbz", "Z/本.cbz"])
    }

    /// **差し替えは日常的に起こる**ので、通常は「適用」を押すだけで済ませる
    /// ［ユーザー判断］。危険なものは区画で分けて見せることで補う [ID-09]。
    @Test("既定ではすべてにチェックが入る [ID-10]")
    func defaultsToEverythingSelected() {
        let sections = IdentityDecision.sections(from: [
            orphan("A/本.cbz", id: 1, candidates: [candidate("A/本.cbz", id: 10, samePath: true)]),
            orphan("B/本.cbz", id: 2, candidates: [candidate("別/本.cbz", id: 20, samePath: false)]),
        ])
        #expect(IdentityDecision.defaultSelection(sections)
                == [FileID(rawValue: 1), FileID(rawValue: 2)])
    }

    /// **チェックを外す＝別物と判断する** [ID-11]。「今は決めない」は
    /// キャンセル（何も起きない）で表す。
    @Test("チェックを外したものは却下側へ回る [ID-11]")
    func unselectedRowsBecomeRejections() {
        let sections = IdentityDecision.sections(from: [
            orphan("A/本.cbz", id: 1, candidates: [candidate("A/本.cbz", id: 10, samePath: true)]),
            orphan("B/本.cbz", id: 2, candidates: [candidate("別/本.cbz", id: 20, samePath: false)]),
        ])
        let (accepted, rejected) = IdentityDecision.split(sections,
                                                          selected: [FileID(rawValue: 1)])
        #expect(accepted.map(\.orphanID) == [FileID(rawValue: 1)])
        #expect(accepted.map(\.candidateID) == [FileID(rawValue: 10)])
        #expect(rejected.map(\.orphanID) == [FileID(rawValue: 2)])
    }

    @Test("何も選ばなければ全部が却下になる")
    func selectingNothingRejectsEverything() {
        let sections = IdentityDecision.sections(from: [
            orphan("A/本.cbz", id: 1, candidates: [candidate("A/本.cbz", id: 10, samePath: true)]),
        ])
        let (accepted, rejected) = IdentityDecision.split(sections, selected: [])
        #expect(accepted.isEmpty)
        #expect(rejected.count == 1)
    }
}
