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
            TextNormalizer.searchKey(stem, options: options),
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
                args.append(path.isEmpty ? 1 : path.count + 2)
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
        }
    }

    // MARK: - 読み取り

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
                args.append(path.isEmpty ? 1 : path.count + 2)
            }
        }

        if let rating = q.ratingFilter {
            if rating.unratedOnly {
                clauses.append("rating = 0")
            } else {
                clauses.append("rating >= ?")
                args.append(rating.minimum)
            }
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
