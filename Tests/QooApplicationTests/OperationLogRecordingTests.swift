//
//  操作履歴の書き手 [HS-01][OH-01〜OH-03][15章 §15.13]。
//
//  **`CommandStack.record()` を通る経路をすべて固定する。** 実行・取り消し・
//  やり直し・部分取り消し・失敗・中断の 6 つで、どれか 1 つでも記録が
//  抜けると履歴が「何も起きなかった」と嘘をつく——とくに失敗は、
//  `PartialTransferFailure` のように**ファイルが動いていても失敗として
//  投げられる**ものがあるため外せない。
//
import Foundation
import QooInfrastructure
import QooKit
import Testing

@testable import QooApplication

/// メモリ上のストア。**永続化層を経由せずに書き手だけを試す**ため。
final class SpyOperationLogStore: OperationLogStore, @unchecked Sendable {
    private let lock = NSLock()
    private var rows: [OperationLogDraft] = []
    private var purges: [(retentionDays: Int, maxCount: Int)] = []
    var failNextAppend = false

    var drafts: [OperationLogDraft] { lock.lock(); defer { lock.unlock() }; return rows }
    var purgeCalls: [(retentionDays: Int, maxCount: Int)] {
        lock.lock(); defer { lock.unlock() }; return purges
    }

    struct AppendFailure: Error {}

    func append(_ draft: OperationLogDraft) async throws -> OperationLogID {
        // `NSLock.lock()` は async 関数の本体から呼べない（`noasync`）ので
        // 同期ヘルパーへ退避する（このコードベースで繰り返し踏んでいる罠）。
        try appendSync(draft)
    }

    private func appendSync(_ draft: OperationLogDraft) throws -> OperationLogID {
        lock.lock()
        defer { lock.unlock() }
        if failNextAppend { failNextAppend = false; throw AppendFailure() }
        rows.append(draft)
        return OperationLogID(rawValue: Int64(rows.count))
    }

    func query(_ filter: OperationLogFilter) async throws -> [OperationLogEntry] { [] }
    func count() async throws -> Int { drafts.count }

    func purgeExpired(retentionDays: Int, maxCount: Int) async throws {
        purgeSync(retentionDays: retentionDays, maxCount: maxCount)
    }

    private func purgeSync(retentionDays: Int, maxCount: Int) {
        lock.lock()
        defer { lock.unlock() }
        purges.append((retentionDays, maxCount))
    }
}

@MainActor
@Suite("操作履歴の書き手 [HS-01][OH-01]")
struct OperationLogRecordingTests {

    /// 書き手が実際に 1 件書くまで待つ。**件数で待つ**——`record` は
    /// `Task` で投げるので、時間で待つと負荷次第で落ちる。
    private func waitForRows(_ store: SpyOperationLogStore, count: Int,
                             within seconds: Double = 3) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while store.drafts.count < count, Date() < deadline {
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        #expect(store.drafts.count >= count)
    }

    private func attached() async -> (OperationLogRecorder, SpyOperationLogStore) {
        let store = SpyOperationLogStore()
        let recorder = OperationLogRecorder()
        await recorder.attach(store, retentionDays: 90, maxCount: 1_000)
        return (recorder, store)
    }

    // MARK: - `record()` を通る 6 経路

    @Test("実行が記録される")
    func executionIsRecorded() async throws {
        let (recorder, store) = await attached()
        let stack = CommandStack(operationLog: recorder)
        try await stack.run(FakeCommand(displayName: "「A.cbz」を移動"))
        try await waitForRows(store, count: 1)
        let draft = try #require(store.drafts.first)
        #expect(draft.kind == .executed)
        #expect(draft.summary == "「A.cbz」を移動")
        #expect(draft.commandName == "FakeCommand")
    }

    @Test("取り消し・やり直しがそれぞれ 1 行として足される")
    func undoAndRedoAppendRows() async throws {
        let (recorder, store) = await attached()
        let stack = CommandStack(operationLog: recorder)
        try await stack.run(FakeCommand(displayName: "移動"))
        _ = await stack.undo()
        _ = await stack.redo()
        try await waitForRows(store, count: 3)
        #expect(store.drafts.map(\.kind) == [.executed, .undone, .redone])
    }

