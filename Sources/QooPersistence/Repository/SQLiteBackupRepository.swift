//
//  BackupRepository の SQLite 実装 [IE-01〜IE-14][JS-01〜JS-09][BK-05]。
//
//  何を出し、何を出さないかの根拠は `BackupDocument`（`QooKit`）の型コメントに、
//  取り込みが「重ねるだけ」である理由は `BackupRepository` の型コメントにある。
//  **触る前にその 2 つを読むこと。**
//
import Foundation
import GRDB
import QooKit

public struct SQLiteBackupRepository: BackupRepository, Sendable {
    let database: QooDatabase

    public init(database: QooDatabase) {
        self.database = database
    }

    // MARK: - 書き出し [IE-01][IE-02]

    public func export(scope: BackupScope, appVersion: String?) async throws -> BackupDocument {
        let libraries = try await database.writer.read { db -> [LibraryBackup] in
            let records: [LibraryRecord]
            switch scope {
            case .everything:
                records = try LibraryRecord.order(sql: "displayName").fetchAll(db)
            case .libraries(let ids):
                guard !ids.isEmpty else { return [] }
                let placeholders = ids.map { _ in "?" }.joined(separator: ", ")
                records = try LibraryRecord
                    .filter(sql: "id IN (\(placeholders))",
                            arguments: StatementArguments(ids.map { $0.rawValue }))
                    .order(sql: "displayName")
                    .fetchAll(db)
            }
            return try records.map { try Self.exportLibrary(db, record: $0) }
        }
        return BackupDocument(exportedAt: Date(), appVersion: appVersion, libraries: libraries)
    }

    private static func exportLibrary(_ db: Database, record: LibraryRecord) throws -> LibraryBackup {
        guard let libraryID = record.id else {
            throw BackupError.malformed("library に行 ID が無い")
        }
        guard let type = try LibraryTypeRecord.fetchOne(db, key: record.libraryTypeId) else {
            throw BackupError.malformed("libraryType \(record.libraryTypeId) が見つからない")
        }

        return LibraryBackup(
            uuid: UUID(uuidString: record.uuid) ?? UUID(),
            displayName: record.displayName,
            rootPath: record.resolvedPath,
            volumeUUID: record.volumeUUID,
            libraryType: LibraryTypeBackup(
                presetKey: type.presetKey, name: type.name,
                libraryTypeName: type.libraryTypeName, isPreset: type.isPreset,
                version: type.version, definitionJSON: type.definitionJSON),
            caseSensitive: record.caseSensitive,
            duplicateGrouping: record.duplicateGrouping,
            thumbnailsAlwaysHidden: record.thumbnailsAlwaysHidden,
            settings: record.settingsJSON,
            labelGroups: try exportLabelGroups(db, libraryID: libraryID),
            filenameFormats: try FilenameFormatRecord
                .filter(sql: "libraryId = ?", arguments: [libraryID])
                .order(sql: "priority").fetchAll(db)
                .map { FormatBackup(source: $0.source, priority: $0.priority,
                                    isEnabled: $0.isEnabled) },
            volumeFormats: try VolumeFormatRecord
                .filter(sql: "libraryId = ?", arguments: [libraryID])
                .order(sql: "priority").fetchAll(db)
                .map { VolumeFormatBackup(source: $0.source, priority: $0.priority,
                                          isEnabled: $0.isEnabled, kind: $0.kind) },
            folderLevelMappings: try FolderLevelMappingRecord
                .filter(sql: "libraryId = ?", arguments: [libraryID])
                .order(sql: "level").fetchAll(db)
                .map { FolderLevelMappingBackup(level: $0.level,
                                                assignmentKind: $0.assignmentKind,
                                                labelGroupIndex: $0.labelGroupIndex,
                                                formatSource: $0.formatSource) },
            protectedTokens: try ProtectedTokenRecord
                .filter(sql: "ownerKind = 'library' AND ownerID = ?", arguments: [libraryID])
                .order(sql: "id").fetchAll(db)
                .map { ProtectedTokenBackup(pattern: $0.pattern, position: $0.position,
                                            isEnabled: $0.isEnabled) },
            files: try exportFiles(db, libraryID: libraryID))
    }

