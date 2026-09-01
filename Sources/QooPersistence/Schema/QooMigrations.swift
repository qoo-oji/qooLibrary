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
    public static let identifiers: [String] = [
        "v1_initial", "v2_regexPatterns", "v3_embeddedMetadata", "v4_fsEventsCheckpoint",
        "v5_identityRejection", "v6_duplicateTitleKey", "v7_identityPending",
        "v8_stage1Removals", "v9_reservedWordCleanup", "v10_metadataProtection",
        "v11_orphanedProtectedTokens", "v12_shelf",
    ]

    public static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        // eraseDatabaseOnSchemaChange は**決して**有効にしない（データを消すため）。
        m.registerMigration(identifiers[0], migrate: v1Initial)
        m.registerMigration(identifiers[1], migrate: v2RegexPatterns)
        m.registerMigration(identifiers[2], migrate: v3EmbeddedMetadata)
        m.registerMigration(identifiers[3], migrate: v4FSEventsCheckpoint)
        m.registerMigration(identifiers[4], migrate: v5IdentityRejection)
        m.registerMigration(identifiers[5], migrate: v6DuplicateTitleKey)
        m.registerMigration(identifiers[6], migrate: v7IdentityPending)
        m.registerMigration(identifiers[7], migrate: v8Stage1Removals)
        m.registerMigration(identifiers[8], migrate: v9ReservedWordCleanup)
        m.registerMigration(identifiers[9], migrate: v10MetadataProtection)
        m.registerMigration(identifiers[10], migrate: v11OrphanedProtectedTokens)
        m.registerMigration(identifiers[11], migrate: v12Shelf)
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

    // MARK: - v4

    /// 差分の起点を `(eventID, デバイス UUID)` の**組**にする [SY-02][SY-04][WA-10]。
    ///
    /// **`lastFSEventID` だけでは足りない**（10章 §10.1.0 の実測）。FSEvents の
    /// 履歴はボリューム単位の DB に載っていて、消去・purge・カウンタの巻き戻りで
    /// 別物に差し替わる。SDK の `FSEvents.h` は「保存したイベント ID は
    /// `FSEventsCopyUUIDForDevice()` の UUID とセットで保存し、一致するときだけ
    /// 渡してよい」と明記しており、**NULL のボリューム（実測: SMB）へ渡すと
    /// 履歴が 1 件も再生されないのにエラーもフラグも出ない。**
    ///
    /// 既存の行は `fsEventsUUID` が NULL になる＝「起点が検証できない」ので、
    /// 次の起動で履歴を要求せずフルスキャンへ落ちる [SY-04]。**移行の時点で
    /// UUID を引きにいかない**——移行はストアを開く前に走るため、ライブラリの
    /// ボリュームが接続されているとは限らない（v3 と同じ判断）。
    static func v4FSEventsCheckpoint(_ db: Database) throws {
        for table in ["library", "temporaryFolder"] {
            try db.alter(table: table) { t in
                t.add(column: "fsEventsUUID", .text)       // NULL = 起点を検証できない
            }
        }
        // `lastFullScanAt` [SY-05] は v1 から `library` にあるが、
        // `temporaryFolder` には無い。フェーズ 3 で要るので今そろえておく
        // （後から列を足すより、器のあるうちに揃えるほうが移行が 1 本で済む）。
        try db.alter(table: "temporaryFolder") { t in
            t.add(column: "lastFullScanAt", .double)
        }
        try db.execute(sql: "UPDATE storeMetadata SET schemaVersion = ? WHERE id = 1",
                       arguments: [identifiers[3]])
    }

    // MARK: - v5

    /// 「同じ名前だが別のファイルだ」という判断を覚える [ID-11]。
    ///
    /// 走査は「名前が同じで inode が違う」組を見つけるたびに一括確認へ回す
    /// [ID-05] が、**一度「別物」と答えた組を毎回聞き直しては使い物にならない**
    /// ——`第01巻.cbz` のように複数シリーズに存在しうる名前では、走査のたびに
    /// 同じ組が挙がってくる。ラベルの `manuallyRemoved` [RC-04] と同じ考え方で、
    /// 「付いていない」ではなく「**付けないと決めた**」を明示的に持つ。
    ///
    /// **どちらの行が消えれば記録も消える**（`ON DELETE CASCADE`）——組の片方が
    /// 無くなれば、その判断はもう意味を持たない。
    // MARK: - v7

    /// 確認待ちの組を**明示的に記録する** [ID3-08][ID-05][ID-09]。
    ///
    /// **以前は「孤立していて、同じ名前の生きている行がある」という状態から
    /// 導いていた**（07章 §7.5「確認待ちは記録しない」）。その前提は誤りで、
    /// 導出では**無関係な同名ファイルの行**と区別が付かない——`第01巻.cbz` の
    /// ように複数シリーズに存在しうる名前では、片方を消しただけで
    /// もう片方の行が「確認待ちの候補」に化け、既定の設定 [ID-13] が
    /// それを黙って承認して**評価・手動ラベルごと行を消していた**。
    ///
    /// 確認待ちは「走査が実際に差し替えを疑った」という**出来事**であって、
    /// あとから状態を見て言い当てられるものではない。疑った時点で記録する。
    ///
    /// **既存のストアは空のまま始める**（backfill しない）。導出で拾えていた
    /// 組には誤った組が混ざっているので、それを引き継ぐと欠陥ごと持ち越す。
    /// 取り残された孤立レコードは §15.7 の一覧から片付けられるし、実体が
    /// 差し替えられていれば次の走査が正しい組を作り直す。
    // MARK: - v8

    /// 概念モデル v3 のステージ 1（撤去）[§19.8][§19.10]。
    ///
    /// - `identityPending`／`identityRejection` を落とす [ID-09〜ID-15 撤回]。
    ///   差し替えは走査がガード付き [ID3-08] で自動的に引き継ぐので、
    ///   確認待ちの記録も「別物だ」という判断の記録も要らなくなった。
    ///   溜まっていた確認待ちは**確認されないまま消える**——孤立レコード
    ///   自体は残るので、「見つからないファイル」一覧から片付けられる。
    /// - `library.caseSensitive` を落とす [N-04 撤回]。照合は常に同一視。
    ///   大小だけ違うラベルの normalizedName が既に分かれている店では、
    ///   以後の照合で新しい行が増えないだけで、既存の行はそのまま残る
    ///   （改名・統合はいつでもできる）。
    /// - `managedFile.isDuplicateRepresentativePinned` を落とす [DU-08 撤回]。
    ///   代表は自動選定（評価 → サイズ → 名前）に任せる。
    ///
    /// どの列も索引・トリガ・ビューから参照されていないので
    /// `ALTER TABLE … DROP COLUMN` で足りる（SQLite 3.35+、この環境は 3.51）。
    // MARK: - v11

    /// 登録解除で取り残された保護文字列を掃除する [PT-08]。
    ///
    /// **`protectedToken` は `ownerKind`／`ownerID` の多相参照なので外部キー
    /// 制約を張れず、`library` の行を消しても連鎖しない。** `unregister` は
    /// `DELETE FROM library` しか実行していなかったため、登録・解除のたびに
    /// 孤児が既定の 3 件ずつ積み上がっていた（実ストアで 12 ライブラリ分・
    /// 36 件を実測）。書き手側（`SQLiteLibraryRepository.unregister`）も
    /// 同時に直してある——**移行は 1 回きりなので、掃除だけでは再発する。**
    ///
    /// **`PRAGMA foreign_key_check` はこの漏れを検出しない**——制約が無いの
    /// だから当然で、「検査が通ること」を根拠にできない類の欠陥だった。
    /// **外部キーで守れない参照は、削除の経路を人が書くしかない。**
    ///
    /// `library.id` は AUTOINCREMENT で再利用されない [T-03 決定③] ので、
    /// 孤児が別のライブラリの保護文字列として蘇ることは無い。実害は増え
    /// 続けることだけで、掃除そのものは安全に行える。
    ///
    /// **`temporary` 側も対称に掃除する。** 現状この種別の行を作る経路は
    /// 無い（フェーズ 3）が、実装する人は**削除の経路も一緒に書くこと。**
    static func v11OrphanedProtectedTokens(_ db: Database) throws {
        try db.execute(sql: """
            DELETE FROM protectedToken
             WHERE (ownerKind = 'library'   AND ownerID NOT IN (SELECT id FROM library))
                OR (ownerKind = 'temporary' AND ownerID NOT IN (SELECT id FROM temporaryFolder))
            """)
        try db.execute(sql: "UPDATE storeMetadata SET schemaVersion = ? WHERE id = 1",
                       arguments: [identifiers[10]])
    }

    // MARK: - v12

    /// シェルフ（保存した絞り込み）を足す [SH-01][19章 §19.9]。
    ///
    /// **条件は JSON 1 列**（`ShelfRecord` の注記）。`libraryId` は単一参照なので
    /// 外部キーを張れる——`protectedToken` が多相参照ゆえに連鎖削除できず、
    /// 登録解除のたびに孤児を積み上げていた轍を踏まない [PT-08]。
    ///
    /// `AUTOINCREMENT` にするのは、削除の ⌘Z が**同じ行 ID で**戻すため
    /// [SH-11]（`label` と同じ理由 [07章 §7.3]）。
    static func v12Shelf(_ db: Database) throws {
        try db.create(table: "shelf") { t in
            t.autoIncrementedPrimaryKey("id")
            t.belongsTo("library", onDelete: .cascade).notNull()
            t.column("name", .text).notNull()
            t.column("displayOrder", .integer).notNull()   // [SH-10][ST-23]
            t.column("conditionJSON", .text).notNull()
            t.column("createdAt", .double).notNull()
        }
        try db.create(index: "shelf_lib_order", on: "shelf",
                      columns: ["libraryId", "displayOrder"])
        try db.execute(sql: "UPDATE storeMetadata SET schemaVersion = ? WHERE id = 1",
                       arguments: [identifiers[11]])
    }

    // MARK: - v10

    /// メタデータの保護 [PR-01〜PR-09]（概念モデル v3 ステージ 6）。
    ///
    /// `fileLabel.origin` の 3 状態 [RC-04] と `managedFile.titleOrigin` [RP-11]
    /// という**2 つの暗黙の保護機構を、1 つの見える概念へ畳む** [PR-08]。
    ///
    /// | 変換前 | 変換後 |
    /// |---|---|
    /// | `titleOrigin = 'manual'` | 基本情報スコープ `basic` |
    /// | `fileLabel.origin` が `manual` / `manuallyRemoved` | そのラベルが属する
    ///   フィールドのスコープ `field:<labelGroupId>` |
    ///
    /// **`manuallyRemoved` も保護に変換する**のが要点。あれは「このラベルは
    /// 付けないと決めた」という意思表示なので、行を消すだけでは次の走査で
    /// 復活する——フィールドごと保護しておけば走査はそこに一切触れない。
    ///
    /// **変換は保護を広い側へ倒す。** タイトルだけを手で直した行は、
    /// シリーズ名と巻数まで守られるようになる（基本情報は 1 かたまり
    /// [PR-02]）。逆向き（守っていたものを守らなくなる）に倒すと、手で
    /// 直した値が次の走査で黙って消えるので、こちらを選ぶ。
    static func v10MetadataProtection(_ db: Database) throws {
        try db.alter(table: "managedFile") { t in
            t.add(column: "protectedScopes", .text).notNull().defaults(to: "[]")
        }
        // **綴りの昇順に揃える**——`ProtectionScopeCoding.encode` と同じ形に
        // しておかないと、移行が書いた行と以後に書いた行で同じ集合が違う
        // 文字列になり、JSON バックアップに意味の無い差分が出る。
        try db.execute(sql: """
            WITH scopes AS (
                SELECT id AS fileId, 'basic' AS scope FROM managedFile
                 WHERE titleOrigin = 'manual'
                UNION
                SELECT fl.managedFileId, 'field:' || l.labelGroupId
                  FROM fileLabel fl JOIN label l ON l.id = fl.labelId
                 WHERE fl.origin IN ('manual', 'manuallyRemoved')
            )
            UPDATE managedFile SET protectedScopes = (
                SELECT json_group_array(scope)
                  FROM (SELECT scope FROM scopes
                         WHERE fileId = managedFile.id ORDER BY scope)
            ) WHERE id IN (SELECT fileId FROM scopes)
            """)
        // 除去の印は保護へ移ったので、行そのものは要らない [PR-08]。
        // **ラベル件数 [DB-02] は動かない**——`manuallyRemoved` は元から
        // 「付いていない」として数えられていなかった。
        try db.execute(sql: "DELETE FROM fileLabel WHERE origin = 'manuallyRemoved'")
        try db.alter(table: "managedFile") { t in t.drop(column: "titleOrigin") }
        // WITHOUT ROWID テーブルでも DROP COLUMN は通る［実測、SQLite 3.51］。
        try db.alter(table: "fileLabel") { t in t.drop(column: "origin") }
        try db.execute(sql: "UPDATE storeMetadata SET schemaVersion = ? WHERE id = 1",
                       arguments: [identifiers[9]])
    }

    // MARK: - v9

    /// 予約語の整理（v3 ステージ 5）[RWI-02]。
    ///
    /// **保存済みのフォーマットを書き換える。** 予約語の綴りを変えただけでは
    /// 既存の行が「不明な予約語」になり、`SQLiteLibraryRepository` が `try?` で
    /// 落とすので**フォーマットが 1 本も無いライブラリ**になる——次の走査が
    /// タイトルもラベルも全部 nil で上書きする、最も静かな壊れ方をする。
    ///
    /// 機械的に置き換えられるのは `@librarytype` → `@booktype` だけ
    /// （純粋な改名）。`@labelgroupN` と `@libraryname` は**変換先が無い**
    /// ——前者は番号から意味を復元できず、後者はそもそも撤回した機能なので、
    /// 該当する行は**無効にして残す**（消すと利用者が何を失ったか分からない。
    /// 設定画面で見えるので、必要なら書き直せる）。
    static func v9ReservedWordCleanup(_ db: Database) throws {
        try db.execute(sql: """
            UPDATE filenameFormat SET source = REPLACE(source, '@librarytype', '@booktype')
            """)
        try db.execute(sql: """
            UPDATE folderLevelMapping SET formatSource =
                REPLACE(formatSource, '@librarytype', '@booktype')
             WHERE formatSource IS NOT NULL
            """)
        try db.execute(sql: """
            UPDATE filenameFormat SET isEnabled = 0
             WHERE source LIKE '%@labelgroup%' OR source LIKE '%@libraryname%'
            """)
        try db.execute(sql: "UPDATE storeMetadata SET schemaVersion = ? WHERE id = 1",
                       arguments: [identifiers[8]])
    }

    static func v8Stage1Removals(_ db: Database) throws {
        try db.drop(table: "identityPending")
        try db.drop(table: "identityRejection")
        try db.alter(table: "library") { t in
            t.drop(column: "caseSensitive")
        }
        try db.alter(table: "managedFile") { t in
            t.drop(column: "isDuplicateRepresentativePinned")
        }
        try db.execute(sql: "UPDATE storeMetadata SET schemaVersion = ? WHERE id = 1",
                       arguments: [identifiers[7]])
    }

    static func v7IdentityPending(_ db: Database) throws {
        try db.create(table: "identityPending") { t in
            t.belongsTo("orphanFile", inTable: "managedFile", onDelete: .cascade).notNull()
            t.belongsTo("candidateFile", inTable: "managedFile", onDelete: .cascade).notNull()
            t.column("detectedAt", .double).notNull()
            t.primaryKey(["orphanFileId", "candidateFileId"])
        }
        try db.execute(sql: "UPDATE storeMetadata SET schemaVersion = ? WHERE id = 1",
                       arguments: [identifiers[6]])
    }

    static func v5IdentityRejection(_ db: Database) throws {
        try db.create(table: "identityRejection") { t in
            t.belongsTo("orphanFile", inTable: "managedFile", onDelete: .cascade).notNull()
            t.belongsTo("candidateFile", inTable: "managedFile", onDelete: .cascade).notNull()
            t.column("decidedAt", .double).notNull()
            t.primaryKey(["orphanFileId", "candidateFileId"])
        }
        try db.execute(sql: "UPDATE storeMetadata SET schemaVersion = ? WHERE id = 1",
                       arguments: [identifiers[4]])
    }

    // MARK: - v6

    /// 重複判定のための**正規化済みタイトル** [DU-02][DU-03]。
    ///
    /// **グループ化を SQL で行うために要る。** 正規化（N-01〜N-03 + WS-06）は
    /// 全角畳み込みと NFC 化を伴うので SQLite の式では書けず、書き込み時に
    /// 畳んでおくしかない——`searchKey` / `seriesKey` と同じ形にしてある。
    ///
    /// **既存の行は NULL のままで、次の走査が埋める**（再生成可能 [DB-03] なので
    /// JSON にも持たない）。移行時に埋めなかったのは、当時の正規化が
    /// ライブラリごとの `caseSensitive` 設定（v8 で撤去）に依存していたため。
    ///
    /// 索引は `(libraryId, titleKey)`。グループ化は必ずライブラリ単位で
    /// 絞ってから行う [DU-04]。
    static func v6DuplicateTitleKey(_ db: Database) throws {
        try db.alter(table: "managedFile") { t in
            t.add(column: "titleKey", .text)               // 再生成可能 [DU-02][DU-03]
        }
        try db.create(index: "mf_lib_titlekey", on: "managedFile",
                      columns: ["libraryId", "titleKey"])
        try db.execute(sql: "UPDATE storeMetadata SET schemaVersion = ? WHERE id = 1",
                       arguments: [identifiers[5]])
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
