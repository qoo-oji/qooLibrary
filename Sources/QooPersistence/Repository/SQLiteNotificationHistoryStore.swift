//
//  通知履歴ストアの SQLite 実装 [NT-01〜NT-07][NW-03][NW-05][NW-06][02章 §2.4]。
//
//  何を記録するか（全強度）・なぜ未読は強度 4 以上だけかは
//  `NotificationHistoryStore`（`QooKit`）の型コメントにある。**触る前にそこを読むこと。**
//
import Foundation
import GRDB
import QooKit

public struct SQLiteNotificationHistoryStore: NotificationHistoryStore, Sendable {
    let database: QooDatabase

    public init(database: QooDatabase) {
        self.database = database
    }

    // MARK: - 書き込み

    @discardableResult
    public func append(_ item: NotificationItem) async throws -> NotificationID {
        // **導線として意味を持つのは `.openWindow` だけ** [NT-05]。「再試行」は
        // 当時の文脈（どのファイルを、どの設定で）を失っているので写さない。
        let links = item.actions.compactMap { action -> NotificationLink? in
            guard case .openWindow = action.kind else { return nil }
            return NotificationLink(actionID: action.id, title: action.title)
        }
        let payload = NotificationPayload(target: item.target,
                                          technicalDetail: item.technicalDetail,
                                          links: links)
        let json = try Self.encodePayload(payload)
        return try await database.writer.write { db in
            var record = NotificationRecord(
                id: nil,
                date: item.date.timeIntervalSince1970,
                category: Self.categoryName(item.category),
                severity: item.severity.rawValue,
                targetJSON: json,
                title: item.title,
                body: item.body,
                // **記録した時点では常に未読。** 強度で未読に数えるかどうかを
                // 決めるのは読み出し側 [NT-02]——ここで既読にしてしまうと
                // 「すべて既読にする」と区別が付かなくなり、後から未読の
                // 定義を変えられなくなる。
                isRead: false,
                operationLogID: nil)
            try record.insert(db)
            return NotificationID(rawValue: record.id ?? 0)
        }
    }

    public func markRead(_ ids: [NotificationID]) async throws {
        guard !ids.isEmpty else { return }
        try await database.writer.write { db in
            // **900 件ずつ区切る。** この環境の SQLite はホスト変数の上限が
            // 高いので外しても結果は正しく、壊れるのは上限の低いビルドと速度
            // だけ（`setRating`/`matchingRelativePaths` とまったく同じ事情）。
            // 通ることを理由に外さないこと。
            for chunk in stride(from: 0, to: ids.count, by: 900).map({
                Array(ids[$0..<min($0 + 900, ids.count)])
            }) {
                let placeholders = chunk.map { _ in "?" }.joined(separator: ", ")
                try db.execute(
                    sql: "UPDATE notificationRecord SET isRead = 1 WHERE id IN (\(placeholders))",
                    arguments: StatementArguments(chunk.map(\.rawValue)))
            }
        }
    }

    public func markAllRead() async throws {
        try await database.writer.write { db in
            try db.execute(sql: "UPDATE notificationRecord SET isRead = 1 WHERE isRead = 0")
        }
    }

    public func delete(_ ids: [NotificationID]) async throws {
        guard !ids.isEmpty else { return }
        try await database.writer.write { db in
            for chunk in stride(from: 0, to: ids.count, by: 900).map({
                Array(ids[$0..<min($0 + 900, ids.count)])
            }) {
                let placeholders = chunk.map { _ in "?" }.joined(separator: ", ")
                try db.execute(
                    sql: "DELETE FROM notificationRecord WHERE id IN (\(placeholders))",
                    arguments: StatementArguments(chunk.map(\.rawValue)))
            }
        }
    }

    public func deleteAll() async throws {
        try await database.writer.write { db in
            try db.execute(sql: "DELETE FROM notificationRecord")
        }
    }

    /// [NT-07] 保持期間と件数の上限を保つ。
    ///
    /// **期限と件数の両方を見る。** 片方だけだと、1 日で 1 万件出た日は
    /// 期限では減らず、逆に静かな月は上限に触れないまま何年分も溜まる。
    /// どちらも `0` 以下なら無効（環境設定で「無制限」を選べる）。
    public func purgeExpired(retentionDays: Int, maxCount: Int) async throws {
        try await database.writer.write { db in
            if retentionDays > 0 {
                let cutoff = Date().addingTimeInterval(-Double(retentionDays) * 24 * 60 * 60)
                try db.execute(sql: "DELETE FROM notificationRecord WHERE date < ?",
                               arguments: [cutoff.timeIntervalSince1970])
            }
            if maxCount > 0 {
                // 新しいほうから `maxCount` 件を残す。**`OFFSET` の起点を
                // 日時の降順で決める**——`id` の降順でも今は同じ並びになるが、
                // 「新しいものを残す」という意図は日時が表している。
                try db.execute(sql: """
                    DELETE FROM notificationRecord WHERE id NOT IN (
                        SELECT id FROM notificationRecord ORDER BY date DESC, id DESC LIMIT ?
                    )
                    """, arguments: [maxCount])
            }
        }
    }

    // MARK: - 読み出し

