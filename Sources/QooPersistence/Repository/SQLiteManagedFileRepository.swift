//
//  ManagedFileRepository の SQLite 実装 [10.4][ID-01〜ID-08][7.4]。
//
import Foundation
import GRDB
import QooKit

public struct SQLiteManagedFileRepository: ManagedFileRepository, Sendable {
    let database: QooDatabase

    public init(database: QooDatabase) {
        self.database = database
    }

    // MARK: - 同一性判定 [10.4]

    /// 主キー `(volumeUUID, inode)` で引く [ID-01][ID-02][ID3-01]。
    public func find(identity: FileIdentity) async throws -> FileID? {
        try await database.writer.read { db in
            try Self.find(db, identity: identity)
        }
    }

    static func find(_ db: Database, identity: FileIdentity) throws -> FileID? {
        let stmt = try db.cachedStatement(sql:
            "SELECT id FROM managedFile WHERE volumeUUID = ? AND inode = ?")
        let id = try Int64.fetchOne(stmt, arguments: [identity.volumeUUID,
                                                      Int64(bitPattern: identity.inode)])
        return id.map { FileID(rawValue: $0) }
    }

    /// `searchKey` を行の現在値から作り直す [SR-03]。
    ///
    /// タイトル・シリーズ名を書き換えた**あと**に呼ぶこと。**書いた値ではなく
    /// 行を読み直す**のが要点——`applyParsedFields` の `title` は
    /// `CASE WHEN titleOrigin = 'manual'` で据え置かれることがあるので、
    /// 渡された値から組み立てると手動編集した行だけ鍵が実態とずれる。
    static func refreshSearchKey(_ db: Database, id: FileID,
                                 options: NormalizationOptions) throws {
        let stmt = try db.cachedStatement(sql:
            "SELECT filename, title, seriesName FROM managedFile WHERE id = ?")
        guard let row = try Row.fetchOne(stmt, arguments: [id.rawValue]) else { return }
        let filename: String = row["filename"]
        let key = ManagedFileSearchKey.make(
            stem: ManagedFileSearchKey.stem(ofFilename: filename),
            title: row["title"], seriesName: row["seriesName"], options: options)
        try db.execute(sql: "UPDATE managedFile SET searchKey = ? WHERE id = ?",
                       arguments: [key, id.rawValue])
    }

    /// 再照合の候補を確度の高い順に返す [ID-03][ID3-02]。
    ///
    /// ① 同一相対パス + 同一サイズ ② 同一ファイル名 + 同一サイズ ③ 同一ファイル名のみ。
    /// **③ のみの一致は自動で紐づけない** [ID-05][ID3-03]——呼び出し側が判断する。
    public func findCandidates(for snapshot: FileSnapshot) async throws
        -> [ReidentificationCandidate]
    {
        try await database.writer.read { db in
            try Self.findCandidates(db, snapshot: snapshot)
        }
    }

    static func findCandidates(_ db: Database, snapshot: FileSnapshot) throws
        -> [ReidentificationCandidate]
    {
        // 同じ inode を持つ行は「別のファイル」なので候補から外す。
        let rows = try Row.fetchAll(db, sql: """
            SELECT id, relativePath, filename, fileSize FROM managedFile
            WHERE libraryId = ?
              AND state IN ('active', 'orphaned', 'trashed')
              AND NOT (volumeUUID = ? AND inode = ?)
              AND (relativePath = ? OR filename = ?)
            """, arguments: [snapshot.libraryID.rawValue,
                             snapshot.identity.volumeUUID,
                             Int64(bitPattern: snapshot.identity.inode),
                             snapshot.relativePath, snapshot.filename])

        var out: [ReidentificationCandidate] = []
        for row in rows {
            let path: String = row["relativePath"]
            let name: String = row["filename"]
            let size: Int64 = row["fileSize"]
            let confidence: ReidentificationCandidate.Confidence
            if path == snapshot.relativePath, size == snapshot.fileSize {
                confidence = .pathAndSize
            } else if name == snapshot.filename, size == snapshot.fileSize {
                confidence = .nameAndSize
            } else if name == snapshot.filename {
                confidence = .nameOnly
            } else {
                continue                      // 相対パスは同じだがサイズが違う → 別物
            }
            out.append(ReidentificationCandidate(
                fileID: FileID(rawValue: row["id"]), confidence: confidence,
                relativePath: path, filename: name))
        }
        return out.sorted { $0.confidence < $1.confidence }
    }

    // MARK: - 書き込み

    @discardableResult
    public func upsert(_ snapshot: FileSnapshot) async throws -> FileID {
        try await upsertBatch([snapshot])[0]
    }

