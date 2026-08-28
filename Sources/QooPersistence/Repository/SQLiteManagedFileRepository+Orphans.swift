//
//  孤立ファイルの整理 [OR-01〜OR-05][ID-05][ID-07]。
//
//  本体（`SQLiteManagedFileRepository`）から切り出してあるのは、あちらが
//  走査のホットパスと一覧の問い合わせで既に大きいため。振る舞いは同じ型の一部。
//
import Foundation
import GRDB
import QooKit

extension SQLiteManagedFileRepository {

    // MARK: - 一覧 [OR-01][OR-02]

    /// 孤立レコードと、その再照合候補。
    ///
    /// **候補は 1 本の JOIN でまとめて引く。** 孤立は数千件になりうる
    /// （ボリュームを取り違えると全件が孤立する——`ScanEngine` の砦がそれを
    /// 防いでいるが、外付けの中身が入れ替わればふつうに起こる）ので、1 件ずつ
    /// 問い合わせると件数ぶんの往復になる。既存の索引
    /// `mf_lib_name_size (libraryId, filename, fileSize)` がそのまま効く
    /// ——再照合 [ID-03]②③ のために置いた索引で、引く向きが逆でも同じ。
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

            // ラベル件数 [OR-04 の確認に使う]。**`manuallyRemoved` は数えない**
            // ——利用者から見て「付いている」ラベルだけを数えなければ、
            // 「N 件のラベルが外れます」の数字が右ペインの表示と食い違う [RC-04]。
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

            // 候補 [ID-03]③。走査が①②で自動的に紐づけ直した [ID-04] ものは
            // そもそも孤立に残らないので、ここへ来るのは原則「名前だけ一致」。
            let candidates = try Self.candidates(db, libraryID: libraryID)

