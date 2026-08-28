//
//  重複グループの読み書き [DU-05][DU-20]。
//
import Foundation
import GRDB
import QooKit

extension SQLiteManagedFileRepository {

    /// 比較ビュー [DU-20] のための、同じ組の全メンバー。
    ///
    /// **並びは `DuplicateSelection` が決める**——SQL では畳んだ 1 行しか
    /// 返さないので、ここでは素の行を返して呼び出し側（純粋関数）に並べさせる。
    /// 規則の実装を 2 つに増やさないため。
    public func duplicateGroupMembers(containing id: FileID,
                                      mode: DuplicateGrouping) async throws -> [FileRow] {
        try await database.writer.read { db in
            guard let ids = try Self.groupMemberIDs(db, containing: id, mode: mode),
                  !ids.isEmpty else {
                // グループ化していない、またはタイトルが無い＝組を作らない。
                return try ManagedFileRecord.fetchOne(db, key: id.rawValue).map { [$0.fileRow] } ?? []
            }
            let rows = try ManagedFileRecord.fetchAll(db, sql: """
                SELECT * FROM managedFile WHERE id IN (\(Self.placeholders(ids.count)))
                """, arguments: StatementArguments(ids.map(\.rawValue)))
            return DuplicateSelection.inRepresentativeOrder(rows.map(\.fileRow))
        }
    }

    /// 数え終わった遅延メタデータを控える [MD-02][DU-22][DT-05][DT-06]。
    ///
    /// **再生成可能な列**なので JSON バックアップには入らない [MG-21]
    /// ——書き出した後にファイル側が変わっても、古い値で上書きされない。
    ///
    /// **`nil` は書かない。** 呼び出し側が「数えられなかった」ときは
    /// そもそも呼ばないこと——0 を書くと「中身が空の本」として残り、
    /// 一括選択規則 [DU-25] が中身のあるほうを捨てる材料になる。
    public func cacheArchiveMetadata(
        pageCount: Int, subfolderCount: Int,
        firstImageWidth: Int?, firstImageHeight: Int?, for id: FileID) async throws
    {
        try await database.writer.write { db in
            try db.execute(sql: """
                UPDATE managedFile
                   SET pageCount = ?, subfolderCount = ?,
                       firstImageWidth = ?, firstImageHeight = ?
                 WHERE id = ?
                """, arguments: [pageCount, subfolderCount,
                                 firstImageWidth, firstImageHeight, id.rawValue])
        }
    }

    /// 同じ組に属する行の ID。`nil` は「組を作らない」（モードが `.off`、
    /// またはタイトルが無い）。**自分自身も含む。**
    static func groupMemberIDs(_ db: Database, containing id: FileID,
                               mode: DuplicateGrouping) throws -> [FileID]? {
        guard mode.isEnabled else { return nil }
        guard let row = try Row.fetchOne(
            db, sql: """
                SELECT libraryId, titleKey, volumeNumber, volumeKind
                  FROM managedFile WHERE id = ?
                """, arguments: [id.rawValue])
        else { return nil }
        // タイトルが無い行は組を作らない [DU-02]——`titleKey IS NULL` で
        // 引くと、タイトルの無いファイル全部が 1 つの組になってしまう。
        guard let titleKey: String = row["titleKey"] else { return nil }

        var sql = """
            SELECT id FROM managedFile
             WHERE libraryId = ? AND state = 'active' AND isArchived = 0
               AND titleKey = ?
            """
        var args: [(any DatabaseValueConvertible)?] = [row["libraryId"] as Int64, titleKey]
        if mode == .byTitleAndVolume {
            // NULL は `=` で一致しないので `IS` を使う。巻数を持たないもの
            // どうしは同じ組 [DU-02]。
            sql += " AND volumeNumber IS ? AND volumeKind IS ?"
            args.append(row["volumeNumber"] as Double?)
            args.append(row["volumeKind"] as String?)
        }
        let ids = try Int64.fetchAll(db, sql: sql, arguments: StatementArguments(args))
        return ids.map { FileID(rawValue: $0) }
    }
}
