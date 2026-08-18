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
                                     priority: $0.priority, ordinalRank: $0.ordinalRank) }

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
                .map { ProtectedToken(text: $0.text,
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
                protectedTokens: tokens,
                filenameFormats: formats,
                folderLevelAssignments: levels,
                volumeFormats: VolumePatternCompiler.compileAll(volumePatterns),
                semanticBindings: semantic,
                normalization: options,
                seriesTitleCompositionFormat: payload.seriesTitleCompositionFormat)
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
    public func register(_ registration: LibraryRegistration,
                         template: LibraryTypeTemplate) async throws -> LibraryID {
        // **空集合で登録してはならない** [AL-11][IF-01]。`LibraryEnumerator` は
        // 空を「すべてのファイルが対象」と読むため、空のまま登録すると初回
        // スキャンが `.DS_Store` まで取り込む。要件定義書 11.4 節は
        // 「対象拡張子は全テンプレート共通」と定めており、テンプレート側は
        // この値を持たないので、ここで既定を入れるのが正しい場所になる。
        // 以後の変更はライブラリ設定ウインドウ（2-12）が担う。
        let payload = LibrarySettingsPayload(
            targetExtensions: AppDefaults.Library.targetExtensions.sorted(),
            imageExtensions: [],
            delimiters: .default,
            semanticBindings: template.semanticBindings,
            seriesTitleCompositionFormat: "@series @volume",
            labelGroupOrder: template.labelGroups.map(\.index).sorted())
        let payloadJSON = String(decoding: try JSONEncoder().encode(payload), as: UTF8.self)
        let volumePatterns = volumeSets.patterns(named: template.volumeSet) ?? []
        let colors = LabelColorPalette.palette(count: max(template.labelGroups.count, 1))

        return try await database.writer.write { db in
            // ライブラリタイプ（プリセットは presetKey で同定）[LT-10]
            let typeID: Int64
            if var existing = try LibraryTypeRecord
                .filter(sql: "presetKey = ?", arguments: [template.key]).fetchOne(db) {
                // 改訂されていたら version だけ上げる。**設定は自動反映しない** [LT-11]
                if existing.version != template.version {
                    existing.version = template.version
                    try existing.update(db)
                }
                typeID = existing.id ?? 0
            } else {
                var record = LibraryTypeRecord(
                    id: nil, presetKey: template.key, name: template.displayName,
                    libraryTypeName: template.libraryTypeName, isPreset: true,
                    version: template.version,
                    definitionJSON: String(decoding: try JSONEncoder().encode(template), as: UTF8.self))
                try record.insert(db)
                typeID = record.id ?? 0
            }

            var library = LibraryRecord(
                id: nil, uuid: registration.uuid.uuidString,
                displayName: registration.displayName,
                bookmarkData: registration.bookmarkData,
                resolvedPath: registration.resolvedPath,
                volumeUUID: registration.volumeUUID,
                libraryTypeId: typeID,
                libraryTypeVersion: template.version,
                settingsJSON: payloadJSON,
                caseSensitive: false,
                duplicateGrouping: "off",
                thumbnailsAlwaysHidden: false,
                lastFSEventID: 0, lastFullScanAt: nil,
                isOnline: true, isReadOnlyDueToFS: false, settingsRevision: 0)
            try library.insert(db)
            let libraryID = library.id ?? 0

            for (offset, group) in template.labelGroups.sorted(by: { $0.index < $1.index }).enumerated() {
                let color = colors[min(offset, colors.count - 1)]
                var record = LabelGroupRecord(
                    id: nil, libraryId: libraryID, groupIndex: group.index, name: group.name,
                    colorHexLight: color.hexLight, colorHexDark: color.hexDark,
                    displayOrder: offset, assignsAutomatically: group.assignsAutomatically)
                try record.insert(db)
            }
            for (priority, source) in template.filenameFormats.enumerated() {
                var record = FilenameFormatRecord(id: nil, libraryId: libraryID, source: source,
                                                  priority: priority, isEnabled: true)
                try record.insert(db)
            }
            for pattern in volumePatterns {
                var record = VolumeFormatRecord(id: nil, libraryId: libraryID, source: pattern.source,
                                                priority: pattern.priority, isEnabled: true,
                                                ordinalRank: pattern.ordinalRank)
                try record.insert(db)
            }
            for (rawLevel, spec) in template.folderLevels {
                guard let level = Int(rawLevel) else { continue }
                var record = FolderLevelMappingRecord(
                    id: nil, libraryId: libraryID, level: level,
                    assignmentKind: spec.kind.rawValue,
                    labelGroupIndex: spec.labelGroup, formatSource: spec.format)
                try record.insert(db)
            }
            return LibraryID(rawValue: libraryID)
        }
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

    public func setLastFSEventID(_ eventID: UInt64, libraryID: LibraryID) async throws {
        try await database.writer.write { db in
            try db.execute(sql: "UPDATE library SET lastFSEventID = ? WHERE id = ?",
                           arguments: [Int64(bitPattern: eventID), libraryID.rawValue])
        }
    }
}
