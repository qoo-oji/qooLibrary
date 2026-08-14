import Foundation
import QooKit
import Testing

@testable import QooInfrastructure

/// 診断ログ本体 [LG2-01〜LG2-04][CB-20][CB-21] の検証。
@Suite struct DiagnosticLogTests {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("qoo-diaglog-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func readLines(_ directory: URL, generation: Int = 0) throws -> [String] {
        let url = directory.appendingPathComponent("qoo-\(generation).log")
        let text = try String(contentsOf: url, encoding: .utf8)
        return text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    @Test func writesRecordsToTheCurrentGeneration() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = DiagnosticLog(directory: dir, level: .info)

        log.log(.info, category: .fileOps, "こんにちは", fileID: "Module/Thing.swift", line: 42)
        await log.flush()

        let lines = try readLines(dir)
        #expect(lines.count == 1)
        #expect(lines[0].contains("[I]"))
        #expect(lines[0].contains("[FileOps]"))
        #expect(lines[0].contains("Thing.swift:42"))
        #expect(lines[0].contains("こんにちは"))
        // `#fileID` のモジュール名部分は落とし、ファイル名だけを残す。
        #expect(!lines[0].contains("Module/"))
    }

    @Test func recordsBelowTheThresholdAreNotWritten() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = DiagnosticLog(directory: dir, level: .warning)

        log.log(.error, category: .app, "残る", fileID: "A.swift", line: 1)
        log.log(.warning, category: .app, "残る", fileID: "A.swift", line: 2)
        log.log(.info, category: .app, "消える", fileID: "A.swift", line: 3)
        log.log(.debug, category: .app, "消える", fileID: "A.swift", line: 4)
        await log.flush()