    /// **「失敗」でありながらファイルが動いているものがある**
    /// （`PartialTransferFailure`）ので、記録しないと履歴が嘘をつく。
    @Test("実行の失敗も記録される [HS-01]")
    func failureIsRecorded() async throws {
        let (recorder, store) = await attached()
        let stack = CommandStack(operationLog: recorder)
        let command = FakeCommand(displayName: "移動")
        struct Boom: LocalizedError { var errorDescription: String? { "書き込めません" } }
        command.executeError = Boom()
        await #expect(throws: Boom.self) { try await stack.run(command) }
        try await waitForRows(store, count: 1)
        let draft = try #require(store.drafts.first)
        #expect(draft.kind == .failed)
        #expect(draft.detail == "書き込めません")
    }

    /// **中断は失敗ではない**（ユーザー自身の意思）。同じ区画に入れると、
    /// 「うまくいかなかったもの」を見たいときにキャンセルが紛れる。
    @Test("中断は失敗と別の種別で記録される")
    func cancellationIsRecordedSeparately() async throws {
        let (recorder, store) = await attached()
        let stack = CommandStack(operationLog: recorder)
        let command = FakeCommand(displayName: "展開")
        command.executeError = CancellationError()
        await #expect(throws: CancellationError.self) { try await stack.run(command) }
        try await waitForRows(store, count: 1)
        #expect(store.drafts.first?.kind == .cancelled)
        #expect(store.drafts.first?.detail == nil)
    }

    @Test("部分的な取り消しは件数を詳細に残す")
    func partialUndoKeepsCounts() async throws {
        let (recorder, store) = await attached()
        let stack = CommandStack(operationLog: recorder)
        let command = FakeCommand(displayName: "移動")
        command.undoResult = .partial(succeeded: 3,
                                      failed: [FailedItem(item: "/a", reason: "x")])
        try await stack.run(command)
        _ = await stack.undo()
        try await waitForRows(store, count: 2)
        #expect(store.drafts.last?.kind == .undonePartially)
        #expect(store.drafts.last?.detail == "成功 3 件 / 失敗 1 件")
    }

    @Test("取り消しの失敗は理由を残す")
    func undoFailureKeepsReason() async throws {
        let (recorder, store) = await attached()
        let stack = CommandStack(operationLog: recorder)
        let command = FakeCommand(displayName: "移動")
        command.undoResult = .impossible(reason: "元の場所がありません")
        try await stack.run(command)
        _ = await stack.undo()
        try await waitForRows(store, count: 2)
        #expect(store.drafts.last?.kind == .undoFailed)
        #expect(store.drafts.last?.detail == "元の場所がありません")
    }

    // MARK: - 対象 [OH-01]

    /// **既定実装は `logDescription` の印付きパスを拾う。** 自由文の推測では
    /// なく、書き込み側が `Log.path(_:)` で明示した範囲を読んでいる。
    @Test("印の無い説明からは対象を取らない")
    func defaultTargetsComeFromMarkedPathsOnly() async throws {
        let (recorder, store) = await attached()
        let stack = CommandStack(operationLog: recorder)
        // `FakeCommand` は `logDescription` を上書きしないので既定実装
        // （`displayName`）が使われ、印が 1 つも無い。
        try await stack.run(FakeCommand(displayName: "ラベル「A」を改名"))
        try await waitForRows(store, count: 1)
        #expect(store.drafts.first?.targets.isEmpty == true)
    }

    /// 対象の一覧を手元に持つコマンドは**必ずオーバーライドする**
    /// ——`logDescription` は 1 行を短く保つために先頭 5 件で打ち切るので、
    /// 既定実装のままだと 1,000 件の一括処理が「5 件」として記録される。
    @Test("URL を持つコマンドは全件を対象にする")
    func commandsWithURLsReportEveryTarget() async throws {
        let (recorder, store) = await attached()
        let stack = CommandStack(operationLog: recorder)
        let items = (0..<8).map { URL(fileURLWithPath: "/Volumes/X/\($0).cbz") }
        let command = TrashCommand(items: items)
        #expect(command.logTargets.count == 8)
        // 既定実装（`logDescription` からの抽出）だと 5 件しか拾えないことも
        // 併せて固定する——ここが縮んだらオーバーライドが外れた合図。
        #expect(Log.paths(in: command.logDescription).count == 5)
        _ = stack   // 実行はディスクに触れるのでここでは行わない
    }

