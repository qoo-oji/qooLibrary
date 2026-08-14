import Foundation
import QooKit

public enum DiagnosticExportError: Error, Sendable, Equatable {
    /// 書き出せるログが 1 本も無い（一度も記録されていない）。
    case noLogFiles
    case stagingFailed(String)
}

public extension DiagnosticLog {
    /// 診断情報バンドル（zip）を書き出す [LG2-05][LG2-06][CB-22][CB-24]。
    ///
    /// 中身:
    /// ```
    /// qooLibrary-diagnostics-<日時>/
    ///   diagnostics.json    ← 環境情報 [CB-22]
    ///   qoo-0.log … qoo-4.log
    /// ```
    ///
    /// **手順**は `ArchiveCompressor` と同じ「ステージングで組み立ててから、
    /// ユーザーに見える最終位置へは `FileOperationService` 経由で移す」
    /// [EX-04 相当]。zip 化そのものも `ArchiveCompressor` を再利用するため、
    /// 衝突処理・昇格の安全性（`.replace` の退避と復元）は既存の実装と
    /// 完全に同じものが効く。
    ///
    /// **ネットワーク送信は一切行わない** [LG2-08][SC-01][CB-24]。書き出した
    /// zip をユーザーが自分で共有する。
    @discardableResult
    func exportBundle(
        anonymizePaths: Bool,
        to destination: URL,
        report: DiagnosticsReport?
    ) async throws -> URL {
        // 書き出し待ちのレコードを先にディスクへ落とす。直前の操作こそが
        // 報告したい事象であることが多いため、ここを飛ばしてはならない。
        await flush()

        let logFiles = await logFileURLs()
        guard !logFiles.isEmpty else { throw DiagnosticExportError.noLogFiles }

        let resolvedReport: DiagnosticsReport
        if let report {
            resolvedReport = report
        } else {
            resolvedReport = await DiagnosticsReport.current(
                level: currentLevel,
                pathsAnonymized: anonymizePaths,
                logFiles: logFiles
            )
        }

        let anonymizer = anonymizePaths
            ? PathAnonymizer(salt: DiagnosticLogPreferences.anonymizationSalt())
            : nil

        let stagingRoot = SecureExtractor.defaultStagingRoot()
        let stagingDir = stagingRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let payloadName = Self.bundleName(at: resolvedReport.generatedAt)
        let payloadDir = stagingDir.appendingPathComponent(payloadName, isDirectory: true)
        defer {
            // 成功・失敗を問わず必ず片付ける [EX-24 と同じ方針]。
            try? FileManager.default.removeItem(at: stagingDir)
        }

        do {
            try FileManager.default.createDirectory(at: payloadDir, withIntermediateDirectories: true)
        } catch {
            throw DiagnosticExportError.stagingFailed(error.localizedDescription)
        }

        // diagnostics.json [CB-22]
        var reportData = try resolvedReport.jsonData()
        if let anonymizer, let text = String(data: reportData, encoding: .utf8) {
            reportData = Data(anonymizer.anonymize(text).utf8)
        }
        try reportData.write(to: payloadDir.appendingPathComponent("diagnostics.json"))

        // ログ本体。1 本ずつ処理してピークメモリを抑える（1 本 10MB × 5 世代）。
        //
        // **匿名化しない場合もそのままコピーはしない** — ディスク上のログには
        // パスの範囲を示す印（`Log.path(_:)` が付ける `⟪…⟫`）が入っており、
        // 読む人には不要なため取り除く。
        for source in logFiles {
            let target = payloadDir.appendingPathComponent(source.lastPathComponent)
            let raw = try Data(contentsOf: source)
            // 不正なバイト列で全体を失わないよう、UTF-8 として読めなければ
            // 諦めて素通しするのではなく、置換文字で読み直す。
            let text = String(data: raw, encoding: .utf8) ?? String(decoding: raw, as: UTF8.self)
            let processed = anonymizer.map { $0.anonymize(text) } ?? PathAnonymizer.strippingMarkers(text)
            try Data(processed.utf8).write(to: target)
        }

        // zip 化と最終位置への昇格 [AR-10 と同じ経路]。`NSSavePanel` が既に
        // 上書き確認を済ませているため `.replace`。
        return try await ArchiveCompressor.shared.compress(
            [payloadDir],
            destinationName: destination.deletingPathExtension().lastPathComponent,
            in: destination.deletingLastPathComponent(),
            options: CompressionOptions(format: .zip),
            conflictPolicy: .replace
        )
    }

    /// 既定のファイル名（`NSSavePanel` の初期値にも使う）。
    /// 例: `qooLibrary-diagnostics-20260814-123456`
    ///
    /// 表示言語の設定に関わらず同じ綴りになるよう、暦・ロケールを固定する
    /// （ファイル名なのでローカライズ対象ではない）。
    static func bundleName(at date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "qooLibrary-diagnostics-\(formatter.string(from: date))"
    }
}