        let lines = try readLines(dir)
        #expect(lines.count == 2)
        #expect(lines.allSatisfy { $0.contains("残る") })
    }

    @Test func changingTheLevelTakesEffectImmediately() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = DiagnosticLog(directory: dir, level: .error)

        log.log(.debug, category: .app, "まだ出ない", fileID: "A.swift", line: 1)
        log.currentLevel = .debug
        log.log(.debug, category: .app, "出る", fileID: "A.swift", line: 2)
        await log.flush()

        let lines = try readLines(dir)
        #expect(lines.count == 1)
        #expect(lines[0].contains("出る"))
    }

    @Test func theAutoclosureIsNotEvaluatedBelowTheThreshold() async throws {
        // `@autoclosure` の遅延評価が実際に効いていること（しきい値未満では
        // 文字列の組み立てコストすら払わない）。
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = DiagnosticLog(directory: dir, level: .info)

        final class Counter: @unchecked Sendable { var value = 0 }
        let counter = Counter()
        func expensive() -> String {
            counter.value += 1
            return "計算した"
        }

        log.log(.debug, category: .app, expensive(), fileID: "A.swift", line: 1)
        #expect(counter.value == 0)

        log.log(.info, category: .app, expensive(), fileID: "A.swift", line: 2)
        #expect(counter.value == 1)
        await log.flush()
    }

    @Test func recordsKeepTheirOrderEvenWhenLoggedConcurrently() async throws {
        // 1 レコードごとに `Task` を起こす実装では順序が保証されない。
        // `AsyncStream`（FIFO）に乗せていることの回帰テスト。
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = DiagnosticLog(directory: dir, level: .debug)

        for index in 0..<500 {
            log.log(.info, category: .app, "行\(index)", fileID: "A.swift", line: UInt(index))
        }
        await log.flush()

        let lines = try readLines(dir)
        #expect(lines.count == 500)
        for (index, line) in lines.enumerated() {
            #expect(line.hasSuffix("行\(index)"))
        }
    }

    @Test func multilineMessagesStayOnASingleLine() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = DiagnosticLog(directory: dir, level: .info)

        log.log(.info, category: .app, "1行目\n2行目\r\n3行目", fileID: "A.swift", line: 1)
        await log.flush()

        let lines = try readLines(dir)
        #expect(lines.count == 1)
        #expect(lines[0].contains("1行目 ⏎ 2行目 ⏎ 3行目"))
    }

    @Test func rotatesWhenTheCurrentFileExceedsTheLimit() async throws {
        // [LG2-04][CB-20] 上限を超えたら世代をずらす。
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = DiagnosticLog(directory: dir, maxFileBytes: 400, generations: 3, level: .info)

        for index in 0..<40 {
            log.log(.info, category: .app, String(repeating: "x", count: 60) + "#\(index)", fileID: "A.swift", line: 1)
        }
        await log.flush()

        let files = await log.logFileURLs()
        // 3 世代までしか残さない。
        #expect(files.count == 3)
        #expect(files.map(\.lastPathComponent) == ["qoo-0.log", "qoo-1.log", "qoo-2.log"])
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("qoo-3.log").path))

        // 最新の世代（qoo-0）に、最後に書いたレコードが入っている。
        let newest = try readLines(dir, generation: 0)
        #expect(newest.last?.contains("#39") == true)
    }

    @Test func rotationDoesNotLoseRecordsWhileGenerationsRemain() async throws {
        // 世代を使い切らない範囲であれば、ローテーションを何度またいでも
        // 1 行も落ちない（＝退避と再オープンの継ぎ目に穴が無い）。
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = DiagnosticLog(directory: dir, maxFileBytes: 300, generations: 30, level: .info)

        for index in 0..<30 {
            log.log(.info, category: .app, String(repeating: "y", count: 50) + "#\(index)", fileID: "A.swift", line: 1)
        }
        await log.flush()

        let files = await log.logFileURLs()
        #expect(files.count > 1) // 実際にローテーションが起きたこと
        var total = 0
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            total += text.split(separator: "\n", omittingEmptySubsequences: true).count
        }
        #expect(total == 30)
    }

    @Test func oldestGenerationIsDiscardedOnceTheLimitIsReached() async throws {
        // [LG2-04] 保持世代を超えた分は捨てる（ディスクを無制限に食わない）。
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = DiagnosticLog(directory: dir, maxFileBytes: 300, generations: 3, level: .info)

        for index in 0..<60 {
            log.log(.info, category: .app, String(repeating: "z", count: 50) + "#\(index)", fileID: "A.swift", line: 1)
        }
        await log.flush()

        let files = await log.logFileURLs()
        #expect(files.count == 3)
        var total = 0
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            total += text.split(separator: "\n", omittingEmptySubsequences: true).count
        }
        #expect(total < 60)
        // 捨てられるのは常に古い側。最後の行は残っている。
        let newest = try readLines(dir, generation: 0)
        #expect(newest.last?.contains("#59") == true)
    }

    @Test func flushReturnsEvenWithoutAnyRecords() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = DiagnosticLog(directory: dir, level: .info)
        await log.flush() // ハングしないこと自体が検証内容
    }

    @Test func theDefaultDirectoryIsRedirectedWhileTestsAreRunning() {
        // `Log.*` は `FileOperationService` など広範囲に埋め込まれているため、
        // これが効いていないと `swift test` のたびに開発機の実ログが
        // テストのノイズで埋まる。
        let directory = DiagnosticLog.defaultLogDirectory().path
        #expect(directory.hasPrefix(FileManager.default.temporaryDirectory.path))
        #expect(!directory.contains("Application Support"))
    }

    @Test func logFileURLsIsEmptyBeforeAnythingIsWritten() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = DiagnosticLog(directory: dir, level: .info)
        let files = await log.logFileURLs()
        #expect(files.isEmpty)
    }

    @Test func overflowingTheBufferIsReportedInsteadOfSilentlyDropping() async throws {
        // ディスクが追いつかない場合でも「黙って失う」ことはしない。
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = DiagnosticLog(directory: dir, level: .info, maxBufferedRecords: 4)

        for index in 0..<400 {
            log.log(.info, category: .app, "行\(index)", fileID: "A.swift", line: 1)
        }
        await log.flush()

        let lines = try readLines(dir)
        // 溢れているかどうかは消費側の速度次第なので件数は問わない。溢れた
        // 場合に必ず注記が残ることだけを見る。
        if lines.count < 400 {
            #expect(lines.contains { $0.contains("ログのバッファが溢れ") })
        }
    }
}