    /// スキャンのホットパス [HP2-01][HP2-02][SE3-05]。
    ///
    /// 1 回の書き込みトランザクションでまとめて処理する。呼び出し側が 500 件ごとに
    /// 区切ること——ここで区切ると進捗とキャンセルの境界が合わなくなる。
    @discardableResult
    public func upsertBatch(_ snapshots: [FileSnapshot]) async throws -> [FileID] {
        guard !snapshots.isEmpty else { return [] }
        return try await database.writer.write { db in
            let options = try Self.normalizationOptions(db, libraryID: snapshots[0].libraryID)
            var out: [FileID] = []
            out.reserveCapacity(snapshots.count)
            for snapshot in snapshots {
                if let existing = try Self.find(db, identity: snapshot.identity) {
                    // パス・ファイル名の変化を追従更新する [ID-02]
                    try Self.updateInPlace(db, id: existing, snapshot: snapshot, options: options)
                    out.append(existing)
                } else {
                    var record = ManagedFileRecord(snapshot: snapshot, options: options)
                    try record.insert(db)
                    out.append(FileID(rawValue: record.id ?? 0))
                }
            }
            return out
        }
    }

    static func updateInPlace(_ db: Database, id: FileID,
                              snapshot: FileSnapshot, options: NormalizationOptions) throws {
        let stem = snapshot.nameWithoutExtension
        let stmt = try db.cachedStatement(sql: """
            UPDATE managedFile SET
                relativePath = ?, filename = ?, normalizedName = ?, searchKey = ?,
                fileSize = ?, modifiedAt = ?, isBookFolder = ?,
                -- ゴミ箱から元の場所へ戻った場合は active へ戻す [TR-04]
                state = CASE WHEN state IN ('orphaned', 'offline') THEN 'active' ELSE state END,
                trashedAt = CASE WHEN state IN ('orphaned', 'offline') THEN NULL ELSE trashedAt END
            WHERE id = ?
            """)
        try stmt.execute(arguments: [
            snapshot.relativePath, snapshot.filename,
            TextNormalizer.normalize(stem, options: options),
            // **stem だけ**を書く [SR-03]。タイトル・シリーズを混ぜた最終形は
            // 直後に走る `applyParsedFields` が書く——走査は upsert と
            // `applyParsedFields` を必ず対にして呼ぶ（`ScanEngine` の ②→④）。
            // ここで DB のタイトルを読み直すと、走査の内側の輪で 1 ファイルにつき
            // SELECT が 1 本増える。**この対を崩す経路を作らないこと。**
            ManagedFileSearchKey.make(stem: stem, title: nil, seriesName: nil,
                                      options: options),
            snapshot.fileSize,
            snapshot.modifiedAt.timeIntervalSinceReferenceDate,
            snapshot.isBookFolder, id.rawValue])
    }

    /// 同一性が変わったレコードの inode を差し替える [ID-04]。ラベルは維持される。
    public func reidentify(_ id: FileID, to identity: FileIdentity) async throws {
        try await database.writer.write { db in
            try db.execute(sql: """
                UPDATE managedFile SET volumeUUID = ?, inode = ?,
                    state = CASE WHEN state IN ('orphaned', 'trashed') THEN 'active' ELSE state END
                WHERE id = ?
                """, arguments: [identity.volumeUUID, Int64(bitPattern: identity.inode), id.rawValue])
        }
    }

    public func setState(_ state: FileState, ids: [FileID]) async throws {
        guard !ids.isEmpty else { return }
        try await database.writer.write { db in
            try db.execute(sql: """
                UPDATE managedFile SET state = ? WHERE id IN (\(Self.placeholders(ids.count)))
                """, arguments: StatementArguments([state.rawValue] + ids.map(\.rawValue)) ?? StatementArguments())
        }
    }

    public func markTrashed(_ ids: [FileID], at date: Date) async throws {
        guard !ids.isEmpty else { return }
        try await database.writer.write { db in
            try db.execute(sql: """
                UPDATE managedFile SET state = 'trashed', trashedAt = ?
                WHERE id IN (\(Self.placeholders(ids.count)))
                """, arguments: StatementArguments(
                    [date.timeIntervalSinceReferenceDate as any DatabaseValueConvertible]
                    + ids.map { $0.rawValue as any DatabaseValueConvertible }) ?? StatementArguments())
        }
    }

    /// 期限切れのゴミ箱レコードを消す [TR-06]。
    public func purgeExpiredTrashed(retentionDays: Int, now: Date) async throws -> Int {
        let cutoff = now.addingTimeInterval(-Double(retentionDays) * 86_400)
            .timeIntervalSinceReferenceDate
        return try await database.writer.write { db in
            try db.execute(sql: """
                DELETE FROM managedFile WHERE state = 'trashed' AND trashedAt IS NOT NULL
                  AND trashedAt < ?
                """, arguments: [cutoff])
            return db.changesCount
        }
    }

