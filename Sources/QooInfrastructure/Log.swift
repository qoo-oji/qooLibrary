import Foundation
import QooKit

/// ログの入口を集約する [2.6 節、MT-05]。`Log.fileOps.info("…")` の形で使う。
///
/// 1-15 以前は `OSLog` の `Logger` を直接公開していたが、`OSLog` は
/// 「ユーザーが不具合を報告する際にログを添付する」用途に向かない
/// （`Console.app` から手作業で絞り込んで書き出す必要があり、非 Apple 署名
/// ビルドでは内容が伏字化されることもある）。そのため各チャンネルは
/// **`OSLog` とファイルログの両方**へ同時に流すようになっている
/// [LG2-01][CB-21]。呼び出し側の書き方は変わらない。
///
/// **計装の作法**:
/// - `error` … ユーザーに提示する失敗、データを失いかねない事象
/// - `warning` … 回復した失敗、想定外だが処理は続行できた事象
/// - `info` … 1 回のユーザー操作＝1 行を目安にした操作単位の記録
/// - `debug` … 項目単位の詳細。既定のレベル（`info`）では出力されない
/// - **パスは必ず `Log.path(url)` で囲む**。素の `url.path` を書くと、
///   書き出し時の匿名化 [LG2-06] が範囲を推測するしかなくなり、括弧や空白を
///   含むファイル名で取りこぼす（`PathAnonymizer` のコメント参照）。
/// - `lastPathComponent`（ファイル名だけ）は書かない。絶対パスの方が
///   匿名化できるうえ、「どこのファイルか」が分かって診断にも役立つ。
/// - 絶対パスが手元に無いユーザー由来の名前は `Log.redactable(_:)` で包む。
public enum Log {
    public static let app = LogChannel(.app, sink: DiagnosticLog.shared)
    public static let fileOps = LogChannel(.fileOps, sink: DiagnosticLog.shared)
    public static let scan = LogChannel(.scan, sink: DiagnosticLog.shared)
    public static let watch = LogChannel(.watch, sink: DiagnosticLog.shared)
    public static let parser = LogChannel(.parser, sink: DiagnosticLog.shared)
    public static let archive = LogChannel(.archive, sink: DiagnosticLog.shared)
    public static let db = LogChannel(.db, sink: DiagnosticLog.shared)
    public static let ui = LogChannel(.ui, sink: DiagnosticLog.shared)
    public static let command = LogChannel(.command, sink: DiagnosticLog.shared)
    public static let sandbox = LogChannel(.sandbox, sink: DiagnosticLog.shared)
    public static let image = LogChannel(.image, sink: DiagnosticLog.shared)

    /// ログにパスを書くときは**必ずこれで囲む** [LG2-06]。
    ///
    /// macOS のファイル名には `/` と NUL 以外のあらゆる文字が入るため、
    /// 「この文字が来たらパスの終わり」という区切りは存在しない。書き出し時の
    /// 匿名化が範囲を推測せずに済むよう、**書く側が範囲を明示する**
    /// （詳細は `PathAnonymizer` のコメント参照）。印そのものがファイル名に
    /// 含まれていた場合は二重化してエスケープするので曖昧さは残らない。
    ///
    /// 書き出したバンドルからは印が取り除かれるため、読む人には見えない。
    public static func path(_ url: URL) -> String {
        path(url.path)
    }

    public static func path(_ path: String) -> String {
        let escaped = path
            .replacingOccurrences(of: String(PathAnonymizer.pathOpen), with: String(repeating: PathAnonymizer.pathOpen, count: 2))
            .replacingOccurrences(of: String(PathAnonymizer.pathClose), with: String(repeating: PathAnonymizer.pathClose, count: 2))
        return "\(PathAnonymizer.pathOpen)\(escaped)\(PathAnonymizer.pathClose)"
    }

    /// 絶対パスではないユーザー由来の名前（解決できない登録フォルダの表示名、
    /// アーカイブ内のエントリ名など）に、匿名化の対象である印を付ける
    /// [LG2-06]。
    ///
    /// 匿名化しない場合は `作品A` とそのまま読め、匿名化すると `1e6b04dd`
    /// になる。**絶対パスが手元にあるなら `path(_:)` を使うこと** —
    /// 階層関係が残るぶんパスの方が診断に役立つ。
    public static func redactable(_ name: String) -> String {
        let escaped = name
            .replacingOccurrences(of: String(PathAnonymizer.redactionOpen), with: String(repeating: PathAnonymizer.redactionOpen, count: 2))
            .replacingOccurrences(of: String(PathAnonymizer.redactionClose), with: String(repeating: PathAnonymizer.redactionClose, count: 2))
        return "\(PathAnonymizer.redactionOpen)\(escaped)\(PathAnonymizer.redactionClose)"
    }

    /// 起動時に 1 度だけ呼ぶ。保存済みのログレベルを適用し [LG2-03]、
    /// セッションの区切りと環境情報を記録する。
    ///
    /// **書き出したログの先頭を見ればどのビルド・どの macOS で起きた事象か
    /// 分かる**ようにするためのもので、`diagnostics.json` [CB-22] と情報が
    /// 一部重複するのは意図的（ログ本文だけを抜き出して共有された場合にも
    /// 最低限の環境が分かるように）。
    public static func startSession() {
        DiagnosticLog.shared.currentLevel = DiagnosticLogPreferences.storedLevel()
        let report = DiagnosticsReport.sessionBanner()
        app.info("=== セッション開始 === \(report)")
    }

    /// 終了時に呼ぶ。書き出し待ちのレコードを確実にディスクへ落とす。
    public static func endSession() async {
        app.info("=== セッション終了 ===")
        await DiagnosticLog.shared.flush()
    }
}
