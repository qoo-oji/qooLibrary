//
//  LabelRepository の SQLite 実装 [LB-01〜LB-07][LA-01〜LA-09][RC-04][DB-02][IX-03][IX-04]。
//
import Foundation
import GRDB
import QooKit

public struct SQLiteLabelRepository: LabelRepository, Sendable {
    let database: QooDatabase

    public init(database: QooDatabase) {
        self.database = database
    }

    // MARK: - 読み取り

    public func groups(libraryID: LibraryID) async throws -> [LabelGroupSummary] {
        try await database.writer.read { db in
            try Row.fetchAll(db, sql: """
                SELECT labelGroup.*,
                       (SELECT COUNT(*) FROM label
                         WHERE label.labelGroupId = labelGroup.id AND label.isArchived = 0) AS labelCount
                FROM labelGroup WHERE libraryId = ? ORDER BY displayOrder, groupIndex
                """, arguments: [libraryID.rawValue]).map(Self.groupSummary)
        }
    }

    public func group(libraryID: LibraryID, index: Int) async throws -> LabelGroupSummary? {
        try await database.writer.read { db in
            try Row.fetchOne(db, sql: """
                SELECT labelGroup.*,
                       (SELECT COUNT(*) FROM label
                         WHERE label.labelGroupId = labelGroup.id AND label.isArchived = 0) AS labelCount
                FROM labelGroup WHERE libraryId = ? AND groupIndex = ?
                """, arguments: [libraryID.rawValue, index]).map(Self.groupSummary)
        }
    }

    static func groupSummary(_ row: Row) -> LabelGroupSummary {
        LabelGroupSummary(
            id: LabelGroupID(rawValue: row["id"]),
            libraryID: LibraryID(rawValue: row["libraryId"]),
            index: row["groupIndex"], name: row["name"],
            colorHexLight: row["colorHexLight"], colorHexDark: row["colorHexDark"],
            displayOrder: row["displayOrder"], labelCount: row["labelCount"])
    }

    public func labels(groupID: LabelGroupID, includeArchived: Bool) async throws -> [LabelSummary] {
        try await database.writer.read { db in
            let sql = """
                SELECT * FROM label WHERE labelGroupId = ?
                \(includeArchived ? "" : "AND isArchived = 0")
                ORDER BY isPinned DESC, name
                """
            return try LabelRecord.fetchAll(db, sql: sql, arguments: [groupID.rawValue])
                .map(Self.summary)
        }
    }

    static func summary(_ r: LabelRecord) -> LabelSummary {
        LabelSummary(id: LabelID(rawValue: r.id ?? 0), groupID: LabelGroupID(rawValue: r.labelGroupId),
                     name: r.name, normalizedName: r.normalizedName, colorHex: r.colorHex,
                     isPinned: r.isPinned, isArchived: r.isArchived, fileCount: r.fileCount)
    }

    public func labelIDs(fileID: FileID) async throws -> [(labelID: LabelID, origin: LabelOrigin)] {
        try await database.writer.read { db in
            try Row.fetchAll(db, sql:
                "SELECT labelId, origin FROM fileLabel WHERE managedFileId = ?",
                arguments: [fileID.rawValue]
            ).map { (LabelID(rawValue: $0["labelId"]),
                     LabelOrigin(rawValue: $0["origin"]) ?? .auto) }
        }
    }

    // MARK: - 書き込み

    /// 複数ファイルの紐づけを 1 度に読む [RL-04][RP-02]。
    public func assignments(fileIDs: [FileID]) async throws -> [FileID: [LabelID: LabelOrigin]] {
        guard !fileIDs.isEmpty else { return [:] }
        return try await database.writer.read { db in
            var result: [FileID: [LabelID: LabelOrigin]] = [:]
            // ホスト変数の上限を避けて分ける（`setRating` と同じ事情。**外しても
            // 結果は正しく、壊れるのは速度のほう**なので変異検証では空振りする）。
            let step = SQLiteManagedFileRepository.maxBoundParameters
            for start in stride(from: 0, to: fileIDs.count, by: step) {
                let chunk = Array(fileIDs[start..<min(start + step, fileIDs.count)])
                let rows = try Row.fetchAll(db, sql: """
                    SELECT managedFileId, labelId, origin FROM fileLabel
                    WHERE managedFileId IN (\(SQLiteManagedFileRepository.placeholders(chunk.count)))
                    """, arguments: StatementArguments(chunk.map { Optional($0.rawValue) }))
                for row in rows {
                    let file = FileID(rawValue: row["managedFileId"])
                    let label = LabelID(rawValue: row["labelId"])
                    let origin = LabelOrigin(rawValue: row["origin"]) ?? .auto
                    result[file, default: [:]][label] = origin
                }
            }
            return result
        }
    }


