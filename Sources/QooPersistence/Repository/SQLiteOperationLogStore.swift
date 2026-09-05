//
//  操作履歴ストアの SQLite 実装 [HS-01〜HS-04][OH-01〜OH-06][15章 §15.13]。
//
//  何を記録するか（全種別）・なぜ消せないのかは `OperationLogStore`（`QooKit`）の
//  型コメントにある。**触る前にそこを読むこと。**
//
//  形は `SQLiteNotificationHistoryStore` に揃えてある——絞り込みを
//  「SQL で引けるものは SQL、幅非依存の照合は Swift」で分ける線引きまで含めて、
//  同じ判断が同じ理由で成り立つため。
//
import Foundation
import GRDB
import QooKit

public struct SQLiteOperationLogStore: OperationLogStore, Sendable {
    let database: QooDatabase

    public init(database: QooDatabase) {
        self.database = database
    }

    // MARK: - 書き込み

    @discardableResult
    public func append(_ draft: OperationLogDraft) async throws -> OperationLogID {
        // **対象は上限で切る** [AppLimits.Operations.maxTargetsPerEntry]。
        // 一括リネーム 1 万件を 1 行に畳む [D2] ので、全部持つと 1 行が数 MB に
        // なる。切り落とした件数は詳細に残すので「N 件のうち一部」だと分かる。
        let limit = AppLimits.Operations.maxTargetsPerEntry
        let kept = Array(draft.targets.prefix(limit))
        let payload = OperationLogPayload(
            detail: draft.detail,
            truncatedTargets: max(0, draft.targets.count - kept.count))
        let targetsJSON = try Self.encode(kept)
        let detailJSON = try Self.encodePayload(payload)
        return try await database.writer.write { db in
            var record = OperationLogRecord(
                id: nil,
                date: draft.date.timeIntervalSince1970,
                commandName: draft.commandName,
                kind: draft.kind.rawValue,
                targetsJSON: targetsJSON,
                libraryUUID: draft.libraryUUID?.uuidString,
                summary: draft.summary,
                detailJSON: detailJSON)
            try record.insert(db)
            return OperationLogID(rawValue: record.id ?? 0)
        }
    }

    /// [HS-04] 保持期間と件数の上限を保つ。
    ///
    /// **期限と件数の両方を見る**（通知履歴 [NT-07] とまったく同じ理由）。
    /// 片方だけだと、1 日で 1 万件出た日は期限では減らず、逆に静かな月は
    /// 上限に触れないまま何年分も溜まる。どちらも `0` 以下なら無効。
    public func purgeExpired(retentionDays: Int, maxCount: Int) async throws {
        try await database.writer.write { db in
            if retentionDays > 0 {
                let cutoff = Date().addingTimeInterval(-Double(retentionDays) * 24 * 60 * 60)
                try db.execute(sql: "DELETE FROM operationLog WHERE date < ?",
                               arguments: [cutoff.timeIntervalSince1970])
            }
            if maxCount > 0 {
                try db.execute(sql: """
                    DELETE FROM operationLog WHERE id NOT IN (
                        SELECT id FROM operationLog ORDER BY date DESC, id DESC LIMIT ?
                    )
                    """, arguments: [maxCount])
            }
        }
    }

    // MARK: - 読み出し

