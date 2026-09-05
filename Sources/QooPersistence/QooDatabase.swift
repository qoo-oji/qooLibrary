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
                            beforeMigration: (@Sendable (any PreMigrationSource) throws -> Void)? = nil)
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
            try beforeMigration(PreMigrationSnapshot(writer: pool))  // [MG-10]
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

    /// 同期で写すための取っ手 [MG-10]。
    ///
    /// 移行前フックが受け取るのと**同じもの**。移行を伴わない場面からも
    /// 同じ経路を通せるように公開している——経路を 2 通り持つと、片方だけ
    /// 直したときに移行前だけが壊れる。
    public var synchronousHandle: PreMigrationSnapshot { PreMigrationSnapshot(writer: writer) }

    /// 整合性検査 [RB-03]。
    public func integrityCheck() async throws -> Bool {
        try await writer.read { db in
            try String.fetchOne(db, sql: "PRAGMA integrity_check") == "ok"
        }
    }

    /// オンラインバックアップ [BK-01][BK-02][BK2-01]。
    ///
    /// **ファイルを直接コピーしてはならない**——`-wal` に未反映の内容を取りこぼす。
    ///
    /// - Important: **失敗しても宛先ファイルは残る。** 宛先は 1 ページも写す前に
    ///   作られるためで、後始末は**呼び出し側の仕事** [BK3-09]——この層は
    ///   削除系の `FileManager` API を呼べない（[B-10]。層の依存方向 [A-01] に
    ///   より `FileOps` を呼べないので、`createDirectory` だけが許されている）。
    ///   合成根の `BackupService` が引き取る。
    public func backup(to destination: URL,
                       progress: (@Sendable (Double) -> Void)? = nil) async throws {
        try Self.backup(writer: writer, to: destination, progress: progress)
    }

    /// 生の writer からのオンラインバックアップ [MG-10]。
    ///
    /// **移行前フックのためだけに切り出してある**——`open` は移行の前に
    /// `beforeMigration(pool)` を**同期で**呼ぶが、その時点では `QooDatabase`
    /// がまだ組み上がっていない。中身は ``backup(to:progress:)`` と同じで、
    /// あちらがこれを呼ぶ（**同じ規則を 2 通りに書かない**）。
    ///
    /// 中身が全部同期なので `async` は元から飾りだった——インスタンス側の
    /// `async` は呼び出し側の作法（`FileIO` 経由）を保つために残してある。
    public static func backup(writer: any DatabaseWriter, to destination: URL,
                              progress: (@Sendable (Double) -> Void)? = nil) throws
    {
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let target = try DatabaseQueue(path: destination.path,
                                       configuration: backupTargetConfiguration())
        // `DatabaseReader.backup(to:)` は接続レベルの API。`read { }` の中で
        // `Database.backup(to:)` を呼ぶと宛先も `Database` を要求されて型が合わない。
        try writer.backup(to: target, pagesPerStep: 256) { p in
            guard let progress, p.totalPageCount > 0 else { return }
            progress(1 - Double(p.remainingPageCount) / Double(p.totalPageCount))
        }
    }

    /// 複製先の設定。**WAL にしない。**
    ///
    /// 既定の ``configuration()`` は `journal_mode = WAL` を立てるので、
    /// 複製のたびに `-wal` / `-shm` が世代の隣にできる——**`generations()`
    /// からは見えないのに容量を食い、剪定の対象にもならない**
    /// ［code-review が実測で発見］。複製は読み書きされないファイルなので
    /// WAL は要らず、復元して開けば ``open(at:beforeMigration:)`` が WAL へ戻す。
    private static func backupTargetConfiguration() -> Configuration {
        var config = Configuration()
        config.prepareDatabase { db in
            db.add(collation: naturalOrder)
            try db.execute(sql: "PRAGMA journal_mode = DELETE")
        }
        return config
    }

    /// 整合性検査の同期版 [RB-03]。移行前フックから使う。
    public static func integrityCheck(writer: any DatabaseWriter) throws -> Bool {
        try writer.read { db in
            try String.fetchOne(db, sql: "PRAGMA integrity_check") == "ok"
        }
    }

    public enum StoreError: Error, Equatable {
        /// アプリが知らない移行が適用済み [MG-12]。起動を中止する。
        case schemaTooNew
        case migrationFailed(String)
    }
}

/// 移行前の DB へ触れる唯一の窓口 [MG-10]。
///
/// `QooDatabase.open` は移行の**前に**このハンドルを渡す。そこでしか
/// 「移行前の状態」には触れられない——移行が始まればスキーマは書き換わり、
/// 失敗しても途中まで進んだ状態が残るため [MG-11][R-14]。
///
/// **生の `DatabaseWriter` を外へ出さないためにある**——`GRDB` を import して
/// よいのは `QooPersistence` だけで [A-01][B-11]、フックを書くのは合成根の
/// `QooApplication` だから。ここが GRDB の型を包み隠す境界になる。
///
/// すべて同期。`open` 自体が同期で、しかも `FileIO.perform` の中から
/// 呼ばれている [NV6-02] ので、この中で待ってよい。
public struct PreMigrationSnapshot: PreMigrationSource, Sendable {
    let writer: any DatabaseWriter

    /// 移行前の状態が**存在するか**。
    ///
    /// **新規ストアでは偽**——`open` は移行が未適用なら必ずフックを呼ぶが
    /// （`SchemaTests` がその契約を固定している）、まだテーブルが 1 つも無い
    /// ので写すものが無い。**ここを見ずに書き出すと `no such table` で失敗し、
    /// 「写すものが無い」と「本当に写せなかった」の区別が付かなくなる**
    /// ——後者だけを異常として報告したい。
    public var hasExistingSchema: Bool {
        (try? writer.read { db in try db.tableExists("library") }) ?? false
    }

    /// 再生成できないデータだけを JSON へ写す [MG-10][BK-05]。
    public func exportDocument(appVersion: String?) throws -> BackupDocument {
        try SQLiteBackupRepository(writer: writer)
            .exportSynchronously(scope: .everything, appVersion: appVersion)
    }

    /// ストアを丸ごと複製する [MG-10][BK-03]。
    public func copyStore(to destination: URL) throws {
        try QooDatabase.backup(writer: writer, to: destination)
    }

    /// 移行前の DB が健全か [RB-03]。
    ///
    /// **壊れた状態を「成功」として保存しないため**［外部調査］——それを
    /// 押し込むと、良い世代を押し出したうえで、いざ復元しようとして初めて
    /// 使えないと分かる。
    public func integrityCheck() throws -> Bool {
        try QooDatabase.integrityCheck(writer: writer)
    }
}
