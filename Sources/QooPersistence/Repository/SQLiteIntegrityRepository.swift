//
//  整合性チェックの問い合わせ [RB-02][12章 §12.7]。
//
import Foundation
import GRDB
import QooKit

/// DB 側から見える不整合を数える [RB-02]。
///
/// **走査がやることはやらない**（`IntegrityReport` の doc）。ここは
/// **DB を読むだけで分かる食い違い**と、**DB の外にある実体との照合**のうち
/// 走査が見ないもの（ユーザー指定カバーの複製）だけを見る。
public struct SQLiteIntegrityRepository: Sendable {
    let writer: any DatabaseWriter

    public init(database: QooDatabase) { writer = database.writer }

    /// - Parameter userCoverExists: 複製の実体があるか。**判定を注入する**
    ///   ——置き場所を知っているのは `QooInfrastructure` の `UserCoverStore`
    ///   で、この層はそこへ依存できない [A-01]。
    public func check(
        userCoverExists: @Sendable (LibraryID, String) -> Bool
    ) async throws -> IntegrityReport {
        try await writer.read { db in
            var report = IntegrityReport()

            // ① ユーザー指定カバーの複製が失われている [CV-02][CV-06]。
            // **カーソルで回す**——`managedFile` は 10 万行を想定する [C-07]
            // ので、`fetchAll` は全行をいちどにメモリへ載せることになる。
            let coverRows = try Row.fetchCursor(db, sql: """
                SELECT id, libraryId, relativePath, coverImageRef
                  FROM managedFile
                 WHERE coverImageSource = 'userSpecified' AND coverImageRef IS NOT NULL
                """)
            while let row = try coverRows.next() {
                let ref: String = row["coverImageRef"]
                let library = LibraryID(rawValue: row["libraryId"] as Int64)
                guard !userCoverExists(library, ref) else { continue }
                report.brokenCoverRefs.append(IntegrityFinding(
                    id: "cover-\(row["id"] as Int64)",
                    subject: row["relativePath"],
                    detail: ref,
                    repair: .clearCoverReference))
            }

            // ② `isArchived` と相対パスの食い違い [FA-05][SY-10]。
            //
            // **判定は `VaultPath` に任せる**——「保管庫の中か」を SQL で
            // 書き直すと、規則が 2 通りになって食い違う（走査・移動・整理
            // ウインドウはどれも `VaultPath` を見ている）。
            let archiveRows = try Row.fetchCursor(db, sql: """
                SELECT id, relativePath, isArchived FROM managedFile
                """)
            while let row = try archiveRows.next() {
                let path: String = row["relativePath"]
                let flag: Bool = row["isArchived"]
                let actual = VaultPath.isInside(path)
                guard flag != actual else { continue }
                report.archiveMismatches.append(IntegrityFinding(
                    id: "archive-\(row["id"] as Int64)",
                    subject: path,
                    detail: actual ? "isArchived=false" : "isArchived=true",
                    repair: .matchArchiveFlagToPath(actual)))
            }

            // ③ 持ち主を失った保護文字列 [PT-08]。**外部キーで守れない**
            //    （`ownerKind` / `ownerID` の多相参照）ので、`foreign_key_check`
            //    にも映らない——だから明示的に数える。
            let tokenRows = try Row.fetchAll(db, sql: """
                SELECT t.id, t.pattern, t.ownerKind, t.ownerID
                  FROM protectedToken t
                 WHERE (t.ownerKind = 'library'
                        AND NOT EXISTS (SELECT 1 FROM library WHERE id = t.ownerID))
                    OR (t.ownerKind = 'temporary'
                        AND NOT EXISTS (SELECT 1 FROM temporaryFolder WHERE id = t.ownerID))
                """)
            for row in tokenRows {
                report.orphanedProtectedTokens.append(IntegrityFinding(
                    id: "token-\(row["id"] as Int64)",
                    subject: row["pattern"],
                    detail: "\(row["ownerKind"] as String)#\(row["ownerID"] as Int64)",
                    repair: .deleteProtectedToken))
            }

            // ④ 外部キー制約 [RB-02]。**普通は空**——空でなければ制約を
            //    切ったまま書いた経路があるか、ストアが壊れている。
            //    **直し方は出さない**——何が正しい状態かをアプリが決められない
            //    [12章 §12.7: 誤った一括修復でラベルを失うリスクを避ける]。
            for row in try Row.fetchAll(db, sql: "PRAGMA foreign_key_check") {
                let table: String = row[0]
                let rowid: Int64? = row[1]
                report.foreignKeyViolations.append(IntegrityFinding(
                    id: "fk-\(table)-\(rowid ?? 0)",
                    subject: table,
                    detail: "rowid \(rowid.map(String.init) ?? "?")"))
            }
            return report
        }
    }

    /// 選ばれた項目だけを直す [12章 §12.7: 自動修復はしない]。
    ///
    /// **1 トランザクション**——途中で失敗したときに半端な状態を残さない。
    /// - Returns: 実際に直した件数。
    @discardableResult
    public func repair(_ findings: [IntegrityFinding]) async throws -> Int {
        try await writer.write { db in
            var repaired = 0
            for finding in findings {
                guard let repair = finding.repair else { continue }
                let id = Int64(finding.id.split(separator: "-").last.map(String.init) ?? "") ?? 0
                switch repair {
                case .clearCoverReference:
                    try db.execute(sql: """
                        UPDATE managedFile
                           SET coverImageRef = NULL, coverImageSource = 'auto'
                         WHERE id = ?
                        """, arguments: [id])
                case .matchArchiveFlagToPath(let value):
                    try db.execute(sql: "UPDATE managedFile SET isArchived = ? WHERE id = ?",
                                   arguments: [value, id])
                case .deleteProtectedToken:
                    try db.execute(sql: "DELETE FROM protectedToken WHERE id = ?", arguments: [id])
                }
                repaired += 1
            }
            return repaired
        }
    }
}
