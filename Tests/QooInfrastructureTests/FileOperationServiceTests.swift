import Foundation
import Testing

@testable import QooInfrastructure

/// `trash()`/`restoreFromTrash()` は `NSWorkspace.shared.recycle` を呼び、
/// 実行環境の実際の Finder ゴミ箱に触れてしまうため、自動テストの対象外とする。
/// 実サンドボックスアプリでの手動検証で確認する（README/コミットログ参照）。
@Suite struct FileOperationServiceTests {
    let service = FileOperationService()

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("qoo-fileops-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func write(_ text: String, to url: URL) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    @Test func createDirectoryMakesAFolder() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let newDir = root.appendingPathComponent("child")
        let receipt = try await service.createDirectory(at: newDir)

        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: newDir.path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
        #expect(receipt.kind == .createDirectory)
        #expect(receipt.after != nil)
    }

    @Test func copyDuplicatesTheFile() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let destDir = root.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)

        let source = root.appendingPathComponent("a.txt")
        try write("hello", to: source)

        let receipts = try await service.copy([source], to: destDir)

        #expect(receipts.count == 1)
        #expect(FileManager.default.fileExists(atPath: source.path)) // 元ファイルは残る
        let copied = destDir.appendingPathComponent("a.txt")
        #expect(FileManager.default.fileExists(atPath: copied.path))
        #expect(try String(contentsOf: copied, encoding: .utf8) == "hello")
    }

    @Test func moveRelocatesTheFile() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let destDir = root.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)

        let source = root.appendingPathComponent("a.txt")
        try write("hello", to: source)

        let receipts = try await service.move([source], to: destDir)

        #expect(receipts.count == 1)
        #expect(!FileManager.default.fileExists(atPath: source.path)) // 元の位置には無い
        #expect(FileManager.default.fileExists(atPath: destDir.appendingPathComponent("a.txt").path))
    }

    @Test func promoteFromStagingMovesTopLevelChildrenOnly() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let staging = root.appendingPathComponent("staging")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let destDir = root.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)

        try write("page1", to: staging.appendingPathComponent("page001.jpg"))
        try FileManager.default.createDirectory(at: staging.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try write("page2", to: staging.appendingPathComponent("sub/page002.jpg"))

        let receipts = try await service.promoteFromStaging(staging, to: destDir)

        #expect(receipts.count == 2) // ステージング直下の2項目（page001.jpg, sub/）
        #expect(FileManager.default.fileExists(atPath: destDir.appendingPathComponent("page001.jpg").path))
        #expect(FileManager.default.fileExists(atPath: destDir.appendingPathComponent("sub/page002.jpg").path))
    }

    @Test func renameChangesTheFileName() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let source = root.appendingPathComponent("old.txt")
        try write("hello", to: source)

        let receipt = try await service.rename(source, to: "new.txt")

        #expect(receipt.toURL.lastPathComponent == "new.txt")
        #expect(!FileManager.default.fileExists(atPath: source.path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("new.txt").path))
    }

    @Test func deletePermanentlyRemovesTheFile() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let target = root.appendingPathComponent("a.txt")
        try write("hello", to: target)

        _ = try await service.deletePermanently([target])

        #expect(!FileManager.default.fileExists(atPath: target.path))
    }

    // MARK: - 完全削除 [FM-14〜FM-18、8章 §8.5]

    /// [ER-13] 1 件の失敗で全体を中断しない。**完全削除で中断すると、
    /// 「実際には消えているのに操作は失敗扱いで記録も残らない」項目が
    /// 生まれ得るため、他の一括操作より強い要件になる。**
    @Test func deletePermanentlyContinuesAfterAFailureAndReportsEachItem() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let first = root.appendingPathComponent("first.txt")
        let third = root.appendingPathComponent("third.txt")
        try write("1", to: first)
        try write("3", to: third)
        let missing = root.appendingPathComponent("does-not-exist.txt")

        let outcome = try await service.deletePermanently([first, missing, third])

        // 存在しない 2 番目で止まらず、3 番目まで削除されている。
        #expect(!FileManager.default.fileExists(atPath: first.path))
        #expect(!FileManager.default.fileExists(atPath: third.path))
        #expect(outcome.succeededCount == 2)
        #expect(outcome.failures.map(\.url) == [missing])
        #expect(!outcome.isCompleteSuccess)
    }

    /// [PD-06] 確認手段が無いとき（resolver 未指定）はロック済み項目を
    /// **消さずにスキップ**する。安全側の既定。
    @Test func deletePermanentlySkipsLockedItemsWhenNoResolverIsProvided() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let locked = root.appendingPathComponent("locked.txt")
        try write("keep me", to: locked)
        try setLocked(locked, true)
        defer { try? setLocked(locked, false) }

        let outcome = try await service.deletePermanently([locked])

        #expect(FileManager.default.fileExists(atPath: locked.path))
        #expect(outcome.skipped == [locked])
        #expect(outcome.succeededCount == 0)
    }

    /// [PD-06][ER-11] resolver が `.delete` を返したらロックを解除して削除する。
    @Test func deletePermanentlyDeletesLockedItemWhenResolverApproves() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let locked = root.appendingPathComponent("locked.txt")
        try write("bye", to: locked)
        try setLocked(locked, true)

        let asked = AskedURLs()
        let outcome = try await service.deletePermanently(
            [locked], options: DeletePermanentlyOptions(lockedItemResolver: { url in
                await asked.record(url)
                return .delete
            })
        )

        #expect(!FileManager.default.fileExists(atPath: locked.path))
        #expect(outcome.succeededCount == 1)
        #expect(await asked.urls == [locked])
    }

    /// フォルダ自身はロックされていなくても、**中にロック済みの項目があれば
    /// 尋ねる**。`FileManager.removeItem` はロック済みの子で失敗し、そこまでに
    /// 消した子だけが失われた中途半端な状態を残すため、先に確認を取る。
    @Test func deletePermanentlyAsksWhenAFolderContainsALockedDescendant() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let folder = root.appendingPathComponent("folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let plain = folder.appendingPathComponent("plain.txt")
        let lockedChild = folder.appendingPathComponent("locked.txt")
        try write("a", to: plain)
        try write("b", to: lockedChild)
        try setLocked(lockedChild, true)

        let asked = AskedURLs()
        let outcome = try await service.deletePermanently(
            [folder], options: DeletePermanentlyOptions(lockedItemResolver: { url in
                await asked.record(url)
                return .delete
            })
        )

        // 尋ねられるのは操作対象（フォルダ）であって、中の 1 件ではない。
        #expect(await asked.urls == [folder])
        #expect(!FileManager.default.fileExists(atPath: folder.path))
        #expect(outcome.succeededCount == 1)
    }

    /// `.unattended`（ステージング等アプリ内部領域の後始末）はロック済みでも
    /// 尋ねずに消す。既定の挙動でスキップされると残骸が永久に残るため。
    @Test func unattendedOptionsDeleteLockedItemsWithoutAsking() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let locked = root.appendingPathComponent("residual.txt")
        try write("residual", to: locked)
        try setLocked(locked, true)

        let outcome = try await service.deletePermanently([locked], options: .unattended)

        #expect(!FileManager.default.fileExists(atPath: locked.path))
        #expect(outcome.isCompleteSuccess)
    }

    /// リンク切れのシンボリックリンクも削除できる。存在チェックに
    /// `fileExists`（リンクを辿る）を使うと「項目が見つかりません」になり
    /// 永久に消せなくなる [レビューで発見した退行]。
    @Test func deletePermanentlyRemovesADanglingSymlink() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let link = root.appendingPathComponent("dangling")
        try FileManager.default.createSymbolicLink(
            at: link, withDestinationURL: root.appendingPathComponent("no-such-target")
        )
        // リンク先は存在しない = fileExists は false を返す。
        #expect(FileManager.default.fileExists(atPath: link.path) == false)

        let outcome = try await service.deletePermanently([link])

        #expect(outcome.succeededCount == 1)
        #expect(outcome.failures.isEmpty)
        #expect((try? FileManager.default.attributesOfItem(atPath: link.path)) == nil)
    }

    /// 削除に失敗したら、そのために外したロックを元に戻す。さもないと
    /// 「消えてもいないのにロックだけ解除された」状態が残る [レビューで発見]。
    @Test func deletePermanentlyRestoresTheLockWhenTheDeletionFails() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let readOnlyDir = root.appendingPathComponent("readonly", isDirectory: true)
        try FileManager.default.createDirectory(at: readOnlyDir, withIntermediateDirectories: true)
        let locked = readOnlyDir.appendingPathComponent("locked.txt")
        try write("x", to: locked)
        try setLocked(locked, true)
        // 親ディレクトリを書き込み不可にすると、子の削除自体が失敗する。
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: readOnlyDir.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: readOnlyDir.path)
            try? setLocked(locked, false)
        }

        let outcome = try await service.deletePermanently([locked], options: .unattended)

        #expect(outcome.succeededCount == 0)
        #expect(outcome.failures.count == 1)
        #expect(FileManager.default.fileExists(atPath: locked.path))
        let stillLocked = (try? locked.resourceValues(forKeys: [.isUserImmutableKey]))?.isUserImmutable
        #expect(stillLocked == true) // ロックが戻っている
    }

    private func setLocked(_ url: URL, _ locked: Bool) throws {
        var mutable = url
        var values = URLResourceValues()
        values.isUserImmutable = locked
        try mutable.setResourceValues(values)
    }

    // MARK: - 衝突処理 [FM-11〜FM-13]

    @Test func conflictSkipLeavesDestinationUntouched() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let destDir = root.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)

        let source = root.appendingPathComponent("a.txt")
        try write("new", to: source)
        let existing = destDir.appendingPathComponent("a.txt")
        try write("original", to: existing)

        let receipts = try await service.copy([source], to: destDir, options: OpOptions(conflictPolicy: .skip))

        #expect(receipts.isEmpty)
        #expect(try String(contentsOf: existing, encoding: .utf8) == "original")
    }

    @Test func conflictReplaceOverwritesDestination() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let destDir = root.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)

        let source = root.appendingPathComponent("a.txt")
        try write("new", to: source)
        let existing = destDir.appendingPathComponent("a.txt")
        try write("original", to: existing)

        let receipts = try await service.copy([source], to: destDir, options: OpOptions(conflictPolicy: .replace))

        #expect(receipts.count == 1)
        #expect(try String(contentsOf: existing, encoding: .utf8) == "new")
    }

    /// [フェーズ1完了時のリソースリーク・ファイル安全性監査で追加、ユーザー
    /// 指摘: 「壊れたファイルで健康なファイルを書き潰してしまうおそれは
    /// 本当にないか」] `.replace` は宛先を即座に削除するのではなく退避してから
    /// 書き込む。書き込みが失敗した場合は退避先から元へ戻し、健康だった
    /// 既存ファイルを失わないことを確認する。退避用の一時ファイルが後始末
    /// されずに残らないことも確認する。
    @Test func conflictReplaceRestoresOriginalDestinationIfWriteFails() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let destDir = root.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)

        // ソースを実在しない状態にし、`copyItem` が必ず失敗するようにする。
        let missingSource = root.appendingPathComponent("missing.txt")
        let existing = destDir.appendingPathComponent("missing.txt")
        try write("original and healthy", to: existing)

        await #expect(throws: (any Error).self) {
            try await service.copy([missingSource], to: destDir, options: OpOptions(conflictPolicy: .replace))
        }

        #expect(try String(contentsOf: existing, encoding: .utf8) == "original and healthy")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: destDir.path)
        #expect(leftovers == ["missing.txt"])
    }

    @Test func conflictKeepBothUsesFinderStyleSuffix() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let destDir = root.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)

        let source = root.appendingPathComponent("a.txt")
        try write("new", to: source)
        try write("original", to: destDir.appendingPathComponent("a.txt"))

        let receipts = try await service.copy([source], to: destDir, options: OpOptions(conflictPolicy: .keepBoth))

        #expect(receipts.count == 1)
        #expect(receipts[0].toURL.lastPathComponent == "a 2.txt") // [CF-01]
        #expect(FileManager.default.fileExists(atPath: destDir.appendingPathComponent("a.txt").path))
        #expect(FileManager.default.fileExists(atPath: destDir.appendingPathComponent("a 2.txt").path))
    }

    @Test func conflictKeepBothIncrementsExistingSuffixInsteadOfStacking() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let destDir = root.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)

        // 移動先に「a 2.txt」が既にある状態で、同名の「a 2.txt」をコピーしようとした場合、
        // 「a 2 2.txt」ではなく「a 3.txt」になるべき [CF-01]。
        let source = root.appendingPathComponent("a 2.txt")
        try write("new", to: source)
        try write("original", to: destDir.appendingPathComponent("a 2.txt"))

        let receipts = try await service.copy([source], to: destDir, options: OpOptions(conflictPolicy: .keepBoth))

        #expect(receipts.count == 1)
        #expect(receipts[0].toURL.lastPathComponent == "a 3.txt")
        #expect(FileManager.default.fileExists(atPath: destDir.appendingPathComponent("a 2.txt").path))
        #expect(FileManager.default.fileExists(atPath: destDir.appendingPathComponent("a 3.txt").path))
    }

    @Test func conflictAskWithoutResolverThrows() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let destDir = root.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)

        let source = root.appendingPathComponent("a.txt")
        try write("new", to: source)
        try write("original", to: destDir.appendingPathComponent("a.txt"))

        await #expect(throws: FileOperationError.self) {
            try await service.copy([source], to: destDir, options: OpOptions(conflictPolicy: .ask))
        }
    }

    @Test func conflictAskDelegatesToResolver() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let destDir = root.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)

        let source = root.appendingPathComponent("a.txt")
        try write("new", to: source)
        try write("original", to: destDir.appendingPathComponent("a.txt"))

        let options = OpOptions(conflictPolicy: .ask, conflictResolver: { _, _ in .keepBoth })
        let receipts = try await service.copy([source], to: destDir, options: options)

        #expect(receipts[0].toURL.lastPathComponent == "a 2.txt")
    }
}

