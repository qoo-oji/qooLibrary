//
//  重複グループの読み書き [DU-05][DU-08][DU-20]。
//
import Foundation
import GRDB
import QooKit

extension SQLiteManagedFileRepository {

    /// 代表の手動固定 [DU-08]。
    ///
    /// **同じ組の他のファイルの固定は外す。** 1 つの組に固定が 2 つあると、
    /// どちらが代表になるかは残りの条件（評価・サイズ・名前）で決まってしまい、
    /// 「固定したのに代表にならない」という説明の付かない状態になる。
    ///
    /// 組の範囲は**そのとき有効な判定キー** [DU-02] で決まるので、
    /// 呼び出し側が現在のモードを渡すこと。
    /// - Parameter mode: **既定値を持たせない。** 組の範囲はそのとき有効な
    ///   判定キー [DU-02] で決まるので、既定で決め打ちすると `.byTitle` の
    ///   ライブラリで**違う組の固定を外す**（結果、1 つの組に固定が 2 つ残る）。
    public func setDuplicateRepresentativePinned(
        _ pinned: Bool, for id: FileID, mode: DuplicateGrouping) async throws
    {
        try await database.writer.write { db in
            if pinned, let siblings = try Self.groupMemberIDs(db, containing: id, mode: mode),
               !siblings.isEmpty {
                try db.execute(sql: """
                    UPDATE managedFile SET isDuplicateRepresentativePinned = 0
                     WHERE id IN (\(Self.placeholders(siblings.count)))
                    """, arguments: StatementArguments(siblings.map(\.rawValue)))
            }
            try db.execute(sql: """
                UPDATE managedFile SET isDuplicateRepresentativePinned = ? WHERE id = ?
                """, arguments: [pinned, id.rawValue])
        }
    }

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
