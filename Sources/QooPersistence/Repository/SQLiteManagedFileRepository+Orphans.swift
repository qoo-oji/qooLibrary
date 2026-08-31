//
//  孤立ファイルの整理 [OR-01][OR-04][ID-07]。
//
//  本体（`SQLiteManagedFileRepository`）から切り出してあるのは、あちらが
//  走査のホットパスと一覧の問い合わせで既に大きいため。振る舞いは同じ型の一部。
//
import Foundation
import GRDB
import QooKit

extension SQLiteManagedFileRepository {

    // MARK: - 一覧 [OR-01][OR-02]

    /// 孤立レコードの一覧 [OR-01]。
    ///
    /// **オフラインのライブラリを弾くのは呼び出し側** [OR2-06][ID-08][SB-05]
    /// ——リポジトリはボリュームの接続状態を知らない。
    public func orphanedFiles(libraryID: LibraryID) async throws -> [OrphanedFile] {
        try await database.writer.read { db in
            let records = try ManagedFileRecord
                .filter(sql: "libraryId = ? AND state = ?",
                        arguments: [libraryID.rawValue, FileState.orphaned.rawValue])
                .order(sql: "relativePath, filename")
                .fetchAll(db)
            guard !records.isEmpty else { return [] }
            let ids = records.compactMap(\.id)

            // ラベル件数 [OR-04 の確認に使う]。行があること＝付いていること
            // なので、素朴に数えればよい [PR-08]。
            var labelCounts: [Int64: Int] = [:]
            for row in try Row.fetchAll(db, sql: """
                SELECT managedFileId, COUNT(*) AS n FROM fileLabel
                WHERE managedFileId IN (\(Self.placeholders(ids.count)))
                GROUP BY managedFileId
                """, arguments: StatementArguments(ids) ?? StatementArguments()) {
                labelCounts[row["managedFileId"]] = row["n"]
            }

            return records.map { record in
                OrphanedFile(row: record.fileRow,
                             labelCount: labelCounts[record.id ?? 0] ?? 0)
            }
        }
    }

    public func orphanedFileCounts() async throws -> [LibraryID: Int] {
        try await database.writer.read { db in
            var out: [LibraryID: Int] = [:]
            for row in try Row.fetchAll(db, sql: """
                SELECT libraryId, COUNT(*) AS n FROM managedFile
                WHERE state = ? GROUP BY libraryId
                """, arguments: [FileState.orphaned.rawValue]) {
                out[LibraryID(rawValue: row["libraryId"])] = row["n"]
            }
            return out
        }
    }

    // MARK: - 削除と写し [OR-04][UD-03]

    /// 不要になった孤立レコードを消す。`fileLabel` は cascade で消える。
    public func deleteFiles(_ ids: [FileID]) async throws {
        guard !ids.isEmpty else { return }
        try await database.writer.write { db in
            // **消す前に集める**——`fileLabel` は cascade で消えるので、
            // 後からでは誰の件数 [DB-02] を直せばよいか分からなくなる。
            let labels = try Self.labelIDsAttached(db, to: ids)
            try db.execute(sql: """
                DELETE FROM managedFile WHERE id IN (\(Self.placeholders(ids.count)))
                """, arguments: StatementArguments(ids.map(\.rawValue)))
            try SQLiteLabelRepository.recount(db, labelIDs: labels)
        }
    }

    /// 削除・再紐づけの前に控える写し。
    ///
    /// **存在しない ID は飛ばす**（`LabelRepository.snapshot` と同じ）——
    /// 同時に消えていた 1 件のせいで、戻せるはずの残りまで戻せなくなるほうが
    /// 害が大きい。
    public func fileSnapshots(ids: [FileID]) async throws -> [ManagedFileSnapshot] {
        guard !ids.isEmpty else { return [] }
        return try await database.writer.read { db in
            var out: [ManagedFileSnapshot] = []
            for id in ids {
                guard let record = try ManagedFileRecord.fetchOne(db, key: id.rawValue) else {
                    continue
                }
                let rows = try Row.fetchAll(db, sql: """
                    SELECT labelId, assignedAt FROM fileLabel WHERE managedFileId = ?
                    """, arguments: [id.rawValue])
                out.append(record.snapshotForUndo(labels: rows.map { row in
                    ManagedFileSnapshot.LabelAssignment(
                        labelID: LabelID(rawValue: row["labelId"]),
                        assignedAt: Date(timeIntervalSinceReferenceDate: row["assignedAt"]))
                }))
            }
            return out
        }
    }