    private static func exportLabelGroups(_ db: Database,
                                          libraryID: Int64) throws -> [LabelGroupBackup] {
        let groups = try LabelGroupRecord
            .filter(sql: "libraryId = ?", arguments: [libraryID])
            .order(sql: "groupIndex").fetchAll(db)
        return try groups.map { group in
            let labels = try LabelRecord
                .filter(sql: "labelGroupId = ?", arguments: [group.id ?? 0])
                .order(sql: "name").fetchAll(db)
                .map { LabelBackup(name: $0.name, colorHex: $0.colorHex,
                                   isPinned: $0.isPinned, isArchived: $0.isArchived) }
            return LabelGroupBackup(
                groupIndex: group.groupIndex, name: group.name,
                colorHexLight: group.colorHexLight, colorHexDark: group.colorHexDark,
                displayOrder: group.displayOrder,
                assignsAutomatically: group.assignsAutomatically,
                labels: labels)
        }
    }

    private static func exportFiles(_ db: Database, libraryID: Int64) throws -> [FileBackup] {
        // ラベル紐づけは**ライブラリ単位で 1 回引いて**ファイル ID で束ねる。
        // ファイルごとに引くと 10 万件で 10 万回の問い合わせになる。
        //
        // **`origin = 'auto'` は引かない** [RC-04]。自動で付いたラベルは
        // 再スキャンが付け直すので、書き出すと蔵書の規模ぶん無駄に膨らむ。
        // 残す価値があるのは「人が付けた」と「人が外した」の記録だけ。
        var labelsByFile: [Int64: [FileLabelBackup]] = [:]
        let rows = try Row.fetchAll(db, sql: """
            SELECT fileLabel.managedFileId AS fileId, fileLabel.origin, fileLabel.assignedAt,
                   label.name AS labelName,
                   labelGroup.groupIndex AS groupIndex, labelGroup.name AS groupName
            FROM fileLabel
            JOIN label ON label.id = fileLabel.labelId
            JOIN labelGroup ON labelGroup.id = label.labelGroupId
            WHERE labelGroup.libraryId = ?
              AND fileLabel.origin <> 'auto'
            ORDER BY fileLabel.managedFileId, labelGroup.groupIndex, label.name
            """, arguments: [libraryID])
        for row in rows {
            let fileID: Int64 = row["fileId"]
            labelsByFile[fileID, default: []].append(FileLabelBackup(
                groupIndex: row["groupIndex"],
                groupName: row["groupName"],
                labelName: row["labelName"],
                origin: row["origin"],
                assignedAt: Date(timeIntervalSinceReferenceDate: row["assignedAt"])))
        }

        // 「以後無視する」を立てたファイル [AL-33][MG-22]。**走査からは作り直せない
        // 利用者の判断**なので出す。行そのもの（＝未解決であること）は走査が
        // 作り直すので、出すのはこの旗だけでよい。
        let ignored = Set(try Int64.fetchAll(db, sql: """
            SELECT managedFileId FROM unresolvedFile WHERE libraryId = ? AND isIgnored = 1
            """, arguments: [libraryID]))

        return try ManagedFileRecord
            .filter(sql: "libraryId = ?", arguments: [libraryID])
            .order(sql: "relativePath, filename").fetchAll(db)
            .compactMap { record -> FileBackup? in
                let id = record.id ?? 0
                let labels = labelsByFile[id] ?? []
                let file = FileBackup(
                    relativePath: record.relativePath,
                    filename: record.filename,
                    rating: record.rating,
                    titleOrigin: record.titleOrigin,
                    // `titleOrigin == "auto"` のタイトルはパーサが作り直す [RP-11]。
                    // 出しても害は無いが、10 万件ぶん膨らむだけで復元には使わない。
                    title: record.titleOrigin == ValueOrigin.auto.rawValue ? nil : record.title,
                    coverImageSource: record.coverImageSource,
                    // 同じ理由で、自動抽出したカバーの参照は出さない [IV-03]。
                    coverImageRef: record.coverImageSource == CoverSource.auto.rawValue
                        ? nil : record.coverImageRef,
                    isArchived: record.isArchived,
                    archivedFromPath: record.archivedFromPath,
                    archivedAt: record.archivedAt.map(Date.init(timeIntervalSinceReferenceDate:)),
                    isDuplicateRepresentativePinned: record.isDuplicateRepresentativePinned,
                    state: record.state,
                    trashedAt: record.trashedAt.map(Date.init(timeIntervalSinceReferenceDate:)),
                    // 立っているときだけ出す。`title` を自動なら出さないのと同じ
                    // 考え方で、10 万件ぶんの `false` を書いても意味が無い。
                    isUnresolvedIgnored: ignored.contains(id) ? true : nil,
                    labels: labels)
                // **再生成できる情報しか持たない行は出さない。** 再スキャンが
                // 実体から作り直すので、書き出しても取り込みが何もしない
                // ——10 万件の蔵書で JSON が無意味に膨らむのを避ける。
                return file.carriesUnrecoverableData ? file : nil
            }
    }
}

