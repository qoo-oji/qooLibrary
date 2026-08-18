//
//  主キーの型がサイズと速度にどれだけ効くかを測る。
//
//  07章の草案は `ManagedFile.id: UUID` / `FileLabel.fileID: UUID` としているが、
//  fileLabel は 50 万行あり、UUID 文字列（36 バイト）×2 が本体とインデックスの
//  両方に載る。JSON 入出力の同一性キーは UUID ではなく「相対パス + ファイル名」
//  [JS-04] なので、内部の行 ID を Int64 にしても外部仕様は変わらない。
//
import Foundation
import GRDB

func probePrimaryKeyShape(namePool: [String]) throws {
    print("\n--- 主キーの型（内部 ID を UUID にするか Int64 にするか） ---")
    let n = 100_000, labelsPerFile = 5, labelCount = 10_530

    for useInt in [false, true] {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("qoo-pk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("t.sqlite").path
        var cfg = Configuration()
        cfg.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
        }
        let pool = try DatabasePool(path: path, configuration: cfg)

        try pool.write { db in
            if useInt {
                try db.execute(sql: """
                    CREATE TABLE managedFile (
                        id INTEGER PRIMARY KEY, libraryID INTEGER NOT NULL, inode INTEGER NOT NULL,
                        volumeUUID TEXT NOT NULL, relativePath TEXT NOT NULL, filename TEXT NOT NULL,
                        searchKey TEXT NOT NULL, fileSize INTEGER NOT NULL, rating INTEGER NOT NULL,
                        state TEXT NOT NULL, isArchived INTEGER NOT NULL);
                    CREATE UNIQUE INDEX i1 ON managedFile(volumeUUID, inode);
                    CREATE INDEX i2 ON managedFile(libraryID, relativePath);
                    CREATE TABLE fileLabel (
                        fileID INTEGER NOT NULL, labelID INTEGER NOT NULL, origin INTEGER NOT NULL,
                        PRIMARY KEY (fileID, labelID)) WITHOUT ROWID;
                    CREATE INDEX i3 ON fileLabel(labelID);
                    """)
            } else {
                try db.execute(sql: """
                    CREATE TABLE managedFile (
                        id TEXT PRIMARY KEY, libraryID TEXT NOT NULL, inode INTEGER NOT NULL,
                        volumeUUID TEXT NOT NULL, relativePath TEXT NOT NULL, filename TEXT NOT NULL,
                        searchKey TEXT NOT NULL, fileSize INTEGER NOT NULL, rating INTEGER NOT NULL,
                        state TEXT NOT NULL, isArchived INTEGER NOT NULL);
                    CREATE UNIQUE INDEX i1 ON managedFile(volumeUUID, inode);
                    CREATE INDEX i2 ON managedFile(libraryID, relativePath);
                    CREATE TABLE fileLabel (
                        fileID TEXT NOT NULL, labelID TEXT NOT NULL, origin TEXT NOT NULL,
                        PRIMARY KEY (fileID, labelID));
                    CREATE INDEX i3 ON fileLabel(labelID);
                    """)
            }
        }

        let labelKeys: [DatabaseValueConvertible] = useInt
            ? (0..<labelCount).map { Int64($0 + 1) }
            : (0..<labelCount).map { _ in UUID().uuidString }

        let t0 = DispatchTime.now().uptimeNanoseconds
        var produced = 0
        while produced < n {
            let batch = min(500, n - produced)
            try pool.write { db in
                let insF = try db.cachedStatement(sql: """
                    INSERT INTO managedFile (id, libraryID, inode, volumeUUID, relativePath, filename,
                    searchKey, fileSize, rating, state, isArchived) VALUES (?,?,?,?,?,?,?,?,?,'active',0)
                    """)
                let insL = try db.cachedStatement(sql:
                    "INSERT INTO fileLabel (fileID, labelID, origin) VALUES (?,?,?)")
                for k in 0..<batch {
                    let i = produced + k
                    let fid: DatabaseValueConvertible = useInt ? Int64(i + 1) : UUID().uuidString
                    let lib: DatabaseValueConvertible = useInt ? Int64(i / 50_000) : UUID().uuidString
                    let name = namePool[i % namePool.count]
                    try insF.execute(arguments: [fid, lib, Int64(i + 1), "VOL-\(i / 50_000)",
                                                 "第\(i % 200)階層/\(name)", name, name.lowercased(),
                                                 Int64(i) * 977, i % 6])
                    for g in 0..<labelsPerFile {
                        try insL.execute(arguments: [fid, labelKeys[(i * 7 + g * 1301) % labelCount],
                                                     useInt ? 0 : "auto"])
                    }
                }
            }
            produced += batch
        }
        let insMS = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000

        // ラベルフィルタ（3 グループ相当の INTERSECT）
        let sel = (0..<3).map { g in (0..<8).map { labelKeys[(g * 97 + $0 * 331) % labelCount] } }
        let parts = sel.map { ids in "SELECT fileID FROM fileLabel WHERE labelID IN (\(ids.map { _ in "?" }.joined(separator: ",")))" }
        let sql = "SELECT COUNT(*) FROM managedFile WHERE id IN (\(parts.joined(separator: " INTERSECT ")))"
        // `StatementArguments([any DatabaseValueConvertible])` は失敗しうる
        // オーバーロードに解決される。Optional の列として渡すと非失敗の初期化子に
        // 一意に決まる。
        var flat: [(any DatabaseValueConvertible)?] = []
        for ids in sel { flat.append(contentsOf: ids.map { Optional($0) }) }
        let args = StatementArguments(flat)
        let t1 = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<5 { _ = try pool.read { try Int.fetchOne($0, sql: sql, arguments: args) } }
        let qMS = Double(DispatchTime.now().uptimeNanoseconds - t1) / 1_000_000 / 5

        // DatabasePool のリーダー接続が生きている間は TRUNCATE チェックポイントが
        // 取れない（database table is locked）。閉じてから実サイズを測る。
        try pool.close()
        var bytes: Int64 = 0
        for suffix in ["", "-wal", "-shm"] {
            bytes += ((try? FileManager.default.attributesOfItem(atPath: path + suffix)[.size]) as? Int64) ?? 0
        }

        let kind = useInt ? "Int64 (rowid)" : "UUID 文字列"
        print(String(format: "  %-16@  投入 %6.0f ms   DB %5.0f MB   フィルタ %5.1f ms",
                     kind as NSString, insMS, Double(bytes) / 1_048_576, qMS))
    }
}
