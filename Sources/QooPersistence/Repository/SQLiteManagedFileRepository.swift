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

    /// 走査の upsert 用。`id` と**現在の** `isArchived` を 1 回の問い合わせで取る。
    ///
    /// **別に SELECT を足さないための形。** 保管庫の出入りが起きた行だけ
    /// ラベル件数を数え直す [DB-02] 必要があるが、そのために 1 ファイルにつき
    /// 問い合わせを 1 本増やすと、5 万件の走査で実測 0.036 ms × 5 万 ≒ 1.8 秒が
    /// 上乗せされる。既に引いている行から一緒に読めば費用はゼロ。
    static func findForUpsert(_ db: Database, identity: FileIdentity) throws
        -> (id: FileID, isArchived: Bool)?
    {
        let stmt = try db.cachedStatement(sql:
            "SELECT id, isArchived FROM managedFile WHERE volumeUUID = ? AND inode = ?")
        guard let row = try Row.fetchOne(stmt, arguments: [identity.volumeUUID,
                                                           Int64(bitPattern: identity.inode)])
        else { return nil }
        return (FileID(rawValue: row["id"]), row["isArchived"])
    }

    /// 対象ファイルに紐づくラベルの、非正規化件数 [DB-02] を作り直す。
    ///
    /// **`fileCount` は「生きていて保管庫にも入っていない」ファイルだけを
    /// 数える**（`SQLiteLabelRepository.recount`）ので、`state` が変わるか
    /// 行が消えるたびに直さないと、ラベルフィルタと編集ウインドウの件数が
    /// 実態からずれていく。
    ///
    /// **消す・変える「前」に呼んで ID を集めること**——`fileLabel` は cascade
    /// で消えるので、後からでは誰を数え直せばよいか分からなくなる。
    static func labelIDsAttached(_ db: Database, to ids: [FileID]) throws -> [LabelID] {
        guard !ids.isEmpty else { return [] }
        let raw = try Int64.fetchAll(db, sql: """
            SELECT DISTINCT labelId FROM fileLabel
            WHERE managedFileId IN (\(placeholders(ids.count)))
            """, arguments: StatementArguments(ids.map(\.rawValue)))
        return raw.map { LabelID(rawValue: $0) }
    }

    /// タイトルから導く鍵（`searchKey` [SR-03] と `titleKey` [DU-02]）を
    /// 行の現在値から作り直す。
    ///
    /// タイトル・シリーズ名を書き換えた**あと**に呼ぶこと。**書いた値ではなく
    /// 行を読み直す**のが要点——`applyParsedFields` の `title` は
    /// `CASE WHEN titleOrigin = 'manual'` で据え置かれることがあるので、
    /// 渡された値から組み立てると手動編集した行だけ鍵が実態とずれる。
    ///
    /// **2 つの鍵を 1 回で書く。** どちらも「タイトルが変わったら作り直す」
    /// という同じ条件で、別々の関数に分けると片方だけ呼ぶ経路がいずれできる
    /// ——`searchKey` は 2-9 の時点で実際にそうなっていた（CLAUDE.md）。
    static func refreshDerivedKeys(_ db: Database, id: FileID) throws {
        let stmt = try db.cachedStatement(sql:
            "SELECT filename, title, seriesName FROM managedFile WHERE id = ?")
        guard let row = try Row.fetchOne(stmt, arguments: [id.rawValue]) else { return }
        let filename: String = row["filename"]
        let title: String? = row["title"]
        let key = ManagedFileSearchKey.make(
            stem: ManagedFileSearchKey.stem(ofFilename: filename),
            title: title, seriesName: row["seriesName"])
        // `nil` は「グループ化の対象外」——空文字にしてはならない [DU-02]。
        let titleKey = DuplicateGroupKey.titleKey(title: title)
        try db.execute(sql: "UPDATE managedFile SET searchKey = ?, titleKey = ? WHERE id = ?",
                       arguments: [key, titleKey, id.rawValue])
    }

    /// 再照合の候補を確度の高い順に返す [ID-03][ID3-02]。
    ///
    /// ① 同一相対パス + 同一サイズ ② 同一ファイル名 + 同一サイズ
    /// ③a 同一相対パス（サイズ違い）③b 同一ファイル名のみ。
    ///
    /// **生きている行を除くガードはここでは掛けない** [ID3-03]。呼び出し側
    /// （`ScanEngine.unclaimedCandidates` [ID3-08]）が実体を見て絞る——
    /// リポジトリはディスクを知らない。
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
            } else if path == snapshot.relativePath {
                // 同じ場所にあるがサイズが違う＝**その場での差し替え** [ID-03]③a。
                // 相対パスが同じならファイル名も必ず同じなので、`.nameOnly` の
                // 判定より**前**に見ること——逆にすると ③a が ③b に埋もれ、
                // 「同じ場所か」で出し分ける設定 [ID-13] が効かなくなる。
                confidence = .pathOnly
            } else if name == snapshot.filename {
                confidence = .nameOnly
            } else {
                continue
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
            var out: [FileID] = []
            out.reserveCapacity(snapshots.count)
            // 保管庫の出入りが起きた行 [FA-05]。ラベルの非正規化件数 [DB-02] は
            // 「生きていて保管庫にも入っていない」ファイルだけを数えるので、
            // ここを数え直さないとフィルタと編集ウインドウの件数がずれていく。
            // **`state` について 2-14 で直したのと同じ穴**——外部で
            // `.qooarchive` へ出し入れされると走査だけで値が変わる。
            var vaultFlipped: [FileID] = []
            for snapshot in snapshots {
                if let existing = try Self.findForUpsert(db, identity: snapshot.identity) {
                    if existing.isArchived != snapshot.isArchived {
                        vaultFlipped.append(existing.id)
                    }
                    // パス・ファイル名の変化を追従更新する [ID-02]
                    try Self.updateInPlace(db, id: existing.id, snapshot: snapshot)
                    out.append(existing.id)
                } else {
                    var record = ManagedFileRecord(snapshot: snapshot)
                    try record.insert(db)
                    out.append(FileID(rawValue: record.id ?? 0))
                }
            }
            // 変えた**あと**でよい——`fileLabel` の行は消えないので、
            // 誰を数え直すかは後からでも分かる（削除の経路とは事情が違う）。
            // 900 件ずつに区切るのは、フォルダごと外から出し入れされると
            // 一度に数千件が変わりうるため（ホスト変数の上限が低いビルドで
            // 落ちる。壊れるのは上限の低い環境だけなので、通ることを理由に
            // 外さないこと）。
            for chunk in stride(from: 0, to: vaultFlipped.count, by: 900) {
                let slice = Array(vaultFlipped[chunk..<min(chunk + 900, vaultFlipped.count)])
                let labels = try Self.labelIDsAttached(db, to: slice)
                try SQLiteLabelRepository.recount(db, labelIDs: labels)
            }
            return out
        }
    }

    static func updateInPlace(_ db: Database, id: FileID,
                              snapshot: FileSnapshot) throws {
        let stem = snapshot.nameWithoutExtension
        let stmt = try db.cachedStatement(sql: """
            UPDATE managedFile SET
                relativePath = ?, filename = ?, normalizedName = ?, searchKey = ?,
                fileSize = ?, modifiedAt = ?, isBookFolder = ?,
                -- 保管庫の中かは**観測した位置**が決める [SY-10][FA-05]。外部で
                -- 出し入れされても次の走査で追随する。`archivedFromPath` には
                -- 触れない——元の場所を知っているのは移した操作だけ [FA-04]。
                isArchived = ?,
                -- ゴミ箱から元の場所へ戻った場合は active へ戻す [TR-04]
                state = CASE WHEN state IN ('orphaned', 'offline') THEN 'active' ELSE state END,
                trashedAt = CASE WHEN state IN ('orphaned', 'offline') THEN NULL ELSE trashedAt END
            WHERE id = ?
            """)
        try stmt.execute(arguments: [
            snapshot.relativePath, snapshot.filename,
            TextNormalizer.normalize(stem),
            // **stem だけ**を書く [SR-03]。タイトル・シリーズを混ぜた最終形は
            // 直後に走る `applyParsedFields` が書く——走査は upsert と
            // `applyParsedFields` を必ず対にして呼ぶ（`ScanEngine` の ②→④）。
            // ここで DB のタイトルを読み直すと、走査の内側の輪で 1 ファイルにつき
            // SELECT が 1 本増える。**この対を崩す経路を作らないこと。**
            ManagedFileSearchKey.make(stem: stem, title: nil, seriesName: nil),
            snapshot.fileSize,
            snapshot.modifiedAt.timeIntervalSinceReferenceDate,
            snapshot.isBookFolder, snapshot.isArchived, id.rawValue])
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
            // **先に集める**——`state` が変われば `fileCount` の母数が変わる
            // ので、変更後のラベルを引き直すのではなく変更前の紐づけから引く。
            let labels = try Self.labelIDsAttached(db, to: ids)
            try db.execute(sql: """
                UPDATE managedFile SET state = ? WHERE id IN (\(Self.placeholders(ids.count)))
                """, arguments: StatementArguments([state.rawValue] + ids.map(\.rawValue)) ?? StatementArguments())
            try SQLiteLabelRepository.recount(db, labelIDs: labels)
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
            // 孤立にする前に、影響を受けるラベルを控える [DB-02]。
            let labels = try Int64.fetchAll(db, sql: """
                SELECT DISTINCT labelId FROM fileLabel
                WHERE managedFileId IN (SELECT id FROM managedFile WHERE \(clause))
                """, arguments: StatementArguments(args.map { Optional($0) }))
                .map { LabelID(rawValue: $0) }
            try db.execute(sql: "UPDATE managedFile SET state = 'orphaned' WHERE \(clause)",
                           arguments: StatementArguments(args.map { Optional($0) }))
            try SQLiteLabelRepository.recount(db, labelIDs: labels)
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

    /// パーサの結果を書き戻す [RC-01][PR-01]。
    ///
    /// **基本情報スコープが保護されていれば、タイトル・シリーズ名・巻数・
    /// 著者名の 4 つとも据え置く** [PR-02]。置き換える前はタイトルだけを
    /// 守っており、手で直したシリーズ名は次の走査で黙って自動値へ戻っていた。
    ///
    /// **`lastParsedFormatID` と `libraryTypeMismatch` は保護されていても
    /// 更新する。** あれは「どのフォーマットに当たったか」という走査の観測
    /// 結果であって、利用者が決めたメタデータではない——止めると未整理一覧
    /// [UR3-01] の判定が保護済みのファイルだけ古いまま凍る。
    public func applyParsedFields(_ fields: ParsedFileFields?, to id: FileID) async throws {
        try await database.writer.write { db in
            let basicProtected = ProtectionScopeCoding.decode(try String.fetchOne(db, sql:
                "SELECT protectedScopes FROM managedFile WHERE id = ?",
                arguments: [id.rawValue])).contains(.basic)

            guard let fields else {
                if basicProtected {
                    try db.execute(sql: """
                        UPDATE managedFile SET lastParsedFormatID = NULL,
                            libraryTypeMismatch = 0
                        WHERE id = ?
                        """, arguments: [id.rawValue])
                } else {
                    try db.execute(sql: """
                        UPDATE managedFile SET seriesName = NULL, seriesKey = NULL,
                            volumeNumber = NULL, volumeKind = 'none', volumeRaw = NULL,
                            authorName = NULL, title = NULL,
                            lastParsedFormatID = NULL, libraryTypeMismatch = 0
                        WHERE id = ?
                        """, arguments: [id.rawValue])
                }
                try Self.refreshDerivedKeys(db, id: id)
                return
            }
            if basicProtected {
                try db.execute(sql: """
                    UPDATE managedFile SET lastParsedFormatID = ?, libraryTypeMismatch = ?
                    WHERE id = ?
                    """, arguments: [fields.matchedFormatID.uuidString,
                                     fields.libraryTypeMismatch, id.rawValue])
            } else {
                try db.execute(sql: """
                    UPDATE managedFile SET
                        title = ?, seriesName = ?, seriesKey = ?,
                        volumeNumber = ?, volumeKind = ?, volumeRaw = ?,
                        authorName = ?, lastParsedFormatID = ?, libraryTypeMismatch = ?
                    WHERE id = ?
                    """, arguments: [
                        fields.title,
                        fields.seriesName,
                        fields.seriesName.map { TextNormalizer.normalize($0) },
                        fields.volume.number,
                        fields.volume.kind.rawValue,
                        fields.volume.raw,
                        fields.authorName,
                        fields.matchedFormatID.uuidString,
                        fields.libraryTypeMismatch,
                        id.rawValue])
            }
            // タイトル・シリーズ名も検索対象 [SR-03]。**書いた値ではなく行を
            // 読み直す**（保護されていれば据え置かれるため）。
            try Self.refreshDerivedKeys(db, id: id)
        }
    }

    // MARK: - メタデータの保護 [PR-01〜PR-09]

    public func setProtectedScopes(_ scopes: [FileID: Set<ProtectionScope>]) async throws {
        guard !scopes.isEmpty else { return }
        try await database.writer.write { db in
            let stmt = try db.cachedStatement(sql:
                "UPDATE managedFile SET protectedScopes = ? WHERE id = ?")
            for (id, set) in scopes {
                try stmt.execute(arguments: [ProtectionScopeCoding.encode(set), id.rawValue])
            }
        }
    }

    public func protectedScopes(ids: [FileID]) async throws -> [FileID: Set<ProtectionScope>] {
        guard !ids.isEmpty else { return [:] }
        return try await database.writer.read { db in
            var result: [FileID: Set<ProtectionScope>] = [:]
            // ホスト変数の上限を避けて分ける（`setRating` と同じ事情。**外しても
            // 結果は正しく、壊れるのは速度のほう**なので変異検証では空振りする）。
            for start in stride(from: 0, to: ids.count, by: Self.maxBoundParameters) {
                let chunk = Array(ids[start..<min(start + Self.maxBoundParameters, ids.count)])
                let rows = try Row.fetchAll(db, sql: """
                    SELECT id, protectedScopes FROM managedFile
                    WHERE id IN (\(Self.placeholders(chunk.count)))
                    """, arguments: StatementArguments(chunk.map { Optional($0.rawValue) }))
                for row in rows {
                    result[FileID(rawValue: row["id"])] =
                        ProtectionScopeCoding.decode(row["protectedScopes"])
                }
            }
            return result
        }
    }

    // MARK: - 埋め込みメタデータ [EM-07]

    public func embeddedMetadataCache(ids: [FileID]) async throws
        -> [FileID: EmbeddedMetadataCacheEntry]
    {
        guard !ids.isEmpty else { return [:] }
        return try await database.writer.read { db in
            // **ここで区切る。** 走査は 1 チャンク（`scanBatchSize`）ぶんしか
            // 渡さないが、再マッチング [AL-34] は未解決の全件を渡す
            // ——`unresolvedBulkThreshold`（500）を超える状況はこの機能が
            // まさに想定しているもので、ホスト変数の上限が低いビルドでは
            // `too many SQL variables` で**再マッチングが丸ごと失敗する**
            // （足したフォーマットが 1 件も適用されない）。呼び出し側に
            // 区切りを求めると、次に足す呼び出し元が同じ穴を開ける。
            //
            // **この区切りを外しても、この環境のテストは通る**［既知の空振り］
            // ——SQLite 3.51 の `SQLITE_MAX_VARIABLE_NUMBER` は既定 32,766 で、
            // 1,500 件では届かない。壊れるのは上限の低いビルドと**速度**の
            // ほうで（`matchingRelativePaths` の実測では 900 件区切り 0.20 秒に
            // 対し 1 文 11.14 秒＝56 倍）、通ることを理由に外さないこと。
            // `setRating` / `matchingRelativePaths` とまったく同じ事情。
            var rows: [Row] = []
            for start in stride(from: 0, to: ids.count, by: Self.maxBoundParameters) {
                let chunk = Array(ids[start..<min(start + Self.maxBoundParameters, ids.count)])
                rows += try Row.fetchAll(db, sql: """
                    SELECT id, metadataStamp, metadataJSON FROM managedFile
                    WHERE id IN (\(Self.placeholders(chunk.count))) AND metadataStamp IS NOT NULL
                    """, arguments: StatementArguments(chunk.map { $0.rawValue }))
            }
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

    public func setFields(_ edit: FileFieldEdit, id: FileID,
                          protectedScopes: Set<ProtectionScope>) async throws {
        try await database.writer.write { db in
            // **保護も同じトランザクションで** [PR-03]。
            try db.execute(sql: "UPDATE managedFile SET protectedScopes = ? WHERE id = ?",
                           arguments: [ProtectionScopeCoding.encode(protectedScopes),
                                       id.rawValue])
            // 正規化はここで行う [3.8 節]。`applyParsedFields` とまったく同じ
            // 導出を通すので、手で編集したシリーズ名でも表記ゆれの吸収
            // （`filesInSameSeries` の照合）が走査由来のものと揃う。
            try db.execute(sql: """
                UPDATE managedFile SET
                    title = ?,
                    seriesName = ?, seriesKey = ?,
                    volumeNumber = ?, volumeKind = ?, volumeRaw = ?,
                    authorName = ?
                WHERE id = ?
                """, arguments: [
                    edit.title,
                    edit.seriesName,
                    edit.seriesName.map { TextNormalizer.normalize($0) },
                    edit.volume.number,
                    edit.volume.kind.rawValue,
                    edit.volume.raw,
                    edit.authorName,
                    id.rawValue])
            // 手で直したタイトル・シリーズ名も、その場で検索に出る [SR-03]。
            // ここを忘れると「直したのに検索で見つからない」という、
            // 画面からは理由の読み取れない形になる。
            try Self.refreshDerivedKeys(db, id: id)
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
            guard let grouped = Self.groupedSubquery(q, where_: where_) else {
                // グループ化しない従来の経路。
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
            // グループ化する経路 [DU-04〜DU-06][DU-11]。**総数はグループ数**
            // ——行数を出すと、畳んだぶんだけ一覧より大きい数がステータスバーへ出る。
            // 条件が UNION ALL の両側に現れるので、引数もその回数だけ繰り返す。
            let groupArgs = Array(repeating: args, count: grouped.repeatsWhereArgs).flatMap { $0 }
            var pageArgs = groupArgs
            pageArgs.append(q.limit)
            pageArgs.append(q.offset)
            // **総数は同じ問い合わせの中で数える。** 別に
            // `SELECT COUNT(*) FROM (…)` を撃つと、**高い窓関数をページごとに
            // 2 回走らせる**ことになる［実測: 5 万件で 131 ms → 298 ms と
            // 倍以上になっていた］。`COUNT(*) OVER ()` は絞り込んだ後の
            // 行数を同じ走査で返す。
            let raw = try Row.fetchAll(db, sql: """
                SELECT *, COUNT(*) OVER () AS totalGroups FROM (\(grouped.sql))
                ORDER BY \(Self.orderClause(q)) LIMIT ? OFFSET ?
                """, arguments: StatementArguments(pageArgs.map { Optional($0) }))
            // 行が 1 つも返らなければ総数を読む先が無い（末尾より後ろを
            // 要求した場合）。そのときだけ数え直す——**0 と決めつけない。**
            let total: Int = try raw.first.map { $0["totalGroups"] ?? 0 }
                ?? (Int.fetchOne(db, sql: "SELECT COUNT(*) FROM (\(grouped.sql))",
                                 arguments: StatementArguments(
                                    groupArgs.map { Optional($0) })) ?? 0)
            var rows: [FileRow] = []
            var counts: [FileID: Int] = [:]
            rows.reserveCapacity(raw.count)
            for r in raw {
                let row = try ManagedFileRecord(row: r).fileRow
                rows.append(row)
                let n: Int = r["dupCount"] ?? 1
                if n > 1 { counts[row.id] = n }      // 1 件だけの組は「重複」ではない
            }
            return FilePage(rows: rows, totalCount: total, duplicateCounts: counts)
        }
    }

    /// 同じ作品を 1 行に畳む問い合わせ [DU-02][DU-05][DU-06]。
    ///
    /// グループ化しないときは `nil`——呼び出し側は従来の経路を通る。
    /// 返り値の `repeatsWhereArgs` が 2 のときは、`where_` の引数を
    /// **2 回続けて**渡すこと（下の UNION ALL が両側で同じ条件を使う）。
    ///
    /// **タイトルの有無で 2 つに割ってある。**「タイトルが無い行は決して
    /// 畳まない」[DU-02] を、`COALESCE(titleKey, …)` という一区画一意な式では
    /// なく**問い合わせの形そのもの**で表す——不変条件が式の細工に依存せず、
    /// 読み手にも分かりやすい。
    ///
    /// **［実測］この分割は速度のためには効かなかった。** `COALESCE` が索引を
    /// 使えないのは事実で（`USE TEMP B-TREE FOR ORDER BY` → 素の列なら
    /// `mf_lib_titlekey` を使い `LAST TERM OF ORDER BY` だけになる）、そこが
    /// 5 万件で 308 ms の原因だと見込んで割ったが、**計画は変わったのに時間は
    /// 300 ms でほとんど動かなかった**。支配的なのは窓関数そのもの——
    /// `COUNT(*) OVER` と `ROW_NUMBER()` は区画全体を見るので、`LIMIT` を
    /// 先に効かせられず、ページを送るたびに全件を処理する。
    ///
    /// 現状は目標（500 ms）の内側なので、この形のまま受け入れている。
    /// **グループ化は既定で無効** [DU-01] なので、費用を払うのは自分で
    /// 有効にした利用者だけである。速くするなら「代表かどうか」を列として
    /// 持たせるしかないが、**評価を変えると代表が変わる** [DU-05] ため
    /// 古くなりやすく、割に合うかは別途測ってから決めること。
    ///
    /// **代表の決定順は `DuplicateSelection.precedes` と 1 対 1 で対応する。**
    /// 食い違うと、一覧に出る代表と比較ビューの並びが噛み合わなくなる。
    /// 自然順は専用の照合（`QooDatabase.naturalOrder`）で、Swift 側と
    /// **同じ `localizedStandardCompare`** を呼ぶ。一致は
    /// `DuplicateGroupingQueryTests` が固定している。
    static func groupedSubquery(_ q: FileQuery, where_: String)
        -> (sql: String, repeatsWhereArgs: Int)?
    {
        guard let partition = partitionExpression(q.grouping) else { return nil }
        let onlyDuplicates = q.duplicatesOnly ? " AND dupCount > 1" : ""
        let folded = """
            SELECT * FROM (
              SELECT managedFile.*,
                     COUNT(*) OVER dupWindow AS dupCount,
                     ROW_NUMBER() OVER (
                       PARTITION BY \(partition)
                       ORDER BY rating DESC, fileSize DESC,
                                filename COLLATE qooNaturalOrder ASC, id ASC
                     ) AS dupRank
                FROM managedFile
               WHERE \(where_) AND titleKey IS NOT NULL
              WINDOW dupWindow AS (PARTITION BY \(partition))
            ) WHERE dupRank = 1\(onlyDuplicates)
            """
        // 「重複のみ」[DU-11] のときは、タイトルの無い行は定義上 1 件の組
        // なので出さない——2 本目そのものを付けない。
        guard !q.duplicatesOnly else { return (folded, 1) }
        return ("""
            \(folded)
            UNION ALL
            SELECT managedFile.*, 1 AS dupCount, 1 AS dupRank
              FROM managedFile
             WHERE \(where_) AND titleKey IS NULL
            """, 2)
    }

    /// 区画の式 [DU-02]。
    ///
    /// **タイトルを取れなかった行は、1 行ずつ独立した区画にする。**
    /// SQLite の `PARTITION BY` は NULL どうしを同じ区画と見なすので、素の
    /// `titleKey` で区切ると**タイトルの無いファイル全部が 1 グループに畳まれ、
    /// 1 行を残して画面から消える**——未解決ファイル [AL-30] は蔵書によっては
    /// 数千件あるので、実害になる。`DuplicateGroupKey.make` が `nil` を返すのと
    /// 同じ判断を、SQL 側でも守る。
    static func partitionExpression(_ mode: DuplicateGrouping) -> String? {
        // **`titleKey IS NOT NULL` に絞った側でしか使わない**ので、素の列で
        // よい（NULL の行は別の枝を通り、畳まれない）。素の列にしておくと
        // 索引 `mf_lib_titlekey` がそのまま効く。
        switch mode {
        case .off:              return nil
        case .byTitle:          return "titleKey"
        case .byTitleAndVolume: return "titleKey, volumeNumber, volumeKind"
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

    /// 直下の蔵書の「ファイル名 → 行 ID」[RL3-01]。
    ///
    /// `bookFolderChildNames` と同じく `whereClause` を使い回す——既定の絞り
    /// （active・保管庫外 [FI-02]）を通るので、孤立・保管庫のレコードは
    /// ラベル付けの対象にならない。
    public func fileIDsByChildName(libraryID: LibraryID,
                                   relativePath: String) async throws -> [String: FileID] {
        var q = FileQuery(libraryID: libraryID)
        q.scope = .folder(path: relativePath, recursive: false)
        let frozen = q
        return try await database.writer.read { db in
            let (where_, whereArgs) = Self.whereClause(frozen)
            let rows = try Row.fetchAll(db, sql: """
                SELECT filename, id FROM managedFile
                 WHERE \(where_)
                """, arguments: StatementArguments(whereArgs.map { Optional($0) }))
            var result: [String: FileID] = [:]
            for row in rows {
                result[row["filename"]] = FileID(rawValue: row["id"])
            }
            return result
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

        // 未整理だけに絞る [UR3-01][UR3-05]。**テーブル名で修飾する**
        // ——`groupedSubquery` はこの句を `FROM managedFile` の窓関数つき
        // 副問い合わせにも埋めるので、素の `id` では曖昧になりうる。
        if let unresolved = q.unresolvedFilter {
            let pendingOnly = unresolved == .pending ? " AND unresolvedFile.isIgnored = 0" : ""
            clauses.append("EXISTS (SELECT 1 FROM unresolvedFile"
                           + " WHERE unresolvedFile.managedFileId = managedFile.id\(pendingOnly))")
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

}