    // MARK: - ストアが繋がる前

    /// 起動直後の操作（退避記録の復旧 [NV-92] 等）は `bootstrap()` より前に
    /// 走りうる。**溜めて、繋がったら流し込む。**
    @Test("繋がる前の記録は溜めてから流し込む")
    func draftsBeforeAttachAreFlushed() async throws {
        let recorder = OperationLogRecorder()
        recorder.record(OperationLogDraft(commandName: "X", kind: .executed, summary: "早い"))
        let store = SpyOperationLogStore()
        await recorder.attach(store, retentionDays: 90, maxCount: 1_000)
        #expect(store.drafts.map(\.summary) == ["早い"])
    }

    /// **1 件の失敗で残りを失わない**［レビューで発見］。`pendingBeforeStore` は
    /// 流し込む前に空にしてあるので、ループ全体を `do/catch` で囲むと
    /// 2 件目が投げた時点で 3 件目以降が**どこにも残らずに消える**。
    @Test("流し込みの途中で失敗しても残りは書かれる")
    func oneFailureDoesNotDropTheRest() async throws {
        let recorder = OperationLogRecorder()
        for i in 0..<3 {
            recorder.record(OperationLogDraft(commandName: "X", kind: .executed,
                                              summary: "\(i)"))
        }
        let store = SpyOperationLogStore()
        store.failNextAppend = true          // 1 件目だけ失敗させる
        await recorder.attach(store, retentionDays: 90, maxCount: 1_000)
        #expect(store.drafts.map(\.summary) == ["1", "2"])
        // **掃除も別に守る**——追記の失敗に巻き込まれて飛ぶと、掃除の契機は
        // 起動時 1 度きりなので次の起動まで上限が効かない。
        #expect(store.purgeCalls.count == 1)
    }

    @Test("繋いだ時点で 1 度だけ掃除する [HS-04]")
    func purgesOnceOnAttach() async throws {
        let (_, store) = await attached()
        #expect(store.purgeCalls.count == 1)
        #expect(store.purgeCalls.first?.retentionDays == 90)
        #expect(store.purgeCalls.first?.maxCount == 1_000)
    }

    /// **書き込みの失敗で本体の操作を止めない。** 履歴に残せなかったことを
    /// 理由に、利用者が頼んだ操作を失敗させるのは本末転倒。
    @Test("履歴に書けなくても操作は成功する")
    func appendFailureDoesNotBreakTheCommand() async throws {
        let (recorder, store) = await attached()
        store.failNextAppend = true
        let stack = CommandStack(operationLog: recorder)
        try await stack.run(FakeCommand(displayName: "移動"))
        #expect(stack.canUndo)
    }
}

@Suite("操作履歴への写像 [OH-01]")
struct OperationLogDraftMappingTests {

    /// **種別は 1 対 1 で写す。** 取りこぼすと、その経路の行だけ別の区画に
    /// 並んで「取り消したはずのものが実行として残る」ことになる。
    @Test("すべての `Action` が固有の種別へ写る")
    func everyActionMapsToADistinctKind() {
        let actions: [OperationHistoryEntry.Action] = [
            .executed, .failed(reason: "x"), .cancelled, .undone,
            .undonePartially(succeeded: 1, failedCount: 1),
            .undoFailed(reason: "x"), .redone, .redoFailed(reason: "x"),
        ]
        let kinds = actions.map(\.logKind)
        #expect(Set(kinds).count == actions.count)
        // `.scan` だけはコマンド由来ではない（走査が直接書く）。
        #expect(!kinds.contains(.scan))
    }

    @Test("理由を持つ `Action` だけが詳細を残す")
    func onlyActionsWithReasonsCarryDetail() {
        #expect(OperationHistoryEntry.Action.executed.logDetail == nil)
        #expect(OperationHistoryEntry.Action.cancelled.logDetail == nil)
        #expect(OperationHistoryEntry.Action.failed(reason: "だめ").logDetail == "だめ")
    }
}

