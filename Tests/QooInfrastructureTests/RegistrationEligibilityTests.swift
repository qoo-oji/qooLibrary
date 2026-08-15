import Foundation
import QooKit
import Testing

@testable import QooInfrastructure

/// **前提が成り立たないファイルシステムは、ライブラリ／テンポラリとして
/// 登録させない** [FS-01〜FS-05][RG-08]［ユーザー確認済みの期待挙動］。
///
/// アプリはファイルを移動しても同一と判別できること（永続ファイル ID）を
/// 土台にしている。これが無いボリュームを登録できてしまうと、移動や改名の
/// たびに「別のファイル」として扱われ、ラベル・評価・カバー画像といった
/// 再生成できないデータの結びつきが静かに壊れる。**登録の時点で断るのが
/// 唯一の防ぎ方**で、あとから救う手立ては無い。
///
/// ## 実測（このマシンで確認した値）
///
/// | 形式 | 永続ファイル ID |
/// |---|---|
/// | APFS / APFS 大文字小文字区別 / HFS+ | ○ |
/// | exFAT / FAT12・16・32 / UDF | × |
/// | **SMB（実 NAS）** | **×** |
///
/// SMB が `×` なのは、ネットワークボリュームを弾く仕組みが**別途要らない**
/// ことを意味する。「ネットワークだから」ではなく「前提が成り立たないから」で
/// 一律に弾ける（ユーザーの意図もこちら）。
///
/// ディスクイメージを作れない環境では静かに飛ばす（`FreeSpacePreflightTests`
/// と同じ方針）。
/// **`.serialized`**: この suite の各検証は使い捨てのディスクイメージを
/// 作って外す。並列に走らせると `hdiutil` が同時に何本も動いてディスクを
/// 圧迫し、FSEvents の到達を待つ別の検証（`DirectoryWatchIntegrationTests`）が
/// 10 秒の猶予でも間に合わなくなることがある。I/O 律速でそもそも並列にする
/// 価値が無いため直列にする。
@Suite(.serialized) struct RegistrationEligibilityTests {
    /// exFAT は永続ファイル ID を持たない。実 NAS（SMB）と同じ理由で弾かれる
    /// はずで、こちらは使い捨てのイメージで再現できる。
    @Test func volumesWithoutPersistentFileIDsAreRejected() async throws {
        guard let volume = TinyVolume.make(megabytes: 40, fileSystem: "ExFAT") else { return }
        defer { volume.destroy() }

        let checker = VolumeEligibilityChecker()
        let capability = try checker.capability(of: volume.mountPoint)
        // 前提: この形式は永続 ID を持たない（持つようになったら検証の意味が変わる）。
        guard capability.supportsPersistentIDs == false else { return }

        let verdict = try await checker.evaluate(volume.mountPoint)
        guard case let .rejected(reason) = verdict else {
            Issue.record("永続ファイル ID の無いボリュームが受け入れられた: \(verdict)")
            return
        }
        guard case .noPersistentFileID = reason else {
            Issue.record("理由が想定と違う: \(reason)")
            return
        }
    }

    /// 登録ストア越しでも弾かれること（`VolumeEligibilityChecker` を直接
    /// 呼ぶ経路だけでなく、実際にユーザーが通る経路で確かめる）。
    @Test func registeringAFolderOnSuchAVolumeFails() async throws {
        guard let volume = TinyVolume.make(megabytes: 40, fileSystem: "ExFAT") else { return }
        defer { volume.destroy() }
        let folder = volume.mountPoint.appendingPathComponent("library", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let storage = FileManager.default.temporaryDirectory
            .appendingPathComponent("qoo-eligibility-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: storage) }
        let store = RegisteredFolderStore(storageURL: storage)

        var thrown: (any Error)?
        do { _ = try await store.register(url: folder, kind: .library, displayName: nil) } catch { thrown = error }

        let error = try #require(thrown as? RegisteredFolderError)
        guard case .unsupportedFileSystem = error else {
            Issue.record("対応外の形式として断られなかった: \(error)")
            return
        }
        // 理由がそのまま読める文言であること（「エラーN」に潰れない）[ER-03]。
        #expect(!error.localizedDescription.contains("RegisteredFolderError"))
        #expect(error.localizedDescription.contains("登録できません"))
        // 登録一覧に混入していないこと。
        #expect(await store.folders(kind: .library).isEmpty)
    }

    /// 逆方向の固定 — 前提を満たすボリューム（APFS）は当然受け入れること。
    /// ここが壊れると、正当なフォルダまで登録できなくなる。
    @Test func volumesWithPersistentFileIDsAreAccepted() async throws {
        guard let volume = TinyVolume.make(megabytes: 40) else { return }
        defer { volume.destroy() }

        let verdict = try await VolumeEligibilityChecker().evaluate(volume.mountPoint)
        guard case .eligible = verdict else {
            Issue.record("APFS が受け入れられなかった: \(verdict)")
            return
        }
    }
}
