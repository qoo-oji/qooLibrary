import Foundation
import QooKit
import Testing
@testable import QooInfrastructure

//
//  自動バックアップの置き場所と世代管理 [BK-01][BK2-03]。
//
//  **必ず一時ディレクトリを渡すこと**——既定の場所は `swift test` 中も
//  振り替わるが、テストどうしで共有すると互いの世代を剪定し合う。
//

@Suite("バックアップの世代管理 [BK-01][BK2-03]")
struct BackupStoreTests {
    private func makeStore() -> BackupStore {
        BackupStore(directory: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("qoo-backup-\(UUID().uuidString)"))
    }

    @Test("ファイル名は往復する [BackupFileName]")
    func fileNameRoundTrips() throws {
        // ミリ秒まで残るので、同じ秒に取った 2 件が別の名前になる。
        let date = Date(timeIntervalSince1970: 1_757_000_000.123)
        for reason in BackupReason.allCases {
            for kind in BackupGeneration.Kind.allCases {
                let name = BackupFileName.make(date: date, reason: reason, kind: kind)
                let parts = try #require(BackupFileName.parse(name))
                #expect(parts.reason == reason)
                #expect(parts.kind == kind)
                #expect(abs(parts.date.timeIntervalSince(date)) < 0.001)
            }
        }
    }

