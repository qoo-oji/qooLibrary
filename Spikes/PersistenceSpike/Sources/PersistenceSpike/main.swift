//
//  永続化層の実測スパイク（フェーズ2 着手前、T-03 / T-04 / PF-01〜PF-07）。
//
//  目的:
//    ① C-07 の想定規模（全体 10 万ファイル、1 ライブラリ 5 万）で GRDB が
//       PF-01〜PF-07 を満たすかを実測する。
//    ② [T-03] 「ラベルグループ間 AND × グループ内 OR」を素の SQL で表現でき、
//       かつ PF-03（5 万件で 500ms）を満たすか。満たすなら 07章 §7.3 の
//       `LabelIndex`（メモリ上の索引）は不要になり、整合性維持の危険が丸ごと消える。
//    ③ [T-04] `Label.fileCount` の増分更新が破綻しないか。全件再集計の実費用。
//
//  測定は使い捨ての一時ディレクトリで行い、ユーザーのデータには一切触れない。
//  文字列だけは実コーパス（Tests/GoldenDataset/private/corpus、gitignore 済み）を
//  読めれば使う。無ければ同じ長さ分布の合成名で代替する。
//
import Foundation
import GRDB

// MARK: - 測定ユーティリティ

@discardableResult
func measure(_ label: String, _ body: () throws -> Void) rethrows -> Double {
    let t0 = DispatchTime.now().uptimeNanoseconds
    try body()
    let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000
    let pad = String(repeating: " ", count: max(0, 58 - label.count))
    print("  " + label + pad + String(format: "%8.1f ms", ms))
    return ms
}

func residentBytes() -> UInt64 {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    return kr == KERN_SUCCESS ? info.resident_size : 0
}

func mb(_ b: UInt64) -> String { String(format: "%.0f MB", Double(b) / 1_048_576) }

// MARK: - 実データに基づく名前の供給

/// 実コーパスがあれば実ファイル名を、無ければ同じ長さ分布の合成名を返す。
func loadNamePool() -> [String] {
    let repo = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let dir = repo.appendingPathComponent("Tests/GoldenDataset/private/corpus")
    var pool: [String] = []
    if let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
        struct Corpus: Decodable { struct E: Decodable { let relativePath: String; let isDirectory: Bool }
                                   let entries: [E] }
        for f in files where f.pathExtension == "json" {
            guard let d = try? Data(contentsOf: f),
                  let c = try? JSONDecoder().decode(Corpus.self, from: d) else { continue }
            pool.append(contentsOf: c.entries.filter { !$0.isDirectory }
                .map { ($0.relativePath as NSString).lastPathComponent })
        }
    }
    if pool.count >= 500 {
        print("  名前プール: 実コーパス \(pool.count) 件")
        return pool
    }
    // 実測した分布（平均 46.6 文字 / 101 バイト）に合わせた合成名。
    print("  名前プール: 合成（実コーパスなし）")
    let base = "あいうえおかきくけこアイウエオ漢字混じり作品名ABCdef0123"
    return (0..<2000).map { i in
        let n = 30 + (i % 45)
        return "(合成) [\(i % 700)] " + String(String(repeating: base, count: 4).prefix(n)) + ".cbz"
    }
}

// MARK: - スキーマ（07章 §7.2 の要点だけを写したもの）

