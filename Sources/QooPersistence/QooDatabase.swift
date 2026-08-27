//
//  データベース接続 [07章 §7.1][ST-01〜ST-07][CN-01〜CN-07]。
//
import Foundation
import GRDB
import QooKit

/// アプリで単一の接続 [ST-01]。全ウインドウ・全タブが共有する [ST-02]。
///
/// `DatabasePool`（WAL）なので読み取りは並行、書き込みは直列化される。
/// **GRDB は協調スレッドプールの外（自前の直列キュー）で待つ**ため、
/// 8章 §8.11 の `FileIO` へ逃がす必要はない [CN-04、実測: 協調プールを
/// コア数ぶん塞いだ状態でも `await pool.read` が 12 ms で返る]。
public final class QooDatabase: Sendable {
    public let writer: any DatabaseWriter

    init(writer: any DatabaseWriter) {
        self.writer = writer
    }

    /// 既定の置き場所。`~/Library/Application Support/qooLibrary/qooLibrary.sqlite`。
    public static func defaultStoreURL(applicationSupport: URL) -> URL {
        applicationSupport
            .appendingPathComponent("qooLibrary", isDirectory: true)
            .appendingPathComponent("qooLibrary.sqlite")
    }

    /// ファイル名の**自然順**照合 [DU-05]。
    ///
    /// 重複グループの代表を SQL の窓関数で決める [DU2-03] ときに、Swift 側の
    /// `DuplicateSelection.precedes` とまったく同じ比較を使うために要る
    /// ——素の BINARY 照合だと `第10巻` が `第2巻` より前に来て、一覧に出る
    /// 代表と比較ビューの並びが食い違う。**同じ規則を 2 通りに書かない**ため、
    /// どちらも `localizedStandardCompare` を呼ぶ。
    ///
    /// 一致は `NaturalOrderCollationTests` が固定している。
    public static let naturalOrder = DatabaseCollation("qooNaturalOrder") { lhs, rhs in
        lhs.localizedStandardCompare(rhs)
    }

    public static func configuration() -> Configuration {
        var config = Configuration()
        config.prepareDatabase { db in
            db.add(collation: naturalOrder)
            // WAL は open 時に一度設定すれば永続する（ファイルの属性）。
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            // NORMAL は WAL と組で使う既定。電源断でも DB は壊れず、
            // 直前のトランザクションだけが失われうる [RB-03 の想定内]。
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        config.busyMode = .timeout(5)
        return config
    }

    /// ストアを開き、必要なら移行する [MG-10〜MG-13]。
    ///
    /// - Parameter beforeMigration: 未適用の移行があるときだけ呼ばれる。
    ///   JSON スナップショットとストア複製をここで取る [MG-10]。
    public static func open(at url: URL,
                            beforeMigration: (@Sendable (any DatabaseWriter) throws -> Void)? = nil)
        throws -> QooDatabase
    {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        let pool = try DatabasePool(path: url.path, configuration: configuration())
        let migrator = QooMigrations.migrator

        // [MG-12] アプリが知らない移行が適用済み = ストアが新しすぎる。起動を中止する。
        // バージョン番号の自前比較より確実。
        let superseded = try pool.read { try migrator.hasBeenSuperseded($0) }
        if superseded { throw StoreError.schemaTooNew }

        let pending = try pool.read { db in
            try migrator.appliedIdentifiers(db).count < QooMigrations.identifiers.count
        }
        if pending, let beforeMigration {
            try beforeMigration(pool)                               // [MG-10]
        }
        do {
            try migrator.migrate(pool)
        } catch {
            throw StoreError.migrationFailed(String(describing: error))  // [MG-11][RB-06]
        }
        return QooDatabase(writer: pool)
    }

    /// 一時的な（テスト用の）メモリ上のストア。
    public static func inMemory() throws -> QooDatabase {
        let queue = try DatabaseQueue(configuration: configuration())
        try QooMigrations.migrator.migrate(queue)
        return QooDatabase(writer: queue)
    }

    /// 整合性検査 [RB-03]。
    public func integrityCheck() async throws -> Bool {
        try await writer.read { db in
            try String.fetchOne(db, sql: "PRAGMA integrity_check") == "ok"
        }
    }

    /// オンラインバックアップ [BK-01][BK-02][BK2-01]。
    ///
    /// **ファイルを直接コピーしてはならない**——`-wal` に未反映の内容を取りこぼす。
    public func backup(to destination: URL,
                       progress: (@Sendable (Double) -> Void)? = nil) async throws {
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let target = try DatabaseQueue(path: destination.path, configuration: Self.configuration())
        // `DatabaseReader.backup(to:)` は接続レベルの API。`read { }` の中で
        // `Database.backup(to:)` を呼ぶと宛先も `Database` を要求されて型が合わない。
        try writer.backup(to: target, pagesPerStep: 256) { p in
            guard let progress, p.totalPageCount > 0 else { return }
            progress(1 - Double(p.remainingPageCount) / Double(p.totalPageCount))
        }
    }

    public enum StoreError: Error, Equatable {
        /// アプリが知らない移行が適用済み [MG-12]。起動を中止する。
        case schemaTooNew
        case migrationFailed(String)
    }
}