extension FileBackup {
    /// この行に、再スキャンでは作り直せない情報が載っているか [MG-22]。
    ///
    /// **判定を 1 箇所に閉じる。** 書き出し（何を出すか）と取り込み（何を
    /// 書き戻すか）が別々の条件を持つと、片方だけ直したときに静かにずれる。
    var carriesUnrecoverableData: Bool {
        if rating != 0 { return true }
        if titleOrigin != "auto" { return true }
        if coverImageSource != "auto" { return true }
        if isArchived || archivedFromPath != nil { return true }
        if isDuplicateRepresentativePinned { return true }
        // `active` 以外の状態（孤立・ゴミ箱）は観測の結果なので再現し得るが、
        // ゴミ箱の日付だけは人の操作の記録で作り直せない [TR-01]。
        if trashedAt != nil { return true }
        // 「以後無視する」[AL-33] も人の判断。これだけを持つ行も残す。
        if isUnresolvedIgnored == true { return true }
        // ここへ来る `labels` は `origin != 'auto'` に絞ってある——自動で
        // 付いたラベルは再スキャンが付け直す [RC-04]。残っているのは
        // 「人が付けた」「人が外した」の記録だけなので、1 件でもあれば残す。
        return !labels.isEmpty
    }
}

// MARK: - 取り込み [IE-11][IE-12][JS-06][JS-08]

extension SQLiteBackupRepository {

    public func plan(_ document: BackupDocument) async throws -> ImportPlan {
        try await database.writer.read { db in
            try Self.apply(db, document, dryRun: true)
        }
    }

    public func `import`(_ document: BackupDocument) async throws -> ImportPlan {
        // `write` の閉包全体が 1 つのトランザクション [JS-08]。途中で投げれば
        // すべて巻き戻る——半分だけ取り込まれた状態を残さない。
        try await database.writer.write { db in
            try Self.apply(db, document, dryRun: false)
        }
    }

    /// **プレビューと実行を同じ関数で通す** [設計判断]。別々に書くと、
    /// 片方だけ直したときに「承認した内容と違うことが起きる」——承認を
    /// 求める意味そのものが消える壊れ方をする。`dryRun` は書き込みだけを
    /// 抑え、数え方は共有する。
    static func apply(_ db: Database, _ document: BackupDocument,
                      dryRun: Bool) throws -> ImportPlan {
        guard document.schemaVersion <= BackupDocument.currentSchemaVersion else {
            throw BackupError.schemaTooNew(found: document.schemaVersion,
                                           supported: BackupDocument.currentSchemaVersion)
        }
        return ImportPlan(libraries: try document.libraries.map {
            try applyLibrary(db, $0, dryRun: dryRun)
        })
    }

