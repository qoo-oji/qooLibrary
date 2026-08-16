import Foundation
import QooKit
import Testing

@testable import QooInfrastructure

/// **「置き換える」の途中で落ちても、ユーザーのファイルを見失わないこと**
/// [NV-92]。
///
/// `.replace` は既存の項目を `.qoo-replace-backup-<UUID>` へ退避してから書く。
/// その間に落ちる／切断されると、ユーザーの元ファイルは**先頭がドットの
/// 名前のまま残る**——Finder にも本アプリにも見えないので、ユーザーから
/// 見れば消えている。
@Suite(.serialized) struct ReplaceBackupJournalTests {
    private func makeSandbox() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("qoo-journal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeJournal(in root: URL) -> ReplaceBackupJournal {
        ReplaceBackupJournal(storageURL: root.appendingPathComponent("journal.json"))
    }

    /// **この suite の主眼。** 退避したまま落ちた状況を作り、次の起動で
    /// 元の場所へ戻ることを確かめる。
    @Test func putsBackAnItemLeftBehindByAnInterruptedReplace() throws {
        let root = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = makeJournal(in: root)

        // 「置き換える」の途中で落ちた状態そのもの:
        // 元ファイルは退避名になっていて、元の場所には何も無い。
        let target = root.appendingPathComponent("作品 第01巻.cbz")
        let backup = root.appendingPathComponent(".qoo-replace-backup-\(UUID().uuidString)")
        try Data("ユーザーの大切な中身".utf8).write(to: backup)
        journal.record(backup: backup, target: target)

        let outcomes = journal.recoverAll()

        #expect(outcomes == [.restored(target: target)])
        #expect(FileManager.default.fileExists(atPath: target.path), "元の場所へ戻っていない")
        #expect(!FileManager.default.fileExists(atPath: backup.path), "退避名のものが残っている")
        #expect(try String(contentsOf: target, encoding: .utf8) == "ユーザーの大切な中身")
    }

    /// **元の場所に何かあるなら上書きしない。**
    ///
    /// 「書き込みは実は成功していた（新しい内容が入っている）」か
    /// 「ユーザーが後から別のものを置いた」のどちらかで、どちらの場合も
    /// 上書きすると**今度はそちらを失う**。
    @Test func neverOverwritesWhateverIsNowAtTheTarget() throws {
        let root = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = makeJournal(in: root)

        let target = root.appendingPathComponent("作品 第01巻.cbz")
        let backup = root.appendingPathComponent(".qoo-replace-backup-\(UUID().uuidString)")
        try Data("古い内容".utf8).write(to: backup)
        try Data("新しい内容".utf8).write(to: target)
        journal.record(backup: backup, target: target)

        let outcomes = journal.recoverAll()

        guard case .orphaned = outcomes.first else {
            Issue.record("上書きを避けたことが報告されていない: \(outcomes)")
            return
        }
        #expect(try String(contentsOf: target, encoding: .utf8) == "新しい内容", "既にあったものを潰した")
        #expect(FileManager.default.fileExists(atPath: backup.path), "退避を消してしまっている")
    }

    /// 戻せなかったものは**記録に残す** — 次回起動でもう一度試せるように
    /// （相手がネットワークなら、次は繋がっているかもしれない）。
    @Test func keepsTheRecordWhenItCouldNotPutTheItemBack() throws {
        let root = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = makeJournal(in: root)

        let target = root.appendingPathComponent("作品 第01巻.cbz")
        let backup = root.appendingPathComponent(".qoo-replace-backup-\(UUID().uuidString)")
        try Data("古い内容".utf8).write(to: backup)
        try Data("新しい内容".utf8).write(to: target)
        journal.record(backup: backup, target: target)

        _ = journal.recoverAll()
        // 邪魔をしていたものを取り除けば、次の起動で戻せる。
        try FileManager.default.removeItem(at: target)
        let second = journal.recoverAll()

        #expect(second == [.restored(target: target)], "記録が落ちていて再試行できない")
    }

    /// 正常に片付いた場合は、記録も残らない（通常時にファイルが残り続けない）。
    @Test func forgettingLeavesNothingBehind() throws {
        let root = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = root.appendingPathComponent("journal.json")
        let journal = ReplaceBackupJournal(storageURL: storage)

        let backup = root.appendingPathComponent(".qoo-replace-backup-x")
        journal.record(backup: backup, target: root.appendingPathComponent("a.txt"))
        #expect(FileManager.default.fileExists(atPath: storage.path))
        journal.forget(backup: backup)
        #expect(!FileManager.default.fileExists(atPath: storage.path), "空の記録が残り続けている")
        #expect(journal.recoverAll().isEmpty)
    }

    /// 退避が既に無い（＝実は正常に片付いていた）なら、記録だけを捨てる。
    @Test func dropsRecordsWhoseBackupIsAlreadyGone() throws {
        let root = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = makeJournal(in: root)
        let backup = root.appendingPathComponent(".qoo-replace-backup-missing")
        journal.record(backup: backup, target: root.appendingPathComponent("a.txt"))

        #expect(journal.recoverAll() == [.alreadyClean])
        #expect(journal.recoverAll().isEmpty, "記録が残り続けている")
    }