@MainActor
@Suite("走査の記録 [OH-03][HS-03]", .serialized)
struct ScanOperationLogTests {

    private func waitForRows(_ store: any OperationLogStore, count: Int,
                             within seconds: Double = 3) async throws -> [OperationLogEntry] {
        let deadline = Date().addingTimeInterval(seconds)
        var rows = try await store.query(OperationLogFilter())
        while rows.count < count, Date() < deadline {
            try await Task.sleep(nanoseconds: 5_000_000)
            rows = try await store.query(OperationLogFilter())
        }
        return rows
    }

    /// **1 回の走査を 1 行に畳む。** ファイルごとに行を作ると、5 万件の
    /// 初回走査だけで保持件数 [HS-04] を使い切る。
    @Test("手動の走査は 1 行として記録される")
    func manualScanIsRecordedAsOneRow() async throws {
        // 走査の記録だけを見たいので、作業領域に**独立した書き手**を挿す
        // （既定の `.shared` はテスト中は繋がれない）。
        let w = try ServicesWorkspace(operationLogRecorder: OperationLogRecorder())
        await w.bootstrap()
        try w.write("(同人誌) [サークル値A (著者値1)] 作品タイトル1 (ジャンル値1).cbz")
        try w.write("(同人誌) [サークル値B (著者値2)] 作品タイトル2 (ジャンル値2).cbz")
        let id = try await w.enable()
        let store = try #require(w.services.operationLog)
        #expect(try await store.count() == 0, "登録しただけでは走査していない")

        _ = try await w.services.scan(libraryID: id)
        let rows = try await waitForRows(store, count: 1)
        #expect(rows.count == 1, "5 万件でも 1 行に畳む")
        let row = try #require(rows.first)
        #expect(row.kind == .scan)
        #expect(row.commandName == "scan")
        #expect(row.libraryUUID == w.registrationUUID)
        #expect(row.targets == [w.libraryRoot.path], "対象はライブラリの根 1 つ")
        #expect(row.detail?.contains("追加 2") == true)
    }

    /// **中身が変わらなくても手動は残す。** 利用者が明示的に頼んだ操作で、
    /// 「走らせたのに履歴に無い」ほうが分かりにくい。
    @Test("変化の無い手動の再走査も記録される")
    func unchangedManualRescanIsStillRecorded() async throws {
        let w = try ServicesWorkspace(operationLogRecorder: OperationLogRecorder())
        await w.bootstrap()
        try w.write("(同人誌) [サークル値A (著者値1)] 作品タイトル1 (ジャンル値1).cbz")
        let id = try await w.enable()
        let store = try #require(w.services.operationLog)
        _ = try await w.services.scan(libraryID: id)
        _ = try await waitForRows(store, count: 1)
        _ = try await w.services.scan(libraryID: id)
        let rows = try await waitForRows(store, count: 2)
        #expect(rows.count == 2)
    }
}

/// 走査を記録するかの判定 [OH-03]。
///
/// **自動走査の経路（`sync.onScanFinished`）はテストから組み立てにくい**
/// ので、判定を純粋関数として切り出して固定する。
@Suite("走査を記録するかの判定 [OH-03]")
struct ShouldRecordScanTests {

    private func summary(added: Int = 0, updated: Int = 0, reidentified: Int = 0,
                         orphaned: Int = 0, unresolved: Int = 0,
                         skipped: Bool = false) -> ScanSummary {
        var s = ScanSummary(skipped: skipped)
        s.added = added
        s.updated = updated
        s.reidentified = reidentified
        s.orphaned = orphaned
        s.unresolvedNames = unresolved
        return s
    }

    @Test("走らなかった走査は記録しない [SB-05]")
    func skippedIsNeverRecorded() {
        #expect(!LibraryServices.shouldRecordScan(summary(added: 5, skipped: true), manual: true))
        #expect(!LibraryServices.shouldRecordScan(summary(skipped: true), manual: false))
    }

    @Test("手動は結果によらず記録する")
    func manualIsAlwaysRecorded() {
        #expect(LibraryServices.shouldRecordScan(summary(), manual: true))
    }