    /// 走査の範囲にあるが今回観測されなかったレコードを孤立にする [ID-06]。
    ///
    /// **即削除しない。ラベル紐づけは保持する** [ID3-04]。`.trashed` は期限まで
    /// 保持するので触らない [TR-01]。
    ///
    /// `seen` は 5 万件規模になりうるので、`IN (...)` ではなく一時テーブルへ入れる。
    /// 観測されなかったレコードを返す（孤立にはしない）。
    public func unseen(libraryID: LibraryID, scope: FileQuery.Scope,
                       seen: Set<FileID>) async throws -> [FileRow] {
        try await database.writer.write { db in
            try Self.fillSeenTable(db, seen)
            let (clause, args) = Self.unseenClause(libraryID: libraryID, scope: scope)
            return try ManagedFileRecord.fetchAll(
                db, sql: "SELECT * FROM managedFile WHERE \(clause)",
                arguments: StatementArguments(args.map { Optional($0) })).map(\.fileRow)
        }
    }

    /// 1 冊扱いの解除 [IF-05]。**孤立にしない・ラベルにも触れない。**
    public func releaseBookFolder(_ id: FileID) async throws {
        try await database.writer.write { db in
            try db.execute(sql: """
                UPDATE managedFile SET isBookFolder = 0, state = 'active' WHERE id = ?
                """, arguments: [id.rawValue])
        }
    }

    @discardableResult
    public func markUnseenAsOrphaned(libraryID: LibraryID, scope: FileQuery.Scope,
                                     seen: Set<FileID>) async throws -> Int {
        try await database.writer.write { db in
            try Self.fillSeenTable(db, seen)
            let (clause, args) = Self.unseenClause(libraryID: libraryID, scope: scope)
            try db.execute(sql: "UPDATE managedFile SET state = 'orphaned' WHERE \(clause)",
                           arguments: StatementArguments(args.map { Optional($0) }))
            return db.changesCount
        }
    }

    static func fillSeenTable(_ db: Database, _ seen: Set<FileID>) throws {
        // `seen` は 5 万件規模になりうるので `IN (...)` ではなく一時テーブルへ。
        try db.execute(sql: "CREATE TEMP TABLE IF NOT EXISTS seenFile (id INTEGER PRIMARY KEY)")
        try db.execute(sql: "DELETE FROM seenFile")
        let insert = try db.cachedStatement(sql: "INSERT OR IGNORE INTO seenFile (id) VALUES (?)")
        for id in seen { try insert.execute(arguments: [id.rawValue]) }
    }

    static func unseenClause(libraryID: LibraryID, scope: FileQuery.Scope)
        -> (String, [any DatabaseValueConvertible])
    {
        var sql = "libraryId = ? AND state = 'active' AND id NOT IN (SELECT id FROM seenFile)"
        var args: [any DatabaseValueConvertible] = [libraryID.rawValue]
        if case .folder(let path, let recursive) = scope {
            if recursive {
                sql += " AND relativePath LIKE ? ESCAPE '\\'"
                args.append(likePrefix(path) + "%")
            } else {
                // 直下のみ: パス区切りが 1 つも増えないもの
                sql += " AND relativePath LIKE ? ESCAPE '\\' AND instr(substr(relativePath, ?), '/') = 0"
                args.append(likePrefix(path) + "%")
                args.append(sqliteOffsetAfter(path))
            }
        }
        return (sql, args)
    }

