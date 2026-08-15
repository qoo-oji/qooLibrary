import Foundation
import QooKit
import Testing

@testable import QooInfrastructure

/// **展開先の空きが尽きたときに、アプリが落ちないこと。**
///
/// 監査で見つけた中で最も重い欠陥の回帰テスト。展開の書き出しループは
/// `FileHandle.write(_:)`（非 throwing 版）を使っており、これは失敗を
/// Swift のエラーではなく Objective-C 例外
/// （`NSFileHandleOperationException`）で投げる。Swift はこれを捕捉できない
/// ため、**空きが尽きた瞬間にプロセスごと異常終了**していた。
///
/// 使い捨ての小さなボリュームで実測して確認した（SIGABRT / exit 134）。
/// Apple のドキュメントにも「no free space is left on the file system」で
/// 例外を送出すると明記がある。
///
/// ここでは `SecureExtractor` を通さず `LibarchiveBackend` を直接呼ぶ —
/// `SecureExtractor` には空き容量の事前検査があり、そちらで先に断られると
/// **書き出しループそのものを通らない**ため、この回帰を捕まえられない。
///
/// ディスクイメージを作れない環境では静かに飛ばす（`FreeSpacePreflightTests`
/// と同じ方針）。
/// **`.serialized`**: この suite の各検証は使い捨てのディスクイメージを
/// 作って外す。並列に走らせると `hdiutil` が同時に何本も動いてディスクを
/// 圧迫し、FSEvents の到達を待つ別の検証（`DirectoryWatchIntegrationTests`）が
/// 10 秒の猶予でも間に合わなくなることがある。I/O 律速でそもそも並列にする
/// 価値が無いため直列にする。
@Suite(.serialized) struct ExtractionWriteFailureTests {
    @Test func runningOutOfSpaceWhileWritingReportsAnErrorInsteadOfCrashing() async throws {
        guard let volume = TinyVolume.make(megabytes: 20) else { return }
        defer { volume.destroy() }

        // ボリュームより明らかに大きい中身を持つアーカイブを作る。
        // 圧縮が効きすぎないよう、繰り返しではない中身にする。
        let archive = FileManager.default.temporaryDirectory
            .appendingPathComponent("qoo-nospace-\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: archive) }
        var payload = Data(count: 8 * 1_000 * 1_000)
        payload.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            let bytes = base.assumingMemoryBound(to: UInt8.self)
            var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
            for index in 0..<raw.count {
                seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                bytes[index] = UInt8(truncatingIfNeeded: seed >> 33)
            }
        }
        try ArchiveFixtureBuilder.makeZip(at: archive, entries: (0..<8).map {
            .file("part\($0).bin", contents: payload)
        })

        let staging = volume.mountPoint.appendingPathComponent("staging", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

        var thrown: (any Error)?
        do {
            _ = try await LibarchiveBackend.shared.extract(
                archive, to: staging,
                options: ExtractOptions(destination: staging, limits: .default)
            )
        } catch {
            thrown = error
        }

        // ここへ到達できること自体が回帰テストの主眼（以前はプロセスが落ちた）。
        let error = try #require(thrown as? ExtractError, "容量が尽きたのに失敗しなかった")
        guard case let .writeFailed(reason) = error else {
            Issue.record("書き込み失敗として報告されなかった: \(error)")
            return
        }
        // 原因が読める文言になっていること [ER-03]。「エラーN」形式へ潰れない。
        #expect(reason.contains("空き容量"), "容量不足だと分からない文言: \(reason)")
        #expect(!error.localizedDescription.contains("ExtractError"))
    }

    /// 作業領域（起動ボリューム）の空きが足りない場合は、**書き始める前に**
    /// 断ること。展開先に十分な空きがあっても、展開はいったん作業領域へ
    /// 書き出すため全量ぶんの空きが要る — この検査が以前は無かった。
    @Test func stagingShortageIsRefusedBeforeWritingAnything() async throws {
        guard let volume = TinyVolume.make(megabytes: 20) else { return }
        defer { volume.destroy() }

        let archive = FileManager.default.temporaryDirectory
            .appendingPathComponent("qoo-staging-\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: archive) }
        try ArchiveFixtureBuilder.makeZip(at: archive, entries: [
            .file("big.bin", contents: Data(count: 60 * 1_000 * 1_000)),
        ])

        // 作業領域だけを小さなボリュームに置き、展開先は広い一時ディレクトリにする。
        let staging = volume.mountPoint.appendingPathComponent("staging", isDirectory: true)
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("qoo-staging-dst-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: destination) }

        let extractor = SecureExtractor(stagingRoot: staging)
        var thrown: (any Error)?
        do {
            _ = try await extractor.extract(archive, options: ExtractOptions(destination: destination))
        } catch {
            thrown = error
        }

        let error = try #require(thrown as? ExtractError)
        guard case .insufficientStagingSpace = error else {
            Issue.record("作業領域の不足として断られなかった: \(error)")
            return
        }
        #expect(error.localizedDescription.contains("起動ディスク"))
        // 展開先には何も書かれていないこと。
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
    }
}