    /// 写しの状態へちょうど戻す。
    ///
    /// **`id` を明示して `INSERT` する。** `managedFile.id` は AUTOINCREMENT な
    /// ので削除された ID は再利用されず空いたまま残り、元の ID を取り戻せる
    /// ［実測］。別 ID で作り直すと、右ペインが `.task(id:)` で掴んでいる行や
    /// 一覧の選択が黙って別のものを指す。
    ///
    /// **1 トランザクションで書く**——再紐づけの Undo は「孤立側を元に戻す」と
    /// 「消した候補側を復活させる」の 2 件をまとめて戻すので、途中で切れると
    /// どちらでもない状態が残る。
    public func restoreFiles(_ snapshots: [ManagedFileSnapshot]) async throws {
        guard !snapshots.isEmpty else { return }
        try await database.writer.write { db in
            var affectedLabels = Set(snapshots.flatMap { $0.labels.map(\.labelID) })
            affectedLabels.formUnion(
                try Self.labelIDsAttached(db, to: snapshots.map(\.id)))
            for snapshot in snapshots {
                // ライブラリごと消えていたら戻せない（登録解除・無効化）。
                // Undo の対象そのものが失われているので黙って飛ばす。
                let libraryExists = try Bool.fetchOne(db, sql:
                    "SELECT EXISTS(SELECT 1 FROM library WHERE id = ?)",
                    arguments: [snapshot.libraryID.rawValue]) ?? false
                guard libraryExists else { continue }

                var record = ManagedFileRecord(undoSnapshot: snapshot)
                // 同一性は UNIQUE なので、再紐づけで別の行が同じ inode を
                // 持っていると衝突する。**戻す側を優先する**——⌘Z は
                // 「この操作の前へ戻す」であって「今あるものを守る」ではない。
                try db.execute(sql: """
                    DELETE FROM managedFile WHERE volumeUUID = ? AND inode = ? AND id <> ?
                    """, arguments: [record.volumeUUID, record.inode, snapshot.id.rawValue])
                try record.upsert(db)

                // 「ちょうど戻す」ので、写しに無い紐づけは消す。
                try db.execute(sql: "DELETE FROM fileLabel WHERE managedFileId = ?",
                               arguments: [snapshot.id.rawValue])
                for label in snapshot.labels {
                    // **相手のラベルが消えていたら飛ばす**（`LabelRepository.restore`
                    // と同じ）。1 件の消失で Undo 全体が失敗するのを避ける。
                    try db.execute(sql: """
                        INSERT INTO fileLabel (managedFileId, labelId, assignedAt)
                        SELECT ?, ?, ? WHERE EXISTS (SELECT 1 FROM label WHERE id = ?)
                        """, arguments: [snapshot.id.rawValue, label.labelID.rawValue,
                                         label.assignedAt.timeIntervalSinceReferenceDate,
                                         label.labelID.rawValue])
                }
            }
            // **件数の作り直しは `SQLiteLabelRepository.recount` に任せる。**
            // 自前で書くと `state = 'active'` と `isArchived = 0` の除外条件を
            // 写し損ねる——実際に一度落として、孤立レコードのラベルまで数える
            // ものを書いていた。同じ計算を 2 箇所に持たない [LE-03][FA-05]。
            // **戻す先の紐づけも数える。** 写しに無い紐づけは消すので、
            // 写しに載っているラベルだけを数え直すと、消えたほうの件数が
            // 古いまま残る。
            try SQLiteLabelRepository.recount(db, labelIDs: Array(affectedLabels))
        }
    }

}
