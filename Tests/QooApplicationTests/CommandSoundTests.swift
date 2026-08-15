import Foundation
import QooInfrastructure
import Testing

@testable import QooApplication

/// 再生要求を記録するだけのフェイク。実際に音は鳴らさない。
actor RecordingSoundPlayer: SystemSoundPlaying {
    private(set) var played: [SystemSoundEffect] = []
    func play(_ effect: SystemSoundEffect) { played.append(effect) }
}

@MainActor
@Suite struct CommandSoundTests {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("qoo-sound-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - どのコマンドがどの音を持つか

    @Test func trashUsesTheMoveToTrashSound() {
        let command = TrashCommand(items: [URL(fileURLWithPath: "/tmp/a.txt")])
        #expect(command.completionSound == .moveToTrash)
    }

    @Test func permanentDeleteUsesTheIrreversibleDeletionSound() {
        let command = DeletePermanentlyCommand(items: [URL(fileURLWithPath: "/tmp/a.txt")])
        #expect(command.completionSound == .permanentDelete)
    }

    @Test func compressAndExtractUseTheOperationCompleteSound() {
        let compress = CompressCommand(
            items: [URL(fileURLWithPath: "/tmp/a.txt")],
            destinationName: "a", destinationFolder: URL(fileURLWithPath: "/tmp")
        )
        let extract = ExtractCommand(
            archiveURL: URL(fileURLWithPath: "/tmp/a.zip"),
            destination: URL(fileURLWithPath: "/tmp")
        )
        #expect(compress.completionSound == .operationComplete)
        #expect(extract.completionSound == .operationComplete)
    }

    /// ペースト・複製・D&D（移動／コピー）も完了音を鳴らす。Finder も鳴らす
    /// ［当初「Finder は鳴らさない」と誤って結論し、ユーザーの実機での指摘で
    /// 訂正した］。
    @Test func moveAndCopyUseTheOperationCompleteSound() {
        let dst = URL(fileURLWithPath: "/tmp/dst")
        let src = URL(fileURLWithPath: "/tmp/a.txt")
        #expect(MoveFilesCommand(items: [src], destination: dst).completionSound == .operationComplete)
        #expect(CopyFilesCommand(items: [src], destination: dst).completionSound == .operationComplete)
    }

    /// 一瞬で終わり、結果が画面上ですぐ分かる操作は無音のまま。
    @Test func instantaneousOperationsStaySilent() {
        let dst = URL(fileURLWithPath: "/tmp/dst")
        let src = URL(fileURLWithPath: "/tmp/a.txt")
        #expect(RenameCommand(item: src, newName: "b.txt").completionSound == nil)
        #expect(CreateFolderCommand(url: dst).completionSound == nil)
        #expect(CreateAliasCommand(source: src, destinationFolder: dst).completionSound == nil)
        #expect(SetLockedCommand(items: [src], locked: true).completionSound == nil)
    }

    // MARK: - CompositeCommand

    /// 複数アーカイブの一括展開のように子が N 個あっても、鳴るのは 1 回。
    @Test func compositeAdoptsTheFirstSoundingChild() {
        let silent = FakeCommand(displayName: "A")
        let sounding = FakeCommand(displayName: "B", completionSound: .operationComplete)
        let alsoSounding = FakeCommand(displayName: "C", completionSound: .moveToTrash)
        let composite = CompositeCommand(
            displayName: "複合操作", children: [silent, sounding, alsoSounding]
        )

        #expect(composite.completionSound == .operationComplete)
    }

    @Test func compositeIsSilentWhenNoChildHasASound() {
        let composite = CompositeCommand(
            displayName: "複合操作",
            children: [FakeCommand(displayName: "A"), FakeCommand(displayName: "B")]
        )

        #expect(composite.completionSound == nil)
    }

    // MARK: - CommandStack が鳴らす条件

    @Test func runPlaysTheCompletionSoundOnSuccess() async throws {
        let player = RecordingSoundPlayer()
        let stack = CommandStack(soundPlayer: player)

        try await stack.run(FakeCommand(displayName: "A", completionSound: .moveToTrash))

        #expect(await player.played == [.moveToTrash])
    }

    @Test func runIsSilentForCommandsWithoutASound() async throws {
        let player = RecordingSoundPlayer()
        let stack = CommandStack(soundPlayer: player)

        try await stack.run(FakeCommand(displayName: "A"))

        #expect(await player.played.isEmpty)
    }

    /// 部分成功では鳴らさない。一部失敗した操作を「完了」の音で締めるのは
    /// 誤解を招くため（Finder も鳴らす前にエラーの有無を確認している）。
    @Test func runIsSilentOnPartialSuccess() async throws {
        let player = RecordingSoundPlayer()
        let stack = CommandStack(soundPlayer: player)
        let command = FakeCommand(displayName: "A", completionSound: .moveToTrash)
        command.executeResult = .partial(
            succeeded: 1, failed: [FailedItem(item: "b.txt", reason: "権限がありません")]
        )

        try await stack.run(command)

        #expect(await player.played.isEmpty)
    }

    @Test func runIsSilentWhenTheCommandThrows() async {
        let player = RecordingSoundPlayer()
        let stack = CommandStack(soundPlayer: player)
        let command = FakeCommand(displayName: "A", completionSound: .moveToTrash)
        command.executeError = CocoaError(.fileNoSuchFile)

        _ = try? await stack.run(command)

        #expect(await player.played.isEmpty)
    }

    /// 取り消しでは鳴らさない。音は「その操作が起きたこと」に付随するもので、
    /// ⌘Z で圧縮完了音が鳴るのは意味が逆になるため。
    @Test func undoIsSilent() async throws {
        let player = RecordingSoundPlayer()
        let stack = CommandStack(soundPlayer: player)
        try await stack.run(FakeCommand(displayName: "A", completionSound: .moveToTrash))

        await stack.undo()

        #expect(await player.played == [.moveToTrash])  // run のぶんだけ
    }

    /// やり直しは操作をもう一度起こすので鳴らす。
    @Test func redoPlaysTheSoundAgain() async throws {
        let player = RecordingSoundPlayer()
        let stack = CommandStack(soundPlayer: player)
        try await stack.run(FakeCommand(displayName: "A", completionSound: .moveToTrash))
        await stack.undo()

        await stack.redo()

        #expect(await player.played == [.moveToTrash, .moveToTrash])
    }

    /// 実際のコマンドを `CommandStack` 経由で通したときに鳴ることの確認。
    /// ゴミ箱・完全削除は実 Finder ゴミ箱に触れるため自動テスト対象外で、
    /// 実 I/O を伴わずに検証できる新規フォルダ作成（無音）で経路だけ確かめる。
    @Test func realCommandGoesThroughTheSamePath() async throws {
        let player = RecordingSoundPlayer()
        let stack = CommandStack(soundPlayer: player)
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        try await stack.run(CreateFolderCommand(url: root.appendingPathComponent("New")))

        #expect(await player.played.isEmpty)
    }
}
