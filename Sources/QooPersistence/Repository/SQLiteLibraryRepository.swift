//
//  LibraryRepository の SQLite 実装 [A-02][RP2-01〜RP2-05]。
//
import Foundation
import GRDB
import QooKit

public struct SQLiteLibraryRepository: LibraryRepository, Sendable {
    let database: QooDatabase
    /// 巻数フォーマットセットの定義。登録時のテンプレート展開に使う。
    let volumeSets: VolumeSetDefinition

    public init(database: QooDatabase, volumeSets: VolumeSetDefinition) {
        self.database = database
        self.volumeSets = volumeSets
    }

    public enum RepositoryError: Error, Equatable {
        case libraryNotFound(LibraryID)
        case libraryTypeNotFound(String)
        case templateInvalid(String)
        /// 検証を通らない設定 [LS-01]。不備を全件持つ——1 件ずつ返すと
        /// 直すたびに保存を試す往復になる。
        case settingsInvalid([LibrarySettingsIssue])
    }

    // MARK: - 読み取り

    public func libraries() async throws -> [LibrarySummary] {
        try await database.writer.read { db in
            try Self.summaries(db, filter: nil)
        }
    }

    public func library(id: LibraryID) async throws -> LibrarySummary? {
        try await database.writer.read { db in
            try Self.summaries(db, filter: ("library.id = ?", [id.rawValue])).first
        }
    }

    public func library(uuid: UUID) async throws -> LibrarySummary? {
        try await database.writer.read { db in
            try Self.summaries(db, filter: ("library.uuid = ?", [uuid.uuidString])).first
        }
    }

    static func summaries(_ db: Database,
                          filter: (sql: String, args: [any DatabaseValueConvertible])?)
        throws -> [LibrarySummary]
    {
        var sql = """
            SELECT library.*, libraryType.libraryTypeName AS typeName,
                   (SELECT COUNT(*) FROM managedFile
                     WHERE managedFile.libraryId = library.id
                       AND managedFile.state = 'active') AS fileCount
            FROM library
            JOIN libraryType ON libraryType.id = library.libraryTypeId
            """
        var arguments = StatementArguments()
        if let filter {
            sql += "\nWHERE \(filter.sql)"
            arguments = StatementArguments(filter.args.map { Optional($0) })
        }
        sql += "\nORDER BY library.displayName"
        return try Row.fetchAll(db, sql: sql, arguments: arguments).map { row in
            LibrarySummary(
                id: LibraryID(rawValue: row["id"]),
                uuid: UUID(uuidString: row["uuid"]) ?? UUID(),
                displayName: row["displayName"],
                resolvedPath: row["resolvedPath"],
                volumeUUID: row["volumeUUID"],
                libraryTypeID: LibraryTypeID(rawValue: row["libraryTypeId"]),
                libraryTypeName: row["typeName"],
                isOnline: row["isOnline"],
                isReadOnlyDueToFS: row["isReadOnlyDueToFS"],
                fileCount: row["fileCount"],
                settingsRevision: row["settingsRevision"])
        }
    }

