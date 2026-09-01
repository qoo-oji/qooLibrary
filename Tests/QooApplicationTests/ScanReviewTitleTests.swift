import Testing
@testable import QooApplication

//
//  走査結果の題の出し分け [ID-06][AL-31][IF-05][EM-30]。
//
//  **1 種類しか見つからなかったときは名指しする**［ユーザー指摘、2026-09-02］。
//  以前は種類に関わらず 1 つの題（「確認したい点があります」）だったため、
//  本文を読むまで何が起きたのか分からなかった。
//

@Suite("走査結果の題 [UR2-02][ID-06]")
struct ScanReviewTitleTests {

    @Test("何も見つからなければ題は無い")
    func nothingFound() {
        #expect(ScanReviewTitle.subject(orphaned: 0, unresolved: 0,
                                        bookFoldersReleased: 0, volumeConflicts: 0) == nil)
    }

    @Test("1 種類だけなら、それを名指しする")
    func singleKindIsNamed() {
        #expect(ScanReviewTitle.subject(orphaned: 0, unresolved: 3,
                                        bookFoldersReleased: 0, volumeConflicts: 0) == .unresolved)
        #expect(ScanReviewTitle.subject(orphaned: 2, unresolved: 0,
                                        bookFoldersReleased: 0, volumeConflicts: 0) == .orphaned)
        #expect(ScanReviewTitle.subject(orphaned: 0, unresolved: 0,
                                        bookFoldersReleased: 1, volumeConflicts: 0)
                == .bookFoldersReleased)
        #expect(ScanReviewTitle.subject(orphaned: 0, unresolved: 0,
                                        bookFoldersReleased: 0, volumeConflicts: 5)
                == .volumeConflicts)
    }

    /// **1 つを名指しすると、残りが題から抜け落ちて「起きていない」と読める。**
    @Test("2 種類以上なら中立な題にする")
    func multipleKindsAreNeutral() {
        #expect(ScanReviewTitle.subject(orphaned: 1, unresolved: 1,
                                        bookFoldersReleased: 0, volumeConflicts: 0) == .mixed)
        #expect(ScanReviewTitle.subject(orphaned: 1, unresolved: 1,
                                        bookFoldersReleased: 1, volumeConflicts: 1) == .mixed)
    }
}
