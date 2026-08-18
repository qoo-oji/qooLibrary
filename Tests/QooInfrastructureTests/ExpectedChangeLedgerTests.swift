import Testing
import Foundation
import QooKit
@testable import QooInfrastructure

@Suite("期待変更台帳 [FO-10〜FO-15][EV-01]")
struct ExpectedChangeLedgerTests {

    func makeLedger() -> ExpectedChangeLedger { ExpectedChangeLedger() }

    @Test("登録したパスは一致して消費される [FO-12]")
    func consumeByPath() {
        let ledger = makeLedger()
        let url = URL(fileURLWithPath: "/tmp/qoo-ledger/作品.cbz")
        ledger.expect([url], kind: .rename)
        let entry = ledger.consume(path: url.path)
        #expect(entry?.kind == .rename)
    }

    @Test("消費は 1 回きり。2 回目は外部変更として扱う [FO-12]")
    func consumedOnce() {
        let ledger = makeLedger()
        let url = URL(fileURLWithPath: "/tmp/qoo-ledger/作品.cbz")
        ledger.expect([url], kind: .move)
        #expect(ledger.consume(path: url.path) != nil)
        #expect(ledger.consume(path: url.path) == nil)
    }

    @Test("同じパスに 2 回の変更があれば 2 回消費できる")
    func twoChangesTwoEntries() {
        let ledger = makeLedger()
        let url = URL(fileURLWithPath: "/tmp/qoo-ledger/作品.cbz")
        ledger.expect([url], kind: .copy)
        ledger.expect([url], kind: .move)
        #expect(ledger.consume(path: url.path) != nil)
        #expect(ledger.consume(path: url.path) != nil)
        #expect(ledger.consume(path: url.path) == nil)
    }

    /// FSEvents はディレクトリ単位で合体するため、子の変更が親のパスとして
    /// 届くことがある [FO-10]。
    @Test("親フォルダのパスでも一致する [FO-10]")
    func parentDirectoryMatches() {
        let ledger = makeLedger()
        let url = URL(fileURLWithPath: "/tmp/qoo-ledger/フォルダ/作品.cbz")
        ledger.expect([url], kind: .createDirectory)
        #expect(ledger.consume(path: "/tmp/qoo-ledger/フォルダ") != nil)
    }

    @Test("期限切れのエントリは破棄され、以後は外部変更として扱う [FO-13]")
    func entriesExpire() {
        let ledger = makeLedger()
        let url = URL(fileURLWithPath: "/tmp/qoo-ledger/作品.cbz")
        let t0 = Date()
        ledger.expect([url], kind: .move, lifetime: 10, now: t0)
        // 期限内
        #expect(ledger.consume(path: url.path, now: t0.addingTimeInterval(9)) != nil)
        ledger.expect([url], kind: .move, lifetime: 10, now: t0)
        // 期限切れ
        #expect(ledger.consume(path: url.path, now: t0.addingTimeInterval(11)) == nil)
    }

    @Test("既定の有効期限は 10 秒 [FO-13]")
    func defaultLifetime() {
        #expect(AppLimits.Watch.ledgerEntryLifetime == 10)
    }

    @Test("同一性（volumeUUID, inode）でも照合できる")
    func consumeByIdentity() {
        let ledger = makeLedger()
        let identity = FileIdentity(volumeUUID: "VOL", inode: 42)
        let url = URL(fileURLWithPath: "/tmp/qoo-ledger/作品.cbz")
        ledger.recordActual([identity], at: [url], kind: .copy)
        #expect(ledger.consume(path: "/まったく別のパス", identity: identity)?.kind == .copy)
        #expect(ledger.consume(path: "/まったく別のパス", identity: identity) == nil)
    }

    @Test("登録していないパスは一致しない（外部変更）")
    func unknownPathIsExternal() {
        let ledger = makeLedger()
        #expect(ledger.consume(path: "/tmp/qoo-ledger/よそのファイル.cbz") == nil)
    }

    @Test("自動リネームの抑止フラグを運べる [CR-63][PW-15]")
    func suppressFlagIsCarried() {
        let ledger = makeLedger()
        let url = URL(fileURLWithPath: "/tmp/qoo-ledger/作品.cbz")
        ledger.expect([url], kind: .rename, suppressAutoRename: true)
        #expect(ledger.consume(path: url.path)?.suppressAutoRename == true)
    }

    /// FSEvents は実体のパスを返す。`/var` と `/private/var` の食い違いで
    /// 取りこぼさないこと [DW-05]。
    @Test("シンボリックリンク越しのパスでも一致する")
    func physicalPathIsUsed() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("qoo-ledger-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("作品.cbz")
        FileManager.default.createFile(atPath: file.path, contents: Data())

        let ledger = makeLedger()
        ledger.expect([file], kind: .copy)
        // `/var/folders/...`（シンボリックリンク越し）で照合しても当たること
        let viaSymlink = file.path.replacingOccurrences(of: "/private/var", with: "/var")
        #expect(ledger.consume(path: viaSymlink) != nil)
    }

    @Test("全消去できる（一括処理の前後で使う）[FO-14]")
    func removeAll() {
        let ledger = makeLedger()
        ledger.expect([URL(fileURLWithPath: "/tmp/a")], kind: .copy)
        #expect(ledger.pendingCount > 0)
        ledger.removeAll()
        #expect(ledger.pendingCount == 0)
    }

    /// **実際の操作で台帳が埋まること。**配線が外れたら落ちる。
    @Test("FileOperationService の操作が台帳へ登録する [FO-11]")
    func serviceRegistersBeforeOperation() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("qoo-ledger-svc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        ExpectedChangeLedger.shared.removeAll()
        let target = dir.appendingPathComponent("新規フォルダ")
        _ = try await FileOperationService.shared.createDirectory(at: target)
        #expect(ExpectedChangeLedger.shared.consume(path: target.path) != nil,
                "createDirectory が台帳へ登録していない")
        ExpectedChangeLedger.shared.removeAll()
    }
}