    /// **`updated` は変化の証拠にならない**——不変のファイルを再走査しても
    /// 更新として数えられる（実測: 2 回目が「追加 0 / 更新 12 / 孤立 0」）。
    /// ここを数えると、外部でファイルを触るたびに履歴が伸びる。
    @Test("自動走査は `updated` だけでは記録しない")
    func updatedAloneIsNotAChange() {
        #expect(!LibraryServices.shouldRecordScan(summary(updated: 12), manual: false))
    }

    /// **未整理の件数も「変化」ではない**——状態であって、この走査で
    /// 起きたことではない。
    @Test("自動走査は未整理の件数だけでは記録しない")
    func unresolvedCountAloneIsNotAChange() {
        #expect(!LibraryServices.shouldRecordScan(summary(unresolved: 3), manual: false))
    }

    @Test("自動走査でも実際の変化があれば記録する")
    func automaticRecordsRealChanges() {
        #expect(LibraryServices.shouldRecordScan(summary(added: 1), manual: false))
        #expect(LibraryServices.shouldRecordScan(summary(orphaned: 1), manual: false))
        #expect(LibraryServices.shouldRecordScan(summary(reidentified: 1), manual: false))
    }
}

@MainActor
@Suite("一括コマンドの対象 [OH-01]")
struct BulkCommandLogTargetsTests {

    /// **対象の一覧を手元に持つコマンドは必ずオーバーライドする**
    /// ——`Self.logDescription` は 1 行を短く保つために**先頭数件で打ち切る**
    /// ので、既定実装のままだと「12 冊へ適用」が「5 件」として記録される
    /// ［レビューで発見。`Command.logTargets` の doc が定めている条件そのもの］。
    @Test("シリーズ全巻への評価は全件を対象にする [RA-04]")
    func ratingReportsEveryTarget() throws {
        let urls = (0..<12).map { URL(fileURLWithPath: "/Volumes/X/第\($0)巻.cbz") }
        let command = SetRatingCommand(
            targets: urls.enumerated().map {
                RatingTarget(id: FileID(rawValue: Int64($0.offset)), url: $0.element,
                             previousStars: 0)
            },
            stars: 4, subjectName: "作品A", seriesName: "作品A",
            services: LibraryServices())
        #expect(command.logTargets.count == 12)
        // 既定実装（`logDescription` からの抽出）だと 5 件しか拾えない
        // ——ここが縮んだらオーバーライドが外れた合図。
        #expect(Log.paths(in: command.logDescription).count == 5)
    }

    /// **保管庫はフォルダ単位で動く** [FDA-01]——`logDescription` は
    /// 先頭 3 件で打ち切るので、既定実装のままだと 30 冊のフォルダを
    /// 保管庫へ入れた記録が「3 件」になる。
    @Test("フォルダ単位の保管庫移動は全件を対象にする [FA-01]")
    func vaultReportsEveryTarget() throws {
        let root = URL(fileURLWithPath: "/Volumes/X")
        let command = SetFileArchivedCommand(
            targets: (0..<7).map {
                SetFileArchivedCommand.Target(id: FileID(rawValue: Int64($0)),
                                              relativePath: "作者A/\($0).cbz")
            },
            archived: true, root: root, services: LibraryServices())
        #expect(command.logTargets.count == 7)
        #expect(command.logTargets.first == "/Volumes/X/作者A/0.cbz")
        // 既定実装（`logDescription` からの抽出）だと 3 件しか拾えない。
        #expect(Log.paths(in: command.logDescription).count == 3)
    }

    @Test("複数選択の一括ラベル付与は全件を対象にする [RP-02]")
    func labelAssignmentReportsEveryTarget() throws {
        let urls = (0..<9).map { URL(fileURLWithPath: "/Volumes/X/\($0).cbz") }
        let command = AssignLabelCommand(
            labelID: LabelID(rawValue: 1), fieldID: FieldID(rawValue: 1), labelName: "A",
            previous: urls.enumerated().map {
                AssignLabelCommand.Previous(fileID: FileID(rawValue: Int64($0.offset)),
                                            url: $0.element, wasAssigned: false,
                                            protectedScopes: [])
            },
            assigning: true, subjectName: "9 項目", services: LibraryServices())
        #expect(command.logTargets.count == 9)
        #expect(Log.paths(in: command.logDescription).count == 5)
    }
}
