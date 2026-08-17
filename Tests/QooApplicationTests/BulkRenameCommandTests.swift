import Foundation
import QooInfrastructure
import QooKit
import Testing

@testable import QooApplication

/// 一括リネームの**実行順序**。名前の計算は `BulkRenameTests`（`QooKit`）が
/// 見ているので、ここは「実際にファイルを動かしたときに壊れないか」だけを見る。
@MainActor
@Suite struct BulkRenameCommandTests {
    private func makeFolder(_ names: [String]) throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("qoo-bulk-rename-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in names {
            try name.write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        return folder
    }

    private func names(in folder: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    }

    @Test func renamesEveryItem() async throws {
        let folder = try makeFolder(["a.txt", "b.txt"])
        defer { try? FileManager.default.removeItem(at: folder) }
        let changes = BulkRename.plan(names: ["a.txt", "b.txt"], mode: .addText("済_", placement: .before))

        let result = try await BulkRenameCommand(folder: folder, changes: changes, fileOps: FileOperationService()).execute()

        guard case .success = result else { Issue.record("成功しなかった: \(result)"); return }
        #expect(try names(in: folder) == ["済_a.txt", "済_b.txt"])
    }

    /// [BR-10] **入れ替え。** 一時名を経由しないと、片方を書き潰すか衝突で
    /// 失敗する。ここが崩れるとデータを失うので、実ファイルで確かめる。
    @Test func swappingTwoNamesKeepsBothContents() async throws {
        let folder = try makeFolder(["a.txt", "b.txt"])
        defer { try? FileManager.default.removeItem(at: folder) }
        let changes = [
            BulkRename.Change(originalName: "a.txt", newName: "b.txt"),
            BulkRename.Change(originalName: "b.txt", newName: "a.txt"),
        ]

        let result = try await BulkRenameCommand(folder: folder, changes: changes, fileOps: FileOperationService()).execute()

        guard case .success = result else { Issue.record("成功しなかった: \(result)"); return }
        #expect(try names(in: folder) == ["a.txt", "b.txt"])
        // 中身が入れ替わっていること（＝どちらも失われていない）。
        #expect(try String(contentsOf: folder.appendingPathComponent("a.txt"), encoding: .utf8) == "b.txt")
        #expect(try String(contentsOf: folder.appendingPathComponent("b.txt"), encoding: .utf8) == "a.txt")
    }

    /// [BR-10] **ずらし。** 1→2, 2→3 は既存の名前を踏むので、これも一時名が要る。
    @Test func shiftingNamesDoesNotLoseAnyFile() async throws {
        let folder = try makeFolder(["1.txt", "2.txt", "3.txt"])
        defer { try? FileManager.default.removeItem(at: folder) }
        let changes = [
            BulkRename.Change(originalName: "1.txt", newName: "2.txt"),
            BulkRename.Change(originalName: "2.txt", newName: "3.txt"),
            BulkRename.Change(originalName: "3.txt", newName: "4.txt"),
        ]

        _ = try await BulkRenameCommand(folder: folder, changes: changes, fileOps: FileOperationService()).execute()

        #expect(try names(in: folder) == ["2.txt", "3.txt", "4.txt"])
        #expect(try String(contentsOf: folder.appendingPathComponent("2.txt"), encoding: .utf8) == "1.txt")
        #expect(try String(contentsOf: folder.appendingPathComponent("4.txt"), encoding: .utf8) == "3.txt")
    }

    /// [BR-11] 1 つの Undo 単位として、全部まとめて元に戻る。
    @Test func undoRestoresEveryOriginalName() async throws {
        let folder = try makeFolder(["a.txt", "b.txt"])
        defer { try? FileManager.default.removeItem(at: folder) }
        let changes = BulkRename.plan(names: ["a.txt", "b.txt"], mode: .addText("済_", placement: .before))
        let command = BulkRenameCommand(folder: folder, changes: changes, fileOps: FileOperationService())
        _ = try await command.execute()

        let undo = try await command.undo()

        guard case .complete = undo else { Issue.record("完全には戻らなかった: \(undo)"); return }
        #expect(try names(in: folder) == ["a.txt", "b.txt"])
    }

    /// 入れ替えの Undo も入れ替え（＝これも 2 パスが要る）。
    @Test func undoOfASwapAlsoNeedsTwoPasses() async throws {
        let folder = try makeFolder(["a.txt", "b.txt"])
        defer { try? FileManager.default.removeItem(at: folder) }
        let command = BulkRenameCommand(
            folder: folder,
            changes: [
                BulkRename.Change(originalName: "a.txt", newName: "b.txt"),
                BulkRename.Change(originalName: "b.txt", newName: "a.txt"),
            ],
            fileOps: FileOperationService()
        )
        _ = try await command.execute()

        let undo = try await command.undo()

        guard case .complete = undo else { Issue.record("完全には戻らなかった: \(undo)"); return }
        #expect(try String(contentsOf: folder.appendingPathComponent("a.txt"), encoding: .utf8) == "a.txt")
        #expect(try String(contentsOf: folder.appendingPathComponent("b.txt"), encoding: .utf8) == "b.txt")
    }

    /// **第 2 パスの途中で失敗しても、一時名（UUID）のまま取り残さない**
    /// [フェーズ1完了時の監査で発見]。連鎖リネーム（1→2, 2→不正な名前）の
    /// 2 件目が失敗する形で再現する: 以前は残りが
    /// `<uuid>.qoo-bulk-rename-tmp` のまま放置され、Undo でも戻せなかった。
    @Test func phaseTwoFailureDoesNotStrandTemporaryNames() async throws {
        let folder = try makeFolder(["1.txt", "2.txt"])
        defer { try? FileManager.default.removeItem(at: folder) }
        let changes = [
            BulkRename.Change(originalName: "1.txt", newName: "2.txt"),
            // "/" を含む名前は `FileOperationService.rename` の検証が拒否する
            // → 第 2 パス（一時名 → 目的の名前）で必ず失敗する。
            BulkRename.Change(originalName: "2.txt", newName: "bad/name.txt"),
        ]

        await #expect(throws: (any Error).self) {
            _ = try await BulkRenameCommand(folder: folder, changes: changes, fileOps: FileOperationService()).execute()
        }

        // 一時名のファイルが 1 つも残っていないことが要点。失敗した項目は
        // 元の名前（衝突していれば「元の名前 2」）として見える形で残る。
        let remaining = try names(in: folder)
        #expect(remaining.allSatisfy { !$0.hasSuffix(".qoo-bulk-rename-tmp") }, "残骸: \(remaining)")
        #expect(remaining.count == 2)
    }

    /// 名前が変わらない行は触らない（Undo スタックを無意味に汚さない）。
    @Test func unchangedRowsAreLeftAlone() async throws {
        let folder = try makeFolder(["a.txt"])
        defer { try? FileManager.default.removeItem(at: folder) }
        let changes = [BulkRename.Change(originalName: "a.txt", newName: "a.txt")]

        let result = try await BulkRenameCommand(folder: folder, changes: changes, fileOps: FileOperationService()).execute()

        guard case .success = result else { Issue.record("成功しなかった: \(result)"); return }
        #expect(try names(in: folder) == ["a.txt"])
    }
}