    public func count() async throws -> Int {
        try await database.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM operationLog") ?? 0
        }
    }

    /// [OH-02] 絞り込み。
    ///
    /// **種別と期間だけを SQL で絞り、キーワードは Swift で判定する**
    /// ——キーワードは `NameFilter` を通す。**全角で打っても半角に当たる**
    /// [1-16 の実測] のはこのアプリ全体の約束で、SQL の `LIKE` では表せない。
    ///
    /// **SQL 側に上限を置く**——掃除 [HS-04] は起動時に 1 度しか走らないので、
    /// 1 回のセッションの中では件数が伸び続ける（通知履歴でレビューが
    /// 見つけたのと同じ穴）。上限は既定の保持件数の 2 倍なので、既定の設定
    /// では 1 件も切り落とされない。
    ///
    /// **既知の限界**: 件数の上限を「無制限」にした状態で、古いほうにしか
    /// 該当が無いキーワードで絞ると、Swift 側の判定まで届かず 0 件に見える
    /// ことがある。SQL で絞れる種別・期間を併用すれば届く。
    public func query(_ filter: OperationLogFilter) async throws -> [OperationLogEntry] {
        var sql = "SELECT * FROM operationLog"
        var conditions: [String] = []
        var arguments: [DatabaseValueConvertible] = []
        if let group = filter.group {
            // **区画に属する種別を列挙して引く**——`group` を列に持つと
            // `kind` との二重の真実になり、片方だけ直したときにずれる。
            let kinds = OperationLogKind.allCases.filter { $0.group == group }
            let placeholders = kinds.map { _ in "?" }.joined(separator: ", ")
            conditions.append("kind IN (\(placeholders))")
            arguments.append(contentsOf: kinds.map(\.rawValue))
        }
        if let period = filter.period {
            conditions.append("date >= ? AND date < ?")
            arguments.append(period.start.timeIntervalSince1970)
            arguments.append(period.end.timeIntervalSince1970)
        }
        if !conditions.isEmpty {
            sql += " WHERE " + conditions.joined(separator: " AND ")
        }
        sql += " ORDER BY date DESC, id DESC LIMIT \(AppLimits.Operations.queryLimit)"

        // 閉包へ渡す前に不変にしておく（`var` のまま捕まえると Swift 6 の
        // 並行性検査に止められる）。
        let statement = sql
        let bindings = StatementArguments(arguments) ?? StatementArguments()
        let records = try await database.writer.read { db in
            try OperationLogRecord.fetchAll(db, sql: statement, arguments: bindings)
        }
        return records.compactMap(Self.entry(from:)).filter {
            Self.matches($0, keyword: filter.keyword)
        }
    }

    /// キーワードの判定 [OH-02]。**純粋関数として切り出してある**
    /// ——SQL を経由せずに固定できるようにするため。
    static func matches(_ row: OperationLogEntry, keyword: String?) -> Bool {
        guard let keyword, !keyword.trimmingCharacters(in: .whitespaces).isEmpty else { return true }
        // **対象のパスも検索対象に含める**——「あのファイルに何をしたか」を
        // 探すのが、この画面を開く主な動機のひとつ。
        let haystack = ([row.summary, row.commandName, row.detail ?? ""] + row.targets)
            .joined(separator: "\n")
        return NameFilter.matches(name: haystack, query: keyword)
    }

    // MARK: - 変換

    static func entry(from record: OperationLogRecord) -> OperationLogEntry? {
        guard let id = record.id else { return nil }
        let payload = decodePayload(record.detailJSON)
        return OperationLogEntry(
            id: OperationLogID(rawValue: id),
            date: Date(timeIntervalSince1970: record.date),
            commandName: record.commandName,
            // **未知の種別は捨てずに「実行」へ倒す**——古いストアを新しい
            // アプリで読む場面はいまのところ無いが、行を落とすと「いつ何を
            // したか」が丸ごと消える。列に残っている `summary` は読める。
            kind: OperationLogKind(rawValue: record.kind) ?? .executed,
            targets: decodeTargets(record.targetsJSON),
            libraryUUID: record.libraryUUID.flatMap(UUID.init(uuidString:)),
            summary: record.summary,
            detail: payload.detail,
            truncatedTargets: payload.truncatedTargets)
    }

    static func encode(_ targets: [String]) throws -> String {
        String(decoding: try JSONEncoder().encode(targets), as: UTF8.self)
    }

    /// **壊れた JSON でも行そのものは捨てない。** 内容と日時は列にあるので、
    /// 対象を失っても「いつ何をしたか」は読める——履歴が丸ごと消えるより、
    /// 一部が欠けるほうがはるかにましである（通知履歴と同じ判断）。
    static func decodeTargets(_ json: String) -> [String] {
        guard let data = json.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }

    static func encodePayload(_ payload: OperationLogPayload) throws -> String? {
        guard payload.detail != nil || payload.truncatedTargets > 0 else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(payload), as: UTF8.self)
    }

    static func decodePayload(_ json: String?) -> OperationLogPayload {
        guard let json, let data = json.data(using: .utf8) else { return OperationLogPayload() }
        return (try? JSONDecoder().decode(OperationLogPayload.self, from: data))
            ?? OperationLogPayload()
    }
}

/// `operationLog.detailJSON` の中身。
struct OperationLogPayload: Codable, Sendable {
    var detail: String?
    /// 上限で切り落とした対象の件数。**文言は UI が組み立てる**
    /// （`QooKit`/`QooPersistence` は表示言語を知らない [A-01]）。
    var truncatedTargets: Int = 0
}
