import Foundation
import QooKit
import Testing

@testable import QooInfrastructure

/// **その API が使えないボリュームでも、機能そのものは失わないこと** [NV-80]。
///
/// ## なぜこの suite があるのか（1-16b で実際に壊れていた）
/// 移動は `renamex_np(…, RENAME_EXCL)`（宛先が既にあれば失敗する改名）で
/// 実装されている。**これは SMB では `ENOTSUP` になる**ため、共有の中で
/// ファイルを移動する操作が**すべて失敗していた** — D&D・カット＆ペースト・
/// 「ここに項目を移動」。NAS を主な置き場にしている利用では致命的だった。
///
/// ## 見落とした理由と、この suite の役目
/// 8章 §8.11.2 は `RENAME_EXCL の実効 ○ ○ ○ [普遍]` と記録していた。これは
/// **衝突する場合しか試していなかった**ため。smbfs は宛先の有無を先に見るので、
/// 衝突時だけは `EEXIST` を返して正しく動いて見える:
///
/// | 呼び出し | SMB | ローカル(APFS) |
/// |---|---|---|
/// | `RENAME_EXCL`（宛先**あり**）| EEXIST | EEXIST |
/// | **`RENAME_EXCL`（宛先なし＝ふつうの移動）** | **ENOTSUP** | 成功 |
///
/// ネットワーク共有はテストから用意できないが、**UDF も同じく `ENOTSUP` を
/// 返す**ことを実測で確認した（APFS・HFS+・FAT は対応）。縮退経路そのものは
/// これで CI からも守れる。
///
/// | 形式 | `renamex_np(RENAME_EXCL)` |
/// |---|---|
/// | APFS / HFS+ / MS-DOS(FAT) / 起動ボリューム | 対応 |
/// | **UDF** | **ENOTSUP** |
/// | **SMB**（実 NAS）| **ENOTSUP** |
@Suite(.serialized) struct VolumeCapabilityDegradationTests {

    /// `RENAME_EXCL` を持たないボリュームを 1 つ用意する。無ければ `nil`。
    private static func volumeWithoutExclusiveRename() -> TinyVolume? {
        guard let volume = TinyVolume.make(megabytes: 20, fileSystem: "UDF") else { return nil }
        // 前提の確認 — この形式が本当に非対応であること自体が実測に基づく。
        // 将来 macOS が対応したらこの suite は意味を失うので、そのときは
        // 「前提が変わった」と分かるように黙って飛ばす。
        let probe = volume.mountPoint.appendingPathComponent("probe.bin")
        let target = volume.mountPoint.appendingPathComponent("probe-moved.bin")
        guard (try? Data([0x51]).write(to: probe)) != nil else { volume.destroy(); return nil }
        let unsupported = Darwin.renamex_np(probe.path, target.path, UInt32(RENAME_EXCL)) != 0
            && (errno == ENOTSUP || errno == EOPNOTSUPP)
        try? FileManager.default.removeItem(at: probe)
        try? FileManager.default.removeItem(at: target)
        guard unsupported else { volume.destroy(); return nil }
        return volume
    }