    /// パーサへ渡す設定を組み立てる [VT-01][VT-02]。
    ///
    /// フォーマットのコンパイルは毎回行う。`settingsRevision` でキャッシュするのは
    /// 呼び出し側の責務 [VT-02][VT-03]。
    public func settingsSnapshot(libraryID: LibraryID) async throws -> LibrarySettingsSnapshot? {
        try await database.writer.read { db in
            guard let library = try LibraryRecord.fetchOne(db, key: libraryID.rawValue),
                  let type = try LibraryTypeRecord.fetchOne(db, key: library.libraryTypeId)
            else { return nil }

            let payload = (try? JSONDecoder().decode(
                LibrarySettingsPayload.self, from: Data(library.settingsJSON.utf8)))
                ?? .empty
            let options = NormalizationOptions(caseSensitive: library.caseSensitive)
            let allTypeNames = try String.fetchAll(
                db, sql: "SELECT DISTINCT libraryTypeName FROM libraryType ORDER BY libraryTypeName")
            let allDisplayNames = try String.fetchAll(
                db, sql: "SELECT displayName FROM library ORDER BY displayName")

            let semantic: [SemanticKeyword: Int] = payload.semanticBindings.reduce(into: [:]) {
                if let k = SemanticKeyword(rawValue: $1.key) { $0[k] = $1.value }
            }
            let context = FormatCompilationContext(
                delimiters: payload.delimiters,
                allLibraryTypeNames: allTypeNames,
                allLibraryDisplayNames: allDisplayNames,
                semanticBindings: semantic,
                normalization: options)

            // 壊れたフォーマットは黙って落とす——保存時に検証済みなので通常は起こらない
            // が、DB を手で編集された場合にライブラリ全体が開けなくなるのを避ける。
            let formats = try FilenameFormatRecord
                .filter(sql: "libraryId = ? AND isEnabled = 1", arguments: [libraryID.rawValue])
                .order(sql: "priority")
                .fetchAll(db)
                .compactMap { record -> CompiledFormat? in
                    try? FormatCompiler.compile(record.source, context: context,
                                                isEnabled: record.isEnabled,
                                                priority: record.priority)
                }

            let volumePatterns = try VolumeFormatRecord
                .filter(sql: "libraryId = ? AND isEnabled = 1", arguments: [libraryID.rawValue])
                .order(sql: "priority")
                .fetchAll(db)
                .map { VolumePattern(source: $0.source, isEnabled: true,
                                     priority: $0.priority,
                                     kind: VolumePatternKind(rawValue: $0.kind) ?? .volume) }

            var levels: [Int: FolderLevelMappingSpec.Assignment] = [:]
            for record in try FolderLevelMappingRecord
                .filter(sql: "libraryId = ?", arguments: [libraryID.rawValue]).fetchAll(db) {
                switch record.assignmentKind {
                case "singleLabelGroup":
                    if let g = record.labelGroupIndex { levels[record.level] = .singleLabelGroup(index: g) }
                case "format":
                    if let src = record.formatSource,
                       let f = try? FormatCompiler.compile(src, context: context) {
                        levels[record.level] = .format(f)
                    }
                default:
                    levels[record.level] = FolderLevelMappingSpec.Assignment.none
                }
            }

            let tokens = try ProtectedTokenRecord
                .filter(sql: "ownerKind = 'library' AND ownerID = ?", arguments: [libraryID.rawValue])
                .fetchAll(db)
                .map { ProtectedToken(pattern: $0.pattern,
                                      position: ProtectedToken.Position(rawValue: $0.position) ?? .anywhere,
                                      isEnabled: $0.isEnabled) }

            return LibrarySettingsSnapshot(
                libraryID: libraryID,
                settingsRevision: library.settingsRevision,
                displayName: library.displayName,
                libraryTypeName: type.libraryTypeName,
                allLibraryTypeNames: allTypeNames,
                allLibraryDisplayNames: allDisplayNames,
                targetExtensions: Set(payload.targetExtensions),
                imageExtensions: Set(payload.imageExtensions),
                delimiters: payload.delimiters,
                protectedTokens: ProtectedTokenCompiler.compileAll(tokens),
                filenameFormats: formats,
                folderLevelAssignments: levels,
                volumeFormats: VolumePatternCompiler.compileAll(volumePatterns),
                semanticBindings: semantic,
                normalization: options,
                seriesTitleCompositionFormat: payload.seriesTitleCompositionFormat,
                readsEmbeddedMetadata: payload.readsEmbeddedMetadata,
                comicInfoVolumeSource: payload.comicInfoVolumeSource)
        }
    }

