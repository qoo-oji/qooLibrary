import Darwin
import Foundation
import QooKit
import os

/// ログファイルへの実際の書き込みとローテーション [LG2-02][LG2-04][CB-20]。
///
/// `actor` にして書き込みを直列化する [CB-21]。呼び出すのは
/// `DiagnosticLog` の消費タスク 1 本だけなので競合はしないが、`actor` に
/// しておくことで「ファイル記述子と現在サイズという可変状態が
/// 1 スレッドからしか触られない」ことが型で保証される。
///
/// **`FileManager` の変更系 API を使うため `QooInfrastructure/FileOps/` 配下に
/// 置いている** [B-10]。ログはユーザーに見えないアプリ内部データで、期待変更
/// 台帳・Undo・操作履歴の対象外のため `FileOperationService` を経由しない
/// （`SecureExtractor`/`CoverImageCache`/`RegisteredFolderStore` と同じ設計判断・
/// 同じ理由）。**逆に `FileOperationService` を経由してしまうと、その中の
/// ログ出力がこのライターを呼び、それがまた `FileOperationService` を呼ぶ、
/// という再帰になる**点でも、経由しないことが必須になる。
///
/// **書き込みは `FileHandle` ではなく生のファイル記述子（`open`/`write`）で
/// 行う** [1-15 の実装中に踏んだ不具合への対処]。当初は
/// `FileHandle.write(contentsOf:)` を使っていたが、テストスイート全体を
/// 走らせると `EXC_BAD_ACCESS`（メインキューが Swift Concurrency のジョブを
/// 実行中にクラッシュ）が再現した。切り分けの結果、この 1 行だけを
/// 「同じ所要時間の `usleep`」「記述子を開くところまで」「アクター境界を
/// 越えるだけ」のいずれに置き換えてもクラッシュせず、
/// `FileHandle.write(contentsOf:)` を呼んだときだけ落ちることを確認した
/// （タイミングの問題ではない）。生の `write(2)` に置き換えて解消。
/// `O_APPEND` により追記が原子的になり、`lseek` も不要になるという副次的な
/// 利点もある。
actor LogFileWriter {
    private let directory: URL
    private let maxBytes: Int64
    private let generations: Int

    /// 現行ログファイル（`qoo-0.log`）の書き込み用記述子。`-1` は未オープン。
    private var descriptor: Int32 = -1
    /// 現在のログファイルのバイト数。書き込みのたびに `stat` を呼ぶのを避け、
    /// 加算で追跡する（開いた時点の実サイズで初期化する）。
    private var currentBytes: Int64 = 0
    /// 連続して書き込みに失敗した回数。ディスクフル・権限喪失などで毎行
    /// 失敗し続けると `OSLog` を埋め尽くすため、一定回数で沈黙する。
    private var consecutiveFailures = 0
    private static let failureReportLimit = 3

    init(
        directory: URL,
        maxBytes: Int64 = AppLimits.Logging.defaultMaxFileBytes,
        generations: Int = AppLimits.Logging.defaultGenerations
    ) {
        self.directory = directory
        self.maxBytes = maxBytes
        self.generations = max(1, generations)
    }

    /// 世代 `index` のログファイル URL（0 が現行）[CB-20、01章 §1.6]。
    nonisolated func fileURL(generation index: Int) -> URL {
        directory.appendingPathComponent("qoo-\(index).log")
    }

    /// 実在するログファイルを新しい順（`qoo-0.log` が先頭）に返す。
    func existingFiles() -> [URL] {
        (0..<generations)
            .map { fileURL(generation: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// 1 行を書き出す。改行はこのメソッドが付ける。
    func append(_ line: String) {
        var data = Data(line.utf8)
        data.append(0x0A) // \n
        appendBytes(data)
    }

    /// 上限を超えていればローテーションする [LG2-04]。
    ///
    /// 通常は `appendBytes(_:)` が書き込みの直前に自動判定するため、明示的に
    /// 呼ぶ必要は無い（`DiagnosticLogging.rotateIfNeeded()` からの手動要求用）。
    func rotateIfNeeded() {
        guard currentBytes > maxBytes else { return }
        rotate()
    }

    func close() {
        if descriptor >= 0 {
            Darwin.close(descriptor)
            descriptor = -1
        }
    }

    // MARK: - 内部

    /// **ローテーションは書き込みの「前」に判定する。**
    ///
    /// 書き込んだ後に判定すると、上限を超えた瞬間に現行ファイル
    /// （`qoo-0.log`）を退避したまま次の書き込みまで存在しない状態になり、
    /// 「最新のログがどこにあるか分からない」「書き出し [LG2-05] に最新の
    /// 世代が含まれない」ことになる。前に判定すれば、1 レコードが世代を
    /// またいで分断されることも無い。
    private func appendBytes(_ data: Data) {
        guard var fd = openDescriptorIfNeeded() else { return }

        // `currentBytes > 0` の条件は、1 レコードが単独で上限を超える場合に
        // 空のファイルを延々とローテーションし続けないための歯止め
        // （その場合は上限を超えたファイルが 1 本できるだけで済む）。
        if currentBytes > 0, currentBytes + Int64(data.count) > maxBytes {
            rotate()
            guard let reopened = openDescriptorIfNeeded() else { return }
            fd = reopened
        }

        if writeAll(fd, data) {
            currentBytes += Int64(data.count)
            consecutiveFailures = 0
        } else {
            reportFailure("ログの書き込みに失敗", errno)
            // 記述子が壊れている可能性があるため一度閉じ、次回開き直す。
            close()
        }
    }

    /// 部分書き込みと `EINTR` を扱いながら全バイトを書き切る。
    private func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { buffer -> Bool in
            guard let base = buffer.baseAddress else { return true }
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(fd, base.advanced(by: offset), buffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue } // シグナルによる中断は再試行
                    return false
                }
                offset += written
            }
            return true
        }
    }

    private func openDescriptorIfNeeded() -> Int32? {
        if descriptor >= 0 { return descriptor }

        let url = fileURL(generation: 0)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            reportFailure("ログディレクトリを作成できません", errno, error)
            return nil
        }

        // `O_APPEND` により追記が原子的になる（同じファイルを別の経路から
        // 開いても行が混ざらない）。
        let fd = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        }
        guard fd >= 0 else {
            reportFailure("ログファイルを開けません", errno)
            return nil
        }

        descriptor = fd
        currentBytes = Int64(lseek(fd, 0, SEEK_END))
        consecutiveFailures = 0
        return fd
    }

    /// `qoo-{n-1}.log` を捨て、`qoo-i.log` → `qoo-{i+1}.log` へずらし、
    /// 新しい `qoo-0.log` を開き直す [LG2-04][CB-20]。
    private func rotate() {
        close()
        let fm = FileManager.default
        do {
            let oldest = fileURL(generation: generations - 1)
            if fm.fileExists(atPath: oldest.path) {
                try fm.removeItem(at: oldest)
            }
            // 古い側から順にずらす（新しい側から動かすと上書きしてしまう）。
            for index in stride(from: generations - 2, through: 0, by: -1) {
                let source = fileURL(generation: index)
                guard fm.fileExists(atPath: source.path) else { continue }
                let target = fileURL(generation: index + 1)
                if fm.fileExists(atPath: target.path) {
                    try fm.removeItem(at: target)
                }
                try fm.moveItem(at: source, to: target)
            }
            currentBytes = 0
        } catch {
            reportFailure("ログのローテーションに失敗", errno, error)
            // ずらしに失敗した場合、現行ファイルがそのまま残って上限を
            // 超え続ける可能性がある。次の書き込みで再度ローテーションを
            // 試みるが、`currentBytes` は開き直しの際に実サイズで
            // 再初期化されるため無限には膨らまない。
        }
    }

    private func reportFailure(_ what: String, _ code: Int32, _ error: (any Error)? = nil) {
        consecutiveFailures += 1
        guard consecutiveFailures <= Self.failureReportLimit else { return }
        // ここで `Log` を使うと再帰するため、`OSLog` へ直接出す。
        let logger = Logger(subsystem: LogChannel.subsystem, category: LogCategory.app.rawValue)
        let detail = error?.localizedDescription ?? String(cString: strerror(code))
        logger.error("\(what, privacy: .public): \(detail, privacy: .public)")
        if consecutiveFailures == Self.failureReportLimit {
            logger.error("ログの失敗報告はここまでにします（同じ失敗が続いています）")
        }
    }
}