    /// 無ければ作る。一意性は `(groupID, 正規化名)` [LB-01][N-03][NM-06][LA-07]。
    /// **表示名は最初に登録された原文**を使う [N-03]。
    public func ensureLabel(groupID: LabelGroupID, name: String) async throws -> LabelID {
        try await database.writer.write { db in
            try Self.ensureLabel(db, groupID: groupID, name: name)
        }
    }

    static func ensureLabel(_ db: Database, groupID: LabelGroupID, name: String) throws -> LabelID {
        let options = try normalizationOptions(db, groupID: groupID)
        let key = TextNormalizer.normalize(name, options: options)
        let stmt = try db.cachedStatement(sql:
            "SELECT id FROM label WHERE labelGroupId = ? AND normalizedName = ?")
        if let existing = try Int64.fetchOne(stmt, arguments: [groupID.rawValue, key]) {
            return LabelID(rawValue: existing)
        }
        var record = LabelRecord(id: nil, labelGroupId: groupID.rawValue,
                                 name: TextNormalizer.display(name), normalizedName: key,
                                 colorHex: nil, isPinned: false, isArchived: false, fileCount: 0)
        try record.insert(db)
        return LabelID(rawValue: record.id ?? 0)
    }

    public func assign(fileID: FileID, labelID: LabelID, origin: LabelOrigin) async throws {
        try await database.writer.write { db in
            try Self.assign(db, fileID: fileID, labelID: labelID, origin: origin)
        }
    }

    static func assign(_ db: Database, fileID: FileID, labelID: LabelID,
                       origin: LabelOrigin) throws {
        let existing = try String.fetchOne(db, sql:
            "SELECT origin FROM fileLabel WHERE managedFileId = ? AND labelId = ?",
            arguments: [fileID.rawValue, labelID.rawValue])
        try db.execute(sql: """
            INSERT INTO fileLabel (managedFileId, labelId, origin, assignedAt)
            VALUES (?, ?, ?, ?)
            ON CONFLICT (managedFileId, labelId) DO UPDATE SET origin = excluded.origin
            """, arguments: [fileID.rawValue, labelID.rawValue, origin.rawValue,
                             Date().timeIntervalSinceReferenceDate])
        // [IX-03] 件数の増分更新。`manuallyRemoved` は「付いていない」扱い。
        let wasCounted = existing.map { $0 != LabelOrigin.manuallyRemoved.rawValue } ?? false
        let isCounted = origin != .manuallyRemoved
        if isCounted && !wasCounted { try adjustCount(db, labelID: labelID, by: 1) }
        if !isCounted && wasCounted { try adjustCount(db, labelID: labelID, by: -1) }
    }

    /// `markManuallyRemoved` を立てると、再計算で復活させてはいけない印になる [RC-04]。
    public func unassign(fileID: FileID, labelID: LabelID, markManuallyRemoved: Bool) async throws {
        try await database.writer.write { db in
            try Self.unassign(db, fileID: fileID, labelID: labelID,
                              markManuallyRemoved: markManuallyRemoved)
        }
    }

    static func unassign(_ db: Database, fileID: FileID, labelID: LabelID,
                         markManuallyRemoved: Bool) throws {
        let existing = try String.fetchOne(db, sql:
            "SELECT origin FROM fileLabel WHERE managedFileId = ? AND labelId = ?",
            arguments: [fileID.rawValue, labelID.rawValue])
        guard let existing else {
            if markManuallyRemoved {
                try db.execute(sql: """
                    INSERT INTO fileLabel (managedFileId, labelId, origin, assignedAt)
                    VALUES (?, ?, 'manuallyRemoved', ?)
                    """, arguments: [fileID.rawValue, labelID.rawValue,
                                     Date().timeIntervalSinceReferenceDate])
            }
            return
        }
        let wasCounted = existing != LabelOrigin.manuallyRemoved.rawValue
        if markManuallyRemoved {
            try db.execute(sql: """
                UPDATE fileLabel SET origin = 'manuallyRemoved'
                WHERE managedFileId = ? AND labelId = ?
                """, arguments: [fileID.rawValue, labelID.rawValue])
        } else {
            try db.execute(sql: "DELETE FROM fileLabel WHERE managedFileId = ? AND labelId = ?",
                           arguments: [fileID.rawValue, labelID.rawValue])
        }
        if wasCounted { try adjustCount(db, labelID: labelID, by: -1) }
    }

