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
                         WHERE label.labelGroupId = labelGroup.id) AS labelCount
                FROM labelGroup WHERE libraryId = ? ORDER BY displayOrder, groupIndex
                """, arguments: [libraryID.rawValue]).map(Self.groupSummary)
        }
    }

    public func group(libraryID: LibraryID, index: Int) async throws -> LabelGroupSummary? {
        try await database.writer.read { db in
            try Row.fetchOne(db, sql: """
                SELECT labelGroup.*,
                       (SELECT COUNT(*) FROM label
                         WHERE label.labelGroupId = labelGroup.id) AS labelCount
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

    /// グループのラベル [LF-04][LE-03]。**手動で非表示にしたものも返す** [LA3-03]。
    ///
    /// **件数は 1 つだけ**——「生きていて、ファイル保管庫の外にある」ファイルの数
    /// [LA3-01]。かつては意味の違う件数を 2 つ返していた（フィルタ用の非正規化列
    /// [DB-02] と、保管庫のファイルも数える編集ウインドウ用 [LE-05]）が、
    /// 0 件ラベルの赤字 [LE-04] が撤回された [LA3-04] ことで後者の存在理由が消えた。
    ///
    /// **非正規化列は撤去した** [DB-02 撤回][§19.13 #1]。この経路は元々
    /// `countWithArchived` の相関副問い合わせを 1 本走らせており、実測
    /// （10 万件・50 万紐づけ）で 109.4 → 105.3 ms と**むしろ速くなった**
    /// ——列を持つ費用は速度ではなく「数え直しを忘れるとずれる」危険だけだった。
    public func labels(groupID: LabelGroupID) async throws -> [LabelSummary] {
        try await database.writer.read { db in
            try Row.fetchAll(db, sql: """
                SELECT label.*, COALESCE((
                    SELECT COUNT(*) FROM fileLabel fl
                    JOIN managedFile mf ON mf.id = fl.managedFileId
                    WHERE fl.labelId = label.id
                      AND mf.state = 'active' AND mf.isArchived = 0
                ), 0) AS liveCount
                FROM label WHERE labelGroupId = ?
                ORDER BY isPinned DESC, name
                """, arguments: [groupID.rawValue]).map { row in
                LabelSummary(
                    id: LabelID(rawValue: row["id"]),
                    groupID: LabelGroupID(rawValue: row["labelGroupId"]),
                    name: row["name"], normalizedName: row["normalizedName"],
                    colorHex: row["colorHex"], isPinned: row["isPinned"],
                    isHidden: row["isHidden"], fileCount: row["liveCount"])
            }
        }
    }

    public func labelIDs(fileID: FileID) async throws -> [LabelID] {
        try await database.writer.read { db in
            try Int64.fetchAll(db, sql:
                "SELECT labelId FROM fileLabel WHERE managedFileId = ?",
                arguments: [fileID.rawValue]).map { LabelID(rawValue: $0) }
        }
    }

    // MARK: - 書き込み

    /// 複数ファイルの紐づけを 1 度に読む [RL-04][RP-02]。
    public func assignments(fileIDs: [FileID]) async throws -> [FileID: Set<LabelID>] {
        guard !fileIDs.isEmpty else { return [:] }
        return try await database.writer.read { db in
            var result: [FileID: Set<LabelID>] = [:]
            // ホスト変数の上限を避けて分ける（`setRating` と同じ事情。**外しても
            // 結果は正しく、壊れるのは速度のほう**なので変異検証では空振りする）。
            let step = SQLiteManagedFileRepository.maxBoundParameters
            for start in stride(from: 0, to: fileIDs.count, by: step) {
                let chunk = Array(fileIDs[start..<min(start + step, fileIDs.count)])
                let rows = try Row.fetchAll(db, sql: """
                    SELECT managedFileId, labelId FROM fileLabel
                    WHERE managedFileId IN (\(SQLiteManagedFileRepository.placeholders(chunk.count)))
                    """, arguments: StatementArguments(chunk.map { Optional($0.rawValue) }))
                for row in rows {
                    result[FileID(rawValue: row["managedFileId"]), default: []]
                        .insert(LabelID(rawValue: row["labelId"]))
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
        let key = TextNormalizer.normalize(name)
        let stmt = try db.cachedStatement(sql:
            "SELECT id FROM label WHERE labelGroupId = ? AND normalizedName = ?")
        if let existing = try Int64.fetchOne(stmt, arguments: [groupID.rawValue, key]) {
            return LabelID(rawValue: existing)
        }
        var record = LabelRecord(id: nil, labelGroupId: groupID.rawValue,
                                 name: TextNormalizer.display(name), normalizedName: key,
                                 colorHex: nil, isPinned: false, isHidden: false)
        try record.insert(db)
        return LabelID(rawValue: record.id ?? 0)
    }

    public func assign(fileID: FileID, labelID: LabelID) async throws {
        try await database.writer.write { db in
            try Self.assign(db, fileID: fileID, labelID: labelID)
        }
    }

    static func assign(_ db: Database, fileID: FileID, labelID: LabelID) throws {
        try db.execute(sql: """
            INSERT INTO fileLabel (managedFileId, labelId, assignedAt)
            VALUES (?, ?, ?)
            ON CONFLICT (managedFileId, labelId) DO NOTHING
            """, arguments: [fileID.rawValue, labelID.rawValue,
                             Date().timeIntervalSinceReferenceDate])
    }

    public func unassign(fileID: FileID, labelID: LabelID) async throws {
        try await database.writer.write { db in
            try Self.unassign(db, fileID: fileID, labelID: labelID)
        }
    }

    static func unassign(_ db: Database, fileID: FileID, labelID: LabelID) throws {
        try db.execute(sql: "DELETE FROM fileLabel WHERE managedFileId = ? AND labelId = ?",
                       arguments: [fileID.rawValue, labelID.rawValue])
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
    public func applyAssignments(labelID: LabelID, _ changes: [LabelAssignmentChange],
                                 protectedScopes: [FileID: Set<ProtectionScope>]) async throws {
        guard !changes.isEmpty else { return }
        try await database.writer.write { db in
            for change in changes {
                if change.isAssigned {
                    try Self.assign(db, fileID: change.fileID, labelID: labelID)
                } else {
                    try Self.unassign(db, fileID: change.fileID, labelID: labelID)
                }
            }
            // **同じトランザクションで保護も書く** [PR-03]。テーブルは違うが
            // 同じ DB なので、ここで書けば「ラベルは変わったが保護が付いて
            // いない」状態が構造的に生まれない。
            let stmt = try db.cachedStatement(sql:
                "UPDATE managedFile SET protectedScopes = ? WHERE id = ?")
            for (id, scopes) in protectedScopes {
                try stmt.execute(arguments: [ProtectionScopeCoding.encode(scopes), id.rawValue])
            }
        }
    }

    /// 1 ファイルの紐づけを、指定した集合へちょうど揃える（保護は見ない）。
    public func setLabels(fileID: FileID, labelIDs: Set<LabelID>) async throws {
        try await database.writer.write { db in
            let current = Set(try Int64.fetchAll(db, sql:
                "SELECT labelId FROM fileLabel WHERE managedFileId = ?",
                arguments: [fileID.rawValue]).map { LabelID(rawValue: $0) })
            for id in current.subtracting(labelIDs) {
                try Self.unassign(db, fileID: fileID, labelID: id)
            }
            for id in labelIDs.subtracting(current) {
                try Self.assign(db, fileID: fileID, labelID: id)
            }
        }
    }

    /// 1 ファイルのラベルを、走査が導いた集合へ揃える [RC-01][PR-01]。
    ///
    /// **保護されたフィールド [PR-02] には一切触れない。** 消さないだけでなく
    /// **付け足しもしない**——保護は「このフィールドの状態は利用者が決めた」
    /// という意味なので、走査が横から足すのも約束違反になる。
    ///
    /// **判定はこの関数の中で行う**（`managedFile.protectedScopes` と
    /// `label.labelGroupId` を読む）。呼び出し側に渡させると、次に足す
    /// 呼び出し元が忘れる——`embeddedMetadataCache` の区切りを呼び出し側に
    /// 求めなかったのと同じ理由。
    public func replaceAutoLabels(fileID: FileID, labelIDs: Set<LabelID>) async throws {
        try await database.writer.write { db in
            try Self.replaceAutoLabels(db, fileID: fileID, labelIDs: labelIDs)
        }
    }

    static func replaceAutoLabels(_ db: Database, fileID: FileID, labelIDs: Set<LabelID>) throws {
        let protectedFields = ProtectionScopeCoding.decode(try String.fetchOne(db, sql:
            "SELECT protectedScopes FROM managedFile WHERE id = ?",
            arguments: [fileID.rawValue])).protectedFields

        // いま付いているものを、属するフィールドとともに読む。
        let current = try Row.fetchAll(db, sql: """
            SELECT fl.labelId AS labelId, l.labelGroupId AS groupId
              FROM fileLabel fl JOIN label l ON l.id = fl.labelId
             WHERE fl.managedFileId = ?
            """, arguments: [fileID.rawValue])
        // 保護されたフィールドのものは、消す候補からも外す。
        let removable = Set(current
            .filter { !protectedFields.contains(LabelGroupID(rawValue: $0["groupId"] as Int64)) }
            .map { LabelID(rawValue: $0["labelId"] as Int64) })
        let attached = Set(current.map { LabelID(rawValue: $0["labelId"] as Int64) })

        // 付けたいもののうち、保護されたフィールドに属するものを外す。
        // **1 ファイルのラベルは高々数十件**（フィールド数 × 値）なので
        // ホスト変数の区切りは要らない。
        var wanted = labelIDs
        if !protectedFields.isEmpty, !wanted.isEmpty {
            let ids = Array(wanted)
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, labelGroupId FROM label
                 WHERE id IN (\(SQLiteManagedFileRepository.placeholders(ids.count)))
                """, arguments: StatementArguments(ids.map { Optional($0.rawValue) }))
            for row in rows
            where protectedFields.contains(LabelGroupID(rawValue: row["labelGroupId"] as Int64)) {
                wanted.remove(LabelID(rawValue: row["id"] as Int64))
            }
        }

        for id in removable.subtracting(wanted) {
            try db.execute(sql: "DELETE FROM fileLabel WHERE managedFileId = ? AND labelId = ?",
                           arguments: [fileID.rawValue, id.rawValue])
        }
        let now = Date().timeIntervalSinceReferenceDate
        for id in wanted.subtracting(attached) {
            try db.execute(sql: """
                INSERT INTO fileLabel (managedFileId, labelId, assignedAt) VALUES (?, ?, ?)
                """, arguments: [fileID.rawValue, id.rawValue, now])
        }
    }

    /// ラベルの統合 [LB-07][LE-11]。
    ///
    /// **両方が付いているファイルの `origin` は `LabelOrigin.merging` が決める**
    /// ［ユーザー判断］。以前は `UPDATE OR IGNORE` 1 本で移していたが、それだと
    /// 移動先の値が無条件に残り、`source` が `manual`・`target` が
    /// `manuallyRemoved` のファイルで**手動付与が黙って消えていた**。
    public func merge(_ source: LabelID, into target: LabelID) async throws {
        guard source != target else { return }
        try await database.writer.write { db in
            guard let s = try LabelRecord.fetchOne(db, key: source.rawValue) else {
                throw LabelEditError.labelNotFound(source)
            }
            guard let t = try LabelRecord.fetchOne(db, key: target.rawValue) else {
                throw LabelEditError.labelNotFound(target)
            }
            // **グループをまたぐ統合は認めない** [LB-07]。ラベルの一意性は
            // グループ内で定義されており [LB-01]、またぐと「グループを移す」
            // という別の操作になる。
            guard s.labelGroupId == t.labelGroupId else { throw LabelEditError.crossGroupMerge }

            // ① 両方が付いているファイル: 古いほうの付与日時に揃える。
            //    **どちらを残すかの規則は要らなくなった**——紐づけは付いて
            //    いる／いないの 2 値で、保護は紐づけではなくフィールドに
            //    付く [PR-02]。
            try db.execute(sql: """
                UPDATE fileLabel SET assignedAt = MIN(assignedAt, (
                    SELECT src.assignedAt FROM fileLabel src
                     WHERE src.labelId = ? AND src.managedFileId = fileLabel.managedFileId
                ))
                 WHERE labelId = ? AND EXISTS (
                    SELECT 1 FROM fileLabel src
                     WHERE src.labelId = ? AND src.managedFileId = fileLabel.managedFileId
                 )
                """, arguments: [source.rawValue, target.rawValue, source.rawValue])
            // ② 重ならないものは移す。①で処理済みの行は主キーが衝突するので
            //    `OR IGNORE` で飛ばし、残骸は③の cascade が片付ける。
            try db.execute(sql: """
                UPDATE OR IGNORE fileLabel SET labelId = ? WHERE labelId = ?
                """, arguments: [target.rawValue, source.rawValue])
            // ③ 統合元を消す。残った重複行は `ON DELETE CASCADE` で一緒に消える。
            try db.execute(sql: "DELETE FROM label WHERE id = ?", arguments: [source.rawValue])
        }
    }

    /// 改名 [LB-06]。紐づけは行の ID で張られているので何もしなくてよい。
    ///
    /// **衝突は素の UNIQUE 制約違反ではなく `LabelEditError` で返す** [LE-11]
    /// ——「UNIQUE constraint failed: label.labelGroupId, label.normalizedName」を
    /// そのまま見せる代わりに、呼び出し側が「代わりに統合しますか」を出せるよう
    /// 衝突相手の ID を添える。
    public func rename(_ id: LabelID, to name: String) async throws {
        try await database.writer.write { db in
            guard let record = try LabelRecord.fetchOne(db, key: id.rawValue) else {
                throw LabelEditError.labelNotFound(id)
            }
            let normalized = TextNormalizer.normalize(name)
            // **自分自身は衝突ではない。** 大小文字や全角半角だけを直す改名
            // （`abc` → `ABC`）は正規化名が変わらないので、`id != ?` で外さないと
            // 表記を整える操作が一切できなくなる。
            if let other = try Int64.fetchOne(db, sql: """
                SELECT id FROM label
                WHERE labelGroupId = ? AND normalizedName = ? AND id != ?
                """, arguments: [record.labelGroupId, normalized, id.rawValue]) {
                throw LabelEditError.nameAlreadyExists(existing: LabelID(rawValue: other),
                                                       name: name)
            }
            try db.execute(sql: "UPDATE label SET name = ?, normalizedName = ? WHERE id = ?",
                           arguments: [name, normalized, id.rawValue])
        }
    }

    /// 手動での非表示の切り替え [LA3-02]。
    public func setHidden(_ ids: [LabelID], _ hidden: Bool) async throws {
        guard !ids.isEmpty else { return }
        try await database.writer.write { db in
            try db.execute(sql: """
                UPDATE label SET isHidden = ? WHERE id IN (\(SQLiteManagedFileRepository.placeholders(ids.count)))
                """, arguments: StatementArguments(
                    [hidden as any DatabaseValueConvertible]
                    + ids.map { $0.rawValue as any DatabaseValueConvertible }) ?? StatementArguments())
        }
    }

    public func setPinned(_ id: LabelID, _ pinned: Bool) async throws {
        try await database.writer.write { db in
            try db.execute(sql: "UPDATE label SET isPinned = ? WHERE id = ?",
                           arguments: [pinned, id.rawValue])
        }
    }

    /// ラベル固有色 [LE-10][CO-06]。`nil` へ戻すとグループ色を継承する。
    public func setColor(_ id: LabelID, hex: String?) async throws {
        try await database.writer.write { db in
            try db.execute(sql: "UPDATE label SET colorHex = ? WHERE id = ?",
                           arguments: [hex, id.rawValue])
        }
    }

    /// 削除 [LE-07]。**紐づけも一緒に消える** [LE-08][LB-05]——`fileLabel` の
    /// 外部キーが `ON DELETE CASCADE` なので、ここで別途消す必要はない
    /// （消し忘れる余地を作らないため、あえてアプリ側で二重に消さない）。
    ///
    /// **`manuallyRemoved` の印も一緒に消える。** つまり削除したラベルと同じ名前が
    /// 自動付与で再び現れれば、そのラベルは作り直されて付く [AL-07]。「二度と
    /// 付けたくない」という意思表示は削除ではなく保管庫 [LA-01] が担う——
    /// 削除は「このラベルは要らなかった」であって「今後も拒む」ではない。
    public func deleteLabels(_ ids: [LabelID]) async throws {
        guard !ids.isEmpty else { return }
        try await database.writer.write { db in
            try db.execute(sql: """
                DELETE FROM label
                WHERE id IN (\(SQLiteManagedFileRepository.placeholders(ids.count)))
                """, arguments: StatementArguments(
                    ids.map { $0.rawValue as any DatabaseValueConvertible }) ?? StatementArguments())
        }
    }

    /// 行と紐づけの完全な写しを取る [LabelSnapshot]。削除・統合の Undo 用。
    public func snapshot(labelIDs: [LabelID]) async throws -> [LabelSnapshot] {
        guard !labelIDs.isEmpty else { return [] }
        return try await database.writer.read { db in
            var result: [LabelSnapshot] = []
            for id in labelIDs {
                // **存在しない ID は飛ばす。** 同時に消えていた 1 件のせいで、
                // 戻せるはずの残りまで戻せなくなるほうが害が大きい。
                guard let record = try LabelRecord.fetchOne(db, key: id.rawValue) else { continue }
                let rows = try Row.fetchAll(db, sql: """
                    SELECT managedFileId, assignedAt FROM fileLabel WHERE labelId = ?
                    """, arguments: [id.rawValue])
                result.append(LabelSnapshot(
                    id: id, groupID: LabelGroupID(rawValue: record.labelGroupId),
                    name: record.name, normalizedName: record.normalizedName,
                    colorHex: record.colorHex, isPinned: record.isPinned,
                    isHidden: record.isHidden,
                    assignments: rows.map { row in
                        LabelSnapshot.Assignment(
                            fileID: FileID(rawValue: row["managedFileId"]),
                            assignedAt: Date(timeIntervalSinceReferenceDate: row["assignedAt"]))
                    }))
            }
            return result
        }
    }

    /// 写しの状態へちょうど戻す [LabelSnapshot]。
    ///
    /// **`id` を明示して `INSERT` する。** `label.id` は AUTOINCREMENT なので
    /// 削除された ID は再利用されず空いたまま残り、元の ID をそのまま取り戻せる
    /// ［実測］。別 ID で作り直すと、ラベルフィルタでチェック中だった選択が
    /// 黙って外れる。
    ///
    /// **1 トランザクションで書く**——統合の Undo は統合元と統合先の 2 件を
    /// まとめて戻すので、途中で切れると「元は戻ったが先が統合後のまま」という
    /// どちらでもない状態が残る。
    public func restore(_ snapshots: [LabelSnapshot]) async throws {
        guard !snapshots.isEmpty else { return }
        try await database.writer.write { db in
            for snapshot in snapshots {
                // グループごと消えていたら戻せない（ライブラリの登録解除など）。
                // その場合は Undo の対象そのものが失われているので黙って飛ばす。
                let groupExists = try Bool.fetchOne(db, sql:
                    "SELECT EXISTS(SELECT 1 FROM labelGroup WHERE id = ?)",
                    arguments: [snapshot.groupID.rawValue]) ?? false
                guard groupExists else { continue }

                try db.execute(sql: """
                    INSERT INTO label
                        (id, labelGroupId, name, normalizedName, colorHex,
                         isPinned, isHidden)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        labelGroupId = excluded.labelGroupId, name = excluded.name,
                        normalizedName = excluded.normalizedName,
                        colorHex = excluded.colorHex, isPinned = excluded.isPinned,
                        isHidden = excluded.isHidden
                    """, arguments: [snapshot.id.rawValue, snapshot.groupID.rawValue,
                                     snapshot.name, snapshot.normalizedName, snapshot.colorHex,
                                     snapshot.isPinned, snapshot.isHidden])

                // 「ちょうど戻す」ので、写しに無い紐づけは消す。
                try db.execute(sql: "DELETE FROM fileLabel WHERE labelId = ?",
                               arguments: [snapshot.id.rawValue])
                for assignment in snapshot.assignments {
                    // **相手のファイルが消えていたら飛ばす。** `INSERT OR IGNORE`
                    // は外部キー違反を無視しないので、`WHERE EXISTS` で自分で外す
                    // ——1 件の消失で Undo 全体が失敗するのを避ける。
                    try db.execute(sql: """
                        INSERT INTO fileLabel (managedFileId, labelId, assignedAt)
                        SELECT ?, ?, ? WHERE EXISTS (SELECT 1 FROM managedFile WHERE id = ?)
                        """, arguments: [assignment.fileID.rawValue, snapshot.id.rawValue,
                                         assignment.assignedAt.timeIntervalSinceReferenceDate,
                                         assignment.fileID.rawValue])
                }
            }
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

}