    public func totalFileCount() async throws -> Int {
        try await database.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM managedFile") ?? 0
        }
    }

    // MARK: - 書き込み

    /// ライブラリを登録し、テンプレートの内容をコピーする [RG-01][LT-03]。
    ///
    /// **以後の設定変更はライブラリ側に閉じる**——テンプレート本体には影響しない [LT-03]。
    /// テンプレートから登録する [RG-01][LT-03]。
    ///
    /// **既定値を持たず、`TemplateInstantiation.draft(from:)` へ委譲する。**
    /// 有効化ダイアログが見せるのも同じ関数の結果なので、**利用者が見た内容が
    /// そのまま登録される**ことが構造的に保証される——ここに独自の既定値を
    /// 書き足すと、その保証が静かに壊れる。
    public func register(_ registration: LibraryRegistration,
                         template: LibraryTypeTemplate) async throws -> LibraryID {
        let draft = TemplateInstantiation.draft(
            from: template, volumeSets: volumeSets, displayName: registration.displayName)
        return try await register(registration, draft: draft, template: template)
    }

    /// 草案から登録する [RG-01][LT-02][LS-01]。
    ///
    /// - Parameter template: プリセット由来なら渡す。`libraryType` の行を
    ///   `presetKey` で同定し、改訂されていれば版だけ上げる [LT-10][LT-11]。
    ///   **`nil` は「白紙から作ったカスタム」**で、専用の非プリセット型を作る。
    public func register(_ registration: LibraryRegistration,
                         draft: LibrarySettingsDraft,
                         template: LibraryTypeTemplate?) async throws -> LibraryID {
        // **登録の時点で検証する。** 不備のある設定で走査を始めると、
        // 全件が未解決になってから初めて気づくことになる。
        let errors = draft.validationErrors
        guard errors.isEmpty else { throw RepositoryError.settingsInvalid(errors) }
        let payloadJSON = try Self.payloadJSON(draft)

        return try await database.writer.write { db in
            let typeID = try Self.resolveTypeIDForRegistration(db, template: template, draft: draft)
            var library = LibraryRecord(
                id: nil, uuid: registration.uuid.uuidString,
                displayName: draft.displayName.isEmpty
                    ? registration.displayName : draft.displayName,
                bookmarkData: registration.bookmarkData,
                resolvedPath: registration.resolvedPath,
                volumeUUID: registration.volumeUUID,
                libraryTypeId: typeID,
                libraryTypeVersion: template?.version ?? 1,
                settingsJSON: payloadJSON,
                caseSensitive: draft.caseSensitive,
                duplicateGrouping: "off",
                thumbnailsAlwaysHidden: draft.thumbnailsAlwaysHidden,
                lastFSEventID: 0, lastFullScanAt: nil,
                isOnline: true, isReadOnlyDueToFS: false, settingsRevision: 0)
            try library.insert(db)
            let libraryID = library.id ?? 0
            try Self.writeSettingsTables(db, draft, libraryID: libraryID)
            return LibraryID(rawValue: libraryID)
        }
    }

    /// 登録時のライブラリタイプを決める [LT-01][LT-05][LT-10][LT-11]。
    private static func resolveTypeIDForRegistration(
        _ db: Database, template: LibraryTypeTemplate?, draft: LibrarySettingsDraft
    ) throws -> Int64 {
        if let template {
            if var existing = try LibraryTypeRecord
                .filter(sql: "presetKey = ?", arguments: [template.key]).fetchOne(db) {
                // 改訂されていたら版だけ上げる。**設定は自動反映しない** [LT-11]
                if existing.version != template.version {
                    existing.version = template.version
                    try existing.update(db)
                }
                // 型名を編集して登録した場合、プリセット行は共有物なので
                // 書き換えられない [LT-05]。専用の型へ分岐させる。
                if existing.libraryTypeName != draft.libraryTypeName {
                    return try makeCustomType(db, draft: draft, basedOn: template)
                }
                return existing.id ?? 0
            }
            var record = LibraryTypeRecord(
                id: nil, presetKey: template.key, name: template.displayName,
                libraryTypeName: template.libraryTypeName, isPreset: true,
                version: template.version,
                definitionJSON: String(decoding: try JSONEncoder().encode(template), as: UTF8.self))
            try record.insert(db)
            // 型名を編集済みなら、作ったプリセット行はそのままに専用型を作る。
            if record.libraryTypeName != draft.libraryTypeName {
                return try makeCustomType(db, draft: draft, basedOn: template)
            }
            return record.id ?? 0
        }
        return try makeCustomType(db, draft: draft, basedOn: nil)
    }

    /// このライブラリ専用の非プリセット型を作る [LT-02][LT-05]。
    ///
    /// **`presetKey` を持たせない。** 持たせると次に同じプリセットから
    /// 登録したライブラリがこの行を共有し、型名の編集が他へ波及する。
    private static func makeCustomType(_ db: Database, draft: LibrarySettingsDraft,
                                       basedOn template: LibraryTypeTemplate?) throws -> Int64 {
        var record = LibraryTypeRecord(
            id: nil, presetKey: nil,
            name: draft.libraryTypeName.isEmpty ? draft.displayName : draft.libraryTypeName,
            libraryTypeName: draft.libraryTypeName,
            isPreset: false,
            version: template?.version ?? 1,
            definitionJSON: template.map {
                String(decoding: (try? JSONEncoder().encode($0)) ?? Data(), as: UTF8.self)
            } ?? "{}")
        try record.insert(db)
        return record.id ?? 0
    }

    /// 登録解除 [RG-06]。
    ///
    /// `keepLabels` はフェーズ 2 のラベル保管庫へ回すかどうか。**現時点では
    /// どちらでもライブラリ行を消す**（連鎖でファイル・ラベルも消える）。
    /// 保管庫（2-11）が入ったら `keepLabels == true` の経路をそこへ繋ぐ。
    public func unregister(id: LibraryID, keepLabels: Bool) async throws {
        _ = keepLabels
        try await database.writer.write { db in
            try db.execute(sql: "DELETE FROM library WHERE id = ?", arguments: [id.rawValue])
        }
    }

    public func setOnline(_ online: Bool, libraryID: LibraryID) async throws {
        try await database.writer.write { db in
            try db.execute(sql: "UPDATE library SET isOnline = ? WHERE id = ?",
                           arguments: [online, libraryID.rawValue])
        }
    }

    public func setResolvedPath(_ path: String, libraryID: LibraryID) async throws {
        try await database.writer.write { db in
            try db.execute(sql: "UPDATE library SET resolvedPath = ? WHERE id = ?",
                           arguments: [path, libraryID.rawValue])
        }
    }

    // MARK: - 監視と差分スキャンの状態 [SY-01〜SY-05]

    public func watchStates() async throws -> [LibraryWatchState] {
        try await database.writer.read { db in
            try Row.fetchAll(db, sql: """
                SELECT id, uuid, displayName, resolvedPath, volumeUUID, isOnline,
                       lastFSEventID, fsEventsUUID, lastFullScanAt
                FROM library ORDER BY id
                """).map { row in
                LibraryWatchState(
                    id: LibraryID(rawValue: row["id"]),
                    uuid: UUID(uuidString: row["uuid"]) ?? UUID(),
                    displayName: row["displayName"],
                    resolvedPath: row["resolvedPath"],
                    volumeUUID: row["volumeUUID"],
                    isOnline: row["isOnline"],
                    checkpoint: FSEventsCheckpoint(
                        // 保存は `Int64(bitPattern:)` なので読み戻しも対称に。
                        // 素の `UInt64(row[...])` は上位ビットが立った値で落ちる。
                        eventID: UInt64(bitPattern: row["lastFSEventID"] as Int64),
                        deviceUUID: row["fsEventsUUID"]),
                    lastFullScanAt: (row["lastFullScanAt"] as Double?)
                        .map(Date.init(timeIntervalSince1970:)))
            }
        }
    }

    public func setFSEventsCheckpoint(_ checkpoint: FSEventsCheckpoint,
                                      libraryID: LibraryID) async throws {
        try await database.writer.write { db in
            try db.execute(
                sql: "UPDATE library SET lastFSEventID = ?, fsEventsUUID = ? WHERE id = ?",
                arguments: [Int64(bitPattern: checkpoint.eventID),
                            checkpoint.deviceUUID, libraryID.rawValue])
        }
    }

    public func setLastFullScanAt(_ date: Date, libraryID: LibraryID) async throws {
        try await database.writer.write { db in
            try db.execute(sql: "UPDATE library SET lastFullScanAt = ? WHERE id = ?",
                           arguments: [date.timeIntervalSince1970, libraryID.rawValue])
        }
    }

    // MARK: - 設定の編集 [LS-01〜LS-03]

    /// 編集用の設定を組み立てる [LS-01]。
    ///
    /// `settingsSnapshot` との違いは 2 つ。**ソース文字列のまま返す**（コンパイル
    /// 済みの構文木からは元の文字列を復元できない）ことと、**`isEnabled = 0` の
    /// 行も返す**こと——スナップショットはパーサ用なので無効な行を除くが、それを
    /// 編集に使うと保存時に無効な行が消える。
    public func settingsDraft(libraryID: LibraryID) async throws -> LibrarySettingsDraft? {
        try await database.writer.read { db in
            guard let library = try LibraryRecord.fetchOne(db, key: libraryID.rawValue),
                  let type = try LibraryTypeRecord.fetchOne(db, key: library.libraryTypeId)
            else { return nil }

            let payload = (try? JSONDecoder().decode(
                LibrarySettingsPayload.self, from: Data(library.settingsJSON.utf8))) ?? .empty

            // **自分を除いた**他ライブラリの型名・表示名だけを持たせる。編集中の
            // 値は草案側が足すので、型名を書き換えても列挙候補が取り残されない。
            let otherTypeNames = try String.fetchAll(db, sql: """
                SELECT DISTINCT libraryType.libraryTypeName FROM libraryType
                WHERE libraryType.id <> ?
                ORDER BY libraryType.libraryTypeName
                """, arguments: [library.libraryTypeId])
            let otherDisplayNames = try String.fetchAll(
                db, sql: "SELECT displayName FROM library WHERE id <> ? ORDER BY displayName",
                arguments: [libraryID.rawValue])

            let groups = try LabelGroupRecord
                .filter(sql: "libraryId = ?", arguments: [libraryID.rawValue])
                .order(sql: "displayOrder, groupIndex")
                .fetchAll(db)
                .map { record in
                    LabelGroupDraft(persistentID: record.id, index: record.groupIndex,
                                    name: record.name,
                                    colorHexLight: record.colorHexLight,
                                    colorHexDark: record.colorHexDark,
                                    assignsAutomatically: record.assignsAutomatically)
                }

            let formats = try FilenameFormatRecord
                .filter(sql: "libraryId = ?", arguments: [libraryID.rawValue])
                .order(sql: "priority")
                .fetchAll(db)
                .map { FilenameFormatDraft(source: $0.source, isEnabled: $0.isEnabled) }

            let volumes = try VolumeFormatRecord
                .filter(sql: "libraryId = ?", arguments: [libraryID.rawValue])
                .order(sql: "priority")
                .fetchAll(db)
                .map { VolumeFormatDraft(source: $0.source, isEnabled: $0.isEnabled,
                                         kind: VolumePatternKind(rawValue: $0.kind) ?? .volume) }

            let levels = try FolderLevelMappingRecord
                .filter(sql: "libraryId = ?", arguments: [libraryID.rawValue])
                .order(sql: "level")
                .fetchAll(db)
                .map { record -> FolderLevelDraft in
                    let assignment: FolderLevelDraft.Assignment
                    switch record.assignmentKind {
                    case "singleLabelGroup":
                        assignment = record.labelGroupIndex.map { .singleLabelGroup(index: $0) }
                            ?? FolderLevelDraft.Assignment.none
                    case "format":
                        assignment = record.formatSource.map { .format(source: $0) }
                            ?? FolderLevelDraft.Assignment.none
                    default:
                        assignment = FolderLevelDraft.Assignment.none
                    }
                    return FolderLevelDraft(level: record.level, assignment: assignment)
                }

            let tokens = try ProtectedTokenRecord
                .filter(sql: "ownerKind = 'library' AND ownerID = ?", arguments: [libraryID.rawValue])
                .order(sql: "id")
                .fetchAll(db)
                .map { ProtectedToken(pattern: $0.pattern,
                                      position: ProtectedToken.Position(rawValue: $0.position) ?? .anywhere,
                                      isEnabled: $0.isEnabled) }

            let semantic: [SemanticKeyword: Int] = payload.semanticBindings.reduce(into: [:]) {
                if let k = SemanticKeyword(rawValue: $1.key) { $0[k] = $1.value }
            }

            return LibrarySettingsDraft(
                displayName: library.displayName,
                libraryTypeName: type.libraryTypeName,
                caseSensitive: library.caseSensitive,
                thumbnailsAlwaysHidden: library.thumbnailsAlwaysHidden,
                targetExtensions: payload.targetExtensions.sorted(),
                imageExtensions: payload.imageExtensions.sorted(),
                delimiters: payload.delimiters,
                protectedTokens: tokens,
                labelGroups: groups,
                semanticBindings: semantic,
                filenameFormats: formats,
                volumeFormats: volumes,
                folderLevels: levels,
                seriesTitleCompositionFormat: payload.seriesTitleCompositionFormat,
                readsEmbeddedMetadata: payload.readsEmbeddedMetadata,
                comicInfoVolumeSource: payload.comicInfoVolumeSource,
                otherLibraryTypeNames: otherTypeNames,
                otherLibraryDisplayNames: otherDisplayNames)
        }
    }

    /// 設定を保存する [LS-01][LT-03]。
    ///
    /// ## 3 つの不変条件をここで守る
    /// 1. **検証を通らない草案は書かない。** `settingsSnapshot` は壊れた
    ///    フォーマットを黙って落とす造りで、「保存時に検証済み」を前提にしている。
    /// 2. **`settingsRevision` を必ず上げる** [VT-02]。パーサはこの値で
    ///    コンパイル結果をキャッシュするので、上げ忘れると設定変更が効かない。
    ///    呼び出し側に任せず、この 1 箇所で必ず行う。
    /// 3. **ラベルグループは作り直さない。** ラベルは `labelGroup` へ連鎖削除で
    ///    紐づいているため、消して入れ直すと蓄積したラベルと紐づけが全部消える。
    ///    行 ID で同定して更新し、草案から消えたものだけを削除する。
    ///    （フォーマット・階層割り当て・保護文字列は付随データを持たないので
    ///    まとめて入れ替えてよい。）
    public func updateSettings(_ draft: LibrarySettingsDraft,
                               libraryID: LibraryID) async throws {
        let errors = draft.validationErrors
        guard errors.isEmpty else { throw RepositoryError.settingsInvalid(errors) }

        let payloadJSON = try Self.payloadJSON(draft)

        try await database.writer.write { db in
            guard var library = try LibraryRecord.fetchOne(db, key: libraryID.rawValue) else {
                throw RepositoryError.libraryNotFound(libraryID)
            }

            library.libraryTypeId = try Self.resolveLibraryTypeID(
                db, library: library, newTypeName: draft.libraryTypeName)
            library.displayName = draft.displayName
            library.caseSensitive = draft.caseSensitive
            library.thumbnailsAlwaysHidden = draft.thumbnailsAlwaysHidden
            library.settingsJSON = payloadJSON
            library.settingsRevision += 1        // [VT-02] ここでしか上げない
            try library.update(db)

            try Self.writeSettingsTables(db, draft, libraryID: libraryID.rawValue)
        }
    }

    // MARK: - 草案の書き込み（登録と更新で共有）

    /// 草案から `library.settingsJSON` を組み立てる。
    ///
    /// **登録と更新で同じ関数を通す。** 別々に書くと、片方だけ直したときに
    /// 「有効化した直後の設定」と「設定を開いて保存し直した設定」が食い違う。
    static func payloadJSON(_ draft: LibrarySettingsDraft) throws -> String {
        let payload = LibrarySettingsPayload(
            targetExtensions: draft.targetExtensions.sorted(),
            imageExtensions: draft.imageExtensions.sorted(),
            delimiters: draft.delimiters,
            semanticBindings: draft.semanticBindings.reduce(into: [:]) { $0[$1.key.rawValue] = $1.value },
            seriesTitleCompositionFormat: draft.seriesTitleCompositionFormat,
            labelGroupOrder: draft.labelGroups.map(\.index),
            readsEmbeddedMetadata: draft.readsEmbeddedMetadata,
            comicInfoVolumeSource: draft.comicInfoVolumeSource)
        return String(decoding: try JSONEncoder().encode(payload), as: UTF8.self)
    }

    /// 草案の内容を付随テーブルへ書く。**登録と更新で共有する。**
    ///
    /// ラベルグループだけは作り直さず差分適用する（`writeLabelGroups`）
    /// ——ラベルが `labelGroup` へ連鎖削除で紐づくため、消して入れ直すと
    /// 蓄積したラベルと紐づけが全部消える。フォーマット・階層・保護文字列は
    /// 付随データを持たないのでまとめて入れ替えてよい。
    static func writeSettingsTables(_ db: Database, _ draft: LibrarySettingsDraft,
                                    libraryID: Int64) throws {
        try writeLabelGroups(db, draft.labelGroups, libraryID: libraryID)

        try db.execute(sql: "DELETE FROM filenameFormat WHERE libraryId = ?", arguments: [libraryID])
        for (priority, format) in draft.filenameFormats.enumerated() {
            var record = FilenameFormatRecord(id: nil, libraryId: libraryID,
                                              source: format.source, priority: priority,
                                              isEnabled: format.isEnabled)
            try record.insert(db)
        }

        try db.execute(sql: "DELETE FROM volumeFormat WHERE libraryId = ?", arguments: [libraryID])
        for (priority, pattern) in draft.volumeFormats.enumerated() {
            var record = VolumeFormatRecord(id: nil, libraryId: libraryID,
                                            source: pattern.source, priority: priority,
                                            isEnabled: pattern.isEnabled,
                                            kind: pattern.kind.rawValue)
            try record.insert(db)
        }

        try db.execute(sql: "DELETE FROM folderLevelMapping WHERE libraryId = ?", arguments: [libraryID])
        for level in draft.folderLevels {
            let kind: String
            var groupIndex: Int?
            var source: String?
            switch level.assignment {
            case .none:                        kind = "none"
            case .singleLabelGroup(let index): kind = "singleLabelGroup"; groupIndex = index
            case .format(let text):            kind = "format"; source = text
            }
            var record = FolderLevelMappingRecord(
                id: nil, libraryId: libraryID, level: level.level,
                assignmentKind: kind, labelGroupIndex: groupIndex, formatSource: source)
            try record.insert(db)
        }

        try db.execute(sql: "DELETE FROM protectedToken WHERE ownerKind = 'library' AND ownerID = ?",
                       arguments: [libraryID])
        for token in draft.protectedTokens {
            var record = ProtectedTokenRecord(id: nil, ownerKind: "library",
                                              ownerID: libraryID, pattern: token.pattern,
                                              position: token.position.rawValue,
                                              isEnabled: token.isEnabled)
            try record.insert(db)
        }
    }

    /// ライブラリタイプ名の変更を反映し、必要なら型を分岐させる [LT-05]。
    ///
    /// **`libraryType` の行は複数のライブラリで共有される**（同じプリセットから
    /// 登録すると同じ行を指す）。そのまま書き換えると、他のライブラリの
    /// `@librarytype` の照合値まで巻き添えで変わる。プリセットは編集不可 [LT-05]
    /// でもあるので、次のどちらかなら**このライブラリ専用の型へ複製してから**
    /// 書き換える: ①プリセット由来 ②他のライブラリからも参照されている。
    ///
    /// - Note: 複製元の行は残るため、その型名は `@librarytype` の列挙候補
    ///   [TY-01] に残り続ける。照合が緩くなる方向なので実害は無く、プリセットは
    ///   将来の登録の種として消してはならない。
    private static func resolveLibraryTypeID(_ db: Database, library: LibraryRecord,
                                             newTypeName: String) throws -> Int64 {
        guard var type = try LibraryTypeRecord.fetchOne(db, key: library.libraryTypeId) else {
            return library.libraryTypeId
        }
        guard type.libraryTypeName != newTypeName else { return library.libraryTypeId }

        let others = try Int.fetchOne(
            db, sql: "SELECT COUNT(*) FROM library WHERE libraryTypeId = ? AND id <> ?",
            arguments: [library.libraryTypeId, library.id ?? 0]) ?? 0
        if type.isPreset || others > 0 {
            var copy = LibraryTypeRecord(
                id: nil, presetKey: nil, name: type.name, libraryTypeName: newTypeName,
                isPreset: false, version: type.version, definitionJSON: type.definitionJSON)
            try copy.insert(db)
            return copy.id ?? library.libraryTypeId
        }
        type.libraryTypeName = newTypeName
        try type.update(db)
        return library.libraryTypeId
    }

    /// ラベルグループの差分適用。**ラベルを巻き添えにしないための経路** [LB-05]。
    private static func writeLabelGroups(_ db: Database, _ groups: [LabelGroupDraft],
                                         libraryID: Int64) throws {
        let existing = try LabelGroupRecord
            .filter(sql: "libraryId = ?", arguments: [libraryID]).fetchAll(db)
        let keptIDs = Set(groups.compactMap(\.persistentID))
        for record in existing where !keptIDs.contains(record.id ?? -1) {
            // 連鎖でこのグループのラベルと紐づけも消える。**呼び出し側が
            // 確認を取ってから来ること**（UI 側で警告している）。
            try db.execute(sql: "DELETE FROM labelGroup WHERE id = ?", arguments: [record.id])
        }
        for (order, group) in groups.enumerated() {
            if let id = group.persistentID,
               var record = existing.first(where: { $0.id == id }) {
                record.groupIndex = group.index
                record.name = group.name
                record.colorHexLight = group.colorHexLight
                record.colorHexDark = group.colorHexDark
                record.displayOrder = order
                record.assignsAutomatically = group.assignsAutomatically
                try record.update(db)
            } else {
                var record = LabelGroupRecord(
                    id: nil, libraryId: libraryID, groupIndex: group.index, name: group.name,
                    colorHexLight: group.colorHexLight, colorHexDark: group.colorHexDark,
                    displayOrder: order, assignsAutomatically: group.assignsAutomatically)
                try record.insert(db)
            }
        }
    }
}
