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
                isPreset: type.isPreset,
                version: type.version, definitionJSON: type.definitionJSON),
            registeredTemplate: record.registeredTemplateJSON,
            duplicateGrouping: record.duplicateGrouping,
            thumbnailsAlwaysHidden: record.thumbnailsAlwaysHidden,
            settings: record.settingsJSON,
            labelGroups: try exportFields(db, libraryID: libraryID),
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
            shelves: try exportShelves(db, libraryID: libraryID),
            files: try exportFiles(db, libraryID: libraryID))
    }

    private static func exportFields(_ db: Database,
                                          libraryID: Int64) throws -> [FieldBackup] {
        let fields = try FieldRecord
            .filter(sql: "libraryId = ?", arguments: [libraryID])
            .order(sql: "groupIndex").fetchAll(db)
        return try fields.map { field in
            let labels = try LabelRecord
                .filter(sql: "labelGroupId = ?", arguments: [field.id ?? 0])
                .order(sql: "name").fetchAll(db)
                .map { LabelBackup(name: $0.name, colorHex: $0.colorHex,
                                   isPinned: $0.isPinned, isHidden: $0.isHidden) }
            return FieldBackup(
                groupIndex: field.groupIndex, name: field.name,
                colorHexLight: field.colorHexLight, colorHexDark: field.colorHexDark,
                displayOrder: field.displayOrder,
                assignsAutomatically: field.assignsAutomatically,
                labels: labels)
        }
    }

    /// 保存した絞り込み [SH-12][MG-22]。
    ///
    /// **ラベルは行 ID ではなく `groupIndex` + 名前へ翻訳して出す** [JS-04]。
    /// DB の中では行 ID で持っている [SH-05] が、それは環境ごとに違う値なので
    /// 別のマシンで取り込むと無関係なラベルを指す。翻訳できない ID
    /// （既に消えたラベル）は落とす——文書には「いま存在する条件」だけが載る。
    private static func exportShelves(_ db: Database, libraryID: Int64) throws -> [ShelfBackup] {
        var refByLabelID: [Int64: ShelfLabelBackup] = [:]
        for row in try Row.fetchAll(db, sql: """
            SELECT label.id AS id, label.name AS labelName, labelGroup.groupIndex AS groupIndex
            FROM label JOIN labelGroup ON labelGroup.id = label.labelGroupId
            WHERE labelGroup.libraryId = ?
            """, arguments: [libraryID]) {
            refByLabelID[row["id"] as Int64] = ShelfLabelBackup(groupIndex: row["groupIndex"],
                                                               labelName: row["labelName"])
        }

        return try Row.fetchAll(db, sql: """
            SELECT * FROM shelf WHERE libraryId = ? ORDER BY displayOrder, id
            """, arguments: [libraryID]).map { row in
            let condition = SQLiteShelfRepository.decode(row["conditionJSON"])
            return ShelfBackup(
                name: row["name"],
                displayOrder: row["displayOrder"],
                labels: condition.labelIDs.compactMap { refByLabelID[$0.rawValue] },
                ratingStars: condition.rating?.stars,
                ratingMode: condition.rating?.mode.rawValue,
                searchText: condition.searchText,
                sortKey: condition.sort.key.rawValue,
                sortAscending: condition.sort.ascending,
                displayMode: condition.displayMode.rawValue)
        }
    }

    private static func exportFiles(_ db: Database, libraryID: Int64) throws -> [FileBackup] {
        // 保護スコープの `field:` は**行 ID ではなくフィールド番号**で出す
        // [JS-04 と同じ理由]——行 ID を書くと、別の環境で取り込んだときに
        // 無関係なフィールドを保護する。
        let groupIndexByID = try Row.fetchAll(db, sql:
            "SELECT id, groupIndex FROM labelGroup WHERE libraryId = ?", arguments: [libraryID])
            .reduce(into: [Int64: Int]()) { $0[$1["id"] as Int64] = $1["groupIndex"] as Int }

        // ラベル紐づけは**ライブラリ単位で 1 回引いて**ファイル ID で束ねる。
        // ファイルごとに引くと 10 万件で 10 万回の問い合わせになる。
        //
        // **保護されたフィールドの紐づけだけを出す** [PR-02][MG-22]。保護されて
        // いないフィールドのラベルは再スキャンが付け直すので、書き出しても
        // 取り込みが何もしない——蔵書の規模ぶん無駄に膨らむだけ。
        // 保護のあるファイルへ先に絞ってから（`protectedScopes <> '[]'`）
        // フィールドごとの判定をする。
        var labelsByFile: [Int64: [FileLabelBackup]] = [:]
        let rows = try Row.fetchAll(db, sql: """
            SELECT fileLabel.managedFileId AS fileId, fileLabel.assignedAt,
                   label.name AS labelName, label.labelGroupId AS groupId,
                   labelGroup.groupIndex AS groupIndex, labelGroup.name AS groupName,
                   mf.protectedScopes AS scopes
            FROM fileLabel
            JOIN label ON label.id = fileLabel.labelId
            JOIN labelGroup ON labelGroup.id = label.labelGroupId
            JOIN managedFile mf ON mf.id = fileLabel.managedFileId
            WHERE labelGroup.libraryId = ? AND mf.protectedScopes <> ?
            ORDER BY fileLabel.managedFileId, labelGroup.groupIndex, label.name
            """, arguments: [libraryID, ProtectionScopeCoding.empty])
        for row in rows {
            let scopes = ProtectionScopeCoding.decode(row["scopes"])
            guard scopes.contains(.field(FieldID(rawValue: row["groupId"] as Int64)))
            else { continue }
            let fileID: Int64 = row["fileId"]
            labelsByFile[fileID, default: []].append(FileLabelBackup(
                groupIndex: row["groupIndex"],
                groupName: row["groupName"],
                labelName: row["labelName"],
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
                let scopes = ProtectionScopeCoding.decode(record.protectedScopes)
                let file = FileBackup(
                    relativePath: record.relativePath,
                    filename: record.filename,
                    rating: record.rating,
                    // 保護されていない基本情報はパーサが作り直す [PR-01]。
                    // 出しても害は無いが、10 万件ぶん膨らむだけで復元には使わない。
                    title: scopes.contains(.basic) ? record.title : nil,
                    seriesName: scopes.contains(.basic) ? record.seriesName : nil,
                    volumeNumber: scopes.contains(.basic) ? record.volumeNumber : nil,
                    volumeKind: scopes.contains(.basic) ? record.volumeKind : nil,
                    volumeRaw: scopes.contains(.basic) ? record.volumeRaw : nil,
                    authorName: scopes.contains(.basic) ? record.authorName : nil,
                    protectedScopes: Self.exportScopes(scopes,
                                                       groupIndexByID: groupIndexByID),
                    coverImageSource: record.coverImageSource,
                    // 同じ理由で、自動抽出したカバーの参照は出さない [IV-03]。
                    coverImageRef: record.coverImageSource == CoverSource.auto.rawValue
                        ? nil : record.coverImageRef,
                    isArchived: record.isArchived,
                    archivedFromPath: record.archivedFromPath,
                    archivedAt: record.archivedAt.map(Date.init(timeIntervalSinceReferenceDate:)),
                    state: record.state,
                    trashedAt: record.trashedAt.map(Date.init(timeIntervalSinceReferenceDate:)),
                    // 立っているときだけ出す。`title` を自動なら出さないのと同じ
                    // 考え方で、10 万件ぶんの `false` を書いても意味が無い。
                    isUnresolvedIgnored: ignored.contains(id) ? true : nil,
                    // シリーズの提案の無視印 [SS-05]。**タイトルをそのまま出す**
                    // ——名前が変われば無視が解ける、という性質はこの値が
                    // 現在のタイトルと一致するかどうかで表される。
                    seriesSuggestionIgnoredTitle: record.seriesSuggestionIgnoredTitle,
                    labels: labels)
                // **再生成できる情報しか持たない行は出さない。** 再スキャンが
                // 実体から作り直すので、書き出しても取り込みが何もしない
                // ——10 万件の蔵書で JSON が無意味に膨らむのを避ける。
                return file.carriesUnrecoverableData ? file : nil
            }
    }
}

extension SQLiteBackupRepository {
    /// 保護スコープを、環境に依存しない綴りへ翻訳する [PR-09][JS-04]。
    ///
    /// `field:` の数字は**行 ID ではなくフィールド番号**にする。行 ID を
    /// 書くと、別の環境で取り込んだときに無関係なフィールドを保護する。
    static func exportScopes(_ scopes: Set<ProtectionScope>,
                             groupIndexByID: [Int64: Int]) -> [String]? {
        guard !scopes.isEmpty else { return nil }
        var keys: [String] = []
        for scope in scopes {
            switch scope {
            case .basic:
                keys.append(ProtectionScope.basicKey)
            case .field(let id):
                // **翻訳できない保護は出さない。** フィールドが消えていれば
                // 番号が無く、取り込み先でも意味を持てない。
                guard let index = groupIndexByID[id.rawValue] else { continue }
                keys.append(ProtectionScope.portableFieldKey(index: index))
            }
        }
        return keys.isEmpty ? nil : keys.sorted()
    }

    /// 文書の保護スコープを、この環境の行 ID へ翻訳する [PR-09]。
    ///
    /// **版 2 以前の文書は `protectedScopes` を持たない**ので、`titleOrigin` と
    /// 紐づけの `origin` から導く——DB の `v10_metadataProtection` と同じ規則
    /// （`LegacyMetadataProtection`）を通すので、以前書き出した文書と移行済みの
    /// DB とで結果が食い違わない。
    static func importScopes(_ file: FileBackup,
                             groupIDByIndex: [Int: Int64]) -> Set<ProtectionScope> {
        var result: Set<ProtectionScope> = []
        if let keys = file.protectedScopes {
            for key in keys {
                if key == ProtectionScope.basicKey { result.insert(.basic); continue }
                guard let index = ProtectionScope.portableFieldIndex(from: key),
                      let id = groupIDByIndex[index] else { continue }
                result.insert(.field(FieldID(rawValue: id)))
            }
            return result
        }
        if LegacyMetadataProtection.basicIsProtected(titleOrigin: file.titleOrigin) {
            result.insert(.basic)
        }
        for link in file.labels
        where LegacyMetadataProtection.fieldIsProtected(labelOrigin: link.origin) {
            guard let id = groupIDByIndex[link.groupIndex] else { continue }
            result.insert(.field(FieldID(rawValue: id)))
        }
        return result
    }
}

extension FileBackup {
    /// この行に、再スキャンでは作り直せない情報が載っているか [MG-22]。
    ///
    /// **判定を 1 箇所に閉じる。** 書き出し（何を出すか）と取り込み（何を
    /// 書き戻すか）が別々の条件を持つと、片方だけ直したときに静かにずれる。
    var carriesUnrecoverableData: Bool {
        if rating != 0 { return true }
        if protectedScopes?.isEmpty == false { return true }
        if coverImageSource != "auto" { return true }
        if isArchived || archivedFromPath != nil { return true }
        // `active` 以外の状態（孤立・ゴミ箱）は観測の結果なので再現し得るが、
        // ゴミ箱の日付だけは人の操作の記録で作り直せない [TR-01]。
        if trashedAt != nil { return true }
        // 「以後無視する」[AL-33] も人の判断。これだけを持つ行も残す。
        if isUnresolvedIgnored == true { return true }
        // シリーズの提案の無視 [SS-05] も同じく人の判断。
        if seriesSuggestionIgnoredTitle != nil { return true }
        // ここへ来る `labels` は保護されたフィールドのものだけに絞ってある
        // ——保護されていなければ再スキャンが付け直す [PR-01]。
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
                fieldsAdded: 0, labelsAdded: 0, fileLabelsAdded: 0)
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

        // --- ラベルフィールドとラベル ---------------------------------------
        // **フィールドは作り直さない。** ラベルが `labelGroup` へ連鎖削除で
        // 紐づいているので、消して入れ直すと蓄積したラベルと紐づけが全部
        // 消える（`updateSettings` が守っているのと同じ不変条件）。
        var groupIDByIndex: [Int: Int64] = [:]
        for field in backup.labelGroups {
            let existing = try FieldRecord
                .filter(sql: "libraryId = ? AND groupIndex = ?",
                        arguments: [libraryID, field.groupIndex])
                .fetchOne(db)
            if let existing, let id = existing.id {
                groupIDByIndex[field.groupIndex] = id
                if !dryRun {
                    var updated = existing
                    updated.name = field.name
                    updated.colorHexLight = field.colorHexLight
                    updated.colorHexDark = field.colorHexDark
                    updated.displayOrder = field.displayOrder
                    updated.assignsAutomatically = field.assignsAutomatically
                    try updated.update(db)
                }
            } else {
                groupsAdded += 1
                guard !dryRun else { continue }
                var created = FieldRecord(
                    id: nil, libraryId: libraryID, groupIndex: field.groupIndex,
                    name: field.name, colorHexLight: field.colorHexLight,
                    colorHexDark: field.colorHexDark, displayOrder: field.displayOrder,
                    assignsAutomatically: field.assignsAutomatically)
                try created.insert(db)
                groupIDByIndex[field.groupIndex] = created.id
            }
        }

        // ラベル。一意性は `(フィールド, 正規化名)` [LB-01][N-03]。
        var labelIDByKey: [LabelKey: Int64] = [:]
        for field in backup.labelGroups {
            guard let fieldID = groupIDByIndex[field.groupIndex] else {
                // dryRun でフィールドがまだ無い場合。ラベルは全件が新規になる。
                labelsAdded += field.labels.count
                continue
            }
            for label in field.labels {
                let normalized = TextNormalizer.normalize(label.name)
                let existing = try LabelRecord
                    .filter(sql: "labelGroupId = ? AND normalizedName = ?",
                            arguments: [fieldID, normalized])
                    .fetchOne(db)
                if let existing, let id = existing.id {
                    labelIDByKey[LabelKey(groupIndex: field.groupIndex, normalized: normalized)] = id
                    if !dryRun {
                        var updated = existing
                        // 原文・色・ピン・非表示はユーザーの設定 [MG-22]。
                        // **件数の列はもう無い** [DB-02 撤回]。
                        updated.name = label.name
                        updated.colorHex = label.colorHex
                        updated.isPinned = label.isPinned
                        updated.isHidden = label.isHidden
                        try updated.update(db)
                    }
                } else {
                    labelsAdded += 1
                    guard !dryRun else { continue }
                    var created = LabelRecord(
                        id: nil, labelGroupId: fieldID, name: label.name,
                        normalizedName: normalized, colorHex: label.colorHex,
                        isPinned: label.isPinned, isHidden: label.isHidden)
                    try created.insert(db)
                    labelIDByKey[LabelKey(groupIndex: field.groupIndex,
                                          normalized: normalized)] = created.id
                }
            }
        }

        // --- シェルフ -----------------------------------------------------
        // **名前で突き合わせて重ねる** [SH-12][JS-06]。取り込みは「消せない」
        // 方針なので、文書に無いシェルフは残す——復旧のつもりの取り込みで
        // 別の絞り込みを失う経路を作らない [JS-05 と同じ判断]。
        if !dryRun {
            try applyShelves(db, libraryID: libraryID, backup: backup,
                             labelIDByKey: labelIDByKey)
        }

        // --- ファイル -----------------------------------------------------
        // 行は作らない。**再スキャンが実体から作った行にだけ値を載せる**
        // ——実体を伴わないレコードを増やすと、次の走査でそれが孤立として
        // 現れ「消えたファイル」の報告に混ざる [ID-06]。
        var filesMissing = 0
        var filesUpdated = 0

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
                try writeBack(db, file, into: existing, fileID: fileID,
                              scopes: importScopes(file, groupIDByIndex: groupIDByIndex))
            }
            for link in file.labels {
                // 版 2 以前の「外した」印は紐づけとして取り込まない [PR-08]。
                // 保護のほうへ読み替え済みで、行を作ると外したはずのラベルが
                // 復活する。
                guard LegacyMetadataProtection.isAttached(labelOrigin: link.origin) else { continue }
                let normalized = TextNormalizer.normalize(link.labelName)
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
                    db, fileID: FileID(rawValue: fileID), labelID: LabelID(rawValue: labelID))
            }
        }

        return ImportPlan.LibraryChange(
            identityKey: backup.identityKey, displayName: backup.displayName,
            kind: .update, filesMissing: filesMissing, filesUpdated: filesUpdated,
            fieldsAdded: groupsAdded, labelsAdded: labelsAdded,
            fileLabelsAdded: fileLabelsAdded)
    }

    /// ファイル 1 件に、再生成できない値だけを書き戻す [MG-22]。
    ///
    /// **再生成できる列には触れない。** 触ると、走査が実体から読んだ正しい値を
    /// 古いバックアップで上書きすることになる（ファイルサイズ・更新日時・
    /// パーサの結果など、実体が正である列）。
    private static func writeBack(_ db: Database, _ file: FileBackup,
                                  into existing: ManagedFileRecord, fileID: Int64,
                                  scopes: Set<ProtectionScope>) throws {
        var record = existing
        record.rating = file.rating
        record.protectedScopes = ProtectionScopeCoding.encode(scopes)
        // 保護されていない基本情報はパーサが作る。保護されているときだけ
        // 書き戻す [PR-01]。**4 つとも戻す**——1 つでも落とすと、保護した
        // つもりの値が復元後に自動値のまま残る。
        if scopes.contains(.basic) {
            record.title = file.title
            record.seriesName = file.seriesName
            record.seriesKey = file.seriesName.map { TextNormalizer.normalize($0) }
            record.volumeNumber = file.volumeNumber
            if let kind = file.volumeKind { record.volumeKind = kind }
            record.volumeRaw = file.volumeRaw
            record.authorName = file.authorName
        }
        record.coverImageSource = file.coverImageSource
        if file.coverImageSource != CoverSource.auto.rawValue {
            record.coverImageRef = file.coverImageRef
        }
        record.isArchived = file.isArchived
        record.archivedFromPath = file.archivedFromPath
        record.archivedAt = file.archivedAt?.timeIntervalSinceReferenceDate
        record.trashedAt = file.trashedAt?.timeIntervalSinceReferenceDate
        // シリーズの提案の無視印 [SS-05]。**取り込んだ値が現在のタイトルと
        // 食い違っていても書き戻してよい**——判定は読み出し側が行うので、
        // 一致しなければ自然に「無視していない」になる。
        record.seriesSuggestionIgnoredTitle = file.seriesSuggestionIgnoredTitle
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

    /// 保存した絞り込みを取り込む [SH-12]。
    ///
    /// **ラベルは `groupIndex` + 正規化名で引き直す** [JS-04]。引けなかった参照
    /// （この環境に無いラベル）は落とす——存在しない行 ID を条件に残すと、
    /// 後から同じ ID が別のラベルへ割り当たる余地を作ることになる
    /// （`label.id` は AUTOINCREMENT なので実際には起きないが、文書は別の
    /// マシンから来るので保証が無い）。
    ///
    /// 読めない列挙の生値は既定へ落とす（`ShelfBackup` の型コメント参照）。
    private static func applyShelves(_ db: Database, libraryID: Int64,
                                     backup: LibraryBackup,
                                     labelIDByKey: [LabelKey: Int64]) throws {
        guard let shelves = backup.shelves, !shelves.isEmpty else { return }

        // **同じ名前の行を 1 つずつ消費する**［code-review の指摘］。SH-03 は
        // 同名を許すので、単に「その名前の最初の行」を毎回選ぶと、文書に
        // 同名が 2 つある場合に 2 件目が 1 件目を上書きし、**条件が 1 つ静かに
        // 失われる**（しかも復元の経路で起きる）。
        var unclaimed: [String: [Int64]] = [:]
        for row in try Row.fetchAll(db, sql: """
            SELECT id, name FROM shelf WHERE libraryId = ? ORDER BY displayOrder, id
            """, arguments: [libraryID]) {
            unclaimed[row["name"] as String, default: []].append(row["id"] as Int64)
        }

        for shelf in shelves {
            let labelIDs = shelf.labels.compactMap { ref -> LabelID? in
                let key = LabelKey(groupIndex: ref.groupIndex,
                                   normalized: TextNormalizer.normalize(ref.labelName))
                return labelIDByKey[key].map { LabelID(rawValue: $0) }
            }
            let rating = shelf.ratingStars.map {
                FileQuery.RatingFilter(
                    stars: $0,
                    mode: shelf.ratingMode.flatMap(FileQuery.RatingFilter.Mode.init) ?? .atLeast)
            }
            let condition = ShelfCondition(
                labelIDs: labelIDs,
                rating: rating,
                searchText: shelf.searchText,
                sort: FileQuery.SortSpec(
                    key: FileQuery.SortKey(rawValue: shelf.sortKey) ?? .filename,
                    ascending: shelf.sortAscending),
                displayMode: FileQuery.DisplayMode(rawValue: shelf.displayMode) ?? .libraryFlat)
            let json = try SQLiteShelfRepository.encode(condition)

            if let existing = unclaimed[shelf.name]?.first {
                unclaimed[shelf.name]?.removeFirst()
                try db.execute(sql: """
                    UPDATE shelf SET conditionJSON = ?, displayOrder = ? WHERE id = ?
                    """, arguments: [json, shelf.displayOrder, existing])
            } else {
                try db.execute(sql: """
                    INSERT INTO shelf (libraryId, name, displayOrder, conditionJSON, createdAt)
                    VALUES (?, ?, ?, ?, ?)
                    """, arguments: [libraryID, shelf.name, shelf.displayOrder, json,
                                     Date().timeIntervalSince1970])
            }
        }
    }

    /// 設定を置き換える [LS-01][VT-02]。
    private static func replaceSettings(_ db: Database, libraryID: Int64,
                                        backup: LibraryBackup) throws {
        // **`COALESCE` で書き戻す** [LT-10]。文書が登録時の定義を持たない
        // （版 4 以前の書き出し）ときに `NULL` で潰すと、いま有効化して
        // 得たばかりの base を消してしまう——復元したつもりで差分の基準を
        // 失う、という気づきにくい壊れ方になる。
        try db.execute(sql: """
            UPDATE library
               SET settingsJSON = ?, duplicateGrouping = ?,
                   thumbnailsAlwaysHidden = ?,
                   registeredTemplateJSON = COALESCE(?, registeredTemplateJSON),
                   settingsRevision = settingsRevision + 1
             WHERE id = ?
            """, arguments: [backup.settings, backup.duplicateGrouping,
                             backup.thumbnailsAlwaysHidden, backup.registeredTemplate,
                             libraryID])

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