    private static func applyLibrary(_ db: Database, _ backup: LibraryBackup,
                                     dryRun: Bool) throws -> ImportPlan.LibraryChange {
        // 同一性キーは表示名 + 根のパス [IE-10][JS-04]。行 ID も UUID も使わない
        // ——前者は環境固有、後者は別のマシンでは別の登録フォルダを指す。
        let record = try LibraryRecord
            .filter(sql: "displayName = ? AND resolvedPath = ?",
                    arguments: [backup.displayName, backup.rootPath])
            .fetchOne(db)
        guard let record, let libraryID = record.id else {
            // ライブラリを作るにはブックマークが要り、それは JSON に持てない。
            // 取り込まずに報告する（`BackupRepository` の型コメント参照）。
            return ImportPlan.LibraryChange(
                identityKey: backup.identityKey, displayName: backup.displayName,
                kind: .missing, filesMissing: backup.files.count, filesUpdated: 0,
                labelGroupsAdded: 0, labelsAdded: 0, fileLabelsAdded: 0)
        }

        var groupsAdded = 0
        var labelsAdded = 0
        var fileLabelsAdded = 0

        // --- 設定 ---------------------------------------------------------
        // 設定は**置き換える**。「重ねる」原則の例外で、フォーマットの一覧や
        // 階層の割り当ては集合として意味を持つため、部分的に混ぜると
        // 元とも取り込み元とも違う設定ができあがる。
        if !dryRun {
            try replaceSettings(db, libraryID: libraryID, backup: backup)
        }

        // --- ラベルグループとラベル ---------------------------------------
        // **グループは作り直さない。** ラベルが `labelGroup` へ連鎖削除で
        // 紐づいているので、消して入れ直すと蓄積したラベルと紐づけが全部
        // 消える（`updateSettings` が守っているのと同じ不変条件）。
        var groupIDByIndex: [Int: Int64] = [:]
        for group in backup.labelGroups {
            let existing = try LabelGroupRecord
                .filter(sql: "libraryId = ? AND groupIndex = ?",
                        arguments: [libraryID, group.groupIndex])
                .fetchOne(db)
            if let existing, let id = existing.id {
                groupIDByIndex[group.groupIndex] = id
                if !dryRun {
                    var updated = existing
                    updated.name = group.name
                    updated.colorHexLight = group.colorHexLight
                    updated.colorHexDark = group.colorHexDark
                    updated.displayOrder = group.displayOrder
                    updated.assignsAutomatically = group.assignsAutomatically
                    try updated.update(db)
                }
            } else {
                groupsAdded += 1
                guard !dryRun else { continue }
                var created = LabelGroupRecord(
                    id: nil, libraryId: libraryID, groupIndex: group.groupIndex,
                    name: group.name, colorHexLight: group.colorHexLight,
                    colorHexDark: group.colorHexDark, displayOrder: group.displayOrder,
                    assignsAutomatically: group.assignsAutomatically)
                try created.insert(db)
                groupIDByIndex[group.groupIndex] = created.id
            }
        }

        // ラベル。一意性は `(グループ, 正規化名)` [LB-01][N-03]。
        var labelIDByKey: [LabelKey: Int64] = [:]
        for group in backup.labelGroups {
            guard let groupID = groupIDByIndex[group.groupIndex] else {
                // dryRun でグループがまだ無い場合。ラベルは全件が新規になる。
                labelsAdded += group.labels.count
                continue
            }
            let options = try SQLiteLabelRepository.normalizationOptions(
                db, groupID: LabelGroupID(rawValue: groupID))
            for label in group.labels {
                let normalized = TextNormalizer.normalize(label.name, options: options)
                let existing = try LabelRecord
                    .filter(sql: "labelGroupId = ? AND normalizedName = ?",
                            arguments: [groupID, normalized])
                    .fetchOne(db)
                if let existing, let id = existing.id {
                    labelIDByKey[LabelKey(groupIndex: group.groupIndex, normalized: normalized)] = id
                    if !dryRun {
                        var updated = existing
                        // 原文・色・ピン・アーカイブはユーザーの設定 [MG-22]。
                        // `fileCount` は触らない——非正規化キャッシュ [DB-02] で、
                        // 紐づけの増減にあわせて別途更新される。
                        updated.name = label.name
                        updated.colorHex = label.colorHex
                        updated.isPinned = label.isPinned
                        updated.isArchived = label.isArchived
                        try updated.update(db)
                    }
                } else {
                    labelsAdded += 1
                    guard !dryRun else { continue }
                    var created = LabelRecord(
                        id: nil, labelGroupId: groupID, name: label.name,
                        normalizedName: normalized, colorHex: label.colorHex,
                        isPinned: label.isPinned, isArchived: label.isArchived, fileCount: 0)
                    try created.insert(db)
                    labelIDByKey[LabelKey(groupIndex: group.groupIndex,
                                          normalized: normalized)] = created.id
                }
            }
        }

        // --- ファイル -----------------------------------------------------
        // 行は作らない。**再スキャンが実体から作った行にだけ値を載せる**
        // ——実体を伴わないレコードを増やすと、次の走査でそれが孤立として
        // 現れ「消えたファイル」の報告に混ざる [ID-06]。
        var filesMissing = 0
        var filesUpdated = 0
        let caseSensitive = record.caseSensitive
        let options = NormalizationOptions(caseSensitive: caseSensitive)

        for file in backup.files {
            let existing = try ManagedFileRecord
                .filter(sql: "libraryId = ? AND relativePath = ? AND filename = ?",
                        arguments: [libraryID, file.relativePath, file.filename])
                .fetchOne(db)
            guard let existing, let fileID = existing.id else {
                filesMissing += 1
                continue
            }
            filesUpdated += 1
            if !dryRun {
                try writeBack(db, file, into: existing, fileID: fileID)
            }
            for link in file.labels {
                let normalized = TextNormalizer.normalize(link.labelName, options: options)
                let key = LabelKey(groupIndex: link.groupIndex, normalized: normalized)
                guard let labelID = labelIDByKey[key] else {
                    // 文書のラベル一覧に無いラベルが紐づけにだけ現れる形。
                    // 壊れた文書でも取り込みを止めず、その 1 件を諦める。
                    continue
                }
                let already = try Bool.fetchOne(db, sql: """
                    SELECT 1 FROM fileLabel WHERE managedFileId = ? AND labelId = ?
                    """, arguments: [fileID, labelID]) ?? false
                if !already { fileLabelsAdded += 1 }
                guard !dryRun else { continue }
                try SQLiteLabelRepository.assign(
                    db, fileID: FileID(rawValue: fileID), labelID: LabelID(rawValue: labelID),
                    origin: LabelOrigin(rawValue: link.origin) ?? .manual)
            }
        }

        return ImportPlan.LibraryChange(
            identityKey: backup.identityKey, displayName: backup.displayName,
            kind: .update, filesMissing: filesMissing, filesUpdated: filesUpdated,
            labelGroupsAdded: groupsAdded, labelsAdded: labelsAdded,
            fileLabelsAdded: fileLabelsAdded)
    }