    /// 1 つのラベルの紐づけを、指定した状態へ揃える [RL-01][RL-07]。
    ///
    /// **1 トランザクション**で書く [RP2-04]——一括付与 [RP-02] の途中で失敗
    /// したときに、半分だけ付いた状態を残さない。`execute()` と `undo()` の
    /// どちらもこれを通る。
    ///
    /// **この原子性は変異検証では空振りする**——書き込みを 1 件ずつのトランザクション
    /// に割っても、失敗を注入しない限り結果は同じになるため。壊れるのは
    /// 「途中で失敗したときに半端な状態が残らない」という性質のほうなので、
    /// 通ることを理由に割らないこと（`setRating` の 900 件分割と同じ事情）。
    public func applyAssignments(labelID: LabelID,
                                 _ changes: [LabelAssignmentChange]) async throws {
        guard !changes.isEmpty else { return }
        try await database.writer.write { db in
            for change in changes {
                if let origin = change.origin {
                    try Self.assign(db, fileID: change.fileID, labelID: labelID, origin: origin)
                } else {
                    try Self.unassign(db, fileID: change.fileID, labelID: labelID,
                                      markManuallyRemoved: false)
                }
            }
        }
    }

    /// 1 ファイルの**自動**ラベルを丸ごと置き換える [RC-01][RC-04]。
    ///
    /// `manual` と `manuallyRemoved` には触れない。`manuallyRemoved` の印が付いた
    /// ラベルは、再計算で当たっても付け直さない——「再計算で復活させてはいけない」
    /// をこの 1 箇所で守る。
    public func replaceAutoLabels(fileID: FileID, labelIDs: Set<LabelID>) async throws {
        try await database.writer.write { db in
            try Self.replaceAutoLabels(db, fileID: fileID, labelIDs: labelIDs)
        }
    }

    static func replaceAutoLabels(_ db: Database, fileID: FileID, labelIDs: Set<LabelID>) throws {
        let current = try Row.fetchAll(db, sql:
            "SELECT labelId, origin FROM fileLabel WHERE managedFileId = ?",
            arguments: [fileID.rawValue])
        let manuallyRemoved = Set(current
            .filter { ($0["origin"] as String) == LabelOrigin.manuallyRemoved.rawValue }
            .map { LabelID(rawValue: $0["labelId"] as Int64) })
        let currentAuto = Set(current
            .filter { ($0["origin"] as String) == LabelOrigin.auto.rawValue }
            .map { LabelID(rawValue: $0["labelId"] as Int64) })
        let wanted = labelIDs.subtracting(manuallyRemoved)          // [RC-04]

        for id in currentAuto.subtracting(wanted) {
            try db.execute(sql: "DELETE FROM fileLabel WHERE managedFileId = ? AND labelId = ?",
                           arguments: [fileID.rawValue, id.rawValue])
            try adjustCount(db, labelID: id, by: -1)
        }
        let now = Date().timeIntervalSinceReferenceDate
        for id in wanted.subtracting(currentAuto) {
            // 手動で付いているものは origin を変えない（手動の意思を残す）。
            let existing = try String.fetchOne(db, sql:
                "SELECT origin FROM fileLabel WHERE managedFileId = ? AND labelId = ?",
                arguments: [fileID.rawValue, id.rawValue])
            guard existing == nil else { continue }
            try db.execute(sql: """
                INSERT INTO fileLabel (managedFileId, labelId, origin, assignedAt)
                VALUES (?, ?, 'auto', ?)
                """, arguments: [fileID.rawValue, id.rawValue, now])
            try adjustCount(db, labelID: id, by: 1)
        }
    }

    /// ラベルの統合 [LB-07]。移動先に既にある紐づけは捨てる。
    public func merge(_ source: LabelID, into target: LabelID) async throws {
        guard source != target else { return }
        try await database.writer.write { db in
            try db.execute(sql: """
                UPDATE OR IGNORE fileLabel SET labelId = ? WHERE labelId = ?
                """, arguments: [target.rawValue, source.rawValue])
            try db.execute(sql: "DELETE FROM label WHERE id = ?", arguments: [source.rawValue])
            try Self.recount(db, labelIDs: [target])
        }
    }