            return records.map { record in
                let key = record.id ?? 0
                // **大きさも一致するものを先に。** 名前だけの一致より確からしい。
                // 同点はパスの自然な並びで安定させる（順序が実行ごとに変わると、
                // 「ワンクリックで再紐づけ」が毎回違うものを指しうる）。
                let sorted = (candidates[key] ?? []).sorted(by: Self.moreLikely)
                return OrphanedFile(row: record.fileRow,
                                    labelCount: labelCounts[key] ?? 0,
                                    candidates: sorted)
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

    public func identity(of id: FileID) async throws -> FileIdentity? {
        try await database.writer.read { db in
            guard let row = try Row.fetchOne(db, sql:
                "SELECT volumeUUID, inode FROM managedFile WHERE id = ?",
                arguments: [id.rawValue]) else { return nil }
            return FileIdentity(volumeUUID: row["volumeUUID"],
                                inode: UInt64(bitPattern: row["inode"] as Int64))
        }
    }

    /// 孤立レコードごとの候補 [ID-05]。
    ///
    /// **走査が実際に差し替えを疑った組だけを返す** [ID3-08]——`identityPending`
    /// に記録が無い組は、たまたま同じ名前の別のファイルである。却下済みの組も
    /// 返さない [ID-11]。
    ///
    /// **1 本の JOIN でまとめて引く**（孤立は数千件になりうる）。既存の索引
    /// `mf_lib_name_size (libraryId, filename, fileSize)` がそのまま効く。
    static func candidates(_ db: Database, libraryID: LibraryID) throws
        -> [Int64: [OrphanCandidate]]
    {
        var out: [Int64: [OrphanCandidate]] = [:]
        for row in try Row.fetchAll(db, sql: """
            SELECT o.id AS orphanId, c.id AS candidateId,
                   c.relativePath AS candidatePath, c.filename AS candidateName,
                   c.fileSize AS candidateSize, o.fileSize AS orphanSize,
                   o.relativePath AS orphanPath
            FROM managedFile o
            JOIN managedFile c
              ON c.libraryId = o.libraryId AND c.filename = o.filename
             AND c.state = ? AND c.id <> o.id
            WHERE o.libraryId = ? AND o.state = ?
              AND EXISTS (SELECT 1 FROM identityPending p
                          WHERE p.orphanFileId = o.id AND p.candidateFileId = c.id)
              AND NOT EXISTS (SELECT 1 FROM identityRejection r
                              WHERE r.orphanFileId = o.id AND r.candidateFileId = c.id)
            """, arguments: [FileState.active.rawValue, libraryID.rawValue,
                             FileState.orphaned.rawValue]) {
            let orphanSize: Int64 = row["orphanSize"]
            let candidateSize: Int64 = row["candidateSize"]
            let orphanPath: String = row["orphanPath"]
            let candidatePath: String = row["candidatePath"]
            out[row["orphanId"], default: []].append(OrphanCandidate(
                fileID: FileID(rawValue: row["candidateId"]),
                relativePath: candidatePath,
                filename: row["candidateName"],
                fileSize: candidateSize,
                samePath: candidatePath == orphanPath,
                sizeMatches: candidateSize == orphanSize))
        }
        return out
    }

    /// 確からしい順 [ID-09]。**同じ場所が最優先**（差し替えはほぼ確実）、
    /// 次に大きさの一致。同点はパスの並びで安定させる——順序が実行ごとに
    /// 変わると、既定でチェックが入る先が毎回違うものになる。
    static func moreLikely(_ a: OrphanCandidate, _ b: OrphanCandidate) -> Bool {
        if a.samePath != b.samePath { return a.samePath }
        if a.sizeMatches != b.sizeMatches { return a.sizeMatches }
        return a.relativePath < b.relativePath
    }

    // MARK: - 同一性の確認 [ID-05][ID-09〜ID-12]

    /// 確認待ちの組。**候補を持つ孤立レコードだけ**を返す。
    public func identityMatchesAwaitingDecision(libraryID: LibraryID) async throws
        -> [OrphanedFile]
    {
        try await orphanedFiles(libraryID: libraryID).filter { !$0.candidates.isEmpty }
    }

    /// 走査が差し替えを疑った組を記録する [ID3-08]。
    public func recordIdentityPending(_ matches: [IdentityMatch]) async throws {
        guard !matches.isEmpty else { return }
        try await database.writer.write { db in
            let now = Date().timeIntervalSinceReferenceDate
            for match in matches {
                try db.execute(sql: """
                    INSERT INTO identityPending (orphanFileId, candidateFileId, detectedAt)
                    VALUES (?, ?, ?)
                    ON CONFLICT(orphanFileId, candidateFileId) DO NOTHING
                    """, arguments: [match.orphanID.rawValue, match.candidateID.rawValue, now])
            }
        }
    }

    /// 答えの出た組を確認待ちから外す。**承認のときだけ呼ぶ**
    /// （却下は `identityRejection` が抑えるので消さない。理由は
    /// `rejectIdentityMatches` のコメント）。
    static func clearPending(_ db: Database, _ matches: [IdentityMatch]) throws {
        for match in matches {
            try db.execute(sql: """
                DELETE FROM identityPending
                WHERE orphanFileId = ? AND candidateFileId = ?
                """, arguments: [match.orphanID.rawValue, match.candidateID.rawValue])
        }
    }

    /// 承認された組を確定する [ID-05]。
    ///
    /// **1 トランザクションでまとめて行う。** 1 件ずつ `reattachOrphan` を呼ぶと、
    /// 途中で切れたときに「一部だけ紐づいた」状態が残る——利用者は 1 回
    /// 「適用」を押しただけなので、その半端さは説明が付かない。
    @discardableResult
    public func acceptIdentityMatches(_ matches: [IdentityMatch]) async throws -> [FileID] {
        guard !matches.isEmpty else { return [] }
        return try await database.writer.write { db in
            var removed: [FileID] = []
            for match in matches {
                guard let candidate = try ManagedFileRecord
                    .fetchOne(db, key: match.candidateID.rawValue) else { continue }
                let snapshot = FileSnapshot(
                    identity: FileIdentity(volumeUUID: candidate.volumeUUID,
                                           inode: UInt64(bitPattern: candidate.inode)),
                    libraryID: LibraryID(rawValue: candidate.libraryId),
                    relativePath: candidate.relativePath, filename: candidate.filename,
                    fileSize: candidate.fileSize,
                    createdAt: Date(timeIntervalSinceReferenceDate: candidate.createdAt),
                    modifiedAt: Date(timeIntervalSinceReferenceDate: candidate.modifiedAt),
                    isBookFolder: candidate.isBookFolder)
                if let id = try Self.reattach(db, orphan: match.orphanID, to: snapshot) {
                    removed.append(id)
                }
            }
            // 答えが出た組はもう確認待ちではない。**候補側の行は消えるので
            // cascade でも落ちるが、孤立側だけが残る経路もある**ので明示する。
            try Self.clearPending(db, matches)
            return removed
        }
    }

    /// 「別のファイルだ」という判断を記録する [ID-11]。
    ///
    /// **一度答えた組を毎回聞き直しては使い物にならない**——`第01巻.cbz` の
    /// ように複数シリーズに存在しうる名前では、走査のたびに同じ組が挙がる。
    public func rejectIdentityMatches(_ matches: [IdentityMatch]) async throws {
        guard !matches.isEmpty else { return }
        try await database.writer.write { db in
            let now = Date().timeIntervalSinceReferenceDate
            for match in matches {
                try db.execute(sql: """
                    INSERT INTO identityRejection (orphanFileId, candidateFileId, decidedAt)
                    VALUES (?, ?, ?)
                    ON CONFLICT(orphanFileId, candidateFileId) DO NOTHING
                    """, arguments: [match.orphanID.rawValue, match.candidateID.rawValue, now])
            }
            // **却下では確認待ちの記録を消さない。** 却下は `identityRejection`
            // が抑えるので二重に消す必要が無く、消すと Undo（`clearIdentityRejections`）
            // で組が戻らなくなる——却下を取り消したのに確認に出てこない、
            // という形で [ID-11] が破れる。
        }
    }

    /// 却下の記録を取り消す（Undo 用）。
    public func clearIdentityRejections(_ matches: [IdentityMatch]) async throws {
        guard !matches.isEmpty else { return }
        try await database.writer.write { db in
            for match in matches {
                try db.execute(sql: """
                    DELETE FROM identityRejection
                    WHERE orphanFileId = ? AND candidateFileId = ?
                    """, arguments: [match.orphanID.rawValue, match.candidateID.rawValue])
            }
        }
    }

    // MARK: - 再紐づけ [OR-02][OR-03][ID-04]

    /// 孤立レコードを、実際に観測されたファイルへ結び直す。
    ///
    /// **同じ同一性を持つ別のレコードがあれば消してから結び直す**［ユーザー判断］。
    /// 候補側は原則スキャン直後の新規レコードなので、孤立側のラベル・評価・
    /// 手動タイトル・カバー指定を生かすほうが失うものが少ない。ID-04 の
    /// 「inode を更新して既存レコードとみなす（ラベル維持）」と同じ意味。
    ///
    /// **1 トランザクションで行う**——片方だけ済むと、同じ実体を指すレコードが
    /// 2 つ残るか、どちらも指さない状態になる。
    ///
    /// 候補一覧からの再紐づけ [OR-02] と手動選択 [OR-03] は**同じここを通る**
    /// ——呼び出し側が観測結果（`FileSnapshot`）を作る点だけが違う。同じ操作に
    /// 独立した経路を 2 つ作らない。
    @discardableResult
    public func reattachOrphan(_ id: FileID, to snapshot: FileSnapshot) async throws -> FileID? {
        try await database.writer.write { db in
            try Self.reattach(db, orphan: id, to: snapshot)
        }
    }

    /// 1 組ぶんの結び直し。**一括の承認 [ID-05] と 1 件ずつの経路が共有する**
    /// ——同じ操作に独立した実装を 2 つ持たない。
    @discardableResult
    static func reattach(_ db: Database, orphan id: FileID,
                         to snapshot: FileSnapshot) throws -> FileID? {
        var removed: FileID?
        // 件数 [DB-02] の母数は 2 通りに動く——候補側の行が消えることと、
        // 孤立側が `active` へ戻ること。**両方まとめて先に控える。**
        var affected = try labelIDsAttached(db, to: [id])
        if let duplicate = try find(db, identity: snapshot.identity), duplicate != id {
            affected += try labelIDsAttached(db, to: [duplicate])
            try db.execute(sql: "DELETE FROM managedFile WHERE id = ?",
                           arguments: [duplicate.rawValue])
            removed = duplicate
        }
        let options = try normalizationOptions(db, libraryID: snapshot.libraryID)
        // パス・名前・サイズ・更新日時を観測に合わせ、`state` を戻す。
        try updateInPlace(db, id: id, snapshot: snapshot, options: options)
        try db.execute(sql: """
            UPDATE managedFile SET volumeUUID = ?, inode = ?,
                state = ?, trashedAt = NULL
            WHERE id = ?
            """, arguments: [snapshot.identity.volumeUUID,
                             Int64(bitPattern: snapshot.identity.inode),
                             FileState.active.rawValue, id.rawValue])
        // **`updateInPlace` は `searchKey` に stem だけを書く。** 走査では
        // 直後に `applyParsedFields` が最終形を書く対になっているが、ここには
        // その対が無いので自分で作り直す——さもないとタイトル・シリーズ名で
        // 検索したときだけこの 1 件が出てこなくなる [SR-03]。
        try refreshDerivedKeys(db, id: id, options: options)
        try SQLiteLabelRepository.recount(db, labelIDs: Array(Set(affected)))
        return removed
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
                    SELECT labelId, origin, assignedAt FROM fileLabel WHERE managedFileId = ?
                    """, arguments: [id.rawValue])
                out.append(record.snapshotForUndo(labels: rows.map { row in
                    ManagedFileSnapshot.LabelAssignment(
                        labelID: LabelID(rawValue: row["labelId"]),
                        origin: LabelOrigin(rawValue: row["origin"]) ?? .auto,
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
                        INSERT INTO fileLabel (managedFileId, labelId, origin, assignedAt)
                        SELECT ?, ?, ?, ? WHERE EXISTS (SELECT 1 FROM label WHERE id = ?)
                        """, arguments: [snapshot.id.rawValue, label.labelID.rawValue,
                                         label.origin.rawValue,
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