    @Test("同じ秒に取った 2 件が別の名前になる")
    func sameSecondDoesNotCollide() {
        let a = Date(timeIntervalSince1970: 1_757_000_000.100)
        let b = Date(timeIntervalSince1970: 1_757_000_000.900)
        #expect(BackupFileName.make(date: a, reason: .launch, kind: .document)
                != BackupFileName.make(date: b, reason: .launch, kind: .document))
    }

    @Test("解釈できない名前は世代として数えない")
    func ignoresForeignFiles() throws {
        let store = makeStore()
        _ = try store.writeDocument(Data("{}".utf8), reason: .launch)
        // 利用者が同じフォルダへ置いた無関係なファイル。
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        for name in ["メモ.txt", "20260905T000000000Z-unknownReason.json",
                     "notatimestamp-launch.json", "20260905T000000000Z-launch.zip"] {
            try Data().write(to: store.directory.appendingPathComponent(name))
        }
        let generations = try store.generations()
        #expect(generations.count == 1)
        #expect(generations.first?.reason == .launch)
    }

    @Test("新しい順に並ぶ")
    func newestFirst() throws {
        let store = makeStore()
        let base = Date(timeIntervalSince1970: 1_757_000_000)
        for offset in [0.0, 60.0, 120.0] {
            _ = try store.writeDocument(Data("{}".utf8), reason: .launch,
                                        date: base.addingTimeInterval(offset))
        }
        let dates = try store.generations().map(\.date)
        #expect(dates == dates.sorted(by: >))
    }

    @Test("剪定は新しいほうから keep 件を残す [BK2-03]")
    func prunesOldest() throws {
        let store = makeStore()
        let base = Date(timeIntervalSince1970: 1_757_000_000)
        for offset in 0 ..< 5 {
            _ = try store.writeDocument(Data("{}".utf8), reason: .launch,
                                        date: base.addingTimeInterval(Double(offset) * 60))
        }
        let removed = try store.prune(kind: .document, keep: 2)
        #expect(removed.count == 3)
        let left = try store.generations()
        #expect(left.count == 2)
        // 残ったのは新しいほうの 2 件。
        #expect(left.allSatisfy { $0.date >= base.addingTimeInterval(180) })
    }

    @Test("種別ごとに別々に数える [AppLimits.Backup]")
    func prunesPerKind() throws {
        let store = makeStore()
        let base = Date(timeIntervalSince1970: 1_757_000_000)
        for offset in 0 ..< 3 {
            let date = base.addingTimeInterval(Double(offset) * 60)
            _ = try store.writeDocument(Data("{}".utf8), reason: .launch, date: date)
            let url = try store.prepareStoreDestination(reason: .launch, date: date)
            try Data("db".utf8).write(to: url)
        }
        try store.prune(kind: .document, keep: 1)
        // ストア複製は 1 件も減っていない。
        #expect(try store.generations().filter { $0.kind == .store }.count == 3)
        #expect(try store.generations().filter { $0.kind == .document }.count == 1)
    }

    /// **世代の隣に置かれた付随ファイルも一緒に消す** [BK3-08]。
    ///
    /// 複製先は WAL にしていないので、いまは付随ファイルはできない。ここで
    /// 一緒に消すのは**それ以前に作られた世代**を取り残さないため——
    /// `generations()` は `-wal` を解釈しないので、残ると誰にも見えないまま
    /// 容量を食い続ける［code-review で発見］。
    @Test("剪定は -wal / -shm も一緒に消す [BK3-08]")
    func prunesSidecarsToo() throws {
        let store = makeStore()
        let base = Date(timeIntervalSince1970: 1_757_000_000)
        var sidecars: [URL] = []
        for offset in 0 ..< 2 {
            let date = base.addingTimeInterval(Double(offset) * 60)
            let url = try store.prepareStoreDestination(reason: .launch, date: date)
            try Data("db".utf8).write(to: url)
            // 古い版が残しうる付随ファイルを模す。
            for suffix in ["-wal", "-shm"] {
                let sidecar = url.deletingLastPathComponent()
                    .appendingPathComponent(url.lastPathComponent + suffix, isDirectory: false)
                try Data("x".utf8).write(to: sidecar)
                sidecars.append(sidecar)
            }
        }
        try store.prune(kind: .store, keep: 1)

        let names = try FileManager.default.contentsOfDirectory(atPath: store.directory.path)
        #expect(names.filter { $0.hasSuffix("-wal") || $0.hasSuffix("-shm") }.count == 2,
                "消した世代の付随ファイルが残っている: \(names)")
    }

    @Test("keep は最小 1 件まで。0 を渡しても全部は消さない")
    func neverPrunesEverything() throws {
        let store = makeStore()
        _ = try store.writeDocument(Data("{}".utf8), reason: .launch)
        try store.prune(kind: .document, keep: 0)
        #expect(try store.generations().count == 1)
    }

    @Test("latest は理由で絞れる [BK-01 の間隔判定]")
    func latestFiltersByReason() throws {
        let store = makeStore()
        let base = Date(timeIntervalSince1970: 1_757_000_000)
        _ = try store.writeDocument(Data("{}".utf8), reason: .launch, date: base)
        _ = try store.writeDocument(Data("{}".utf8), reason: .jsonImport,
                                    date: base.addingTimeInterval(600))
        let launch = try #require(try store.latest(kind: .document, reason: .launch))
        #expect(launch.date == base)
        // 理由を渡さなければ全体の最新。
        let newest = try store.latest(kind: .document)
        #expect(newest?.reason == .jsonImport)
    }

    @Test("置き場所が無ければ空を返す（作りにいかない）")
    func missingDirectoryIsEmpty() throws {
        let store = makeStore()
        #expect(try store.generations().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: store.directory.path))
    }

    @Test("DB 全体に及ぶ契機だけがストア複製を取る [copiesStore]")
    func onlyWholeDatabaseReasonsCopyTheStore() {
        // 複製は 10 万件で 71 MB。小さな操作で 3 世代を埋めない。
        #expect(BackupReason.launch.copiesStore)
        #expect(BackupReason.schemaMigration.copiesStore)
        #expect(BackupReason.jsonImport.copiesStore)
        #expect(BackupReason.beforeRestore.copiesStore)
        #expect(BackupReason.libraryDelete.copiesStore)
        #expect(!BackupReason.bulkLabelDelete.copiesStore)
        #expect(!BackupReason.templateApply.copiesStore)
    }
}
