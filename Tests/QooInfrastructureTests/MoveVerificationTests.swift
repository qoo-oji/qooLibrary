import Foundation
import QooKit
import Testing

@testable import QooInfrastructure

/// **元を消す前の検証が、更新日時に依存しないこと**［ユーザー指摘による保険］。
///
/// クロスボリュームの移動は「コピーしてから元を消す」ので、写した内容が元と
/// 食い違ったまま消すとその差分は永久に失われる。既存の検出は
/// `FileContentStamp`（更新日時＋サイズ）だが、更新日時の精度は書き込み先
/// 次第で、実測では FAT が 2 秒（ナノ秒が常に 0）。**NAS の OS は千差万別で、
/// 手元の 1 台で確かめられたことを一般化できない**ため、タイムスタンプに
/// まったく依存しない確認を重ねている。
@Suite struct MoveVerificationTests {
    private func sandbox() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("qoo-verify-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func randomData(_ count: Int, seed: UInt64) -> Data {
        var data = Data(count: count)
        data.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            let bytes = base.assumingMemoryBound(to: UInt8.self)
            var state = seed
            for index in 0..<raw.count {
                state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                bytes[index] = UInt8(truncatingIfNeeded: state >> 33)
            }
        }
        return data
    }

    /// 同じ内容なら一致と判定すること（過敏だと正当な移動を止めてしまう）。
    @Test func identicalFilesMatch() throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = randomData(500_000, seed: 1)
        let a = root.appendingPathComponent("a.bin")
        let b = root.appendingPathComponent("b.bin")
        try payload.write(to: a)
        try payload.write(to: b)
        #expect(MoveVerification.looksIdentical(source: a, destination: b))
    }

    /// **同じ大きさのまま中身だけ入れ替わった場合**を捕まえること。
    /// これが本題 — 更新日時では見分けられない形式があるため。
    @Test func sameSizeDifferentContentIsDetected() throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("a.bin")
        let b = root.appendingPathComponent("b.bin")
        try randomData(500_000, seed: 1).write(to: a)
        try randomData(500_000, seed: 99).write(to: b)
        #expect((try? a.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
            == (try? b.resourceValues(forKeys: [.fileSizeKey]))?.fileSize)
        #expect(!MoveVerification.looksIdentical(source: a, destination: b))
    }

    /// 末尾だけが違う場合も捕まえること（先頭しか見ていないと取り逃がす）。
    @Test func aDifferenceOnlyAtTheEndIsDetected() throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        var payload = randomData(1_000_000, seed: 7)
        let a = root.appendingPathComponent("a.bin")
        try payload.write(to: a)
        payload[payload.count - 10] = payload[payload.count - 10] &+ 1
        let b = root.appendingPathComponent("b.bin")
        try payload.write(to: b)
        #expect(!MoveVerification.looksIdentical(source: a, destination: b))
    }

    /// 大きさが違えば当然捕まえること（切り詰められた場合）。
    @Test func aTruncatedCopyIsDetected() throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("a.bin")
        let b = root.appendingPathComponent("b.bin")
        try randomData(500_000, seed: 3).write(to: a)
        try randomData(400_000, seed: 3).write(to: b)
        #expect(!MoveVerification.looksIdentical(source: a, destination: b))
    }

    /// フォルダは件数と合計バイト数で突き合わせること。
    @Test func aFolderWithADifferentSetOfFilesIsDetected() throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("a", isDirectory: true)
        let b = root.appendingPathComponent("b", isDirectory: true)
        for folder in [a, b] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for index in 0..<3 {
                try randomData(1000, seed: UInt64(index)).write(to: folder.appendingPathComponent("f\(index).bin"))
            }
        }
        #expect(MoveVerification.looksIdentical(source: a, destination: b))
        // 片方に 1 件増えたら一致しない。
        try randomData(1000, seed: 42).write(to: a.appendingPathComponent("extra.bin"))
        #expect(!MoveVerification.looksIdentical(source: a, destination: b))
    }

    /// 判定できない場合は**断らない**こと（確かめられないだけの正当な移動まで
    /// 止めないため）。書き込み先が消えている場合など。
    @Test func anUnreadableDestinationDoesNotBlockTheMove() throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("a.bin")
        try randomData(1000, seed: 5).write(to: a)
        #expect(MoveVerification.looksIdentical(source: a, destination: root.appendingPathComponent("missing.bin")))
    }
}
