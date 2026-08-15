import Foundation
import QooKit
import os

/// `DiagnosticLogging` の既定実装 [LG2-01〜LG2-04][CB-21]。
///
/// **設計の要点**
///
/// 1. **呼び出し元をブロックしない** [CB-21]。`log(_:category:_:fileID:line:)` が
///    行うのは「しきい値判定 → `LogRecord` の生成 → `AsyncStream` への `yield`」
///    だけで、ファイル I/O は消費側のバックグラウンドタスクが行う。
/// 2. **順序が保証される**。`AsyncStream` は FIFO を保証するため、複数の
///    スレッド・アクターから同時に記録しても、ファイルには `yield` された順に
///    並ぶ。**1 レコードごとに `Task { await writer.append(…) }` を起こす方式は
///    採らなかった** — `Task` の実行順序は投入順と一致しないため、ログ行が
///    入れ替わって時系列を追えなくなる。
/// 3. **1 レコードずつ即座に書く**（まとめてから書く方式にしない）。
///    バッファリングすると、クラッシュ直前の——診断上もっとも重要な——数行が
///    失われる。1 行あたり `write(2)` 1 回はバックグラウンドスレッド上の
///    数マイクロ秒に過ぎず、診断ログの流量では問題にならない。
/// 4. **バッファ溢れは黙って捨てない**。ディスクが極端に遅い場合に備えて
///    待ち行列に上限を設ける [AppLimits.Logging.maxBufferedRecords] が、
///    溢れて捨てた件数は後続の行に警告として書き出す。
///
/// タイムスタンプは `log()` の呼び出し時点で取得し、整形は消費側で行う。
/// これにより、書き出しが遅れてもログ上の時刻は実際に事象が起きた時刻になる。
public final class DiagnosticLog: DiagnosticLogging {
    /// アプリ全体で単一のインスタンス（`FileOperationService.shared`/
    /// `CommandStack.shared` と同じ方針）。テストでは `init` で独立した
    /// ディレクトリを持つインスタンスを作れる。
    public static let shared = DiagnosticLog(level: DiagnosticLogPreferences.storedLevel())

    private struct State: Sendable {
        var level: LogLevel
        var flushWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
        /// バッファ溢れで捨てたレコード数（次に書けたときに注記して 0 に戻す）。
        var droppedRecords: Int = 0
    }

    private let state: OSAllocatedUnfairLock<State>
    private let continuation: AsyncStream<Event>.Continuation
    private let writer: LogFileWriter

    private enum Event: Sendable {
        case record(LogRecord)
        /// `flush()` の完了地点を表す番兵。ストリームが FIFO であることを
        /// 利用して「これより前のレコードはすべて書き終わった」を表現する。
        case flush(UUID)
    }

    /// アプリコンテナ配下の既定のログディレクトリ [LG2-02][CB-20]。
    /// `Application Support/qooLibrary/Logs/`。
    ///
    /// **テスト実行中は一時ディレクトリへ振り替える**。`Log.*` の呼び出しは
    /// `FileOperationService` など広範囲に埋め込まれているため、これが無いと
    /// `swift test` を回すたびに開発機の実際のログが**テストのノイズで
    /// 埋まり、ローテーションによって本物の履歴が押し流される**。テストが
    /// 意図的に検証したい場合は `init(directory:)` で明示的に渡す。
    public static func defaultLogDirectory() -> URL {
        let base: URL
        if RuntimeEnvironment.isRunningTests {
            base = FileManager.default.temporaryDirectory
                .appendingPathComponent("qooLibrary-tests", isDirectory: true)
        } else {
            base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
        }
        return base
            .appendingPathComponent("qooLibrary", isDirectory: true)
            .appendingPathComponent("Logs", isDirectory: true)
    }

    public init(
        directory: URL = DiagnosticLog.defaultLogDirectory(),
        maxFileBytes: Int64 = AppLimits.Logging.defaultMaxFileBytes,
        generations: Int = AppLimits.Logging.defaultGenerations,
        level: LogLevel = AppLimits.Logging.defaultLevel,
        maxBufferedRecords: Int = AppLimits.Logging.maxBufferedRecords
    ) {
        let writer = LogFileWriter(directory: directory, maxBytes: maxFileBytes, generations: generations)
        let state = OSAllocatedUnfairLock(initialState: State(level: level))
        let (stream, continuation) = AsyncStream<Event>.makeStream(
            bufferingPolicy: .bufferingNewest(maxBufferedRecords)
        )

        self.writer = writer
        self.state = state
        self.continuation = continuation

        // `self` を強く捕捉すると `shared` 以外（テスト用インスタンス）が
        // 永久に解放されなくなるため、消費タスクは `writer`/`state` だけを
        // 捕捉する。`self` が解放されると `deinit` が `continuation.finish()`
        // を呼び、`for await` が抜けてこのタスクも終了する。
        Task.detached(priority: .utility) {
            for await event in stream {
                switch event {
                case .record(let record):
                    await writer.append(Self.format(record))
                case .flush(let id):
                    let waiter = state.withLock { $0.flushWaiters.removeValue(forKey: id) }
                    waiter?.resume()
                }
            }
            // ストリームが終了した（＝ログ本体が解放された）。取り残された
            // `flush()` の待ち手を必ず再開させる（さもないと永久に待つ）。
            let remaining = state.withLock { s -> [CheckedContinuation<Void, Never>] in
                let waiters = Array(s.flushWaiters.values)
                s.flushWaiters.removeAll()
                return waiters
            }
            for waiter in remaining { waiter.resume() }
            await writer.close()
        }
    }