    /// パーサの結果を書き戻す [RC-01]。
    ///
    /// `titleOrigin == .manual` のタイトルは上書きしない [RP-11]。
    public func applyParsedFields(_ fields: ParsedFileFields?, to id: FileID) async throws {
        try await database.writer.write { db in
            guard let fields else {
                try db.execute(sql: """
                    UPDATE managedFile SET seriesName = NULL, seriesKey = NULL,
                        volumeNumber = NULL, volumeKind = 'none', volumeRaw = NULL,
                        authorName = NULL, lastParsedFormatID = NULL, libraryTypeMismatch = 0
                    WHERE id = ?
                    """, arguments: [id.rawValue])
                // タイトルは `titleOrigin = 'manual'` なら残るので、消した枝でも
                // 鍵は作り直す [SR-03]。
                try Self.refreshSearchKey(db, id: id,
                                          options: try Self.normalizationOptions(db, fileID: id))
                return
            }
            let options = try Self.normalizationOptions(db, fileID: id)
            try db.execute(sql: """
                UPDATE managedFile SET
                    title = CASE WHEN titleOrigin = 'manual' THEN title ELSE ? END,
                    seriesName = ?, seriesKey = ?,
                    volumeNumber = ?, volumeKind = ?, volumeRaw = ?,
                    authorName = ?, lastParsedFormatID = ?, libraryTypeMismatch = ?
                WHERE id = ?
                """, arguments: [
                    fields.title,
                    fields.seriesName,
                    fields.seriesName.map { TextNormalizer.normalize($0, options: options) },
                    fields.volume.number,
                    fields.volume.kind.rawValue,
                    fields.volume.raw,
                    fields.authorName,
                    fields.matchedFormatID.uuidString,
                    fields.libraryTypeMismatch,
                    id.rawValue])
            // タイトル・シリーズ名も検索対象 [SR-03]。**書いた値ではなく行を
            // 読み直す**（上の `CASE WHEN titleOrigin = 'manual'` があるため）。
            try Self.refreshSearchKey(db, id: id, options: options)
        }
    }

    // MARK: - 埋め込みメタデータ [EM-07]