/// `@Sendable` な `lockedItemResolver` から呼ばれた URL を集める。並行に
/// 呼ばれても安全に記録できるよう actor にしている。
private actor AskedURLs {
    var urls: [URL] = []
    func record(_ url: URL) { urls.append(url) }
}

/// 移動が既存の項目を書き潰さないこと [レビューで発見した退行の回帰テスト]。
///
/// 進捗を出すために `FileManager.moveItem` を `rename(2)` へ置き換えた際、
/// **素の `rename(2)` は宛先を黙って上書きする**ため、`FileManager.moveItem`
/// が持っていた安全弁を失っていた。コピー側（`COPYFILE_EXCL`）だけが守られて
/// いる非対称な状態になっており、衝突の解決を取りこぼすと健康なファイルが
/// 消える経路になっていた。
@Suite struct MoveOverwriteSafetyTests {
    private func makeDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("qoo-move-safety-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func moveDoesNotSilentlyOverwriteAnExistingItem() async throws {
        let root = makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceDir = root.appendingPathComponent("from", isDirectory: true)
        let destinationDir = root.appendingPathComponent("to", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destinationDir, withIntermediateDirectories: true)
        try "new".write(to: sourceDir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "existing".write(to: destinationDir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)

        // 衝突方針を `.skip` にして「解決されなかった」状況を作る。
        _ = try await FileOperationService().move(
            [sourceDir.appendingPathComponent("a.txt")], to: destinationDir,
            options: OpOptions(conflictPolicy: .skip)
        )

        // 既存のファイルが残っていること（書き潰されていない）。
        #expect(try String(contentsOf: destinationDir.appendingPathComponent("a.txt"), encoding: .utf8) == "existing")
    }
}