    deinit {
        continuation.finish()
    }

    // MARK: - DiagnosticLogging

    public var currentLevel: LogLevel {
        get { state.withLock { $0.level } }
        set { state.withLock { $0.level = newValue } }
    }

    public func log(
        _ level: LogLevel,
        category: LogCategory,
        _ message: @autoclosure () -> String,
        fileID: String,
        line: UInt
    ) {
        guard level <= currentLevel else { return }
        let record = LogRecord(
            date: Date(),
            level: level,
            category: category,
            message: message(),
            fileID: fileID,
            line: line
        )
        enqueue(.record(record))
    }

    public func flush() async {
        let id = UUID()
        await withCheckedContinuation { (waiter: CheckedContinuation<Void, Never>) in
            state.withLock { $0.flushWaiters[id] = waiter }
            switch continuation.yield(.flush(id)) {
            case .terminated:
                // 消費タスクが既に終了している。ここで再開しないと永久に待つ。
                resumeWaiter(id)
            case .dropped(let discarded):
                handleDiscarded(discarded)
            default:
                break
            }
        }
    }

    public func rotateIfNeeded() async {
        await flush()
        await writer.rotateIfNeeded()
    }

    public func logFileURLs() async -> [URL] {
        await writer.existingFiles()
    }

    // MARK: - 内部

    private func enqueue(_ event: Event) {
        // 直前までに溢れて捨てた分があれば、本来の行より前に注記を差し込む。
        let dropped = state.withLock { s -> Int in
            let count = s.droppedRecords
            s.droppedRecords = 0
            return count
        }
        if dropped > 0 {
            let notice = LogRecord(
                date: Date(),
                level: .warning,
                category: .app,
                message: "ログのバッファが溢れ、\(dropped) 行を破棄しました（書き込みが追いついていません）",
                fileID: #fileID,
                line: #line
            )
            if case .dropped(let discarded) = continuation.yield(.record(notice)) {
                handleDiscarded(discarded)
            }
        }

        if case .dropped(let discarded) = continuation.yield(event) {
            handleDiscarded(discarded)
        }
    }

    /// バッファ溢れで押し出された要素の後始末。
    ///
    /// `.bufferingNewest` は**最も古い要素**を捨てるため、捨てられたのが
    /// `flush()` の番兵だった場合は、その待ち手をここで再開させないと
    /// 永久に待ち続けることになる。
    private func handleDiscarded(_ event: Event) {
        switch event {
        case .flush(let id):
            resumeWaiter(id)
        case .record:
            state.withLock { $0.droppedRecords += 1 }
        }
    }

    private func resumeWaiter(_ id: UUID) {
        state.withLock { $0.flushWaiters.removeValue(forKey: id) }?.resume()
    }

    // MARK: - 整形

    /// 例: `2026-08-14 12:34:56.789+09:00 [I] [FileOps] FileOperationService.swift:88 — 移動 3 件`
    ///
    /// 1 レコード＝1 行を厳守する（メッセージ中の改行は畳む）。行単位で
    /// `grep` できること、ローテーションで行が割れないことを優先する。
    static func format(_ record: LogRecord) -> String {
        let timestamp = record.date.formatted(timestampStyle)
        let file = record.fileID.split(separator: "/").last.map(String.init) ?? record.fileID
        let message = record.message
            .replacingOccurrences(of: "\r\n", with: " ⏎ ")
            .replacingOccurrences(of: "\n", with: " ⏎ ")
            .replacingOccurrences(of: "\r", with: " ⏎ ")
        return "\(timestamp) [\(record.level.symbol)] [\(record.category.rawValue)] \(file):\(record.line) — \(message)"
    }

    private static let timestampStyle = Date.ISO8601FormatStyle(
        dateSeparator: .dash,
        dateTimeSeparator: .space,
        timeSeparator: .colon,
        timeZoneSeparator: .colon,
        includingFractionalSeconds: true,
        timeZone: .current
    )
}