    public func rename(_ id: LabelID, to name: String) async throws {
        try await database.writer.write { db in
            guard let record = try LabelRecord.fetchOne(db, key: id.rawValue) else { return }
            let options = try Self.normalizationOptions(
                db, groupID: LabelGroupID(rawValue: record.labelGroupId))
            try db.execute(sql: "UPDATE label SET name = ?, normalizedName = ? WHERE id = ?",
                           arguments: [name, TextNormalizer.normalize(name, options: options),
                                       id.rawValue])
        }
    }

    public func setArchived(_ ids: [LabelID], _ archived: Bool) async throws {
        guard !ids.isEmpty else { return }
        try await database.writer.write { db in
            try db.execute(sql: """
                UPDATE label SET isArchived = ? WHERE id IN (\(SQLiteManagedFileRepository.placeholders(ids.count)))
                """, arguments: StatementArguments(
                    [archived as any DatabaseValueConvertible]
                    + ids.map { $0.rawValue as any DatabaseValueConvertible }) ?? StatementArguments())
        }
    }

    public func setPinned(_ id: LabelID, _ pinned: Bool) async throws {
        try await database.writer.write { db in
            try db.execute(sql: "UPDATE label SET isPinned = ? WHERE id = ?",
                           arguments: [pinned, id.rawValue])
        }
    }

    /// ラベルフィルタでの表示順 [LF-03][LG-07][ST-23]。
    ///
    /// **1 トランザクションでまとめて振り直す**——途中で落ちて順序が半分だけ
    /// 入れ替わると、`displayOrder` に重複が生まれて並びが不定になる
    /// （`groups()` は `ORDER BY displayOrder, groupIndex` なので、同点は
    /// `groupIndex` で決まってしまい利用者の並べ替えが黙って無かったことになる）。
    public func setGroupOrder(_ orderedIDs: [LabelGroupID]) async throws {
        guard !orderedIDs.isEmpty else { return }
        try await database.writer.write { db in
            for (order, id) in orderedIDs.enumerated() {
                try db.execute(sql: "UPDATE labelGroup SET displayOrder = ? WHERE id = ?",
                               arguments: [order, id.rawValue])
            }
        }
    }

    /// 増分更新 [IX-03] の破綻に備えた全件再集計 [IX-04]。
    /// 実測 844 ms / 10,530 ラベル——疑わしければ気軽に回してよい。
    public func recountAll(libraryID: LibraryID) async throws {
        try await database.writer.write { db in
            try db.execute(sql: """
                UPDATE label SET fileCount = COALESCE((
                    SELECT COUNT(*) FROM fileLabel fl
                    JOIN managedFile mf ON mf.id = fl.managedFileId
                    WHERE fl.labelId = label.id AND fl.origin != 'manuallyRemoved'
                      AND mf.state = 'active' AND mf.isArchived = 0
                ), 0)
                WHERE labelGroupId IN (SELECT id FROM labelGroup WHERE libraryId = ?)
                """, arguments: [libraryID.rawValue])
        }
    }

    // MARK: - 内部

    static func adjustCount(_ db: Database, labelID: LabelID, by delta: Int) throws {
        let stmt = try db.cachedStatement(sql:
            "UPDATE label SET fileCount = MAX(0, fileCount + ?) WHERE id = ?")
        try stmt.execute(arguments: [delta, labelID.rawValue])
    }

    static func recount(_ db: Database, labelIDs: [LabelID]) throws {
        for id in labelIDs {
            try db.execute(sql: """
                UPDATE label SET fileCount = COALESCE((
                    SELECT COUNT(*) FROM fileLabel fl
                    JOIN managedFile mf ON mf.id = fl.managedFileId
                    WHERE fl.labelId = label.id AND fl.origin != 'manuallyRemoved'
                      AND mf.state = 'active' AND mf.isArchived = 0
                ), 0) WHERE id = ?
                """, arguments: [id.rawValue])
        }
    }

    static func normalizationOptions(_ db: Database, groupID: LabelGroupID) throws
        -> NormalizationOptions
    {
        let caseSensitive = try Bool.fetchOne(db, sql: """
            SELECT library.caseSensitive FROM library
            JOIN labelGroup ON labelGroup.libraryId = library.id
            WHERE labelGroup.id = ?
            """, arguments: [groupID.rawValue]) ?? false
        return NormalizationOptions(caseSensitive: caseSensitive)
    }
}
