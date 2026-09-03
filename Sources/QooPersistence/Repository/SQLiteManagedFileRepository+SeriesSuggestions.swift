//
//  シリーズの提案の候補と、無視印 [SS-01〜SS-08、19章 §19.5]（ステージ 10）。
//
//  本体から切り出してあるのは `+Orphans` / `+Unresolved` と同じ理由
//  （あちらは走査のホットパスと一覧の問い合わせで既に大きい）。
//
//  **検出そのものはここでは行わない。** 判定は `QooKit` の純粋関数
//  （`SeriesSuggestionDetector`）で、ここが答えるのは「どの本が候補か」だけ
//  ——合成名のゴールデンで固定できる形にしておくため。
//
import Foundation
import GRDB
import QooKit

extension SQLiteManagedFileRepository {

    public func seriesSuggestionCandidates(libraryID: LibraryID,
                                           circleFieldID: FieldID?) async throws
        -> [SeriesSuggestionCandidate]
    {
        try await database.writer.read { db in
            // **保護の判定は Swift 側で行う。** `protectedScopes` は JSON 配列の
            // TEXT 列で、SQL の `LIKE` で「basic を含むか」を見るのは綴りの
            // 揺れに弱い（`ProtectionScopeCoding` が唯一の読み手であるべき）。
            // どのみち全行を読むので、絞りをここへ持ってきても往復は増えない。
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, relativePath, title, authorName, protectedScopes,
                       seriesSuggestionIgnoredTitle
                FROM managedFile
                WHERE libraryId = ?
                  AND state = ?
                  AND isArchived = 0
                  AND (seriesName IS NULL OR seriesName = '')
                  AND title IS NOT NULL AND title <> ''
                """, arguments: [libraryID.rawValue, FileState.active.rawValue])
            guard !rows.isEmpty else { return [] }

            var ids: [Int64] = []
            var base: [(id: Int64, title: String, folder: String,
                        author: String?, ignoredTitle: String?)] = []
            base.reserveCapacity(rows.count)
            for row in rows {
                let scopes = ProtectionScopeCoding.decode(row["protectedScopes"])
                guard !scopes.contains(.basic) else { continue }   // [SS-08]
                let id: Int64 = row["id"]
                let title: String = row["title"]
                ids.append(id)
                base.append((id: id, title: title,
                             folder: Self.parentPath(of: row["relativePath"]),
                             author: row["authorName"],
                             ignoredTitle: row["seriesSuggestionIgnoredTitle"]))
            }
            guard !base.isEmpty else { return [] }

            // サークルは専用列を持たずラベルとして入る [SS-02][RWI-02]。
            var circles: [Int64: [String]] = [:]
            if let circleFieldID {
                for start in stride(from: 0, to: ids.count, by: Self.maxBoundParameters) {
                    let chunk = Array(ids[start..<min(start + Self.maxBoundParameters,
                                                      ids.count)])
                    var arguments: [DatabaseValueConvertible] = [circleFieldID.rawValue]
                    arguments.append(contentsOf: chunk)
                    for row in try Row.fetchAll(db, sql: """
                        SELECT fileLabel.managedFileId AS fid, label.normalizedName AS name
                        FROM fileLabel JOIN label ON label.id = fileLabel.labelId
                        WHERE label.labelGroupId = ?
                          AND fileLabel.managedFileId IN (\(Self.placeholders(chunk.count)))
                        """, arguments: StatementArguments(arguments) ?? StatementArguments()) {
                        circles[row["fid"], default: []].append(row["name"])
                    }
                }
            }

            return base.map { item in
                // **鍵は正規化済みで渡す** ——`label.normalizedName` は既に
                // 正規化されているので、著者名だけ同じ関数を通して揃える。
                var keys: Set<String> = []
                if let author = item.author, !author.isEmpty {
                    keys.insert(TextNormalizer.normalize(author))
                }
                for name in circles[item.id] ?? [] where !name.isEmpty { keys.insert(name) }
                return SeriesSuggestionCandidate(
                    id: FileID(rawValue: item.id),
                    title: item.title,
                    folderPath: item.folder,
                    groupingKeys: keys,
                    // **印を立てた時点のタイトルと今のタイトルが一致するときだけ
                    // 無視**——名前が変われば判断の前提が消える [SS-05]。
                    isIgnored: item.ignoredTitle == item.title)
            }
        }
    }

    public func updateSeriesSuggestionIgnored(set marks: [FileID: String],
                                              clear ids: [FileID]) async throws {
        guard !marks.isEmpty || !ids.isEmpty else { return }
        try await database.writer.write { db in
            for (id, title) in marks.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
                try db.execute(sql: """
                    UPDATE managedFile SET seriesSuggestionIgnoredTitle = ? WHERE id = ?
                    """, arguments: [title, id.rawValue])
            }
            for start in stride(from: 0, to: ids.count, by: Self.maxBoundParameters) {
                let chunk = Array(ids[start..<min(start + Self.maxBoundParameters, ids.count)])
                try db.execute(sql: """
                    UPDATE managedFile SET seriesSuggestionIgnoredTitle = NULL
                    WHERE id IN (\(Self.placeholders(chunk.count)))
                    """, arguments: StatementArguments(chunk.map(\.rawValue))
                        ?? StatementArguments())
            }
        }
    }

    public func seriesSuggestionIgnoredTitles(ids: [FileID]) async throws -> [FileID: String] {
        guard !ids.isEmpty else { return [:] }
        return try await database.writer.read { db in
            var out: [FileID: String] = [:]
            for start in stride(from: 0, to: ids.count, by: Self.maxBoundParameters) {
                let chunk = Array(ids[start..<min(start + Self.maxBoundParameters, ids.count)])
                for row in try Row.fetchAll(db, sql: """
                    SELECT id, seriesSuggestionIgnoredTitle FROM managedFile
                    WHERE seriesSuggestionIgnoredTitle IS NOT NULL
                      AND id IN (\(Self.placeholders(chunk.count)))
                    """, arguments: StatementArguments(chunk.map(\.rawValue))
                        ?? StatementArguments()) {
                    out[FileID(rawValue: row["id"])] = row["seriesSuggestionIgnoredTitle"]
                }
            }
            return out
        }
    }

    /// 相対パスの親 [SS-02]。ライブラリ直下なら空文字。
    ///
    /// **`URL` を通さない**——相対パスは文字列として保存されており、`URL` へ
    /// 通すと打ち消し合う `..` や percent-encoding の解釈が入る。
    static func parentPath(of relativePath: String) -> String {
        guard let slash = relativePath.lastIndex(of: "/") else { return "" }
        return String(relativePath[relativePath.startIndex..<slash])
    }
}
