//
//  未解決ファイルの記録と整理 [AL-30〜AL-34][UR-01〜UR-06]。
//
//  本体（`SQLiteManagedFileRepository`）から切り出してあるのは、あちらが
//  走査のホットパスと一覧の問い合わせで既に大きいため（`+Orphans` と同じ理由）。
//  振る舞いは同じ型の一部。
//
import Foundation
import GRDB
import QooKit

extension SQLiteManagedFileRepository {

    // MARK: - 走査からの記録 [AL-31]

    /// 走査 1 チャンクぶんの「未解決かどうか」を反映する。
    ///
    /// **1 つのトランザクションで、記録と削除を両方行う。** 走査は収束型
    /// [FO-20] なので、観測した集合をそのまま渡せば結果が正しくなる形にする
    /// ——「足すのは走査、消すのは別経路」にすると、フォーマットを足して
    /// 解決したのに一覧に残り続ける、という食い違いが起こりうる。
    public func syncUnresolved(unresolved: [UnresolvedObservation], resolved: [FileID],
                               libraryID: LibraryID, now: Date) async throws {
        guard !unresolved.isEmpty || !resolved.isEmpty else { return }
        let stamp = now.timeIntervalSinceReferenceDate
        try await database.writer.write { db in
            // **名前が変わっていたら無視を解く**［ユーザー判断、2026-08]。
            // 無視は「この名前はどのフォーマットにも当てはまらないと判断した」
            // という意味なので、名前が変われば前提そのものが消える。
            //
            // `DO UPDATE SET` の右辺は**更新前の行**を見る（SQLite の仕様）ので、
            // 同じ文の中で `filename` を書き換えても `CASE` の判定は壊れない。
            //
            // `detectedAt` は更新しない——「いつから片付いていないか」を表す値で、
            // 走査のたびに今へ寄せると意味を失う。
            let step = Self.unresolvedUpsertRowsPerStatement
            for start in stride(from: 0, to: unresolved.count, by: step) {
                let chunk = Array(unresolved[start..<min(start + step, unresolved.count)])
                let tuples = Array(repeating: "(?, ?, ?, 0, ?)", count: chunk.count)
                    .joined(separator: ", ")
                var args: [any DatabaseValueConvertible] = []
                for item in chunk {
                    args.append(libraryID.rawValue)
                    args.append(item.fileID.rawValue)
                    args.append(item.filename)
                    args.append(stamp)
                }
                try db.execute(sql: """
                    INSERT INTO unresolvedFile
                        (libraryId, managedFileId, filename, isIgnored, detectedAt)
                    VALUES \(tuples)
                    ON CONFLICT(managedFileId) DO UPDATE SET
                        isIgnored = CASE WHEN unresolvedFile.filename <> excluded.filename
                                         THEN 0 ELSE unresolvedFile.isIgnored END,
                        filename = excluded.filename
                    """, arguments: StatementArguments(args) ?? StatementArguments())
            }

            for start in stride(from: 0, to: resolved.count, by: Self.maxBoundParameters) {
                let chunk = Array(resolved[start..<min(start + Self.maxBoundParameters,
                                                       resolved.count)])
                try db.execute(sql: """
                    DELETE FROM unresolvedFile
                    WHERE managedFileId IN (\(Self.placeholders(chunk.count)))
                    """, arguments: StatementArguments(chunk.map(\.rawValue)))
            }
        }
    }

    // MARK: - 一覧 [UR-01][UR-02]

