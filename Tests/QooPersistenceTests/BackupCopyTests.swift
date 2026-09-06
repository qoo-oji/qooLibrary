import Foundation
import GRDB
import Testing
@testable import QooPersistence

//
//  ストア複製 [BK-03][BK3-08][BK3-09]。
//
//  **`QooApplication` 側からは試せない**——失敗を起こすには生の `DatabaseWriter`
//  を閉じる必要があり、`GRDB` を import してよいのは `QooPersistence` だけ [B-11]。
//

@Suite("ストア複製 [BK3-08][BK3-09]")
struct BackupCopyTests {
    private func makeDirectory() -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("qoo-copy-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// **後始末が必要である、という前提そのものを固定する** [BK3-09]。
    ///
    /// 宛先ファイルは 1 ページも写す前に作られるので、失敗すると中身の無い
    /// ファイルが残る——放置すると「正常な世代」として枠を食い、良い世代を
    /// 押し出す［code-review が実測で発見］。**消すのは呼び出し側**
    /// （`BackupService`）で、この層は削除系の `FileManager` API を
    /// 呼べない [B-10]。
    ///
    /// このテストが落ちるとしたら、GRDB が宛先を後から作るように変わった
    /// ときで、そのときは BK3-09 の後始末が不要になる。
    @Test("複製の失敗は宛先ファイルを残す（後始末は呼び出し側）[BK3-09]")
    func failedCopyLeavesTheDestinationForTheCaller() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try QooDatabase.inMemory()
        let destination = directory.appendingPathComponent("copy.sqlite")

        // ソースを閉じてから複製すると、宛先を開いた後で失敗する。
        _ = try source.writer.close()
        #expect(throws: (any Error).self) {
            try QooDatabase.backup(writer: source.writer, to: destination)
        }
        #expect(FileManager.default.fileExists(atPath: destination.path),
                "宛先が作られないなら BK3-09 の後始末は要らなくなる")
    }

    /// **複製先に `-wal` / `-shm` を作らない** [BK3-08]。
    ///
    /// 既定の設定は WAL を立てるので、そのまま使うと付随ファイルが世代の隣に
    /// できる——`BackupStore.generations()` は解釈しないので**誰にも見えない
    /// まま容量を食い、剪定の対象にもならない**［code-review が実測で発見］。
    @Test("複製先に付随ファイルを作らない [BK3-08]")
    func copyLeavesNoSidecars() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try QooDatabase.inMemory()
        let destination = directory.appendingPathComponent("copy.sqlite")

        try QooDatabase.backup(writer: source.writer, to: destination)

        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(names == ["copy.sqlite"], "付随ファイルが残っている: \(names)")
    }

    /// 複製したものは**そのまま開ける**——復元 [BK-03] の前提。
    @Test("複製したストアは開ける [BK-03]")
    func theCopyCanBeOpened() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try QooDatabase.inMemory()
        try source.writer.write {
            try $0.execute(sql: """
                INSERT INTO volumeOutputStyle (name, numericTemplate, digits, numeralWidth, noneOutput)
                VALUES ('x','{n}',2,'halfwidth','')
                """)
        }
        let destination = directory.appendingPathComponent("copy.sqlite")
        try QooDatabase.backup(writer: source.writer, to: destination)

        // `open` は WAL へ戻す（複製先は DELETE ジャーナルで書いてある）。
        let restored = try QooDatabase.open(at: destination)
        let count = try restored.writer.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM volumeOutputStyle")
        }
        #expect(count == 1)
    }

    /// **複製のジャーナル形式は正規化されている**［実測、2026-09-06］。
    ///
    /// ヘッダの 18〜19 バイト目が書き込み／読み取りバージョンで、`2` なら
    /// WAL、`1` ならロールバックジャーナル。**バイトを直接見る**——
    /// `inspect` の結果で確かめると、あちらが持つ互換経路（WAL ヘッダの
    /// 世代を正規化してから読む）が吸収してしまい、この主張を一度も
    /// 検査しないまま通る（実際に変異が空振りした）。
    ///
    /// **標本はファイル由来の（＝WAL の）ストアでなければならない**——
    /// 上の 2 件は `inMemory()` を元にしており、メモリ上の DB は WAL に
    /// ならないので**この経路を一度も通っていなかった**。
    @Test("複製はロールバックジャーナル形式で書かれる [BK3-08][BK-03]")
    func theCopyIsNormalisedToRollbackJournal() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("live.sqlite")
        let source = try QooDatabase.open(at: sourceURL)   // ここで WAL になる
        let destination = directory.appendingPathComponent("copy.sqlite")
        try QooDatabase.backup(writer: source.writer, to: destination)
        try source.writer.close()

        let header = try FileHandle(forReadingFrom: destination).readToEnd() ?? Data()
        #expect(header.count > 20)
        #expect(Array(header[18 ... 19]) == [1, 1],
                "複製のヘッダが WAL のまま: \(Array(header[18 ... 19]))")
    }

    /// 第 1 段（2026-09-05）が書いた世代は**ヘッダが WAL のまま**で、
    /// 素の読み取り専用では開けない。それでも検分できなければ、
    /// **その世代は二度と復元できない**ことになる [BK-03]。
    @Test("WAL ヘッダのままの世代も検分できる [BK-03]")
    func aWalHeaderedGenerationCanStillBeInspected() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("live.sqlite")
        let source = try QooDatabase.open(at: sourceURL)
        try source.writer.writeWithoutTransaction { try $0.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)") }
        try source.writer.close()

        // 素のファイルコピーは WAL ヘッダをそのまま持つ＝第 1 段の世代と同じ形。
        let legacy = directory.appendingPathComponent("legacy.sqlite")
        try FileManager.default.copyItem(at: sourceURL, to: legacy)
        let header = try FileHandle(forReadingFrom: legacy).readToEnd() ?? Data()
        #expect(Array(header[18 ... 19]) == [2, 2], "標本が WAL ヘッダを持っていない")

        #expect(QooDatabase.inspect(at: legacy).isUsable)
    }
}
