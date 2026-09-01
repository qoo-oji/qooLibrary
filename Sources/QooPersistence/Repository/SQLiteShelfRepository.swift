//
//  ShelfRepository の SQLite 実装 [SH-01〜SH-11]。
//
//  条件は JSON 1 列（`ShelfRecord` の注記）。**符号化・復号はここだけで行う**
//  ——上位層は `ShelfCondition` という値だけを見る [A-02]。
//
import Foundation
import GRDB
import QooKit

public struct SQLiteShelfRepository: ShelfRepository, Sendable {
    let database: QooDatabase

    public init(database: QooDatabase) {
        self.database = database
    }

    // MARK: - 符号化

    /// **キーを名前順に並べる** [IE-04 と同じ理由]。同じ条件なら同じバイト列に
    /// なるので、DB の差分を人が読めるし、往復テストも書ける。
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    static func encode(_ condition: ShelfCondition) throws -> String {
        String(decoding: try encoder.encode(condition), as: UTF8.self)
    }

    /// **読めない JSON でも行を落とさない** [ER-01 の精神]。ここで throw すると、
    /// 1 件壊れただけで左ペインからシェルフが全部消え、直す手立ても無くなる。
    /// 空の条件として出せば、名前は見えるので削除・上書き保存で片付けられる。
    static func decode(_ json: String) -> ShelfCondition {
        (try? JSONDecoder().decode(ShelfCondition.self, from: Data(json.utf8)))
            ?? ShelfCondition(labelIDs: [])
    }

    static func summary(_ row: Row) -> ShelfSummary {
        ShelfSummary(id: ShelfID(rawValue: row["id"]),
                     libraryID: LibraryID(rawValue: row["libraryId"]),
                     name: row["name"],
                     displayOrder: row["displayOrder"],
                     condition: decode(row["conditionJSON"]))
    }

    // MARK: - 読み取り

    public func shelves(libraryID: LibraryID) async throws -> [ShelfSummary] {
        try await database.writer.read { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM shelf WHERE libraryId = ? ORDER BY displayOrder, id
                """, arguments: [libraryID.rawValue]).map(Self.summary)
        }
    }

    public func snapshot(ids: [ShelfID]) async throws -> [ShelfSummary] {
        guard !ids.isEmpty else { return [] }
        return try await database.writer.read { db in
            // 存在しない ID は黙って飛ばす（`LabelRepository.snapshot` と同じ
            // 扱い——同時に消えていた場合に、戻せるものまで戻せなくなるのを避ける）。
            try Row.fetchAll(db, sql: """
                SELECT * FROM shelf WHERE id IN (\(ids.map { _ in "?" }.joined(separator: ",")))
                ORDER BY displayOrder, id
                """, arguments: StatementArguments(ids.map(\.rawValue))).map(Self.summary)
        }
    }

    // MARK: - 書き込み

    public func create(libraryID: LibraryID, name: String,
                       condition: ShelfCondition) async throws -> ShelfID {
        let json = try Self.encode(condition)
        return try await database.writer.write { db in
            let next = try Int.fetchOne(db, sql: """
                SELECT COALESCE(MAX(displayOrder), -1) + 1 FROM shelf WHERE libraryId = ?
                """, arguments: [libraryID.rawValue]) ?? 0
            try db.execute(sql: """
                INSERT INTO shelf (libraryId, name, displayOrder, conditionJSON, createdAt)
                VALUES (?, ?, ?, ?, ?)
                """, arguments: [libraryID.rawValue, name, next, json, Date().timeIntervalSince1970])
            return ShelfID(rawValue: db.lastInsertedRowID)
        }
    }

    public func updateCondition(_ id: ShelfID, _ condition: ShelfCondition) async throws {
        let json = try Self.encode(condition)
        try await database.writer.write { db in
            try db.execute(sql: "UPDATE shelf SET conditionJSON = ? WHERE id = ?",
                           arguments: [json, id.rawValue])
        }
    }

    public func rename(_ id: ShelfID, to name: String) async throws {
        try await database.writer.write { db in
            try db.execute(sql: "UPDATE shelf SET name = ? WHERE id = ?",
                           arguments: [name, id.rawValue])
        }
    }

    public func delete(_ ids: [ShelfID]) async throws {
        guard !ids.isEmpty else { return }
        try await database.writer.write { db in
            try db.execute(sql: """
                DELETE FROM shelf WHERE id IN (\(ids.map { _ in "?" }.joined(separator: ",")))
                """, arguments: StatementArguments(ids.map(\.rawValue)))
        }
    }

    public func setOrder(_ orderedIDs: [ShelfID]) async throws {
        guard !orderedIDs.isEmpty else { return }
        try await database.writer.write { db in
            for (order, id) in orderedIDs.enumerated() {
                try db.execute(sql: "UPDATE shelf SET displayOrder = ? WHERE id = ?",
                               arguments: [order, id.rawValue])
            }
        }
    }

    /// **同じ行 ID で作り直す** [SH-11]。`id` を明示して INSERT する。
    public func restore(_ shelves: [ShelfSummary]) async throws {
        guard !shelves.isEmpty else { return }
        let encoded = try shelves.map { ($0, try Self.encode($0.condition)) }
        try await database.writer.write { db in
            for (shelf, json) in encoded {
                try db.execute(sql: """
                    INSERT OR REPLACE INTO shelf (id, libraryId, name, displayOrder,
                                                  conditionJSON, createdAt)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """, arguments: [shelf.id.rawValue, shelf.libraryID.rawValue, shelf.name,
                                     shelf.displayOrder, json, Date().timeIntervalSince1970])
            }
        }
    }
}
