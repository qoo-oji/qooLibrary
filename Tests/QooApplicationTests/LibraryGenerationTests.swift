import Foundation
import Testing

@testable import QooApplication

//
//  読み直し合図の一本化 [§19.13 #2]。
//
//  以前は合図が 4 系統あり、「DB を触る導線を画面へ足したら `.task(id:)` の鍵も
//  足す」を画面ごとに繰り返していた——足し忘れが実機で 2 度出ている。
//

@MainActor
@Suite("ライブラリの世代番号 [§19.13 #2]")
struct LibraryGenerationTests {

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("qoo-generation-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// **run / undo / redo のどれでも進む。** ⌘Z はビューを通らずに DB を
    /// 変えるので、進まないと取り消した結果が画面に出ない。
    @Test("実行・取り消し・やり直しのすべてで世代番号が進む")
    func everyCommandAdvancesTheGeneration() async throws {
        let generation = LibraryGeneration()
        let stack = CommandStack(generation: generation)
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let before = generation.value
        try await stack.run(CreateFolderCommand(url: root.appendingPathComponent("A")))
        let afterRun = generation.value
        #expect(afterRun > before)

        await stack.undo()
        let afterUndo = generation.value
        #expect(afterUndo > afterRun)

        await stack.redo()
        #expect(generation.value > afterUndo)
    }

    /// **これが `operationHistory.count` を鍵にするのをやめた理由。**
    ///
    /// 操作履歴は上限 500 件で頭打ちになるので、501 回目以降の操作では値が
    /// 動かない——それを `.task(id:)` の鍵にしていた画面は、**長いセッションで
    /// だけ、しかも黙って** ⌘Z に追随しなくなっていた。
    @Test("操作履歴が上限に達しても世代番号は進み続ける")
    func generationKeepsAdvancingAfterTheHistoryCapIsReached() async throws {
        let generation = LibraryGeneration()
        let stack = CommandStack(generation: generation)
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        // 上限（500 件）を超えるまで積む。
        for i in 0..<520 {
            try await stack.run(CreateFolderCommand(url: root.appendingPathComponent("f\(i)")))
        }
        #expect(stack.operationHistory.count == 500, "履歴は頭打ちになる")

        let cappedHistory = stack.operationHistory.count
        let beforeGeneration = generation.value
        try await stack.run(CreateFolderCommand(url: root.appendingPathComponent("last")))

        #expect(stack.operationHistory.count == cappedHistory, "履歴の長さはもう動かない")
        #expect(generation.value > beforeGeneration, "世代番号は進み続ける")
    }
}
