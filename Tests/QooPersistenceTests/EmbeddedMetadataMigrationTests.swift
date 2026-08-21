import Foundation
import GRDB
import QooKit
import Testing

@testable import QooPersistence

/// `v3_embeddedMetadata` の移行 [EM-07][07章 §7.2]。
///
/// **v2 までを当てた状態から始める。** 完成した DB を見るだけでは、移行が
/// 実際に走ったのか、そもそも新しいスキーマで作られただけなのかを区別できない。
@Suite("v3_embeddedMetadata の移行")
struct EmbeddedMetadataMigrationTests {

    /// v2 までを当てたストア（外部キーは切って親行の用意を省く）。
    private func v2Store() throws -> DatabaseQueue {
        var config = Configuration()
        config.foreignKeysEnabled = false
        let queue = try DatabaseQueue(configuration: config)
        var migrator = DatabaseMigrator()
        migrator.registerMigration(QooMigrations.identifiers[0], migrate: QooMigrations.v1Initial)
        migrator.registerMigration(QooMigrations.identifiers[1], migrate: QooMigrations.v2RegexPatterns)
        try migrator.migrate(queue)
        return queue
    }

    @Test("既存の行を保ったまま列が増える")
    func addsColumnsWithoutTouchingExistingRows() throws {
        let queue = try v2Store()
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO managedFile
                    (id, libraryId, inode, volumeUUID, relativePath, filename,
                     normalizedName, searchKey, fileSize, createdAt, modifiedAt,
                     titleOrigin, rating, coverImageSource, isArchived, isBookFolder,
                     isDuplicateRepresentativePinned, state, libraryTypeMismatch, volumeKind)
                VALUES (1, 1, 100, 'VOL', '作品名A.cbz', '作品名A.cbz',
                        'さくひんめいa', 'さくひんめいa', 4096, 0, 0,
                        'manual', 3, 'auto', 0, 0, 0, 'active', 0, 'none')
                """)
            try db.execute(sql: "UPDATE managedFile SET title = ? WHERE id = 1",
                           arguments: ["手で直した題"])
        }

        try QooMigrations.migrator.migrate(queue)

        let row = try #require(try queue.read {
            try Row.fetchOne($0, sql: "SELECT * FROM managedFile WHERE id = 1")
        })
        // **手で直した題も評価も残る。**移行で失ってはならない値 [MG-22]。
        #expect(row["title"] == "手で直した題")
        #expect(row["titleOrigin"] == "manual")
        #expect(row["rating"] == 3)
        // **印は NULL。**「まだ読んでいない」＝次のスキャンで読む [EM-07]。
        // 移行時に読みに行かない——移行はストアを開く前に走るので、
        // ライブラリのボリュームが接続されているとは限らない。
        #expect(row["metadataStamp"] == nil)
        #expect(row["metadataSource"] == nil)
        #expect(row["metadataJSON"] == nil)
        #expect(row["hasVolumeConflict"] == false)
    }

    @Test("判断待ちを引くための部分索引ができる")
    func createsThePartialIndex() throws {
        let queue = try v2Store()
        try QooMigrations.migrator.migrate(queue)
        let names = try queue.read {
            try String.fetchAll($0, sql: """
                SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'managedFile'
                """)
        }
        #expect(names.contains("managedFile_volume_conflict"))
    }

    @Test("スキーマ版が記録される")
    func recordsTheSchemaVersion() throws {
        let queue = try v2Store()
        try QooMigrations.migrator.migrate(queue)
        let version = try queue.read {
            try String.fetchOne($0, sql: "SELECT schemaVersion FROM storeMetadata WHERE id = 1")
        }
        // **特定の版を書かない。** 移行を 1 本足すたびにこのテストが落ちるのは
        // 「最新版が記録されること」を確かめたい意図と食い違う（実際に v4 で落ちた）。
        #expect(version == QooMigrations.identifiers.last)
    }

    /// **キーが無い既存の JSON もそのまま読める** [実測: Swift の合成された
    /// `Decodable` は既定値を使わず `keyNotFound` で失敗する]。
    /// 読めなくなると、登録済みのライブラリ設定が丸ごと失われたように見える。
    @Test("新しいキーを持たない settingsJSON が既定値で読める")
    func settingsJSONWrittenBeforeThisMigrationStillDecodes() throws {
        let legacy = """
        {"targetExtensions":["cbz"],"imageExtensions":["jpg"],\
        "delimiters":{"pairs":[],"separators":[]},"semanticBindings":{"@author":3},\
        "seriesTitleCompositionFormat":"@series @volume","labelGroupOrder":[1,2,3]}
        """
        let payload = try JSONDecoder().decode(LibrarySettingsPayload.self,
                                               from: Data(legacy.utf8))
        #expect(payload.targetExtensions == ["cbz"])
        #expect(payload.semanticBindings["@author"] == 3)
        // 新しいキーは既定値で埋まる。
        #expect(payload.readsEmbeddedMetadata == true)
        #expect(payload.comicInfoVolumeSource == .ask)
    }

    /// 空の JSON でも落ちない（すべてのキーが `decodeIfPresent`）。
    @Test("空の settingsJSON も読める")
    func emptySettingsJSONDecodes() throws {
        let payload = try JSONDecoder().decode(LibrarySettingsPayload.self, from: Data("{}".utf8))
        #expect(payload.targetExtensions.isEmpty)
        #expect(payload.readsEmbeddedMetadata == true)
    }
}