    /// ファイル 1 件に、再生成できない値だけを書き戻す [MG-22]。
    ///
    /// **再生成できる列には触れない。** 触ると、走査が実体から読んだ正しい値を
    /// 古いバックアップで上書きすることになる（ファイルサイズ・更新日時・
    /// パーサの結果など、実体が正である列）。
    private static func writeBack(_ db: Database, _ file: FileBackup,
                                  into existing: ManagedFileRecord, fileID: Int64) throws {
        var record = existing
        record.rating = file.rating
        record.titleOrigin = file.titleOrigin
        // 自動タイトルはパーサが作る。手動編集のときだけ上書きする [RP-11]。
        if file.titleOrigin != ValueOrigin.auto.rawValue {
            record.title = file.title
        }
        record.coverImageSource = file.coverImageSource
        if file.coverImageSource != CoverSource.auto.rawValue {
            record.coverImageRef = file.coverImageRef
        }
        record.isArchived = file.isArchived
        record.archivedFromPath = file.archivedFromPath
        record.archivedAt = file.archivedAt?.timeIntervalSinceReferenceDate
        record.isDuplicateRepresentativePinned = file.isDuplicateRepresentativePinned
        record.trashedAt = file.trashedAt?.timeIntervalSinceReferenceDate
        // **`state` は書き戻さない。** 走査が実体を見て決めた現在の状態
        // （`active` / `orphaned`）のほうが常に新しい [ID-06]。ゴミ箱に入れた
        // 記録だけは人の操作なので `trashedAt` として上で復元している。
        try record.update(db)

        // 「以後無視する」[AL-33]。**行が既にあるときだけ立てる**——復旧手順は
        // 「有効化 → 再スキャン → 取り込み」[MG-24] なので、取り込みの時点で
        // 走査が未解決の行を作り終えている。行が無いのは「いまは解決している」
        // という意味なので、そこへ無視を作ると解決済みのファイルに人の判断が
        // 蘇ることになる。
        if file.isUnresolvedIgnored == true {
            try db.execute(sql: """
                UPDATE unresolvedFile SET isIgnored = 1 WHERE managedFileId = ?
                """, arguments: [fileID])
        }
    }