func makeSchema(_ db: Database) throws {
    try db.create(table: "managedFile") { t in
        t.primaryKey("id", .text)
        t.column("libraryID", .text).notNull()
        t.column("inode", .integer).notNull()
        t.column("volumeUUID", .text).notNull()
        t.column("relativePath", .text).notNull()
        t.column("filename", .text).notNull()
        t.column("normalizedName", .text).notNull()
        t.column("searchKey", .text).notNull()
        t.column("fileSize", .integer).notNull()
        t.column("createdAt", .double).notNull()
        t.column("modifiedAt", .double).notNull()
        t.column("title", .text)
        t.column("seriesKey", .text)
        t.column("volumeNumber", .double)
        t.column("rating", .integer).notNull().defaults(to: 0)
        t.column("state", .text).notNull()
        t.column("isArchived", .boolean).notNull().defaults(to: false)
    }
    // [IX-01]
    try db.create(index: "mf_identity", on: "managedFile", columns: ["volumeUUID", "inode"], unique: true)
    try db.create(index: "mf_lib_path", on: "managedFile", columns: ["libraryID", "relativePath"])
    try db.create(index: "mf_lib_state", on: "managedFile", columns: ["libraryID", "state"])
    try db.create(index: "mf_lib_series", on: "managedFile", columns: ["libraryID", "seriesKey"])
    try db.create(index: "mf_search", on: "managedFile", columns: ["searchKey"])

    try db.create(table: "label") { t in
        t.primaryKey("id", .text)
        t.column("labelGroupID", .text).notNull()
        t.column("name", .text).notNull()
        t.column("normalizedName", .text).notNull()
        t.column("fileCount", .integer).notNull().defaults(to: 0)
        t.column("isArchived", .boolean).notNull().defaults(to: false)
    }
    try db.create(index: "lb_group_norm", on: "label", columns: ["labelGroupID", "normalizedName"], unique: true)

    try db.create(table: "fileLabel") { t in
        t.column("fileID", .text).notNull()
        t.column("labelID", .text).notNull()
        t.column("origin", .text).notNull()
        t.primaryKey(["fileID", "labelID"])
    }
    try db.create(index: "fl_label", on: "fileLabel", columns: ["labelID"])
}

// MARK: - パラメータ

let totalFiles = 100_000          // [C-07] 全体で 10 万ファイル
let filesPerLibrary = 50_000      // [C-07] 1 ライブラリ 5 万
let libraryCount = totalFiles / filesPerLibrary
/// ラベルグループ構成（実データの括弧タグ平均 3.13 個に合わせて 5 グループ・各ファイル 5 ラベル）
let groupCardinality = [3000, 2000, 500, 30, 5000]   // 著者 / サークル / 原作 / ジャンル / シリーズ