    /// **この suite の主眼。** `RENAME_EXCL` が使えないボリュームでも、
    /// ふつうの移動が成功すること。
    ///
    /// 直す前はここが `copyFailed(errnoCode: 45)` で失敗していた。
    @Test func movingSucceedsOnAVolumeThatCannotDoAnExclusiveRename() async throws {
        guard let volume = Self.volumeWithoutExclusiveRename() else { return }
        defer { volume.destroy() }

        let folder = volume.mountPoint.appendingPathComponent("dest", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let source = volume.mountPoint.appendingPathComponent("moving.bin")
        try Data(repeating: 0x51, count: 1024).write(to: source)

        let service = FileOperationService()
        let receipts = try await service.move(
            [source], to: folder, options: .init(conflictPolicy: .keepBoth)
        )

        #expect(receipts.count == 1)
        #expect(!FileManager.default.fileExists(atPath: source.path), "移動元が残っている")
        let moved = folder.appendingPathComponent("moving.bin")
        #expect(FileManager.default.fileExists(atPath: moved.path), "移動先に無い")
        #expect(try Data(contentsOf: moved).count == 1024)
    }

    /// **縮退しても安全弁を失わないこと。**
    ///
    /// `RENAME_EXCL` の役目は「取りこぼした衝突で健康なファイルを書き潰さない」
    /// こと。アトミックにできない環境では自分で存在を確かめてから改名するので、
    /// **既にある宛先を上書きしてはならない**。素の `rename(2)` へ素直に
    /// 落とすとここが黙って上書きされる。
    ///
    /// ## なぜ縮退経路を直接呼ぶのか（最初の版は空振りだった）
    /// 当初は非対応のボリューム（UDF）に対して `moveItem` 越しに衝突させて
    /// いたが、**それでは縮退経路に入らない**。非対応のボリュームは
    /// 「宛先がある場合」に限って `EEXIST` を返すため（SMB とまったく同じ
    /// 順序）、衝突を試すと `renamex_np` の時点で弾かれてしまう:
    ///
    /// | | 宛先なし | 宛先あり |
    /// |---|---|---|
    /// | UDF・SMB の `RENAME_EXCL` | **ENOTSUP**（＝縮退へ）| EEXIST（縮退に入らない）|
    ///
    /// 実際、衝突検査を外す変異を当てても**テストは通ってしまった**。
    /// そこで縮退経路だけを切り離し、**素の `rename(2)` なら確実に上書きする
    /// ボリューム**（APFS。実測で上書きを確認）の上で確かめる。
    @Test func theDegradedPathRefusesToOverwriteAnExistingDestination() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("qoo-degrade-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let source = root.appendingPathComponent("incoming.bin")
        let occupied = root.appendingPathComponent("occupied.bin")
        try Data(repeating: 0x51, count: 16).write(to: source)
        try Data(repeating: 0x41, count: 32).write(to: occupied)

        let code = FileOperationService.renameCheckingDestinationFirst(from: source, to: occupied)

        #expect(code == EEXIST, "衝突として断らなかった（errno=\(code)）")
        let survivor = try Data(contentsOf: occupied)
        #expect(survivor.count == 32, "既存の宛先を書き潰した")
        #expect(survivor.allSatisfy { $0 == 0x41 }, "既存の宛先の中身が入れ替わっている")
        #expect(FileManager.default.fileExists(atPath: source.path), "元も失われている")

        // **この検証が意味を持つことの裏取り** — 同じ場所で素の `rename(2)` は
        // 実際に上書きする。つまり上で断ったのはファイルシステムではなく
        // こちらの衝突検査である。
        #expect(Darwin.rename(source.path, occupied.path) == 0)
        #expect(try Data(contentsOf: occupied).count == 16, "前提が崩れている（素の rename が上書きしない）")
    }

    // MARK: - 一過性の削除失敗 [1-16b の実測]

    /// **「待てば直る失敗」と「待っても直らない失敗」を取り違えないこと。**
    ///
    /// SMB では中身のあるフォルダの削除が 5 回に 1 回ほど `EPERM` で失敗し、
    /// これは待てば必ず直る（実測 6/6）。一方 `ENOTEMPTY`（外部がハンドルを
    /// 開いたまま）は 5 秒待っても直らない [NV90-01]。**後者を再試行の対象に
    /// 入れると、直らないものを待つだけの実装になる。**
    @Test func onlyTheRecoverableRemovalFailuresAreRetried() {
        func posixError(_ code: Int32) -> NSError {
            NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError, userInfo: [
                NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(code)),
            ])
        }
        // 待てば直るもの。
        #expect(FileOperationService.isTransientRemovalFailure(posixError(EPERM)))
        #expect(FileOperationService.isTransientRemovalFailure(posixError(EBUSY)))
        // 待っても直らないもの・そもそも別の話。
        #expect(!FileOperationService.isTransientRemovalFailure(posixError(ENOTEMPTY)),
                "ENOTEMPTY を再試行の対象にしている [NV90-01]")
        #expect(!FileOperationService.isTransientRemovalFailure(posixError(EACCES)))
        #expect(!FileOperationService.isTransientRemovalFailure(posixError(ENOENT)))
        #expect(!FileOperationService.isTransientRemovalFailure(posixError(EROFS)))
        // POSIX 由来でない失敗を一過性と決めつけないこと。
        #expect(!FileOperationService.isTransientRemovalFailure(
            NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)))
        // 直接 POSIX ドメインで来た場合も拾えること。
        #expect(FileOperationService.isTransientRemovalFailure(
            NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))))
    }

    /// 縮退経路は、衝突していなければ普通に改名できること。
    @Test func theDegradedPathStillRenamesWhenThereIsNoCollision() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("qoo-degrade-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let source = root.appendingPathComponent("incoming.bin")
        let target = root.appendingPathComponent("free.bin")
        try Data(repeating: 0x51, count: 16).write(to: source)

        #expect(FileOperationService.renameCheckingDestinationFirst(from: source, to: target) == 0)
        #expect(!FileManager.default.fileExists(atPath: source.path))
        #expect(try Data(contentsOf: target).count == 16)
    }
}
