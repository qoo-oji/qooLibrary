import Foundation
import QooInfrastructure
import QooKit
import Testing

@testable import QooApplication

/// **一括処理が途中で失敗しても、そこまでに動いた分は取り消せること** [ER-13][ER-16]。
///
/// 以前は `transfer` が失敗した時点で受領書ごと捨てていた。100 件のうち
/// 30 件が実際に移動したあとで 31 件目が失敗すると、**移動済みの 30 件が
/// Undo にも操作履歴にも残らない**。ユーザーから見ると「エラーが出た。
/// でもファイルは動いている。元に戻す手段が無い」という状態になる。
///
/// 途中で失敗させる手段として、**対象の 1 件を実行直前に消しておく**。
/// 「一括処理の最中に他アプリがファイルを消した」という実際に起こる状況で、
/// しかも決定的に再現する（`ENOENT` になる）。
///
/// 当初は「書き込み先に同名フォルダを置く」形にしたが、`.replace` は
/// フォルダも退避して置き換えるため**成功してしまい**、何も検証できなかった。
@MainActor
@Suite struct PartialBatchFailureTests {
    private func sandbox() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("qoo-partial-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func filesMovedBeforeTheFailureRemainUndoable() async throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("src", isDirectory: true)
        let destination = root.appendingPathComponent("dst", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        // 1〜3 件目は普通のファイル。4 件目は「一覧には載っているが、
        // 実行の直前に他アプリが消してしまった」項目として作ってから消す。
        var items: [URL] = []
        for index in 0..<3 {
            let file = source.appendingPathComponent("ok\(index).txt")
            try Data("data\(index)".utf8).write(to: file)
            items.append(file)
        }
        let vanished = source.appendingPathComponent("vanished.txt")
        try Data("doomed".utf8).write(to: vanished)
        items.append(vanished)
        try FileManager.default.removeItem(at: vanished)

        let stack = CommandStack(soundPlayer: SilentSoundPlayer())
        let command = MoveFilesCommand(items: items, destination: destination)
        let result = try await stack.run(command)

        // 例外ではなく「部分的な成功」として返ること。ここが例外だと
        // `CommandStack` が Undo スタックへ積まず、動いた分を戻せなくなる。
        guard case let .partial(succeeded, failed) = result else {
            Issue.record("部分的な成功として返らなかった: \(result)")
            return
        }
        #expect(succeeded == 3)
        #expect(!failed.isEmpty)
        // 失敗の理由が読める文言であること（「エラーN」に潰れない）[ER-03]。
        #expect(!(failed.first?.reason.contains("FileOperationError") ?? true))

        // 実際に 3 件は動いている。
        #expect(try FileManager.default.contentsOfDirectory(atPath: source.path).isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).count == 3)

        // **ここが本題**: 動いた 3 件を ⌘Z で戻せること。
        #expect(stack.canUndo, "Undo スタックに積まれていない")
        await stack.undo()
        let back = try FileManager.default.contentsOfDirectory(atPath: source.path).sorted()
        #expect(back == ["ok0.txt", "ok1.txt", "ok2.txt"], "戻りきっていない: \(back)")
    }

    /// 1 件も動いていない場合は、これまでどおり素の失敗として投げること
    /// （運ぶものが無いのに「部分的な成功」と言わない）。
    @Test func aFailureBeforeAnyProgressIsStillThrown() async throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("src", isDirectory: true)
        let destination = root.appendingPathComponent("dst", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        let vanished = source.appendingPathComponent("vanished.txt")
        try Data("doomed".utf8).write(to: vanished)
        try FileManager.default.removeItem(at: vanished)

        let stack = CommandStack(soundPlayer: SilentSoundPlayer())
        await #expect(throws: (any Error).self) {
            _ = try await stack.run(MoveFilesCommand(items: [vanished], destination: destination))
        }
        #expect(!stack.canUndo)
    }
}

/// テスト中に実際の音を鳴らさないための差し替え。
private struct SilentSoundPlayer: SystemSoundPlaying {
    func play(_ effect: SystemSoundEffect) async {}
}