print("=== 永続化スパイク: GRDB \(totalFiles) files / \(totalFiles * groupCardinality.count) fileLabels ===")
print("   macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
let namePool = loadNamePool()

let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("qoo-persistence-spike-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: tmp) }
let dbPath = tmp.appendingPathComponent("qoo.sqlite").path

var config = Configuration()
config.prepareDatabase { db in
    try db.execute(sql: "PRAGMA journal_mode = WAL")
    try db.execute(sql: "PRAGMA synchronous = NORMAL")
}
let pool = try DatabasePool(path: dbPath, configuration: config)
try pool.write(makeSchema)

let libraryIDs = (0..<libraryCount).map { _ in UUID().uuidString }
let groupIDs = groupCardinality.map { _ in UUID().uuidString }

// ラベルを先に作る
var labelIDsByGroup: [[String]] = []
print("\n--- 投入 ---")
try measure("ラベル \(groupCardinality.reduce(0,+)) 件を挿入") {
    try pool.write { db in
        for (g, n) in groupCardinality.enumerated() {
            var ids: [String] = []
            ids.reserveCapacity(n)
            for i in 0..<n {
                let id = UUID().uuidString
                ids.append(id)
                try db.execute(sql: """
                    INSERT INTO label (id, labelGroupID, name, normalizedName, fileCount, isArchived)
                    VALUES (?, ?, ?, ?, 0, 0)
                    """, arguments: [id, groupIDs[g], "ラベル\(g)-\(i)", "らべる\(g)-\(i)"])
            }
            labelIDsByGroup.append(ids)
        }
    }
}

// ファイル + fileLabel を、スキャンと同じく 500 件ごとのバッチで投入 [SE3-05]
var allFileIDs: [String] = []
allFileIDs.reserveCapacity(totalFiles)
let insertMS = try measure("ファイル \(totalFiles) 件 + ラベル紐づけ \(totalFiles * 5) 件（500 件バッチ）") {
    var produced = 0
    var rng = SystemRandomNumberGenerator()
    while produced < totalFiles {
        let batch = min(500, totalFiles - produced)
        try pool.write { db in
            for k in 0..<batch {
                let i = produced + k
                let id = UUID().uuidString
                allFileIDs.append(id)
                let name = namePool[i % namePool.count]
                let lib = libraryIDs[i / filesPerLibrary]
                let rel = "第\(i % 200)階層/\(name)"
                try db.execute(sql: """
                    INSERT INTO managedFile
                    (id, libraryID, inode, volumeUUID, relativePath, filename, normalizedName,
                     searchKey, fileSize, createdAt, modifiedAt, title, seriesKey, volumeNumber,
                     rating, state, isArchived)
                    VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,'active',0)
                    """, arguments: [id, lib, Int64(i + 1), "VOL-\(i / filesPerLibrary)",
                                     rel, name, name.lowercased(), name.lowercased(),
                                     Int64.random(in: 1_000_000...500_000_000, using: &rng),
                                     Date().timeIntervalSinceReferenceDate,
                                     Date().timeIntervalSinceReferenceDate,
                                     name, "series-\(i % 5000)", Double(i % 30),
                                     Int.random(in: 0...5, using: &rng)])
                for g in 0..<groupCardinality.count {
                    let lid = labelIDsByGroup[g][i % groupCardinality[g]]
                    try db.execute(sql: "INSERT INTO fileLabel (fileID, labelID, origin) VALUES (?,?,'auto')",
                                   arguments: [id, lid])
                }
            }
        }
        produced += batch
    }
}
print(String(format: "    → %.0f files/sec（[PF-05] 1 万件は %.1f 秒相当。目標 60 秒）",
             Double(totalFiles) / (insertMS / 1000), (insertMS / 1000) * 10_000 / Double(totalFiles)))

let dbBytes = (try? FileManager.default.attributesOfItem(atPath: dbPath)[.size] as? Int64) ?? 0
print("    → DB サイズ \(mb(UInt64(max(0, dbBytes))))、常駐メモリ \(mb(residentBytes()))")

// MARK: - [T-03] ラベルフィルタ: グループ内 OR × グループ間 AND

print("\n--- [T-03] ラベルフィルタ（グループ内 OR × グループ間 AND）1 ライブラリ 5 万件 ---")
let targetLib = libraryIDs[0]

/// 選択: グループ0 から 3 ラベル、グループ1 から 2 ラベル、グループ3 から 1 ラベル
@MainActor func selection() -> [[String]] {
    [Array(labelIDsByGroup[0].prefix(3)),
     Array(labelIDsByGroup[1].prefix(2)),
     Array(labelIDsByGroup[3].prefix(1))]
}

@MainActor func filterSQL(_ sel: [[String]]) -> (String, StatementArguments) {
    // 各グループを INTERSECT で畳む [LF-08][LF-09][LF-10]
    var parts: [String] = []
    var args: [DatabaseValueConvertible] = []
    for ids in sel {
        let q = ids.map { _ in "?" }.joined(separator: ",")
        parts.append("SELECT fileID FROM fileLabel WHERE labelID IN (\(q))")
        args.append(contentsOf: ids)
    }
    let sql = """
        SELECT COUNT(*) FROM managedFile
        WHERE libraryID = ? AND state = 'active' AND isArchived = 0
          AND id IN (\(parts.joined(separator: " INTERSECT ")))
        """
    return (sql, StatementArguments([targetLib] + args))
}

/// 「グループ内 OR × グループ間 AND」を素の SQL へ落とす [LF-08][LF-09][LF-10]。
/// 目的の広さを変えて最悪ケースまで測る（狭い選択だけ測って一般化しないこと）。
@MainActor
func runFilter(_ sel: [[String]], _ title: String, page: Bool) throws -> Int {
    var n = 0
    let (sql, args) = filterSQL(sel)
    _ = try measure(title + " — 件数") {
        n = try pool.read { try Int.fetchOne($0, sql: sql, arguments: args) ?? 0 }
    }
    if page {
        let pageSQL = sql.replacingOccurrences(
            of: "SELECT COUNT(*) FROM managedFile",
            with: "SELECT id, filename, fileSize, modifiedAt, rating FROM managedFile")
            + " ORDER BY filename LIMIT 200"
        _ = try measure(title + " — ソート＋先頭 200 件") {
            _ = try pool.read { try Row.fetchAll($0, sql: pageSQL, arguments: args) }
        }
    }
    return n
}

// (a) 狭い: 3 グループを AND で畳む
var n = try runFilter([Array(labelIDsByGroup[0].prefix(3)),
                       Array(labelIDsByGroup[1].prefix(2)),
                       Array(labelIDsByGroup[3].prefix(1))], "(a) 3 グループ AND（狭い）", page: true)
print("      該当 \(n) 件")

// (b) 単一グループ・単一ラベルで大量ヒット（ジャンル相当、5 万 / 30）
n = try runFilter([[labelIDsByGroup[3][0]]], "(b) 低カーディナリティ 1 ラベル", page: true)
print("      該当 \(n) 件")

// (c) グループ内 OR を 100 ラベルへ広げる
n = try runFilter([Array(labelIDsByGroup[0].prefix(100))], "(c) 1 グループ内 100 ラベルの OR", page: true)
print("      該当 \(n) 件")

// (d) 最悪: 低カーディナリティ 2 グループの AND（両方とも広い集合）
n = try runFilter([Array(labelIDsByGroup[3].prefix(10)), Array(labelIDsByGroup[2].prefix(100))],
                  "(d) 広い集合どうしの AND", page: true)
print("      該当 \(n) 件")

// (e) ほぼ全件が該当（グループ 3 の全ラベルを OR）
n = try runFilter([labelIDsByGroup[3]], "(e) 全ラベル OR（ほぼ全件が該当）", page: true)
print("      該当 \(n) 件")

// (f) フィルタ無しで全 5 万件をソートしてページング（一覧の素の状態）
_ = try measure("(f) フィルタ無し 5 万件を名前順ソート＋先頭 200 件") {
    _ = try pool.read { db in
        try Row.fetchAll(db, sql: """
            SELECT id, filename, fileSize, modifiedAt, rating FROM managedFile
            WHERE libraryID = ? AND state = 'active' AND isArchived = 0
            ORDER BY filename LIMIT 200
            """, arguments: [targetLib])
    }
}
_ = try measure("(g) 同上 + 深いページ（OFFSET 40000）") {
    _ = try pool.read { db in
        try Row.fetchAll(db, sql: """
            SELECT id, filename, fileSize, modifiedAt, rating FROM managedFile
            WHERE libraryID = ? AND state = 'active' AND isArchived = 0
            ORDER BY filename LIMIT 200 OFFSET 40000
            """, arguments: [targetLib])
    }
}
// (h) ラベルフィルタ + 検索 + 評価の複合 [SR-02][RT-01]
_ = try measure("(h) ラベルフィルタ + 部分一致検索 + 評価 >= 3 の複合") {
    let (base, args) = filterSQL([Array(labelIDsByGroup[3].prefix(10))])
    let sql = base.replacingOccurrences(of: "SELECT COUNT(*) FROM managedFile",
                                        with: "SELECT id, filename FROM managedFile")
        .replacingOccurrences(of: "AND id IN (", with: "AND rating >= 3 AND searchKey LIKE ? AND id IN (")
    var a = StatementArguments([targetLib, "%" + String(namePool[3].prefix(4)).lowercased() + "%"])
    a += args
    // 先頭の libraryID が二重に入らないよう組み直す
    let (sql2, args2) = filterSQL([Array(labelIDsByGroup[3].prefix(10))])
    var rebuilt = sql2.replacingOccurrences(of: "SELECT COUNT(*) FROM managedFile",
                                            with: "SELECT id, filename FROM managedFile")
    rebuilt = rebuilt.replacingOccurrences(of: "state = 'active'",
                                           with: "state = 'active' AND rating >= 3 AND searchKey LIKE '%a%'")
    _ = try pool.read { try Row.fetchAll($0, sql: rebuilt + " ORDER BY filename LIMIT 200", arguments: args2) }
    _ = sql; _ = a
}

// MARK: - [T-04] Label.fileCount

print("\n--- [T-04] Label.fileCount ---")
try measure("全ラベル \(groupCardinality.reduce(0,+)) 件の件数を GROUP BY で全件再集計") {
    try pool.write { db in
        try db.execute(sql: """
            UPDATE label SET fileCount = COALESCE((
                SELECT COUNT(*) FROM fileLabel fl
                JOIN managedFile mf ON mf.id = fl.fileID
                WHERE fl.labelID = label.id AND mf.state = 'active' AND mf.isArchived = 0
            ), 0)
            """)
    }
}
try measure("[IX-03] 増分更新: 1 ファイル分の紐づけ 5 件を ±1 する") {
    try pool.write { db in
        for g in 0..<groupCardinality.count {
            try db.execute(sql: "UPDATE label SET fileCount = fileCount + 1 WHERE id = ?",
                           arguments: [labelIDsByGroup[g][0]])
        }
    }
}
try measure("バッジ表示用: 1 グループ分のラベル件数を一括取得") {
    _ = try pool.read { db in
        try Row.fetchAll(db, sql: "SELECT id, name, fileCount FROM label WHERE labelGroupID = ? ORDER BY fileCount DESC LIMIT 200",
                         arguments: [groupIDs[0]])
    }
}

// MARK: - PF-04 検索 / PF-02 フォルダ一覧 / PF-01 起動

print("\n--- PF-04 / PF-02 / PF-01 ---")
let needle = String(namePool[7].dropFirst(6).prefix(6))
try measure("[PF-04] 部分一致検索 LIKE '%…%' 10 万件（目標 300ms）") {
    _ = try pool.read { db in
        try Row.fetchAll(db, sql: "SELECT id, filename FROM managedFile WHERE searchKey LIKE ? LIMIT 200",
                         arguments: ["%" + needle.lowercased() + "%"])
    }
}
try measure("[PF-04] 部分一致検索・1 件もヒットしない最悪ケース（全走査）") {
    _ = try pool.read { db in
        try Row.fetchAll(db, sql: "SELECT id, filename FROM managedFile WHERE searchKey LIKE ? LIMIT 200",
                         arguments: ["%zzqqxx-該当なし-%"])
    }
}
try measure("[PF-02] フォルダ 1 件（約 500 件）の一覧＋ソート（目標 300ms）") {
    _ = try pool.read { db in
        try Row.fetchAll(db, sql: """
            SELECT id, filename, fileSize, modifiedAt, rating FROM managedFile
            WHERE libraryID = ? AND relativePath LIKE ? AND state = 'active'
            ORDER BY filename
            """, arguments: [targetLib, "第17階層/%"])
    }
}
try measure("[PF-01] 起動時: 総件数 + ライブラリ別件数") {
    _ = try pool.read { db in
        _ = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM managedFile")
        _ = try Row.fetchAll(db, sql: "SELECT libraryID, COUNT(*) FROM managedFile GROUP BY libraryID")
    }
}

// MARK: - デコード方式の比較（HN の報告: Codable は手書きの約 3 倍遅い）

print("\n--- デコード方式 ---")
struct FileRowCodable: Codable, FetchableRecord {
    var id: String; var filename: String; var fileSize: Int64; var rating: Int
}
struct FileRowManual: FetchableRecord {
    var id: String; var filename: String; var fileSize: Int64; var rating: Int
    init(row: Row) { id = row[0]; filename = row[1]; fileSize = row[2]; rating = row[3] }
}
let pageSQL = "SELECT id, filename, fileSize, rating FROM managedFile WHERE libraryID = ? LIMIT 20000"
try measure("Codable(FetchableRecord) で 2 万行") {
    _ = try pool.read { try FileRowCodable.fetchAll($0, sql: pageSQL, arguments: [targetLib]) }
}
try measure("手書き init(row:) で 2 万行") {
    _ = try pool.read { try FileRowManual.fetchAll($0, sql: pageSQL, arguments: [targetLib]) }
}

// MARK: - 同一性判定（ID-02）と 1 件更新

print("\n--- スキャン時のホットパス ---")
try measure("[ID-02] (volumeUUID, inode) で 1 万回引く") {
    try pool.read { db in
        let stmt = try db.cachedStatement(sql: "SELECT id FROM managedFile WHERE volumeUUID = ? AND inode = ?")
        for i in 0..<10_000 {
            _ = try String.fetchOne(stmt, arguments: ["VOL-0", Int64(i + 1)])
        }
    }
}

print(String(format: "\n最終常駐メモリ %@（[PF-07] 目標 1 GB 以内）", mb(residentBytes())))
let finalBytes = (try? FileManager.default.attributesOfItem(atPath: dbPath)[.size] as? Int64) ?? 0
print("DB: \(mb(UInt64(max(0, finalBytes))))")

try probePrimaryKeyShape(namePool: namePool)

await probeConcurrency(dbPath: dbPath)