    public func unreadCount() async throws -> Int {
        try await database.writer.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM notificationRecord WHERE isRead = 0 AND severity >= ?
                """, arguments: [NotificationSeverity.transient.rawValue]) ?? 0
        }
    }

    /// [NW-05][NW-01] 絞り込み。
    ///
    /// **区分と期間だけを SQL で絞り、対象ライブラリとキーワードは Swift で
    /// 判定する**［設計判断］。理由は 2 つ:
    ///
    /// - 対象ライブラリは `targetJSON` の中にあり、SQL で引くには JSON1 拡張
    ///   （`json_extract`）に頼ることになる。**列を増やして二重の真実を作るより、
    ///   行を読んでから絞るほうが安い**——`purgeExpired` が件数を
    ///   `maxCount`（既定 1,000 [NT-07]）に保つので、対象の母数に上限がある。
    /// - キーワードは `NameFilter` を通す。**全角で打っても半角に当たる**
    ///   [1-16 の実測] のはこのアプリ全体の約束で、SQL の `LIKE` では表せない。
    ///
    /// **それでも SQL 側に上限を置く**［レビューで発見］。掃除 [NT-07] は起動時に
    /// 1 度しか走らないので、**1 回のセッションの中では件数が伸び続ける**
    /// ——上の「母数に上限がある」は、掃除の直後にしか成り立っていなかった。
    /// 上限は既定の保持件数の 2 倍（`AppLimits.Notifications.queryLimit`）なので、
    /// 既定の設定では 1 件も切り落とされない。
    ///
    /// **既知の限界**: 件数の上限を「無制限」にした状態で、古いほうにしか
    /// 該当が無いライブラリ／キーワードで絞ると、Swift 側の判定まで届かず
    /// 0 件に見えることがある。SQL で絞れる区分・期間を併用すれば届く。
    public func query(_ filter: NotificationHistoryFilter) async throws -> [StoredNotification] {
        var sql = "SELECT * FROM notificationRecord"
        var conditions: [String] = []
        var arguments: [DatabaseValueConvertible] = []
        if let category = filter.category {
            conditions.append("category = ?")
            arguments.append(Self.categoryName(category))
        }
        if let period = filter.period {
            conditions.append("date >= ? AND date < ?")
            arguments.append(period.start.timeIntervalSince1970)
            arguments.append(period.end.timeIntervalSince1970)
        }
        if !conditions.isEmpty {
            sql += " WHERE " + conditions.joined(separator: " AND ")
        }
        sql += " ORDER BY date DESC, id DESC LIMIT \(AppLimits.Notifications.queryLimit)"

        // 閉包へ渡す前に不変にしておく（`var` のまま捕まえると Swift 6 の
        // 並行性検査に止められる）。
        let statement = sql
        let bindings = StatementArguments(arguments) ?? StatementArguments()
        let records = try await database.writer.read { db in
            try NotificationRecord.fetchAll(db, sql: statement, arguments: bindings)
        }
        return records.compactMap(Self.stored(from:)).filter { row in
            Self.matches(row, libraryUUID: filter.libraryUUID, keyword: filter.keyword)
        }
    }

    /// 対象ライブラリとキーワードの判定 [NW-05]。**純粋関数として切り出して
    /// ある**——SQL を経由せずに固定できるようにするため。
    static func matches(_ row: StoredNotification, libraryUUID: UUID?, keyword: String?) -> Bool {
        if let libraryUUID, row.target?.libraryUUID != libraryUUID { return false }
        guard let keyword, !keyword.trimmingCharacters(in: .whitespaces).isEmpty else { return true }
        // **対象名も検索対象に含める**——「あのライブラリで何が起きたか」を
        // 探すのに、区分の絞り込みだけでは足りない。
        let haystack = [row.title, row.body, row.target?.displayName ?? "",
                        row.technicalDetail ?? ""].joined(separator: "\n")
        return NameFilter.matches(name: haystack, query: keyword)
    }

    // MARK: - 変換

    static func stored(from record: NotificationRecord) -> StoredNotification? {
        guard let id = record.id else { return nil }
        let payload = decodePayload(record.targetJSON)
        return StoredNotification(
            id: NotificationID(rawValue: id),
            date: Date(timeIntervalSince1970: record.date),
            category: category(named: record.category),
            // 未知の強度は **SQL の判定と食い違わない側へ寄せる**［レビューで発見］。
            // `unreadCount()` は生の数値を `severity >= 4` で数えるので、Swift 側で
            // 一律に倒すと**バッジは立っているのに一覧では太字にならない**という、
            // 原因の分かりにくい食い違いになる（最初は「弱い側へ倒す」と書いて
            // `.logOnly`(5) にしていたが、それは `>= 4` を満たすので
            // コメントの主張と逆だった）。
            severity: NotificationSeverity(rawValue: record.severity)
                ?? (record.severity >= NotificationSeverity.transient.rawValue
                    ? .transient : .inline),
            target: payload.target,
            title: record.title,
            body: record.body,
            technicalDetail: payload.technicalDetail,
            links: payload.links,
            isRead: record.isRead)
    }

    static func encodePayload(_ payload: NotificationPayload) throws -> String? {
        guard payload.target != nil || payload.technicalDetail != nil
            || !payload.links.isEmpty else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(payload), as: UTF8.self)
    }

    /// **壊れた JSON でも行そのものは捨てない。** 題と本文は列にあるので、
    /// 対象と導線を失っても「いつ何が起きたか」は読める——履歴が丸ごと
    /// 消えるより、一部が欠けるほうがはるかにましである。
    static func decodePayload(_ json: String?) -> NotificationPayload {
        guard let json, let data = json.data(using: .utf8) else { return NotificationPayload() }
        return (try? JSONDecoder().decode(NotificationPayload.self, from: data))
            ?? NotificationPayload()
    }

    /// **列に入れる文字列はここ 1 箇所で決める。** `rawValue` を持たない
    /// enum なので、書き手と読み手で綴りが食い違う余地を消しておく。
    static func categoryName(_ category: NotificationItem.Category) -> String {
        switch category {
        case .error: return "error"
        case .warning: return "warning"
        case .info: return "info"
        }
    }

    static func category(named name: String) -> NotificationItem.Category {
        switch name {
        case "error": return .error
        case "warning": return .warning
        default: return .info
        }
    }
}