    /// 設定を置き換える [LS-01][VT-02]。
    private static func replaceSettings(_ db: Database, libraryID: Int64,
                                        backup: LibraryBackup) throws {
        try db.execute(sql: """
            UPDATE library
               SET settingsJSON = ?, caseSensitive = ?, duplicateGrouping = ?,
                   thumbnailsAlwaysHidden = ?, settingsRevision = settingsRevision + 1
             WHERE id = ?
            """, arguments: [backup.settings, backup.caseSensitive, backup.duplicateGrouping,
                             backup.thumbnailsAlwaysHidden, libraryID])

        // フォーマット・階層・保護文字列は付随データを持たないのでまとめて
        // 入れ替えてよい（`updateSettings` と同じ判断）。
        try db.execute(sql: "DELETE FROM filenameFormat WHERE libraryId = ?", arguments: [libraryID])
        for format in backup.filenameFormats {
            var record = FilenameFormatRecord(id: nil, libraryId: libraryID, source: format.source,
                                              priority: format.priority, isEnabled: format.isEnabled)
            try record.insert(db)
        }
        try db.execute(sql: "DELETE FROM volumeFormat WHERE libraryId = ?", arguments: [libraryID])
        for format in backup.volumeFormats {
            var record = VolumeFormatRecord(id: nil, libraryId: libraryID, source: format.source,
                                            priority: format.priority, isEnabled: format.isEnabled,
                                            kind: format.kind)
            try record.insert(db)
        }
        try db.execute(sql: "DELETE FROM folderLevelMapping WHERE libraryId = ?",
                       arguments: [libraryID])
        for mapping in backup.folderLevelMappings {
            var record = FolderLevelMappingRecord(
                id: nil, libraryId: libraryID, level: mapping.level,
                assignmentKind: mapping.assignmentKind,
                labelGroupIndex: mapping.labelGroupIndex, formatSource: mapping.formatSource)
            try record.insert(db)
        }
        try db.execute(sql: "DELETE FROM protectedToken WHERE ownerKind = 'library' AND ownerID = ?",
                       arguments: [libraryID])
        for token in backup.protectedTokens {
            var record = ProtectedTokenRecord(id: nil, ownerKind: "library", ownerID: libraryID,
                                              pattern: token.pattern, position: token.position,
                                              isEnabled: token.isEnabled)
            try record.insert(db)
        }
    }

    private struct LabelKey: Hashable {
        let groupIndex: Int
        let normalized: String
    }
}
