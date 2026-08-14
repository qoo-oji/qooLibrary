import Foundation
import QooKit
import os

/// ログのカテゴリ [2章 §2.6、MT-05]。`OSLog` の `category` と、ファイルログの
/// 行頭タグの両方に同じ値を使う。
///
/// 仕様書 §2.6 は 8 種（FileOps/Scan/Watch/Parser/Archive/Persistence/UI/
/// Command）を定義しているが、フェーズ1の実装で実際に必要になった
/// **`App`（起動・終了などのライフサイクル）**・**`Sandbox`（Security-Scoped
/// Bookmark の解決、ボリューム許可）**・**`Image`（サムネイル生成）** の 3 種を
/// 追加した [設計判断、1-15。§2.6 も更新済み]。いずれも既存カテゴリへ寄せると
/// 意味が濁る（例: ブックマーク解決の失敗を `FileOps` に混ぜると、実際の
/// ファイル変更操作のログを追うときに紛れる）ため独立させている。
public enum LogCategory: String, Sendable, CaseIterable {
    case app = "App"
    case fileOps = "FileOps"
    case scan = "Scan"
    case watch = "Watch"
    case parser = "Parser"
    case archive = "Archive"
    case db = "Persistence"
    case ui = "UI"
    case command = "Command"
    case sandbox = "Sandbox"
    case image = "Image"
}

/// ログ 1 行分のレコード。**整形は消費側（バックグラウンドタスク）で行う**
/// ため、呼び出し元のスレッドでは `Date()` の取得と値のコピーしか起きない
/// [CB-21: UI スレッドをブロックしない]。
public struct LogRecord: Sendable {
    public let date: Date
    public let level: LogLevel
    public let category: LogCategory
    public let message: String
    /// `#fileID`（"モジュール名/ファイル名.swift"）。`#file`（絶対パス）だと
    /// ビルドマシンのパスがログに残るため使わない。
    public let fileID: String
    public let line: UInt

    public init(date: Date, level: LogLevel, category: LogCategory, message: String, fileID: String, line: UInt) {
        self.date = date
        self.level = level
        self.category = category
        self.message = message
        self.fileID = fileID
        self.line = line
    }
}

/// 診断ログ [LG2-01〜LG2-08][2章 §2.6]。`OSLog` への出力に加えてファイルへも
/// 書き出す。ファイル出力があることで、ユーザーが不具合を報告する際に
/// 「再現手順の説明」ではなく「実際に何が起きたか」を添付できる [LG2-01]。
///
/// **仕様書 §2.6 の宣言からの差分**（いずれも 1-15 実装時の設計判断、
/// 仕様書側も更新済み）:
/// - `category` を `String` ではなく `LogCategory`（型付き）にした。
///   カテゴリ名の打ち間違いを防ぎ、`OSLog` の `Logger` への対応付けを
///   1 箇所（`LogChannel`）に閉じ込められるため。
/// - `exportBundle` に `to destination:` を足した。サンドボックス下では
///   書き出し先をユーザーが `NSSavePanel` で選ぶ必要があり、アプリが
///   勝手に決めた場所へ書けないため。
/// - `flush()` を足した。書き出し（`exportBundle`）とアプリ終了時に、
///   まだディスクへ届いていないレコードを確実に反映させるため。
public protocol DiagnosticLogging: Sendable {
    /// ログを 1 行記録する。**呼び出し元をブロックしない**。
    ///
    /// `message` が `@autoclosure` なのは、しきい値未満のレベル（例: 既定の
    /// `info` 設定下での `debug`）では文字列の組み立て自体を行わせないため。
    /// 呼び出し側は `Log.fileOps.debug("…")` 経由で使うのが通常で、この
    /// メソッドを直接呼ぶことは少ない。
    func log(
        _ level: LogLevel,
        category: LogCategory,
        _ message: @autoclosure () -> String,
        fileID: String,
        line: UInt
    )

    /// 現在のしきい値 [LG2-03]。これ**以下**（＝これ以上に重大）のレコードだけを出力する。
    /// 実装は参照型（`final class` + ロック）を前提にしており、
    /// `any DiagnosticLogging` 越しの読み取りはロックフリーで軽い。
    var currentLevel: LogLevel { get set }

    /// 書き出し待ちのレコードがすべてディスクへ届くまで待つ。
    func flush() async

    /// 上限を超えていればローテーションする [LG2-04]。通常は書き込みのたびに
    /// 自動判定されるため、明示的に呼ぶ必要はない。
    func rotateIfNeeded() async

    /// 現在保持しているログファイルを新しい順に返す（`qoo-0.log` が最新）。
    func logFileURLs() async -> [URL]

    /// 診断情報バンドル（zip）を書き出す [LG2-05][LG2-06][CB-22]。
    /// - Parameters:
    ///   - anonymizePaths: `true` ならログ・診断情報中のパスを匿名化する [LG2-06]。
    ///   - destination: 書き出し先の zip ファイル URL（`NSSavePanel` で選ばせる）。
    ///   - report: 同梱する診断情報。`nil` なら実行時に収集する（テストでは注入する）。
    /// - Returns: 実際に作られた zip の URL。
    @discardableResult
    func exportBundle(anonymizePaths: Bool, to destination: URL, report: DiagnosticsReport?) async throws -> URL
}

