import Foundation
import QooKit
import Testing

@testable import QooInfrastructure

/// **やってみて失敗するのではなく、始める前に断る** [ER-03]。
///
/// この suite は、監査で見つかった「予防できたはずの失敗」を固定する。
/// いずれも実測で実害を確認したもの。
/// **`.serialized`**: この suite の各検証は使い捨てのディスクイメージを
/// 作って外す。並列に走らせると `hdiutil` が同時に何本も動いてディスクを
/// 圧迫し、FSEvents の到達を待つ別の検証（`DirectoryWatchIntegrationTests`）が
/// 10 秒の猶予でも間に合わなくなることがある。I/O 律速でそもそも並列にする
/// 価値が無いため直列にする。
@Suite(.serialized) struct OperationPreflightTests {
    private func makeSandbox() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("qoo-preflight-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    // MARK: - フォルダを自身の中へ入れる

    /// **実測**: `copyfile(3)` はフォルダを自身の子孫へ再帰コピーしても
    /// 止まらず、332 階層まで自己増殖してから `ENAMETOOLONG` で失敗した。
    /// しかもゴミの木は**ユーザーのフォルダの中に残る**。
    /// 同一ボリュームの移動は `rename(2)` が `EINVAL` で止めてくれるが、
    /// コピーは止まらないので、こちら側で断らなければならない。
    @Test func refusesToCopyAFolderIntoItsOwnDescendant() async throws {
        let root = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("A", isDirectory: true)
        let inside = source.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: source.appendingPathComponent("f.txt"))

        let service = FileOperationService()
        var thrown: (any Error)?
        do { _ = try await service.copy([source], to: inside) } catch { thrown = error }

        let error = try #require(thrown as? FileOperationError)
        guard case .destinationInsideSource = error else {
            Issue.record("自己包含として断られなかった: \(error)")
            return
        }
        #expect(error.localizedDescription.contains("A"))

        // **1 つも作られていない**こと（暴走の残骸が出ないこと）がこの検証の主眼。
        let inSub = try FileManager.default.contentsOfDirectory(atPath: inside.path)
        #expect(inSub.isEmpty, "残骸がある: \(inSub)")
    }

    /// フォルダ自身へのドロップも同じ扱い。
    @Test func refusesToMoveAFolderIntoItself() async throws {
        let root = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("A", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)

        let service = FileOperationService()
        await #expect(throws: FileOperationError.self) {
            _ = try await service.move([source], to: source)
        }
    }

    /// 逆方向の固定 — 検査が厳しすぎて、名前が前方一致するだけの**別**フォルダ
    /// への移動まで断る退行を捕まえる（`A` と `A2` は別物）。
    @Test func allowsMovingIntoASiblingWhoseNameSharesAPrefix() async throws {
        let root = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("A", isDirectory: true)
        let sibling = root.appendingPathComponent("A2", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)

        let service = FileOperationService()
        let receipts = try await service.move([source], to: sibling)
        #expect(receipts.count == 1)
    }

    // MARK: - 名前

    /// **実測**: `/` を含む名前でリネームすると、`appendingPathComponent` が
    /// パス区切りとして解釈し**別フォルダへの移動**になっていた。
    /// ユーザーから見ると「名前を変えたはずのファイルが消える」。
    @Test func refusesToRenameWithAPathSeparator() async throws {
        let root = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let subfolder = root.appendingPathComponent("サブ", isDirectory: true)
        try FileManager.default.createDirectory(at: subfolder, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("orig.txt")
        try Data("x".utf8).write(to: file)

        let service = FileOperationService()
        var thrown: (any Error)?
        do { _ = try await service.rename(file, to: "サブ/新しい名前.txt") } catch { thrown = error }

        let error = try #require(thrown as? FileOperationError)
        guard case .invalidName = error else {
            Issue.record("使えない名前として断られなかった: \(error)")
            return
        }
        // 元のファイルはその場に残り、別フォルダへ移動していないこと。
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: subfolder.path).isEmpty)
    }

    /// **実測**: `withIntermediateDirectories: true` と組み合わさって、
    /// 「1 つのフォルダ」のつもりが入れ子のフォルダ 2 つになっていた。
    @Test func refusesToCreateAFolderWhoseNameContainsASeparator() async throws {
        let root = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: root) }

        let service = FileOperationService()
        await #expect(throws: FileOperationError.self) {
            _ = try await service.createDirectory(at: root.appendingPathComponent("親/子"))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    // MARK: - パス全体の長さ

    /// **実測**: macOS がマウントし得る形式すべて（APFS / HFS+ / exFAT /
    /// FAT12・16・32 / UDF / SMB）で、いずれも 1019〜1023 バイトで
    /// `ENAMETOOLONG` になった。名前 1 つの上限とは別に、パス全体に上限がある。
    @Test func refusesWhenTheResultingPathWouldExceedTheLimit() async throws {
        let root = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: root) }

        // 上限ぎりぎりまで深い書き込み先を作る。
        var deep = root
        while PathLimits.resultingPathBytes(destination: deep, relativePath: "") < 900 {
            deep = deep.appendingPathComponent(String(repeating: "d", count: 60), isDirectory: true)
        }
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)

        // そこへ、収まらない長さの名前を持つ項目を運ぼうとする。
        let source = root.appendingPathComponent(String(repeating: "n", count: 200))
        try Data("x".utf8).write(to: source)

        let service = FileOperationService()
        var thrown: (any Error)?
        do { _ = try await service.copy([source], to: deep) } catch { thrown = error }

        let error = try #require(thrown as? FileOperationError)
        guard case let .pathTooLong(_, _, resulting, limit) = error else {
            Issue.record("パス長として断られなかった: \(error)")
            return
        }
        #expect(resulting > limit)
        #expect(error.localizedDescription.contains("パス"))
        // 書き込み先には何も作られていないこと。
        #expect(try FileManager.default.contentsOfDirectory(atPath: deep.path).isEmpty)
    }

    /// `pathconf` が答えられない形式（実測では exFAT / FAT が -1 を返す）でも
    /// `PATH_MAX` へ落ちて、まともな値になること。
    @Test func pathLimitFallsBackToPathMaxWhenTheVolumeDoesNotReportIt() throws {
        let root = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let limit = PathLimits.maxPathBytes(at: root)
        #expect(limit > 0)
        #expect(limit <= Int(PATH_MAX))
        // 実測では全形式 1024（= PATH_MAX）だった。
        #expect(limit >= 1000)
    }

    // MARK: - 読み取り専用

    /// `VolumeCapability.isReadOnly` は以前から計算されていたのに、
    /// **誰も読んでいなかった**［監査で発見］。
    @Test func readOnlyVolumeIsRejectedForRegistrationWithAReadableReason() async throws {
        guard let volume = TinyVolume.make(megabytes: 20) else { return }
        defer { volume.destroy() }
        guard let readOnly = volume.remountReadOnly() else { return }

        var thrown: (any Error)?
        do { _ = try await VolumeEligibilityChecker().evaluate(readOnly) } catch { thrown = error }

        let error = try #require(thrown as? VolumeEligibilityError)
        guard case .readOnlyVolume = error else {
            Issue.record("読み取り専用として断られなかった: \(error)")
            return
        }
        // 「エラー0」形式へ潰れていないこと [ER-03]。
        #expect(!error.localizedDescription.contains("VolumeEligibilityError"))
        #expect(error.localizedDescription.contains("読み取り専用"))
    }
}
