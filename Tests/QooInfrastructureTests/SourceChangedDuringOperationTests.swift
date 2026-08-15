import Foundation
import QooKit
import Testing

@testable import QooInfrastructure

/// **書き込み中のファイルを写して、それを「成功」と言わない。**
///
/// ## 実測で確認した実害
/// 他のアプリが書き足している最中のファイル（ダウンロード中、書き出し中の
/// 動画など）をコピーすると、`copyfile` は**その時点の姿を写して成功を返す**:
///
/// ```
/// 元のサイズ: コピー開始前 72.3MB → 最終 84.9MB
/// コピー結果 72.3MB   copyfile rc=0（成功扱い）
/// ```
///
/// **移動ではこのあと元を消す**ため、書き足された 12.6MB は永久に失われる。
/// `flock` は掛かっていないことも実測済みで、排他では検出できない。
///
/// 対処は「運ぶ前後で元の姿（更新日時とサイズ）が変わっていないか確かめる」。
/// 変わっていたら、移動なら**元を消さず**、コピーなら中途半端な結果を残さない。
///
/// **`.serialized`**: 書き込み続ける別プロセスを走らせるため、並列に回すと
/// 他の検証の I/O を圧迫する。
@Suite(.serialized) struct SourceChangedDuringOperationTests {
    private func sandbox() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("qoo-changing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// **移動: 処理中に元が書き換えられたら、元を消してはならない。**
    /// これが崩れると、書き足された分が永久に失われる。
    ///
    /// ここに至るまでに 3 度、再現に失敗している:
    /// 1. 「書き足し続ける別プロセス」と競争させた → コピーが先に終わり、
    ///    **検出を外しても通る空振り**だった。
    /// 2. 進捗を見て一時停止し、その間に書き足す → 250MB のコピーが実測
    ///    **0.071 秒**で完走し、止める機会が無かった。
    /// 3. 進捗コールバックの中で書き足す → 進捗の `addBytes` は 100ms
    ///    間引きのため速いコピーでは 1 度も出ず、`completedBytes > 0` の
    ///    報告は**完了後**の 1 回だけだった。
    ///
    /// `onBytesCopied` は**コピー中に間引きなしで**呼ばれる。ここから書き足せば
    /// 速さに関係なく必ず「処理中に変わった」状態になる。
    @Test func moveDoesNotDeleteASourceThatChangedWhileCopying() async throws {
        // クロスボリュームでなければ `rename(2)` で一瞬に終わり、写す経路を
        // 通らない。別ボリュームを書き込み先にして実コピーさせる。
        guard let volume = TinyVolume.make(megabytes: 300) else { return }
        defer { volume.destroy() }
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }

        let source = root.appendingPathComponent("downloading.bin")
        try Data(count: 20_000_000).write(to: source)
        let target = volume.mountPoint.appendingPathComponent("downloading.bin")

        let once = OneShot()
        var thrown: (any Error)?
        do {
            _ = try FileOperationService.moveItem(from: source, to: target) { _ in
                guard once.fire() else { return }
                // コピーの最中に元へ書き足す（更新日時とサイズが変わる）。
                guard let handle = try? FileHandle(forWritingTo: source) else { return }
                defer { try? handle.close() }
                try? handle.seekToEnd()
                try? handle.write(contentsOf: Data(count: 4_000_000))
            }
        } catch {
            thrown = error
        }

        let error = try #require(thrown as? FileOperationError, "処理中の書き換えを見逃した")
        guard case .sourceChangedDuringOperation = error else {
            Issue.record("書き換えの検出として報告されなかった: \(error)")
            return
        }
        // **ここが本題**: 元が残っていること。
        #expect(FileManager.default.fileExists(atPath: source.path), "★元ファイルを消してしまった★")
        // 書き足された分も含めて無傷であること。
        #expect((try? source.resourceValues(forKeys: [.fileSizeKey]))?.fileSize == 24_000_000)
        // 中途半端なコピーを残していないこと。
        #expect(!FileManager.default.fileExists(atPath: target.path), "中途半端なコピーが残っている")
        #expect(error.localizedDescription.contains("書き換え"))
    }

    /// **更新日時の検査が効かない環境でも、元を消さないこと。**
    ///
    /// 更新日時の精度は書き込み先次第で、実測では FAT が 2 秒（ナノ秒が常に
    /// 0）。NAS の OS は千差万別で、1 秒精度のサーバなら「同じ大きさのまま
    /// 中身が入れ替わる」書き込み（プリアロケートした領域へ書く torrent など）
    /// を取り逃がす。取り逃がした先にあるのは**元ファイルの削除**である。
    ///
    /// ここでは、コピー中に**同じ大きさで中身を差し替えたうえで更新日時を
    /// 元に戻し**、`FileContentStamp` の検査を意図的に無力化する。それでも
    /// 元が残ることを確かめる（`MoveVerification` が受け止める）。
    @Test func moveKeepsTheSourceEvenWhenTimestampsCannotRevealTheChange() async throws {
        guard let volume = TinyVolume.make(megabytes: 300) else { return }
        defer { volume.destroy() }
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }

        let source = root.appendingPathComponent("preallocated.bin")
        try Data(repeating: 0xAA, count: 20_000_000).write(to: source)
        let target = volume.mountPoint.appendingPathComponent("preallocated.bin")

        // 差し替え前の更新日時を控える（あとで戻して検査を無力化する）。
        var original = stat()
        stat(source.path, &original)

        let once = OneShot()
        var thrown: (any Error)?
        do {
            _ = try FileOperationService.moveItem(from: source, to: target) { _ in
                guard once.fire() else { return }
                // **コピーが既に読み終えた領域**（先頭）を、大きさを変えずに
                // 書き換える。まだ読んでいない領域を書き換えても、その内容が
                // そのまま写るだけで欠落は起きない（当初 19MB 地点を書き換えて
                // いて、検証が通るのが正しい状況だと気づかず空振りにしていた）。
                // 先頭なら、写し終えた古い内容が書き込み先に残り、元を消せば
                // 新しい内容が失われる — これが防ぎたい事象そのもの。
                guard let handle = try? FileHandle(forWritingTo: source) else { return }
                try? handle.seek(toOffset: 0)
                try? handle.write(contentsOf: Data(repeating: 0x55, count: 1_000_000))
                try? handle.close()
                // **更新日時をナノ秒まで元へ戻す** — 粗いタイムスタンプの環境を
                // 再現する。`utimes` はマイクロ秒までしか扱えず、ナノ秒が 0 に
                // なって `FileContentStamp` に差が出てしまう（それだと既存の
                // 検査が捕まえてしまい、この検証が空振りになる。実際に一度
                // そうなった）。`utimensat` ならナノ秒を指定できる。
                var times = [original.st_atimespec, original.st_mtimespec]
                _ = utimensat(AT_FDCWD, source.path, &times, 0)
            }
        } catch {
            thrown = error
        }

        // 前提の確認: 更新日時とサイズだけでは見分けられない状態になっていること。
        // （ここが崩れると、この検証は既存の検査を試しているだけになる）
        var afterStat = stat()
        stat(source.path, &afterStat)
        #expect(afterStat.st_size == 20_000_000, "大きさが変わってしまい、前提が崩れている")
        #expect(afterStat.st_mtimespec.tv_sec == original.st_mtimespec.tv_sec, "更新日時（秒）を戻せていない")
        #expect(
            afterStat.st_mtimespec.tv_nsec == original.st_mtimespec.tv_nsec,
            "更新日時（ナノ秒）を戻せておらず、既存の検査で捕まってしまう"
        )

        let error = try #require(thrown as? FileOperationError, "内容の食い違いを見逃した")
        guard case .sourceChangedDuringOperation = error else {
            Issue.record("書き換えの検出として報告されなかった: \(error)")
            return
        }
        // **ここが本題**: 元が残っていること。
        #expect(FileManager.default.fileExists(atPath: source.path), "★元ファイルを消してしまった★")
        #expect(!FileManager.default.fileExists(atPath: target.path), "中途半端なコピーが残っている")
    }

    /// 一度だけ通す箱（コールバックは任意のスレッドから来る）。
    private final class OneShot: @unchecked Sendable {
        private let lock = NSLock()
        private var used = false
        func fire() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if used { return false }
            used = true
            return true
        }
    }

    /// **逆方向の固定** — 誰も書き換えていなければ、移動は普通に完了して
    /// 元が消えること。検査が過敏だと、正当な移動まで断ってしまう。
    @Test func aQuietFileMovesNormally() async throws {
        guard let volume = TinyVolume.make(megabytes: 300) else { return }
        defer { volume.destroy() }
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }

        let source = root.appendingPathComponent("quiet-move.bin")
        try Data(count: 20_000_000).write(to: source)
        let target = volume.mountPoint.appendingPathComponent("quiet-move.bin")

        let outcome = try FileOperationService.moveItem(from: source, to: target) { _ in }
        guard case .completed = outcome else {
            Issue.record("完了として返らなかった: \(outcome)")
            return
        }
        #expect(!FileManager.default.fileExists(atPath: source.path))
        #expect((try? target.resourceValues(forKeys: [.fileSizeKey]))?.fileSize == 20_000_000)
    }

    /// **逆方向の固定** — 誰も書き換えていない普通のコピーは当然通ること。
    /// この検査が過敏だと、正当なコピーまで断ってしまう。
    @Test func aQuietFileCopiesNormally() async throws {
        guard let volume = TinyVolume.make(megabytes: 300) else { return }
        defer { volume.destroy() }
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }

        let source = root.appendingPathComponent("quiet.bin")
        try Data(count: 20_000_000).write(to: source)

        let service = FileOperationService()
        let receipts = try await service.copy(
            [source], to: volume.mountPoint, options: OpOptions(conflictPolicy: .keepBoth)
        )
        #expect(receipts.count == 1)
        let copied = volume.mountPoint.appendingPathComponent(source.lastPathComponent)
        #expect((try? copied.resourceValues(forKeys: [.fileSizeKey]))?.fileSize == 20_000_000)
    }
}