public extension DiagnosticLogging {
    @discardableResult
    func exportBundle(anonymizePaths: Bool, to destination: URL) async throws -> URL {
        try await exportBundle(anonymizePaths: anonymizePaths, to: destination, report: nil)
    }
}

/// 診断ログ関連の `UserDefaults` キー。
///
/// 環境設定「詳細」タブ（`qooLibraryApp`）と、起動時に設定を読み込む側
/// （`QooLibraryApp.init()`）の両方が同じキーを参照する必要があるため、
/// 文字列リテラルの二重管理を避けてここに集約する
/// （`FolderOperations.PreferenceKeys` と同じ方針）。
public enum DiagnosticLogPreferences {
    /// 選択中のログレベル（`LogLevel.identifier` を保存）[LG2-03]。
    public static let logLevelKey = "qoo.preferences.logLevel"
    /// 書き出し時にパスを匿名化するか [LG2-06]。**既定は匿名化しない**。
    public static let anonymizePathsKey = "qoo.preferences.diagnosticsAnonymizePaths"
    /// パス匿名化用のソルト（インストールごとに一度だけ生成する）。
    /// `PathAnonymizer` のコメント参照。書き出したバンドルには含めない。
    public static let anonymizationSaltKey = "qoo.diagnostics.anonymizationSalt"

    /// 保存済みのログレベルを読む。未設定・不正な値なら既定値 [LG2-03]。
    public static func storedLevel(in defaults: UserDefaults = .standard) -> LogLevel {
        guard let raw = defaults.string(forKey: logLevelKey), let level = LogLevel(identifier: raw) else {
            return AppLimits.Logging.defaultLevel
        }
        return level
    }

    /// 匿名化用ソルトを読む。無ければ生成して保存する。
    ///
    /// ソルトはこの Mac のこのインストールにだけ存在し、書き出したバンドルには
    /// 一切含めない。これにより「同じユーザーが別々のタイミングで書き出した
    /// バンドル同士では同じパスが同じトークンになる（追跡可能性の維持
    /// [CB-23]）」を保ちつつ、`/Users/<よくある名前>/Documents` のような
    /// 推測しやすいパスをハッシュから逆引きされることを防げる。
    public static func anonymizationSalt(in defaults: UserDefaults = .standard) -> String {
        if let existing = defaults.string(forKey: anonymizationSaltKey), !existing.isEmpty {
            return existing
        }
        let generated = UUID().uuidString
        defaults.set(generated, forKey: anonymizationSaltKey)
        return generated
    }
}

/// カテゴリ 1 つ分の入口 [MT-05]。`Log.fileOps.info("…")` の形で使う。
///
/// `OSLog` の `Logger` とファイルログの両方へ同時に流す [CB-21]。
/// **`OSLog` へは `privacy: .public` で渡している** [設計判断]: 既定の
/// `.private` だと、Apple 署名でないビルド（開発中のローカルビルド）では
/// `Console.app` 上で内容が `<private>` に伏字化されて読めない
/// （1-9 の `⌘↑` バグ調査で実際に踏んだ）。パスの秘匿は、書き出し時の
/// 匿名化 [LG2-06] という別の仕組みで担保する。
public struct LogChannel: Sendable {
    public let category: LogCategory
    private let logger: Logger
    private let sink: any DiagnosticLogging

    public init(_ category: LogCategory, sink: any DiagnosticLogging) {
        self.category = category
        self.logger = Logger(subsystem: LogChannel.subsystem, category: category.rawValue)
        self.sink = sink
    }

    static let subsystem = "com.qoolibrary.app"

    public func error(_ message: @autoclosure () -> String, fileID: String = #fileID, line: UInt = #line) {
        emit(.error, message(), fileID: fileID, line: line)
    }

    public func warning(_ message: @autoclosure () -> String, fileID: String = #fileID, line: UInt = #line) {
        emit(.warning, message(), fileID: fileID, line: line)
    }

    public func info(_ message: @autoclosure () -> String, fileID: String = #fileID, line: UInt = #line) {
        emit(.info, message(), fileID: fileID, line: line)
    }

    public func debug(_ message: @autoclosure () -> String, fileID: String = #fileID, line: UInt = #line) {
        emit(.debug, message(), fileID: fileID, line: line)
    }

    /// しきい値の判定を 1 度だけ行い、`OSLog` とファイルログの双方へ同じ
    /// 内容を流す。
    ///
    /// `emit` の `message` も `@autoclosure` にしてあるため、`error(…)` 等が
    /// 受け取った式は**ここで `guard` を通過するまで評価されない**
    /// （`message()` という呼び出しの式そのものが、もう一段クロージャに
    /// 包まれて渡る）。しきい値未満のレベルでは文字列の組み立てコストが
    /// 一切かからない。
    private func emit(_ level: LogLevel, _ message: @autoclosure () -> String, fileID: String, line: UInt) {
        guard level <= sink.currentLevel else { return }
        let text = message()
        switch level {
        case .error: logger.error("\(text, privacy: .public)")
        case .warning: logger.warning("\(text, privacy: .public)")
        case .info: logger.info("\(text, privacy: .public)")
        case .debug: logger.debug("\(text, privacy: .public)")
        }
        sink.log(level, category: category, text, fileID: fileID, line: line)
    }
}
