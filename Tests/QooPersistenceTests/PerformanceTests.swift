import Testing
import Foundation
import GRDB
import QooKit
@testable import QooPersistence

//
//  実装（スパイクではなくリポジトリ本体）で PF 目標を満たすことを固定する。
//
//  スパイク（`Spikes/PersistenceSpike`）は手書きの SQL で測ったもので、
//  `SQLiteManagedFileRepository.whereClause` が組み立てる SQL とは別物。
//  **本当に使う経路で測らないと意味がない。**
//
@Suite("性能 [PF-01〜PF-05]", .serialized)
struct PersistencePerformanceTests {

    /// 5 万件は毎回作ると重いので、この suite で 1 回だけ作る。
    static func makeLibrary(files: Int, labelsPerGroup: [Int]) async throws -> QueryTests.Setup {
        let f = try await Fixture.make(preset: "builtin.doujinshi-a")
        var labelIDs: [[LabelID]] = []
        for (offset, cardinality) in labelsPerGroup.enumerated() {
            let field = try #require(try await f.labels.field(libraryID: f.libraryID, index: offset + 1))
            var ids: [LabelID] = []
            for i in 0..<cardinality {
                ids.append(try await f.labels.ensureLabel(fieldID: field.id, name: "g\(offset)-\(i)"))
            }
            labelIDs.append(ids)
        }
        // 500 件バッチで投入 [SE3-05][HP2-02]
        var produced = 0
        while produced < files {
            let batch = min(500, files - produced)
            let ids = try await f.files.upsertBatch((0..<batch).map { k in
                let i = produced + k
                return f.snapshot(inode: UInt64(i + 1),
                                  path: "第\(i % 200)階層/作品タイトル\(i).cbz",
                                  size: Int64(i) * 977)
            })
            // `@Sendable` なクロージャへ渡すため、必要な値を先に確定させる。
            let base = produced
            let fieldsSnapshot = labelIDs
            try await f.database.writer.write { db in
                let now = Date().timeIntervalSinceReferenceDate
                let stmt = try db.cachedStatement(sql: """
                    INSERT INTO fileLabel (managedFileId, labelId, assignedAt)
                    VALUES (?, ?, ?)
                    """)
                for (k, id) in ids.enumerated() {
                    let i = base + k
                    for field in fieldsSnapshot {
                        try stmt.execute(arguments: [id.rawValue,
                                                     field[i % field.count].rawValue, now])
                    }
                }
            }
            produced += batch
        }
        var setup = QueryTests.Setup(f: f)
        for (offset, ids) in labelIDs.enumerated() {
            for (i, id) in ids.enumerated() { setup.labelID["g\(offset)-\(i)"] = id }
        }
        return setup
    }

    static func measure(_ label: String, _ body: () async throws -> Void) async rethrows -> Double {
        let t0 = DispatchTime.now().uptimeNanoseconds
        try await body()
        let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000
        FileHandle.standardError.write(Data(
            String(format: "  [perf] %@ %.1f ms\n", label, ms).utf8))
        return ms
    }

