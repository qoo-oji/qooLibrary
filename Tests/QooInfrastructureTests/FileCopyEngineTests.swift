import Foundation
import Testing

@testable import QooInfrastructure

/// バイトを運ぶ経路そのもの [UI-09][A-04]。**もっとも安全性が重要な箇所**
/// （`FileManager.copyItem` から差し替えたため）なので、速い経路が速いまま
/// であること・中断がデータを壊さないことを固定する。
@Suite struct FileCopyEngineTests {
    private func makeDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("qoo-copy-engine-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeFile(_ url: URL, megabytes: Int) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        for _ in 0..<megabytes { handle.write(Data(repeating: 0xAB, count: 1_000_000)) }
        try handle.close()
    }

    private func supportsCloning(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.volumeSupportsFileCloningKey]))?.volumeSupportsFileCloning == true
    }

    @Test func copiesFileContents() throws {
        let root = makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("a.bin")
        try makeFile(source, megabytes: 2)
        let destination = root.appendingPathComponent("b.bin")

        _ = try FileCopyEngine.copy(from: source, to: destination) { _ in }

        #expect(try Data(contentsOf: destination) == Data(contentsOf: source))
    }

    /// **同一ボリュームのコピーは 1 バイトも運ばない** — つまりクローンが
    /// 効いている。`COPYFILE_CLONE` を落とすとここが崩れ、同じ操作が実コピーに
    /// 退行して時間もディスクも食う（実測: 1GB で 3ms → 335ms）。
    @Test func copyOnTheSameVolumeIsAClone() throws {
        let root = makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try #require(supportsCloning(root), "クローンできないボリューム上では意味を持たない検査")
        let source = root.appendingPathComponent("a.bin")
        try makeFile(source, megabytes: 8)

        let outcome = try FileCopyEngine.copy(from: source, to: root.appendingPathComponent("b.bin")) { _ in }

        guard case .completed(let bytes) = outcome else {
            Issue.record("完了しなかった")
            return
        }
        #expect(bytes == 0)
    }

    /// クローンできない経路では、運んだバイト数が実サイズと一致する
    /// （これが進捗表示の元になる）。
    @Test func realCopyReportsEveryByte() throws {
        let root = makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("a.bin")
        try makeFile(source, megabytes: 4)
        var reported: Int64 = 0

        let outcome = try FileCopyEngine.copy(
            from: source, to: root.appendingPathComponent("b.bin"), allowsCloning: false
        ) { reported += $0 }

        guard case .completed(let bytes) = outcome else {
            Issue.record("完了しなかった")
            return
        }
        #expect(bytes == 4_000_000)
        #expect(reported == 4_000_000)
    }

    /// 中断しても**書きかけのファイルを残さない**。残すと、見た目は揃っている
    /// のに中身が途中までしかないファイルができてしまう。
    @Test func cancellationLeavesNoPartialFile() async throws {
        let root = makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("a.bin")
        try makeFile(source, megabytes: 8)
        let destination = root.appendingPathComponent("b.bin")

        // 先に取り消してから走らせる。最初のコールバックで確実に降りるため、
        // 「間に合うかどうか」に依存しない検査になる。
        let task = Task {
            try FileCopyEngine.copy(from: source, to: destination, allowsCloning: false) { _ in }
        }
        task.cancel()
        let outcome = try await task.value

        guard case .cancelled = outcome else {
            Issue.record("中断されなかった")
            return
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test func copiesDirectoriesRecursively() throws {
        let root = makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("tree", isDirectory: true)
        try FileManager.default.createDirectory(at: source.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try "hello".write(to: source.appendingPathComponent("sub/a.txt"), atomically: true, encoding: .utf8)
        let destination = root.appendingPathComponent("copy", isDirectory: true)

        _ = try FileCopyEngine.copy(from: source, to: destination) { _ in }

        #expect(try String(contentsOf: destination.appendingPathComponent("sub/a.txt"), encoding: .utf8) == "hello")
    }

    /// [SL-01] リンクは**追跡せず**リンクのまま複製する。追跡すると、リンク先の
    /// 巨大な実体を意図せず丸ごとコピーしてしまう。
    @Test func symbolicLinksAreCopiedAsLinksNotFollowed() throws {
        let root = makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("target.txt")
        try "payload".write(to: target, atomically: true, encoding: .utf8)
        let link = root.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let destination = root.appendingPathComponent("copied-link.txt")

        _ = try FileCopyEngine.copy(from: link, to: destination) { _ in }

        let values = try destination.resourceValues(forKeys: [.isSymbolicLinkKey])
        #expect(values.isSymbolicLink == true)
    }

    /// 宛先が既にあれば失敗する（`COPYFILE_EXCL`）。衝突は呼び出し側が先に
    /// 解決する約束だが、取りこぼしたときに黙って上書きしないための安全弁。
    @Test func refusesToOverwriteAnExistingDestination() throws {
        let root = makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("a.txt")
        try "new".write(to: source, atomically: true, encoding: .utf8)
        let destination = root.appendingPathComponent("b.txt")
        try "existing".write(to: destination, atomically: true, encoding: .utf8)

        #expect(throws: (any Error).self) {
            _ = try FileCopyEngine.copy(from: source, to: destination) { _ in }
        }
        #expect(try String(contentsOf: destination, encoding: .utf8) == "existing")
    }
}
