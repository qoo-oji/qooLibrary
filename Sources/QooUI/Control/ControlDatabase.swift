#if DEBUG
import Foundation
import QooApplication
import QooPersistence

/// アプリ自身のストアを**読み取り専用で**問い合わせる [MT-33]。
///
/// **これが要るのは、外から `sqlite3 -readonly` で読めないことがあるため**
/// ［実記録］。サンドボックスのコンテナは TCC の対象で、検証の途中で
/// 「DB を読めなかったので画面だけで判定した」回が実際にある。アプリは
/// 自分のストアを当然読めるので、口を通せばその壁が構造ごと消える。
///
/// **書き込みの口は作らない** [CT-14]。SQL の実行そのものは読み取り
/// トランザクションなので SQLite が書き込みを拒むが、それ以前に
/// **状態を変える検証は本物の操作（メニュー・ボタン・`library:*`）を通す**
/// ——口から直に書けるようにすると、「アプリを経ずに作った状態」で検証した
/// ことになってしまう。
@MainActor
enum ControlDatabase {
    static func run(_ command: String, _ args: [String: Any]) -> Data {
        switch command {
        case "db:query": return query(args)
        case "db:counts": return counts(args)
        default: return ControlResponse.failure("知らないコマンドです: \(command)")
        }
    }

    private static func query(_ args: [String: Any]) -> Data {
        guard let sql = args["sql"] as? String, !sql.isEmpty else {
            return ControlResponse.failure("sql が要ります")
        }
        let limit = args["limit"] as? Int ?? 200
        do {
            let rows = try LibraryServices.shared.debugQuery(sql: sql, limit: limit)
            return ControlResponse.success([
                "rows": rows.map(node(_:)),
                "count": rows.count,
            ])
        } catch {
            return ControlResponse.failure("問い合わせに失敗しました: \(error)")
        }
    }

    private static func counts(_ args: [String: Any]) -> Data {
        let includeEmpty = args["includeEmpty"] as? Bool ?? false
        do {
            let counts = try LibraryServices.shared.debugTableCounts(includeEmpty: includeEmpty)
            return ControlResponse.success([
                "counts": counts,
                "tables": counts.count,
                "total": counts.values.reduce(0, +),
            ])
        } catch {
            return ControlResponse.failure("件数を数えられませんでした: \(error)")
        }
    }

    /// **文字列は伏字を通す** [CT-06]——`managedFile.relativePath` も
    /// `label.name` も利用者のデータそのもので、ここを素通しにすると
    /// 口がそのまま漏洩経路になる。
    private static func node(_ row: [String: DebugSQLValue]) -> [String: Any] {
        var result: [String: Any] = [:]
        for (column, value) in row {
            switch value {
            case .text(let text): result[column] = ControlRedaction.apply(text)
            case .integer(let number): result[column] = number
            case .real(let number): result[column] = number
            case .blob(let bytes): result[column] = "⟨blob \(bytes) バイト⟩"
            }
        }
        return result
    }
}
#endif
