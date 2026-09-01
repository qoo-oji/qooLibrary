//
//  走査結果を知らせるときの「題」を、何が見つかったかで決める [ID-06][AL-31][IF-05][EM-30]。
//
//  **`qooLibraryApp` ではなく `QooApplication` に置く**——アプリターゲットの
//  コードは `swift test` から触れないため、この出し分けを自動テストで固定
//  できなくなる（`ScanFindingsDigest` と同じ理由）。文字列そのものは持たず、
//  「どの題か」だけを答える。
//
import Foundation

/// 走査結果の題が指すもの。
///
/// **1 種類しか見つからなかったときは、それを名指しする**［ユーザー指摘、
/// 2026-09-02］。以前は種類に関わらず「確認したい点があります」という 1 つの
/// 題を出していたが、**何が起きたのかが題から読み取れない**——本文を読むまで
/// 「未整理なのか、実体が消えたのか」すら分からなかった。
///
/// **2 種類以上あるときだけ中立な題にする。** そこで 1 つを名指しすると、
/// 残りが題から抜け落ちて「そのことは起きていない」と読める。
public enum ScanReviewSubject: Sendable, Equatable, CaseIterable {
    /// どのフォーマットにも一致しなかった [AL-31]。
    case unresolved
    /// 記録はあるが実体が見つからない [ID-06]。
    case orphaned
    /// 1 冊としての扱いをやめた [IF-05]。
    case bookFoldersReleased
    /// 巻数が食い違っていて判断が要る [EM-26][EM-30]。
    case volumeConflicts
    /// 2 種類以上。
    case mixed
}

public enum ScanReviewTitle {

    /// 見つかったものから題を決める。`nil` = 知らせることが何も無い。
    public static func subject(orphaned: Int, unresolved: Int,
                               bookFoldersReleased: Int,
                               volumeConflicts: Int) -> ScanReviewSubject? {
        var found: [ScanReviewSubject] = []
        if unresolved > 0 { found.append(.unresolved) }
        if orphaned > 0 { found.append(.orphaned) }
        if bookFoldersReleased > 0 { found.append(.bookFoldersReleased) }
        if volumeConflicts > 0 { found.append(.volumeConflicts) }
        guard let only = found.first else { return nil }
        return found.count == 1 ? only : .mixed
    }
}