    /// 記録が壊れていても落ちず、**元ファイルは退避して残す**
    /// （中身はユーザーのファイルの居場所そのものなので、黙って捨てない。
    /// `RegisteredFolderStore`/`VolumeAccessStore` と同じ扱い）。
    @Test func corruptRecordIsPreservedInsteadOfBeingOverwritten() throws {
        let root = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = root.appendingPathComponent("journal.json")
        try Data("これは JSON ではない".utf8).write(to: storage)
        let journal = ReplaceBackupJournal(storageURL: storage)

        #expect(journal.recoverAll().isEmpty)

        let siblings = try FileManager.default.contentsOfDirectory(atPath: root.path)
        #expect(siblings.contains { $0.hasPrefix("journal.json.corrupt-") }, "壊れた記録を退避していない")
    }

    // MARK: - 実際の `.replace` 経路と繋がっていること

    /// **この一連の仕組みの生命線**: 書き込んでいる最中、退避が記録されて
    /// いること。
    ///
    /// ここが漏れると、**いちばん長く開いている窓**——4GB を SMB へ
    /// `.replace` で書く数分間——で落ちたときに、ユーザーの元ファイルの
    /// 居場所を見失う。しかも `record` の呼び出しを消しただけでは、
    /// 「成功したら記録が残らない」系のテストはどれも通ってしまう。
    ///
    /// **実際にコピーが走っている最中を覗く**ことで確かめる。進捗の報告は
    /// 退避を作ったあと・片付ける前にしか来ない。クローンでは 1 バイトも
    /// 運ばず報告も来ないため、**ボリュームをまたぐ本物のコピー**にする
    /// 必要がある。
    ///
    /// - Note: **`moveItem` と `record` のどちらが先か、までは見ていない**
    ///   （実際に順序を入れ替えてもこのテストは通ることを確認済み）。その
    ///   隙間は rename 1 回ぶん＝マイクロ秒で、外から覗く手立てが無い。
    ///   本番の実装が「記録が先」なのは、その一瞬でも見失わないための
    ///   ただ乗りの安全側であって、ここで守れているのは長い窓のほうである。
    @Test func theBackupIsRecordedWhileTheCopyIsInFlight() async throws {
        guard let volume = TinyVolume.make(megabytes: 300) else { return }
        defer { volume.destroy() }
        let root = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: root) }

        // 100ms の間引きを越えるだけの大きさが要る（それより速く終わると
        // 報告が 1 度も出ず、覗く機会が無い）。
        let payload = Data(repeating: 0x41, count: 96 * 1024 * 1024)
        let source = root.appendingPathComponent("作品 第01巻.cbz")
        try payload.write(to: source)
        let destination = volume.mountPoint.appendingPathComponent("dst", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("古い内容".utf8).write(to: destination.appendingPathComponent("作品 第01巻.cbz"))

        let observed = MidFlightObservation()
        let reporter = ProgressReporter { _ in
            observed.note(ReplaceBackupJournal.shared.pendingBackupCount())
        }

        let service = FileOperationService()
        _ = try await service.copy(
            [source], to: destination,
            options: OpOptions(conflictPolicy: .replace, progress: reporter)
        )

        #expect(observed.sawAPendingRecord, "コピー中に記録が残っていない＝退避より後に記録している")
        #expect(ReplaceBackupJournal.shared.pendingBackupCount() == 0, "成功後も記録が残っている")
    }

    /// **通常の（成功する）`.replace` は記録を残さない。**
    /// ここが漏れると、起動のたびに存在しない退避を探しに行くことになる。
    @Test func aSuccessfulReplaceLeavesNoRecordBehind() async throws {
        let root = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("src", isDirectory: true)
        let destination = root.appendingPathComponent("dst", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("新しい".utf8).write(to: source.appendingPathComponent("a.txt"))
        try Data("古い".utf8).write(to: destination.appendingPathComponent("a.txt"))

        // 共有インスタンスを使う経路（`FileOperationService` は
        // `ReplaceBackupJournal.shared` を見る）。既定の置き場所を汚さない
        // よう、この検証の前後で内容を確かめるだけに留める。
        let before = ReplaceBackupJournal.shared.recoverAll().count
        let service = FileOperationService()
        _ = try await service.copy(
            [source.appendingPathComponent("a.txt")],
            to: destination,
            options: OpOptions(conflictPolicy: .replace)
        )
        let after = ReplaceBackupJournal.shared.recoverAll().count

        #expect(after == before, "成功した置き換えが記録を残している")
        #expect(
            try String(contentsOf: destination.appendingPathComponent("a.txt"), encoding: .utf8) == "新しい"
        )
    }
}

/// コピーの最中に覗いた記録の件数を集める。**進捗の報告は別スレッドから
/// 来る**（`FileIO.perform` が借りたディスパッチスレッド）ためロックで守る。
final class MidFlightObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [Int] = []

    func note(_ count: Int) {
        lock.lock(); defer { lock.unlock() }
        counts.append(count)
    }

    var sawAPendingRecord: Bool {
        lock.lock(); defer { lock.unlock() }
        return counts.contains { $0 > 0 }
    }
}