    @Test("5 万件でのラベルフィルタが 500ms 以内 [PF-03][T-03]")
    func labelFilterAtScale() async throws {
        // カーディナリティは実データの分布に合わせる（サークル 2000 / 著者 3000 /
        // ジャンル 500 / その他 30 / プレイ 5000 相当を縮めたもの）。
        let s = try await Self.makeLibrary(files: 50_000, labelsPerGroup: [30, 2000, 3000, 500, 100])
        let fields = try await s.f.labels.fields(libraryID: s.f.libraryID)
        func fieldID(_ index: Int) -> FieldID { fields.first { $0.index == index }!.id }

        // (a) 狭い: 3 フィールドの AND
        var narrow = FileQuery(libraryID: s.f.libraryID)
        narrow.labelSelection = [
            fieldID(2): Set((0..<3).map { s.labelID["g1-\($0)"]! }),
            fieldID(3): Set((0..<2).map { s.labelID["g2-\($0)"]! }),
        ]
        let narrowMS = try await Self.measure("(a) 3 フィールド AND（狭い）") {
            _ = try await s.f.files.query(narrow)
        }
        #expect(narrowMS < 500)

        // (b) 最悪: 低カーディナリティのフィールドを全ラベル OR（ほぼ全件が該当）
        var wide = FileQuery(libraryID: s.f.libraryID)
        wide.labelSelection = [fieldID(1): Set((0..<30).map { s.labelID["g0-\($0)"]! })]
        var wideCount = 0
        let wideMS = try await Self.measure("(b) 全ラベル OR（ほぼ全件が該当）") {
            wideCount = try await s.f.files.query(wide).totalCount
        }
        #expect(wideCount == 50_000)
        #expect(wideMS < 500, "最悪ケースで \(wideMS) ms（目標 500 ms）")

        // (c) 部分一致検索 [PF-04]
        var search = FileQuery(libraryID: s.f.libraryID)
        search.searchText = "存在しない文字列"
        var searchCount = -1
        let searchMS = try await Self.measure("(c) 検索・全走査の最悪ケース") {
            searchCount = try await s.f.files.query(search).totalCount
        }
        #expect(searchCount == 0)
        #expect(searchMS < 300, "[PF-04] \(searchMS) ms")

        // (d) フォルダ一覧 [PF-02]
        var folder = FileQuery(libraryID: s.f.libraryID)
        folder.scope = .folder(path: "第17階層", recursive: false)
        let folderMS = try await Self.measure("(d) フォルダ一覧＋ソート") {
            _ = try await s.f.files.query(folder)
        }
        #expect(folderMS < 300, "[PF-02] \(folderMS) ms")

        // (e) 起動時の件数 [PF-01][IX-05]
        var total = 0
        let countMS = try await Self.measure("(e) 総件数") {
            total = try await s.f.libraries.totalFileCount()
        }
        #expect(total == 50_000)
        #expect(countMS < 2000)

        // (f) ラベル件数の集計 [§19.13 #1]。**非正規化列を撤去した**ので、
        // フィルタペインが開くたびにこの経路を通る——ここが遅ければ撤去は
        // 誤りだったことになる。
        //
        // 10 万件・50 万紐づけでの実測は 105.3 ms（この suite の 5 万件・
        // 25 万紐づけならその半分程度）。上限は現行の PF 目標に合わせて 500 ms
        // ——**列を読んでいた頃と同等以下**であることが撤去の根拠だった
        // （109.4 → 105.3 ms。現行の経路が既に相関副問い合わせを 1 本
        // 走らせていたため）。
        let groupsForCount = try await s.f.labels.fields(libraryID: s.f.libraryID)
        let countMS2 = try await Self.measure("(f) 全フィールドのラベル件数") {
            for g in groupsForCount { _ = try await s.f.labels.labels(fieldID: g.id) }
        }
        #expect(countMS2 < 500, "[§19.13 #1] \(countMS2) ms")

        // (g) 同一性判定のホットパス [ID-02]
        let identityMS = try await Self.measure("(g) (volumeUUID, inode) で 1 万回") {
            for i in 1...10_000 {
                _ = try await s.f.files.find(identity: FileIdentity(volumeUUID: "VOL", inode: UInt64(i)))
            }
        }
        FileHandle.standardError.write(Data(
            String(format: "  [perf] → 1 件あたり %.4f ms\n", identityMS / 10_000).utf8))
        // 1 件ずつの `find` は毎回プールへ往復するので、スパイクで測った
        // 「1 トランザクション内で cachedStatement を 1 万回」（0.0027 ms/件）の
        // 12 倍かかる。**スキャンのホットパスはこの API を使わない**——
        // `upsertBatch` が 1 トランザクションの中で引き当てまで済ませる [HP2-01]。
        #expect(identityMS < 5000)
    }
}
