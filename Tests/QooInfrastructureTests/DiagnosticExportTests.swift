import Foundation
import QooKit
import Testing

@testable import QooInfrastructure

/// 診断情報バンドルの書き出し [LG2-05][LG2-06][CB-22] の検証。
///
/// **`DiagnosticsReport` は常に明示的に渡す** — 既定の `nil`（実行時収集）だと
/// `RegisteredFolderStore.shared`/`VolumeAccessStore.shared`（実際のアプリ
/// コンテナを見る共有シングルトン）に触れてしまい、開発機の実データに依存する
/// テストになるため。
@Suite struct DiagnosticExportTests {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("qoo-diagexport-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeReport() -> DiagnosticsReport {
        DiagnosticsReport(
            generatedAt: Date(timeIntervalSince1970: 1_800_000_000),
            app: .init(
                bundleIdentifier: "com.qoolibrary.app",
                shortVersion: "1.0",
                buildVersion: "1",
                buildConfiguration: "Debug",
                permissiveOnlyBuild: false,
                rarBackend: "UnRAR"
            ),
            system: .init(
                osVersion: "Version 26.0",
                architecture: "arm64",
                isSandboxed: true,
                preferredLanguages: ["ja-JP"],
                physicalMemoryBytes: 16_000_000_000,
                processorCount: 10
            ),
            logging: .init(level: LogLevel.info.identifier, pathsAnonymized: false, files: []),
            registeredFolders: .init(library: 2, temporary: 1, activeAccess: 3),
            volumeAccessGrants: 1
        )
    }

    /// 書き出した zip の中身（エントリ名 → 本文）を読み出す。
    private func unpack(_ zip: URL) async throws -> [String: String] {
        let listing = try await LibarchiveBackend.shared.listEntries(zip)
        var contents: [String: String] = [:]
        for entry in listing.entries where !entry.isDirectory {
            let data = try await LibarchiveBackend.shared.readEntry(
                zip, entry: entry, encoding: listing.detectedEncoding, maxBytes: 10_000_000
            )
            contents[entry.pathname] = String(decoding: data, as: UTF8.self)
        }
        return contents
    }

    @Test func bundleContainsTheLogsAndTheDiagnosticsJson() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let log = DiagnosticLog(directory: root.appendingPathComponent("Logs"), level: .info)
        log.log(.info, category: .fileOps, "move 完了: /Volumes/Ext/A.cbz", fileID: "A.swift", line: 1)

        let destination = root.appendingPathComponent("report.zip")
        let bundle = try await log.exportBundle(anonymizePaths: false, to: destination, report: makeReport())

        #expect(bundle.pathExtension == "zip")
        #expect(FileManager.default.fileExists(atPath: bundle.path))

        let contents = try await unpack(bundle)
        let names = contents.keys.map { ($0 as NSString).lastPathComponent }.sorted()
        #expect(names == ["diagnostics.json", "qoo-0.log"])

        // ログ本文がそのまま入っている（匿名化していない場合）。
        let logBody = try #require(contents.first { $0.key.hasSuffix("qoo-0.log") }?.value)
        #expect(logBody.contains("/Volumes/Ext/A.cbz"))

        // 診断情報が読み取れる JSON である [CB-22]。
        let jsonBody = try #require(contents.first { $0.key.hasSuffix("diagnostics.json") }?.value)
        let decoded = try JSONDecoder.iso8601Decoder.decode(DiagnosticsReport.self, from: Data(jsonBody.utf8))
        #expect(decoded.app.rarBackend == "UnRAR")
        #expect(decoded.registeredFolders.library == 2)
        #expect(decoded.database == nil) // フェーズ1では SwiftData 未導入
    }

    @Test func anonymizedBundleContainsNoRawPaths() async throws {
        // [LG2-06] 匿名化を有効にすると、ログ本文・診断情報のどちらからも
        // 実際のパスが消える。
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let log = DiagnosticLog(directory: root.appendingPathComponent("Logs"), level: .info)
        log.log(.info, category: .fileOps, "move 完了: /Volumes/SecretDrive/Private/A.cbz", fileID: "A.swift", line: 1)

        let destination = root.appendingPathComponent("report.zip")
        let bundle = try await log.exportBundle(anonymizePaths: true, to: destination, report: makeReport())

        let contents = try await unpack(bundle)
        let logBody = try #require(contents.first { $0.key.hasSuffix("qoo-0.log") }?.value)
        #expect(!logBody.contains("SecretDrive"))
        #expect(!logBody.contains("Private"))
        #expect(logBody.contains("/Volumes/")) // 構造自体は残る
        #expect(logBody.contains(".cbz")) // 拡張子も残る
        #expect(logBody.contains("move 完了")) // パス以外の本文は変わらない
    }

    @Test func exportFailsWhenNothingHasBeenLogged() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let log = DiagnosticLog(directory: root.appendingPathComponent("Logs"), level: .info)

        await #expect(throws: DiagnosticExportError.noLogFiles) {
            try await log.exportBundle(
                anonymizePaths: false, to: root.appendingPathComponent("report.zip"), report: makeReport()
            )
        }
    }

    @Test func exportIncludesEveryRetainedGeneration() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let log = DiagnosticLog(
            directory: root.appendingPathComponent("Logs"), maxFileBytes: 300, generations: 3, level: .info
        )
        for index in 0..<60 {
            log.log(.info, category: .app, String(repeating: "w", count: 50) + "#\(index)", fileID: "A.swift", line: 1)
        }

        let bundle = try await log.exportBundle(
            anonymizePaths: false, to: root.appendingPathComponent("report.zip"), report: makeReport()
        )

        let contents = try await unpack(bundle)
        let logNames = contents.keys
            .map { ($0 as NSString).lastPathComponent }
            .filter { $0.hasSuffix(".log") }
            .sorted()
        #expect(logNames == ["qoo-0.log", "qoo-1.log", "qoo-2.log"])
    }

    @Test func exportFlushesPendingRecordsFirst() async throws {
        // 直前の操作こそが報告したい事象なので、書き出し前に必ず `flush()`
        // されること。`flush()` を挟まずに書き出すと最後の行が落ちる。
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let log = DiagnosticLog(directory: root.appendingPathComponent("Logs"), level: .info)
        log.log(.info, category: .app, "直前の操作", fileID: "A.swift", line: 1)

        let bundle = try await log.exportBundle(
            anonymizePaths: false, to: root.appendingPathComponent("report.zip"), report: makeReport()
        )

        let contents = try await unpack(bundle)
        let logBody = try #require(contents.first { $0.key.hasSuffix("qoo-0.log") }?.value)
        #expect(logBody.contains("直前の操作"))
    }

    @Test func reportRoundTripsThroughJson() throws {
        let report = makeReport()
        let decoded = try JSONDecoder.iso8601Decoder.decode(DiagnosticsReport.self, from: report.jsonData())
        #expect(decoded == report)
    }
}

private extension JSONDecoder {
    static var iso8601Decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
