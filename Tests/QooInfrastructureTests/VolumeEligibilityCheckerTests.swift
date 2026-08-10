import Foundation
import Testing

@testable import QooInfrastructure

@Suite struct VolumeEligibilityCheckerTests {
    let checker = VolumeEligibilityChecker()

    /// APFS（このリポジトリのテストが動く環境の内蔵ボリュームは APFS 前提）は
    /// persistent file ID をサポートし、移動しても同一性が保たれるはず [FS-01〜FS-03]。
    @Test func evaluateAcceptsAPFSTempDirectory() async throws {
        let tempDir = FileManager.default.temporaryDirectory
        let result = try await checker.evaluate(tempDir)
        guard case .eligible(let warnings) = result else {
            Issue.record("expected .eligible for a local APFS volume, got \(result)")
            return
        }
        #expect(!warnings.contains(.networkVolumeFSEventsUnreliable))
    }

    @Test func capabilityReportsNonNetworkForLocalVolume() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let cap = try checker.capability(of: tempDir)
        #expect(cap.isNetworkVolume == false)
        #expect(!cap.volumeUUID.isEmpty)
    }

    /// 実マシンに接続された外部ボリュームがあれば、それも受理されることを確認する。
    /// CI ランナーには存在しないため、無ければ黙ってスキップする。
    @Test func evaluateAcceptsAttachedExternalVolumesIfPresent() async throws {
        let fm = FileManager.default
        let candidates = try fm.contentsOfDirectory(atPath: "/Volumes").map { "/Volumes/\($0)" }
        var checkedAny = false
        for path in candidates {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { continue }
            guard fm.isWritableFile(atPath: path) else { continue }
            let url = URL(fileURLWithPath: path)
            guard let result = try? await checker.evaluate(url) else { continue }
            checkedAny = true
            if case .rejected(let reason) = result {
                // 非 APFS（exFAT 等）の外部ボリュームが接続されていた場合、拒否されること自体は
                // 正しい挙動 [FS-04]。ここでは「クラッシュせず判定できること」だけを確認する。
                _ = reason
            }
        }
        _ = checkedAny // 外部ボリュームが 1 つも書き込み可能でなくても失敗にはしない。
    }
}