    public func embeddedMetadataCache(ids: [FileID]) async throws
        -> [FileID: EmbeddedMetadataCacheEntry]
    {
        guard !ids.isEmpty else { return [:] }
        return try await database.writer.read { db in
            let placeholders = Self.placeholders(ids.count)
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, metadataStamp, metadataJSON FROM managedFile
                WHERE id IN (\(placeholders)) AND metadataStamp IS NOT NULL
                """, arguments: StatementArguments(ids.map { $0.rawValue }))
            var out: [FileID: EmbeddedMetadataCacheEntry] = [:]
            let decoder = JSONDecoder()
            for row in rows {
                guard let stamp: String = row["metadataStamp"] else { continue }
                var metadata: EmbeddedMetadata?
                if let json: String = row["metadataJSON"] {
                    // 壊れた JSON は「まだ読んでいない」ではなく「持っていない」
                    // として扱う——読み直せば直るので、失敗を伝播させない。
                    metadata = try? decoder.decode(EmbeddedMetadata.self, from: Data(json.utf8))
                }
                out[FileID(rawValue: row["id"])] = EmbeddedMetadataCacheEntry(
                    stamp: stamp, metadata: metadata)
            }
            return out
        }
    }

    public func saveEmbeddedMetadata(_ entries: [FileID: EmbeddedMetadataCacheEntry]) async throws {
        guard !entries.isEmpty else { return }
        try await database.writer.write { db in
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            for (id, entry) in entries {
                var json: String?
                if let metadata = entry.metadata, !metadata.isEmpty {
                    json = String(decoding: try encoder.encode(metadata), as: UTF8.self)
                }
                try db.execute(sql: """
                    UPDATE managedFile
                       SET metadataStamp = ?, metadataSource = ?, metadataJSON = ?,
                           hasVolumeConflict = ?
                     WHERE id = ?
                    """, arguments: [
                        entry.stamp,
                        entry.metadata.map { $0.isEmpty ? nil : $0.source.rawValue } ?? nil,
                        json,
                        entry.metadata?.volumeConflict != nil,
                        id.rawValue])
            }
        }
    }

    public func filesAwaitingVolumeDecision(libraryID: LibraryID) async throws
        -> [VolumeDecisionCandidate]
    {
        try await database.writer.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, filename, relativePath, metadataJSON FROM managedFile
                WHERE libraryId = ? AND hasVolumeConflict = 1 AND state = ?
                ORDER BY relativePath
                """, arguments: [libraryID.rawValue, FileState.active.rawValue])
            let decoder = JSONDecoder()
            return rows.compactMap { row -> VolumeDecisionCandidate? in
                guard let json: String = row["metadataJSON"],
                      let metadata = try? decoder.decode(EmbeddedMetadata.self,
                                                         from: Data(json.utf8)),
                      let conflict = metadata.volumeConflict else { return nil }
                return VolumeDecisionCandidate(
                    id: FileID(rawValue: row["id"]),
                    filename: row["filename"],
                    relativePath: row["relativePath"],
                    conflict: conflict)
            }
        }
    }

    public func resolveVolumeConflicts(_ ids: [FileID],
                                       using source: ComicInfoVolumeSource) async throws {
        guard source != .ask, !ids.isEmpty else { return }
        try await database.writer.write { db in
            let decoder = JSONDecoder()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let placeholders = Self.placeholders(ids.count)
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, metadataJSON FROM managedFile
                WHERE id IN (\(placeholders)) AND hasVolumeConflict = 1
                """, arguments: StatementArguments(ids.map { $0.rawValue }))

            for row in rows {
                guard let json: String = row["metadataJSON"],
                      let metadata = try? decoder.decode(EmbeddedMetadata.self,
                                                         from: Data(json.utf8)),
                      let conflict = metadata.volumeConflict else { continue }
                let value = source == .number ? conflict.number : conflict.volume
                let raw = source == .number ? conflict.numberRaw : conflict.volumeRaw

                // 衝突を解消した形へ書き直す。**次のスキャンで読み直しても
                // 同じ結論になる**ように、判断の結果をメタデータ側にも残す
                // ——残さないと、印が一致する限り衝突のままに見える。
                let settled = EmbeddedMetadata(
                    source: metadata.source, title: metadata.title, series: metadata.series,
                    volume: value, volumeRaw: raw, authors: metadata.authors,
                    volumeConflict: nil)
                let settledJSON = String(decoding: try encoder.encode(settled), as: UTF8.self)
                try db.execute(sql: """
                    UPDATE managedFile
                       SET metadataJSON = ?, hasVolumeConflict = 0,
                           volumeNumber = ?, volumeKind = ?, volumeRaw = ?
                     WHERE id = ?
                    """, arguments: [settledJSON, value, VolumeValue.Kind.numeric.rawValue, raw,
                                     row["id"] as Int64])
            }
        }
    }

    // MARK: - 評価 [RA-01〜RA-08]

    public func setRating(_ stars: Int, ids: [FileID]) async throws {
        guard !ids.isEmpty else { return }
        let clamped = max(0, min(5, stars))
        try await database.writer.write { db in
            // **分割して書く。**「シリーズ全巻に適用」[RA-04] は 1 回で数百件に
            // なりうるので、`matchingRelativePaths` と同じ理由（ホスト変数の
            // 上限と、巨大な `IN` の実測 56 倍の遅さ）で 900 件ずつに区切る。
            //
            // **この分割は変異検証では空振りする**（外しても全件正しく書ける）。
            // この環境の SQLite はホスト変数の上限が高いため——壊れるのは
            // 速度のほうで、`matchingRelativePaths` とまったく同じ事情。
            // 外さないこと。
            for start in stride(from: 0, to: ids.count, by: Self.maxBoundParameters) {
                let chunk = Array(ids[start..<min(start + Self.maxBoundParameters, ids.count)])
                var args: [any DatabaseValueConvertible] = [clamped]
                args.append(contentsOf: chunk.map(\.rawValue))
                try db.execute(sql: """
                    UPDATE managedFile SET rating = ?
                     WHERE id IN (\(Self.placeholders(chunk.count)))
                    """, arguments: StatementArguments(args.map { Optional($0) }))
            }
        }
    }

    public func filesInSameSeries(as id: FileID) async throws -> [FileRow] {
        try await database.writer.read { db in
            // 基準の行から `libraryId` と `seriesKey` を取る——呼び出し側に
            // 渡させない理由はプロトコルのコメント参照。
            guard let anchor = try Row.fetchOne(db, sql: """
                SELECT libraryId, seriesKey FROM managedFile WHERE id = ?
                """, arguments: [id.rawValue]) else { return [] }
            guard let key: String = anchor["seriesKey"], !key.isEmpty else { return [] }
            return try ManagedFileRecord.fetchAll(db, sql: """
                SELECT * FROM managedFile
                 WHERE libraryId = ? AND seriesKey = ? AND state <> 'trashed'
                 ORDER BY COALESCE(volumeNumber, 1e18), relativePath
                """, arguments: [anchor["libraryId"] as Int64, key]).map(\.fileRow)
        }
    }

    // MARK: - 読み取り

    // MARK: - 右ペインからの編集 [RP-10〜RP-12][CV-02〜CV-08]

    public func setFields(_ edit: FileFieldEdit, id: FileID) async throws {
        try await database.writer.write { db in
            // 正規化はここで行う [3.8 節]。`applyParsedFields` とまったく同じ
            // 導出を通すので、手で編集したシリーズ名でも表記ゆれの吸収
            // （`filesInSameSeries` の照合）が走査由来のものと揃う。
            let options = try Self.normalizationOptions(db, fileID: id)
            try db.execute(sql: """
                UPDATE managedFile SET
                    title = ?, titleOrigin = ?,
                    seriesName = ?, seriesKey = ?,
                    volumeNumber = ?, volumeKind = ?, volumeRaw = ?,
                    authorName = ?
                WHERE id = ?
                """, arguments: [
                    edit.title,
                    edit.titleOrigin.rawValue,
                    edit.seriesName,
                    edit.seriesName.map { TextNormalizer.normalize($0, options: options) },
                    edit.volume.number,
                    edit.volume.kind.rawValue,
                    edit.volume.raw,
                    edit.authorName,
                    id.rawValue])
            // 手で直したタイトル・シリーズ名も、その場で検索に出る [SR-03]。
            // ここを忘れると「直したのに検索で見つからない」という、
            // 画面からは理由の読み取れない形になる。
            try Self.refreshSearchKey(db, id: id, options: options)
        }
    }

    public func setCover(_ assignment: CoverAssignment, id: FileID) async throws {
        try await database.writer.write { db in
            // **`.userSpecified` 以外では `ref` を消す。** 残すと「自動に戻した
            // のに複製が参照されたまま」になり、起動時の掃除
            // （`UserCoverStore.purgeUnreferenced`）が永久に捨てられない。
            let ref = assignment.source == .userSpecified ? assignment.ref : nil
            try db.execute(sql: """
                UPDATE managedFile SET coverImageSource = ?, coverImageRef = ?
                 WHERE id = ?
                """, arguments: [assignment.source.rawValue, ref, id.rawValue])
        }
    }

    public func userCoverRefs(libraryID: LibraryID) async throws -> Set<String> {
        try await database.writer.read { db in
            let refs = try String.fetchAll(db, sql: """
                SELECT coverImageRef FROM managedFile
                 WHERE libraryId = ? AND coverImageSource = ? AND coverImageRef IS NOT NULL
                """, arguments: [libraryID.rawValue, CoverSource.userSpecified.rawValue])
            return Set(refs)
        }
    }

    public func row(id: FileID) async throws -> FileRow? {
        try await database.writer.read { db in
            try ManagedFileRecord.fetchOne(db, key: id.rawValue)?.fileRow
        }
    }

    public func query(_ q: FileQuery) async throws -> FilePage {
        try await database.writer.read { db in
            let (where_, args) = Self.whereClause(q)
            let total = try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM managedFile WHERE \(where_)",
                arguments: StatementArguments(args.map { Optional($0) })) ?? 0
            var pageArgs = args
            pageArgs.append(q.limit)
            pageArgs.append(q.offset)
            let rows = try ManagedFileRecord.fetchAll(db, sql: """
                SELECT * FROM managedFile WHERE \(where_)
                ORDER BY \(Self.orderClause(q)) LIMIT ? OFFSET ?
                """, arguments: StatementArguments(pageArgs.map { Optional($0) }))
            return FilePage(rows: rows.map(\.fileRow), totalCount: total)
        }
    }

    public func count(_ q: FileQuery) async throws -> Int {
        try await database.writer.read { db in
            let (where_, args) = Self.whereClause(q)
            return try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM managedFile WHERE \(where_)",
                                    arguments: StatementArguments(args.map { Optional($0) })) ?? 0
        }
    }

    /// フィルタに該当するファイルから、`scope` のフォルダ直下の子の名前を集める
    /// [VM-02][LF-14]。
    ///
    /// **1 度の問い合わせで「該当ファイル」と「該当ファイルを配下に持つフォルダ」
    /// の両方**が得られる。深い所にある該当ファイルは、最初のパス成分
    /// （＝直下のフォルダ名）へ畳まれて現れる。
    public func matchingChildNames(_ q: FileQuery) async throws -> Set<String> {
        // **必ず配下全体を見る。**直下だけに絞ると「該当ファイルを配下に持つ
        // フォルダ」を落とし、フィルタを掛けた瞬間に掘っていけなくなる。
        var recursive = q
        let folder: String
        switch q.scope {
        case .folder(let path, _):
            folder = path
            recursive.scope = .folder(path: path, recursive: true)
        case .library:
            folder = ""
        }
        // 位置は `sqliteOffsetAfter` で数える（`String.count` は使えない。
        // 同関数のコメント参照）。SELECT 節が先なので引数もこちらが先。
        let offset = Self.sqliteOffsetAfter(folder)
        let frozen = recursive
        return try await database.writer.read { db in
            // **引数の組み立てはこの中で行う**——`[any DatabaseValueConvertible]`
            // は Sendable ではないので、外で作ると閉包に渡せない（`query` も同じ形）。
            let (where_, whereArgs) = Self.whereClause(frozen)
            var args: [any DatabaseValueConvertible] = [offset, offset, offset, offset]
            args.append(contentsOf: whereArgs)
            let names = try String.fetchAll(db, sql: """
                SELECT DISTINCT CASE
                    WHEN instr(substr(relativePath, ?), '/') = 0
                        THEN substr(relativePath, ?)
                    ELSE substr(relativePath, ?, instr(substr(relativePath, ?), '/') - 1)
                END FROM managedFile WHERE \(where_)
                """, arguments: StatementArguments(args.map { Optional($0) }))
            return Set(names.filter { !$0.isEmpty })
        }
    }

    /// 直下のブックフォルダの名前 [IF-17]。
    ///
    /// **`whereClause` を使い回す**——ゴミ箱・保管庫の除外 [FI-02] と直下の
    /// 判定（`instr(substr(relativePath, ?), '/') = 0`）を自前で書き直すと、
    /// 除外条件が片方だけ古くなる。位置は `sqliteOffsetAfter` で数えること
    /// （`String.count` は書記素で数えるが SQLite はコードポイントで数える。
    /// 濁点を含むフォルダ名で 1 件も一致しなくなる [10章 §10.6 の実測]）。
    public func bookFolderChildNames(libraryID: LibraryID,
                                     relativePath: String) async throws -> Set<String> {
        var q = FileQuery(libraryID: libraryID)
        q.scope = .folder(path: relativePath, recursive: false)
        let frozen = q
        return try await database.writer.read { db in
            let (where_, whereArgs) = Self.whereClause(frozen)
            let names = try String.fetchAll(db, sql: """
                SELECT filename FROM managedFile
                 WHERE \(where_) AND isBookFolder = 1
                """, arguments: StatementArguments(whereArgs.map { Optional($0) }))
            return Set(names)
        }
    }

    /// 候補の相対パスのうち、条件に該当するものを返す [LF-14]。
    public func matchingRelativePaths(_ q: FileQuery,
                                      among candidates: [String]) async throws -> Set<String> {
        guard !candidates.isEmpty else { return [] }
        let frozen = q
        return try await database.writer.read { db in
            let (where_, whereArgs) = Self.whereClause(frozen)
            var found: Set<String> = []
            // **分割して問う。**理由は 2 つあり、実際に効いているのは後者。
            //
            // ① SQLite のホスト変数の上限は版・ビルドオプションによって 999 まで
            //    下がる。検索結果の上限（2,000 件）をそのまま並べると、GRDB が
            //    同梱する SQLite かシステムのものかで挙動が変わる。
            // ② **巨大な `IN` は桁違いに遅い** [実測]。1,805 件の候補で
            //    900 件ずつなら 0.20 秒、1 回にまとめると 11.14 秒（56 倍）。
            //
            // この環境の上限は高いので ① だけでは分割を外しても通ってしまう
            // （変異検証で確認済み）。**分割をやめると壊れるのは速度のほう。**
            for start in stride(from: 0, to: candidates.count, by: Self.maxBoundParameters) {
                let chunk = Array(candidates[start..<min(start + Self.maxBoundParameters,
                                                         candidates.count)])
                var args: [any DatabaseValueConvertible] = whereArgs
                args.append(contentsOf: chunk)
                let rows = try String.fetchAll(db, sql: """
                    SELECT relativePath FROM managedFile
                     WHERE \(where_) AND relativePath IN (\(Self.placeholders(chunk.count)))
                    """, arguments: StatementArguments(args.map { Optional($0) }))
                found.formUnion(rows)
            }
            return found
        }
    }

    /// 1 度の問い合わせに並べるホスト変数の上限。条件側の分も入るので
    /// 余裕を見て 900 にしてある（SQLite の既定は版により 999〜32,766）。
    /// **速度の観点でも 900 前後が要る**——上の実測を参照。
    static let maxBoundParameters = 900

    // MARK: - SQL の組み立て

    /// 「グループ内 OR × グループ間 AND」は `INTERSECT` で表す [LF-08〜LF-10][FI-01]。
    /// **メモリ上の索引は持たない**——実測で最悪 182 ms（目標 500 ms）[T-03]。
    static func whereClause(_ q: FileQuery) -> (String, [any DatabaseValueConvertible]) {
        var clauses = ["libraryId = ?"]
        var args: [any DatabaseValueConvertible] = [q.libraryID.rawValue]

        // [FI-02] ゴミ箱とアーカイブ済みを除く
        clauses.append("state = 'active'")
        if !q.includeArchived { clauses.append("isArchived = 0") }

        switch q.scope {
        case .library:
            break
        case .folder(let path, let recursive):
            if recursive {
                clauses.append("relativePath LIKE ? ESCAPE '\\'")
                args.append(likePrefix(path) + "%")
            } else {
                clauses.append("relativePath LIKE ? ESCAPE '\\'")
                args.append(likePrefix(path) + "%")
                clauses.append("instr(substr(relativePath, ?), '/') = 0")
                args.append(sqliteOffsetAfter(path))
            }
        }

        if let rating = q.ratingFilter {
            // [RT-03] 「以上」と「完全一致」。未評価は `rating = 0` なので
            // `.exact` の星 0 でそのまま表せる。
            clauses.append(rating.mode == .atLeast ? "rating >= ?" : "rating = ?")
            args.append(rating.stars)
        }

        if let text = q.searchText, !text.isEmpty {
            // 正規化済みの検索用カラムで比較する [SR-06][DB-03]。
            // 実測: 10 万件の全走査で 20.7 ms（目標 300 ms）[PF-04]
            clauses.append("searchKey LIKE ? ESCAPE '\\'")
            args.append("%" + escapeLike(TextNormalizer.searchKey(text)) + "%")
        }

        if !q.labelSelection.isEmpty {
            var parts: [String] = []
            // グループの順序を安定させる（同じ問い合わせが同じ SQL になるように）。
            for (_, labelIDs) in q.labelSelection.sorted(by: { $0.key.rawValue < $1.key.rawValue })
            where !labelIDs.isEmpty {
                parts.append("""
                    SELECT managedFileId FROM fileLabel
                     WHERE labelId IN (\(placeholders(labelIDs.count)))
                    """)
                args.append(contentsOf: labelIDs.sorted { $0.rawValue < $1.rawValue }.map(\.rawValue))
            }
            if !parts.isEmpty {
                clauses.append("id IN (\(parts.joined(separator: " INTERSECT ")))")
            }
        }

        return (clauses.joined(separator: " AND "), args)
    }

    static func orderClause(_ q: FileQuery) -> String {
        let direction = q.sort.ascending ? "ASC" : "DESC"
        let column: String
        switch q.sort.key {
        case .filename:   column = "filename"
        case .title:      column = "COALESCE(title, filename)"
        case .series:     column = "COALESCE(seriesKey, '')"
        case .volume:
            // numeric < none。巻数を持たないものは末尾へ [VM-15]。
            // （序列巻数は 2026-08 の仕様変更で廃止したので 2 段しかない。）
            return "CASE volumeKind WHEN 'numeric' THEN 0 ELSE 1 END \(direction), "
                + "COALESCE(volumeNumber, 0) \(direction), filename ASC"
        case .fileSize:   column = "fileSize"
        case .createdAt:  column = "createdAt"
        case .modifiedAt: column = "modifiedAt"
        case .rating:     column = "rating"
        }
        return "\(column) \(direction), id ASC"
    }

    static func placeholders(_ n: Int) -> String {
        Array(repeating: "?", count: n).joined(separator: ",")
    }

    /// `LIKE` のメタ文字を無効化する。`ESCAPE '\'` と組で使う。
    static func escapeLike(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "%", with: "\\%")
         .replacingOccurrences(of: "_", with: "\\_")
    }

    /// フォルダ配下を表す `LIKE` の前置き。空文字はライブラリ直下を指す。
    /// `substr(relativePath, ?)` に渡す 1 起点の位置。`path` とその直後の
    /// `/` を飛ばした次の文字を指す。
    ///
    /// **`String.count` を使ってはならない** [実測]。Swift はここを
    /// **書記素クラスタ**で数えるが、SQLite の `substr`/`length` は
    /// **コードポイント**で数える。macOS のファイル名は NFD で来るので
    /// （`フォルダ` = `フ ォ ル タ ゛` の 5 コードポイント／4 文字）、
    /// 濁点・半濁点を含むフォルダ名では位置が 1 つずつずれ、
    /// **「直下だけ」の照合が 1 件も一致しなくなる**——差分スキャンの
    /// 孤立判定と、フォルダ表示モードの一覧がまとめて空振りする。
    static func sqliteOffsetAfter(_ path: String) -> Int {
        path.isEmpty ? 1 : path.unicodeScalars.count + 2
    }

    static func likePrefix(_ path: String) -> String {
        path.isEmpty ? "" : escapeLike(path) + "/"
    }

    static func normalizationOptions(_ db: Database, libraryID: LibraryID) throws
        -> NormalizationOptions
    {
        let caseSensitive = try Bool.fetchOne(
            db, sql: "SELECT caseSensitive FROM library WHERE id = ?",
            arguments: [libraryID.rawValue]) ?? false
        return NormalizationOptions(caseSensitive: caseSensitive)
    }

    static func normalizationOptions(_ db: Database, fileID: FileID) throws
        -> NormalizationOptions
    {
        let caseSensitive = try Bool.fetchOne(db, sql: """
            SELECT library.caseSensitive FROM library
            JOIN managedFile ON managedFile.libraryId = library.id
            WHERE managedFile.id = ?
            """, arguments: [fileID.rawValue]) ?? false
        return NormalizationOptions(caseSensitive: caseSensitive)
    }
}