    /// 未解決ファイルの一覧。相対パス順。
    ///
    /// **`state = 'active'` で絞る。** 実体が見つからなくなったものは
    /// 「見つからないファイル」[OR-01] の担当で、両方に出すと同じ 1 件が
    /// 2 つの画面に別の意味で並ぶ（片方で消して、もう片方にはまだ居る、
    /// という読めない状態になる）。ゴミ箱・アーカイブ済みも同じ理由で外す。
    public func unresolvedFiles(libraryID: LibraryID, includeIgnored: Bool) async throws
        -> [UnresolvedFile]
    {
        try await database.writer.read { db in
            // 印（無視・検出時刻）を先に引く。**JOIN の結果を 1 本で読まない**
            // ——`SELECT mf.*, uf.…` にすると素の `Row` から `ManagedFileRecord` を
            // 組み立て直すことになり、列を足したときに黙って落ちる経路が増える。
            var flags: [Int64: (ignored: Bool, detectedAt: Double)] = [:]
            for row in try Row.fetchAll(db, sql: """
                SELECT managedFileId, isIgnored, detectedAt FROM unresolvedFile
                WHERE libraryId = ?
                """, arguments: [libraryID.rawValue]) {
                flags[row["managedFileId"]] = (row["isIgnored"], row["detectedAt"])
            }
            guard !flags.isEmpty else { return [] }

            var sql = """
                SELECT mf.* FROM unresolvedFile uf
                JOIN managedFile mf ON mf.id = uf.managedFileId
                WHERE uf.libraryId = ? AND mf.state = ? AND mf.isArchived = 0
                """
            if !includeIgnored { sql += " AND uf.isIgnored = 0" }
            sql += " ORDER BY mf.relativePath, mf.filename"

            return try ManagedFileRecord
                .fetchAll(db, sql: sql,
                          arguments: [libraryID.rawValue, FileState.active.rawValue])
                .compactMap { record in
                    guard let key = record.id, let flag = flags[key] else { return nil }
                    return UnresolvedFile(
                        row: record.fileRow,
                        isIgnored: flag.ignored,
                        detectedAt: Date(timeIntervalSinceReferenceDate: flag.detectedAt),
                        libraryTypeMismatch: record.libraryTypeMismatch)
                }
        }
    }

    /// ライブラリごとの未解決件数。**無視したものは数えない** [AL-33]。
    ///
    /// 左ペインの「N 件」は「片付けるべき件数」を意味するので、無視したものを
    /// 含めると「0 件にしたのに 0 にならない」ことになる。
    public func unresolvedFileCounts() async throws -> [LibraryID: UnresolvedCounts] {
        try await database.writer.read { db in
            var out: [LibraryID: UnresolvedCounts] = [:]
            for row in try Row.fetchAll(db, sql: """
                SELECT uf.libraryId AS lid,
                       SUM(CASE WHEN uf.isIgnored = 0 THEN 1 ELSE 0 END) AS pending,
                       SUM(CASE WHEN uf.isIgnored = 1 THEN 1 ELSE 0 END) AS ignored
                FROM unresolvedFile uf
                JOIN managedFile mf ON mf.id = uf.managedFileId
                WHERE mf.state = ? AND mf.isArchived = 0
                GROUP BY uf.libraryId
                """, arguments: [FileState.active.rawValue]) {
                out[LibraryID(rawValue: row["lid"])] =
                    UnresolvedCounts(pending: row["pending"], ignored: row["ignored"])
            }
            return out
        }
    }

    // MARK: - 無視フラグ [AL-33][UR-05]

    public func setUnresolvedIgnored(_ ids: [FileID], _ ignored: Bool) async throws {
        guard !ids.isEmpty else { return }
        try await database.writer.write { db in
            for start in stride(from: 0, to: ids.count, by: Self.maxBoundParameters) {
                let chunk = Array(ids[start..<min(start + Self.maxBoundParameters, ids.count)])
                var args: [any DatabaseValueConvertible] = [ignored]
                args.append(contentsOf: chunk.map(\.rawValue))
                try db.execute(sql: """
                    UPDATE unresolvedFile SET isIgnored = ?
                    WHERE managedFileId IN (\(Self.placeholders(chunk.count)))
                    """, arguments: StatementArguments(args) ?? StatementArguments())
            }
        }
    }

    /// 1 文で扱う行数。1 行あたり 4 つの束縛変数を使うので、
    /// `maxBoundParameters`（900）を超えない値にする。
    static let unresolvedUpsertRowsPerStatement = 200
}
