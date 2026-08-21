//
//  スキーマ移行 [07章 §7.2][MG-01〜MG-04][SC-01〜SC-05]。
//
//  **v1 の時点から移行の器を用意する** [MG-01][MG-02]。移行対象がなくても
//  初版スキーマを最初の移行として登録しておく。
//
//  **登録済みの移行は追記のみ。後から書き換えない** [MG-04][SC-02]——適用済みの
//  環境と食い違い、検出できない不整合になる。
//
import Foundation
import GRDB
import QooKit

public enum QooMigrations {
    /// 登録順の識別子。`v<連番>_<内容>` 形式で時系列に並ぶこと [SC-03]。
    public static let identifiers: [String] = ["v1_initial", "v2_regexPatterns", "v3_embeddedMetadata"]

    public static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        // eraseDatabaseOnSchemaChange は**決して**有効にしない（データを消すため）。
        m.registerMigration(identifiers[0], migrate: v1Initial)
        m.registerMigration(identifiers[1], migrate: v2RegexPatterns)
        m.registerMigration(identifiers[2], migrate: v3EmbeddedMetadata)
        return m
    }

    // MARK: - v1

    static func v1Initial(_ db: Database) throws {
        try createLibraryTables(db)
        try createLabelTables(db)
        try createFileTables(db)
        try createFormatTables(db)
        try createOperationalTables(db)
        try db.execute(sql: """
            INSERT INTO storeMetadata (id, schemaVersion, appBuildAtLastWrite)
            VALUES (1, ?, '')
            """, arguments: [identifiers[0]])
    }

    // MARK: - v3

    /// 埋め込みメタデータの読み取り（09章 §9.9）のための列を足す [EM-07]。
    ///
    /// **既存の行は `metadataStamp` が NULL になり、次のスキャンで
    /// 「まだ読んでいない」として扱われる**——移行時に読みに行かない。移行は
    /// ストアを開く前に走るので、ライブラリのボリュームが接続されているとは
    /// 限らない（外付けが無い状態で起動しただけで移行が失敗しては困る）。
    ///
    /// `library.settingsJSON` の新しいキー（`readsEmbeddedMetadata` /
    /// `comicInfoVolumeSource`）はここで触らない。`LibrarySettingsPayload` が
    /// `decodeIfPresent` で読むので、キーが無い既存の JSON もそのまま通る。
    static func v3EmbeddedMetadata(_ db: Database) throws {
        try db.alter(table: "managedFile") { t in
            t.add(column: "metadataStamp", .text)          // "mtime|size"。一致すれば開かない
            t.add(column: "metadataSource", .text)         // NULL | comicInfo | epub | pdf
            t.add(column: "metadataJSON", .text)           // 読み取った EmbeddedMetadata
            t.add(column: "hasVolumeConflict", .boolean).notNull().defaults(to: false)
        }
        // 判断待ちの一覧を引くための部分索引 [EM-31]。件数はごく少ないので
        // 全件の索引を作る必要が無い。
        try db.execute(sql: """
            CREATE INDEX managedFile_volume_conflict
                ON managedFile(libraryId) WHERE hasVolumeConflict = 1
            """)
        try db.execute(sql: "UPDATE storeMetadata SET schemaVersion = ? WHERE id = 1",
                       arguments: [identifiers[2]])
    }

    // MARK: - v2

    /// 巻数フォーマットと保護文字列を正規表現へ移す [2026-08 の仕様変更]。
    ///
    /// - `volumeFormat.source`: `??` / `<space>` の独自記法 → 正規表現
    /// - `volumeFormat.ordinalRank` → `kind`（序列巻数を廃止し「区切り専用」へ）
    /// - `protectedToken.text` → `pattern`（完全一致のリテラル → 正規表現）
    /// - `volumeOutputStyle.ordinalTemplate`: 出力すべき序列が無くなったので削除
    /// - `managedFile.volumeKind`: `ordinal` は取りうる値でなくなったので `none` へ
    ///
    /// 変換は `LegacyVolumeNotation`（`QooKit`）が行う。**JSON バックアップの
    /// 取り込みと同じ関数を使う**——片方だけ直すと、以前書き出した文書と DB とで
    /// 変換結果が食い違う。
    static func v2RegexPatterns(_ db: Database) throws {
        try db.alter(table: "volumeFormat") { t in
            t.add(column: "kind", .text).notNull()
                .defaults(to: VolumePatternKind.volume.rawValue)
        }
        for row in try Row.fetchAll(db, sql: "SELECT id, source, ordinalRank FROM volumeFormat") {
            let id: Int64 = row["id"]
            let source: String = row["source"]
            let ordinalRank: Int? = row["ordinalRank"]
            // 序列巻数だったものは、巻数を持たない「区切り専用」になる。
            let kind = (ordinalRank == nil ? VolumePatternKind.volume : .separator).rawValue
            try db.execute(sql: "UPDATE volumeFormat SET source = ?, kind = ? WHERE id = ?",
                           arguments: [LegacyVolumeNotation.regex(fromVolumeSource: source), kind, id])
        }
        try db.alter(table: "volumeFormat") { t in t.drop(column: "ordinalRank") }

        try db.alter(table: "protectedToken") { t in t.rename(column: "text", to: "pattern") }
        for row in try Row.fetchAll(db, sql: "SELECT id, pattern FROM protectedToken") {
            let id: Int64 = row["id"]
            let literal: String = row["pattern"]
            try db.execute(sql: "UPDATE protectedToken SET pattern = ? WHERE id = ?",
                           arguments: [LegacyVolumeNotation.regex(fromProtectedLiteral: literal), id])
        }

        try db.alter(table: "volumeOutputStyle") { t in t.drop(column: "ordinalTemplate") }
        try db.execute(sql: "UPDATE managedFile SET volumeKind = 'none' WHERE volumeKind = 'ordinal'")
        // 適用済みの版を記録する [MG-03]。忘れると「どこまで移行したか」を
        // ストア自身に尋ねられなくなる。
        try db.execute(sql: "UPDATE storeMetadata SET schemaVersion = ? WHERE id = 1",
                       arguments: [identifiers[1]])
    }

    // MARK: - ライブラリ

    static func createLibraryTables(_ db: Database) throws {
        try db.create(table: "libraryType") { t in
            t.autoIncrementedPrimaryKey("id")
            /// プリセットの安定した識別子。ユーザー定義は NULL [LT-10]。
            t.column("presetKey", .text).unique()
            t.column("name", .text).notNull()
            t.column("libraryTypeName", .text).notNull()
            t.column("isPreset", .boolean).notNull().defaults(to: false)   // [LT-05]
            t.column("version", .integer).notNull().defaults(to: 1)        // [LT-10]
            t.column("definitionJSON", .text).notNull()
        }

        try db.create(table: "library") { t in
            t.autoIncrementedPrimaryKey("id")
            // 外部識別子。フェーズ 1 の登録フォルダ ID を引き継ぐ [07章 §7.3]。
            t.column("uuid", .text).notNull().unique()
            t.column("displayName", .text).notNull()
            t.column("bookmarkData", .blob).notNull()                      // [SB-02][RG-07]
            t.column("resolvedPath", .text).notNull()
            t.column("volumeUUID", .text).notNull()                        // [VD-02]
            t.belongsTo("libraryType", onDelete: .restrict).notNull()
            t.column("libraryTypeVersion", .integer).notNull().defaults(to: 1)  // [LT-10]
            t.column("settingsJSON", .text).notNull()
            t.column("caseSensitive", .boolean).notNull().defaults(to: false)   // [N-04]
            t.column("duplicateGrouping", .text).notNull().defaults(to: "off")  // [DU-01]
            t.column("thumbnailsAlwaysHidden", .boolean).notNull().defaults(to: false) // [DS-04]
            t.column("lastFSEventID", .integer).notNull().defaults(to: 0)  // [SY-02]
            t.column("lastFullScanAt", .double)                            // [SY-05]
            t.column("isOnline", .boolean).notNull().defaults(to: true)    // [SB-05]
            t.column("isReadOnlyDueToFS", .boolean).notNull().defaults(to: false) // [FS-08]
            t.column("settingsRevision", .integer).notNull().defaults(to: 0)     // [VT-02]
        }

        try db.create(table: "temporaryFolder") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("uuid", .text).notNull().unique()
            t.column("displayName", .text).notNull()
            t.column("bookmarkData", .blob).notNull()
            t.column("resolvedPath", .text).notNull()
            t.column("volumeUUID", .text).notNull()
            t.column("defaultTargetLibraryID", .integer)
                .references("library", onDelete: .setNull)
            t.column("settingsJSON", .text).notNull()
            t.column("lastFSEventID", .integer).notNull().defaults(to: 0)
            t.column("isOnline", .boolean).notNull().defaults(to: true)
        }
    }

    // MARK: - ラベル

    static func createLabelTables(_ db: Database) throws {
        // AUTOINCREMENT で rowid の再利用を禁じる [07章 §7.3]。ウインドウ状態復元が
        // ラベルフィルタの選択を保持するため、再利用されると復元後に別のラベルが選ばれる。
        try db.create(table: "labelGroup") { t in
            t.autoIncrementedPrimaryKey("id")
            t.belongsTo("library", onDelete: .cascade).notNull()
            t.column("groupIndex", .integer).notNull()     // 上限判定はここだけ [MT-11]
            t.column("name", .text).notNull()
            t.column("colorHexLight", .text).notNull()
            t.column("colorHexDark", .text).notNull()      // [CO-07]
            t.column("displayOrder", .integer).notNull()   // [LG-07][ST-23]
            t.column("assignsAutomatically", .boolean).notNull().defaults(to: true)
            t.uniqueKey(["libraryId", "groupIndex"])
        }

        try db.create(table: "label") { t in
            t.autoIncrementedPrimaryKey("id")
            t.belongsTo("labelGroup", onDelete: .cascade).notNull()
            t.column("name", .text).notNull()              // 原文 [N-03]
            t.column("normalizedName", .text).notNull()    // 照合用（再生成可能）
            t.column("colorHex", .text)                    // nil → グループ色を継承 [CO-06]
            t.column("isPinned", .boolean).notNull().defaults(to: false)    // [LB-03]
            t.column("isArchived", .boolean).notNull().defaults(to: false)  // [LA-01]
            t.column("fileCount", .integer).notNull().defaults(to: 0)       // 非正規化 [DB-02]
        }
        // [LB-01][IX-02]
        try db.create(index: "label_group_norm", on: "label",
                      columns: ["labelGroupId", "normalizedName"], unique: true)
    }

    // MARK: - ファイル

    static func createFileTables(_ db: Database) throws {
        try db.create(table: "managedFile") { t in
            t.autoIncrementedPrimaryKey("id")
            t.belongsTo("library", onDelete: .cascade).notNull()
            t.column("inode", .integer).notNull()          // 同一性キー [ID-01]
            t.column("volumeUUID", .text).notNull()
            t.column("relativePath", .text).notNull()
            t.column("filename", .text).notNull()
            t.column("normalizedName", .text).notNull()    // 再生成可能 [DB-03]
            t.column("searchKey", .text).notNull()         // 再生成可能 [SR-06]
            t.column("fileSize", .integer).notNull()
            t.column("createdAt", .double).notNull()
            t.column("modifiedAt", .double).notNull()
            t.column("title", .text)
            t.column("titleOrigin", .text).notNull().defaults(to: "auto")   // [RP-11]
            t.column("seriesName", .text)
            t.column("seriesKey", .text)                   // [RA-04][DU-02]
            t.column("volumeNumber", .double)              // 再生成可能 [SE-09]
            t.column("volumeKind", .text).notNull().defaults(to: "none")    // 再生成可能
            t.column("volumeRaw", .text)                   // 再生成可能
            t.column("authorName", .text)                  // [RW-16]
            t.column("rating", .integer).notNull().defaults(to: 0)          // [RA-01]
            t.column("coverImageRef", .text)
            t.column("coverImageSource", .text).notNull().defaults(to: "auto")  // [IV-03]
            t.column("isArchived", .boolean).notNull().defaults(to: false)  // [FA-05]
            t.column("archivedFromPath", .text)            // [FA-04]
            t.column("archivedAt", .double)
            t.column("isBookFolder", .boolean).notNull().defaults(to: false) // 再生成可能 [IF-04]
            t.column("isDuplicateRepresentativePinned", .boolean).notNull().defaults(to: false)
            t.column("pageCount", .integer)                // 再生成可能 [DT-05]
            t.column("subfolderCount", .integer)           // 再生成可能 [DT-06]
            t.column("firstImageWidth", .integer)          // 再生成可能 [DU-21]
            t.column("firstImageHeight", .integer)         // 再生成可能
            t.column("trashedAt", .double)                 // [TR-03]
            t.column("state", .text).notNull().defaults(to: "active")       // [ID-06][TR-01]
            t.column("lastParsedFormatID", .text)
            t.column("libraryTypeMismatch", .boolean).notNull().defaults(to: false) // [RW-01]
        }
        // [IX-01]
        try db.create(index: "mf_identity", on: "managedFile",
                      columns: ["volumeUUID", "inode"], unique: true)
        try db.create(index: "mf_lib_path", on: "managedFile",
                      columns: ["libraryId", "relativePath"])
        try db.create(index: "mf_lib_state", on: "managedFile", columns: ["libraryId", "state"])
        try db.create(index: "mf_lib_series", on: "managedFile", columns: ["libraryId", "seriesKey"])
        try db.create(index: "mf_search", on: "managedFile", columns: ["searchKey"])
        // 再照合の候補探索 [ID-03]②③
        try db.create(index: "mf_lib_name_size", on: "managedFile",
                      columns: ["libraryId", "filename", "fileSize"])

        // 50 万行規模になるため WITHOUT ROWID で本体を小さくする。
        try db.create(table: "fileLabel", options: [.withoutRowID]) { t in
            t.belongsTo("managedFile", onDelete: .cascade).notNull()
            t.belongsTo("label", onDelete: .cascade).notNull()
            t.column("origin", .text).notNull()            // [RC-04]
            t.column("assignedAt", .double).notNull()
            t.primaryKey(["managedFileId", "labelId"])
        }
        // ラベルフィルタの INTERSECT が使う [IX-06][FI-01]
        try db.create(index: "fl_label", on: "fileLabel", columns: ["labelId"])
    }

    // MARK: - フォーマット類

    static func createFormatTables(_ db: Database) throws {
        try db.create(table: "filenameFormat") { t in
            t.autoIncrementedPrimaryKey("id")
            t.belongsTo("library", onDelete: .cascade).notNull()
            t.column("source", .text).notNull()
            t.column("priority", .integer).notNull()       // [FF-03][FF-04]
            t.column("isEnabled", .boolean).notNull().defaults(to: true)    // [FF-05]
        }
        try db.create(table: "volumeFormat") { t in
            t.autoIncrementedPrimaryKey("id")
            t.belongsTo("library", onDelete: .cascade).notNull()
            t.column("source", .text).notNull()
            t.column("priority", .integer).notNull()       // [SE-21]
            t.column("isEnabled", .boolean).notNull().defaults(to: true)
            t.column("ordinalRank", .integer)              // [SE-10]
        }
        try db.create(table: "folderLevelMapping") { t in
            t.autoIncrementedPrimaryKey("id")
            t.belongsTo("library", onDelete: .cascade).notNull()
            t.column("level", .integer).notNull()          // 1 = ライブラリ直下
            t.column("assignmentKind", .text).notNull()    // singleLabelGroup|format|none
            t.column("labelGroupIndex", .integer)
            t.column("formatSource", .text)
            t.uniqueKey(["libraryId", "level"])
        }
        try db.create(table: "protectedToken") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("ownerKind", .text).notNull()         // library | temporary [PT-08]
            t.column("ownerID", .integer).notNull()
            t.column("text", .text).notNull()
            t.column("position", .text).notNull().defaults(to: "anywhere")  // [PT-05]
            t.column("isEnabled", .boolean).notNull().defaults(to: true)
        }
        try db.create(index: "pt_owner", on: "protectedToken", columns: ["ownerKind", "ownerID"])
        try db.create(table: "volumeOutputStyle") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("name", .text).notNull()              // [CR-25]
            t.column("numericTemplate", .text).notNull()
            t.column("digits", .integer).notNull()
            t.column("numeralWidth", .text).notNull()
            t.column("ordinalTemplate", .text).notNull()
            t.column("noneOutput", .text).notNull()
        }
    }

    // MARK: - 運用系

    static func createOperationalTables(_ db: Database) throws {
        try db.create(table: "unresolvedFile") { t in
            t.autoIncrementedPrimaryKey("id")
            t.belongsTo("library", onDelete: .cascade).notNull()
            t.belongsTo("managedFile", onDelete: .cascade).notNull()
            t.column("filename", .text).notNull()
            t.column("isIgnored", .boolean).notNull().defaults(to: false)   // [AL-33]
            t.column("detectedAt", .double).notNull()
            t.column("nearestFormatSource", .text)                          // [UR2-05]
            t.column("nearestFormatReach", .integer)
            t.uniqueKey(["managedFileId"])
        }
        try db.create(table: "notificationRecord") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("date", .double).notNull()
            t.column("category", .text).notNull()
            t.column("severity", .integer).notNull()
            // **行 ID ではなくパスとファイル名を非正規化して持つ** [07章 §7.3]。
            // 対象は消えうるし、消えた後も履歴として意味を保たなければならない。
            t.column("targetJSON", .text)
            t.column("title", .text).notNull()
            t.column("body", .text).notNull()
            t.column("isRead", .boolean).notNull().defaults(to: false)
            t.column("operationLogID", .integer)
        }
        try db.create(index: "nr_date", on: "notificationRecord", columns: ["date"])
        try db.create(table: "operationLog") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("date", .double).notNull()
            t.column("commandName", .text).notNull()
            t.column("kind", .text).notNull()
            t.column("targetsJSON", .text).notNull()       // 同上、非正規化 [HS-01]
            t.column("libraryID", .integer)
            t.column("undone", .boolean).notNull().defaults(to: false)
            t.column("detailJSON", .text)
        }
        try db.create(index: "ol_date", on: "operationLog", columns: ["date"])
        try db.create(table: "pendingMove") { t in
            t.autoIncrementedPrimaryKey("id")
            t.belongsTo("temporaryFolder", onDelete: .cascade).notNull()
            t.column("targetLibraryID", .integer).references("library", onDelete: .cascade)
            t.column("filename", .text).notNull()
            t.column("relativePath", .text).notNull()
            t.column("reason", .text).notNull()
            t.column("parsedFieldsJSON", .text)
            t.column("resolvedDestination", .text)
            t.column("state", .text).notNull()             // [MV-19][MV-20]
        }
        try db.create(table: "appAssociation") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("fileExtension", .text).notNull().unique()
            t.column("primaryBundleID", .text)             // [AS-01]
            t.column("secondaryBundleIDsJSON", .text)      // [AS-06]
        }
        try db.create(table: "storeMetadata") { t in
            t.primaryKey("id", .integer)                   // 常に 1
            t.column("schemaVersion", .text).notNull()     // [MG-03]
            t.column("lastMigratedAt", .double)
            t.column("appBuildAtLastWrite", .text).notNull()
        }
    }
}
