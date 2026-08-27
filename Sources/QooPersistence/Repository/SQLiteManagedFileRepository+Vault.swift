//
//  ファイル保管庫の一覧と出入り [FA-01〜FA-17][FAW-01〜FAW-05]。
//
//  本体から切り出してあるのは孤立・未解決と同じ理由——あちらが走査のホットパスと
//  一覧の問い合わせで既に大きいため。振る舞いは同じ型の一部。
//
import Foundation
import GRDB
import QooKit

extension SQLiteManagedFileRepository {

    // MARK: - 一覧 [FAW-01]

    public func archivedFiles(libraryID: LibraryID) async throws -> [ArchivedFile] {
        try await database.writer.read { db in
            // ゴミ箱の行は出さない [TR-02]。保管庫とゴミ箱は別の場所で、
            // 「捨てた」ものが「しまった」一覧に出ると片付けたつもりが崩れる。
            let records = try ManagedFileRecord
                .filter(sql: "libraryId = ? AND isArchived = 1 AND state <> ?",
                        arguments: [libraryID.rawValue, FileState.trashed.rawValue])
                .order(sql: "relativePath, filename")
                .fetchAll(db)
            guard !records.isEmpty else { return [] }
            let ids = records.compactMap(\.id)

            // ラベル件数。**`manuallyRemoved` は数えない**——利用者から見て
            // 「付いている」ラベルだけを数えないと、削除の確認 [FAW-03] の
            // 数字が右ペインの表示と食い違う [RC-04]。
            var labelCounts: [Int64: Int] = [:]
            var countArgs: [any DatabaseValueConvertible] = ids
            countArgs.append(LabelOrigin.manuallyRemoved.rawValue)
            for row in try Row.fetchAll(db, sql: """
                SELECT managedFileId, COUNT(*) AS n FROM fileLabel
                WHERE managedFileId IN (\(Self.placeholders(ids.count))) AND origin <> ?
                GROUP BY managedFileId
                """, arguments: StatementArguments(countArgs) ?? StatementArguments()) {
                labelCounts[row["managedFileId"]] = row["n"]
            }

            return records.map { record in
                ArchivedFile(row: record.fileRow,
                             labelCount: labelCounts[record.id ?? 0] ?? 0)
            }
        }
    }

    public func archivedFileCounts() async throws -> [LibraryID: Int] {
        try await database.writer.read { db in
            var out: [LibraryID: Int] = [:]
            for row in try Row.fetchAll(db, sql: """
                SELECT libraryId, COUNT(*) AS n FROM managedFile
                WHERE isArchived = 1 AND state <> ? GROUP BY libraryId
                """, arguments: [FileState.trashed.rawValue]) {
                out[LibraryID(rawValue: row["libraryId"])] = row["n"]
            }
            return out
        }
    }

    public func filesUnder(libraryID: LibraryID, folderRelativePath: String) async throws
        -> [FileID: String]
    {
        try await database.writer.read { db in
            var out: [FileID: String] = [:]
            let sql: String
            var args: [any DatabaseValueConvertible] = [libraryID.rawValue,
                                                        FileState.trashed.rawValue]
            if folderRelativePath.isEmpty {
                sql = "libraryId = ? AND state <> ?"
            } else {
                // **フォルダ自身の行も含める。** ブックフォルダは 1 冊 = 1 行で、
                // その `relativePath` はフォルダそのもの [IF-01] ——配下だけを
                // 見ると、丸ごと運んだのに DB が古い場所を指したまま残る。
                //
                // 既存の `likePrefix` は末尾に `/` を足して成分の境界で切る
                // ——素の `a/b%` では `a/bc/…` まで拾う。
                sql = "libraryId = ? AND state <> ?"
                    + " AND (relativePath = ? OR relativePath LIKE ? ESCAPE '\\')"
                args.append(folderRelativePath)
                args.append(Self.likePrefix(folderRelativePath) + "%")
            }
            for row in try Row.fetchAll(
                db, sql: "SELECT id, relativePath FROM managedFile WHERE \(sql)",
                arguments: StatementArguments(args) ?? StatementArguments())
            {
                out[FileID(rawValue: row["id"])] = row["relativePath"]
            }
            return out
        }
    }

    // MARK: - 出入りの記録 [FA-04][FA-05]

    public func setArchived(_ moves: [VaultMove], archived: Bool) async throws {
        guard !moves.isEmpty else { return }
        try await database.writer.write { db in
            let stmt = try db.cachedStatement(sql: """
                UPDATE managedFile SET
                    relativePath = ?, isArchived = ?,
                    archivedFromPath = ?, archivedAt = ?
                WHERE id = ?
                """)
            for move in moves {
                // 保管庫から**出す**ときは記録を消す——残っていると、次に
                // 入れ直したときに古い出どころが混ざる。
                try stmt.execute(arguments: [
                    move.relativePath, archived,
                    archived ? move.previousPath : nil,
                    archived ? move.archivedAt.timeIntervalSinceReferenceDate : nil,
                    move.id.rawValue])
            }
            // ラベルの非正規化件数を数え直す [DB-02][FA-05]。**保管庫の出入りは
            // `fileCount` を必ず変える**（`recount` は `isArchived = 0` だけを
            // 数える）ので、`state` を変える経路と同じくここでも要る。
            // 900 件ずつに区切るのは、フォルダ丸ごと [FDA-01] だと一度に
            // 数千件が動きうるため（上限の低いビルドで落ちる。壊れるのは
            // そちらだけなので、通ることを理由に外さないこと）。
            let ids = moves.map(\.id)
            for chunk in stride(from: 0, to: ids.count, by: 900) {
                let slice = Array(ids[chunk..<min(chunk + 900, ids.count)])
                let labels = try Self.labelIDsAttached(db, to: slice)
                try SQLiteLabelRepository.recount(db, labelIDs: labels)
            }
        }
    }
}
