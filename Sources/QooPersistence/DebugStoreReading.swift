#if DEBUG
import Foundation
import GRDB

/// 制御口 [MT-33] がストアを**読み取り専用で**覗くための口。
///
/// **ここに置くのは層の決まりのため** [A-02]——`GRDB` を import してよいのは
/// この層だけなので、SQL の実行はここでしか書けない。返すのは `Sendable` な
/// 値型だけで、GRDB の型は 1 つも外へ出さない [RP2-02]。
public enum DebugSQLValue: Sendable, Equatable {
    case text(String)
    case integer(Int64)
    case real(Double)
    /// 中身は返さない（大きさだけ）。検証で要るのは「入っているか」まで。
    case blob(byteCount: Int)
}

extension QooDatabase {
    /// 任意の `SELECT` を走らせる。
    ///
    /// **書き込みは通らない。** `read { }` は SQLite の読み取りトランザクション
    /// なので、`INSERT`/`UPDATE`/`DELETE` はエンジン自身が
    /// `attempt to write a readonly database` で拒む——こちらで文を検査する
    /// 必要が無く、うっかり書ける経路が生えることもない [CT-14]。
    public func debugQuery(sql: String, limit: Int) throws -> [[String: DebugSQLValue]] {
        // **カーソルで読み、上限に達したら止める。** `fetchAll` は全行を
        // 実体化してから切るので、10 万件 [C-07] のストアに素の
        // `SELECT * FROM managedFile` を投げると口の応答が上限時間を超える。
        try writer.read { db in
            var rows: [[String: DebugSQLValue]] = []
            let cursor = try Row.fetchCursor(db, sql: sql)
            while rows.count < limit, let row = try cursor.next() {
                var result: [String: DebugSQLValue] = [:]
                for (column, value) in row {
                    switch value.storage {
                    case .string(let text): result[column] = .text(text)
                    case .int64(let number): result[column] = .integer(number)
                    case .double(let number): result[column] = .real(number)
                    case .blob(let data): result[column] = .blob(byteCount: data.count)
                    // NULL は鍵ごと落とす。**「NULL」と「列が無い」を区別
                    // しない**——検証で要るのは「値が入っているか」までで、
                    // 区別が要る場面では `IS NULL` を書けばよい。
                    case .null: break
                    }
                }
                rows.append(result)
            }
            return rows
        }
    }

    /// 全テーブルの行数。**検証のたびに必ず見るもの**——「登録解除で DB 全
    /// テーブル 0 件」は後始末の確認そのもので、毎回 SQL を書き下すより
    /// 1 コマンドで足りる。
    public func debugTableCounts(includeEmpty: Bool) throws -> [String: Int] {
        try writer.read { db in
            let names = try String.fetchAll(db, sql: """
                SELECT name FROM sqlite_master
                WHERE type = 'table' AND name NOT LIKE 'sqlite_%'
                ORDER BY name
                """)
            var counts: [String: Int] = [:]
            for name in names {
                // 表の名前は `sqlite_master` 由来で、外部入力ではない。
                let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \"\(name)\"") ?? 0
                if count > 0 || includeEmpty { counts[name] = count }
            }
            return counts
        }
    }
}
#endif
