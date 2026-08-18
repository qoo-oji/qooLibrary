import Testing
import Foundation
import GRDB
import QooKit
@testable import QooPersistence

@Suite("ラベルフィルタと問い合わせ [7.4][LF-08〜LF-10][FI-01〜FI-05]")
struct QueryTests {

    /// 3 グループ × ラベルを付けたファイルを用意する。
    struct Setup {
        let f: Fixture
        /// (グループ番号, ラベル名) → LabelID
        var labelID: [String: LabelID] = [:]
        var fileID: [String: FileID] = [:]

        static func make() async throws -> Setup {
            let f = try await Fixture.make(preset: "builtin.doujinshi-a")
            var s = Setup(f: f)
            let circle = try #require(try await f.labels.group(libraryID: f.libraryID, index: 2))
            let author = try #require(try await f.labels.group(libraryID: f.libraryID, index: 3))
            let genre = try #require(try await f.labels.group(libraryID: f.libraryID, index: 4))
            for (group, names) in [(circle, ["C1", "C2"]), (author, ["A1", "A2"]), (genre, ["G1"])] {
                for name in names {
                    s.labelID[name] = try await f.labels.ensureLabel(groupID: group.id, name: name)
                }
            }
            // file1: C1 A1 G1 / file2: C1 A2 / file3: C2 A1 / file4: ラベルなし
            let plan: [(String, [String])] = [
                ("file1", ["C1", "A1", "G1"]), ("file2", ["C1", "A2"]),
                ("file3", ["C2", "A1"]), ("file4", []),
            ]
            for (i, (name, labels)) in plan.enumerated() {
                let id = try await f.files.upsert(
                    f.snapshot(inode: UInt64(i + 1), path: "フォルダ\(i % 2)/\(name).cbz",
                               size: Int64((i + 1) * 100)))
                s.fileID[name] = id
                for label in labels {
                    try await f.labels.assign(fileID: id, labelID: s.labelID[label]!, origin: .auto)
                }
            }
            return s
        }

        func query(_ selection: [Int: [String]] = [:]) async throws -> FileQuery {
            var q = FileQuery(libraryID: f.libraryID)
            for (index, names) in selection {
                let group = try #require(try await f.labels.group(libraryID: f.libraryID, index: index))
                q.labelSelection[group.id] = Set(names.map { labelID[$0]! })
            }
            return q
        }
    }

    @Test("グループ内は OR [LF-08]")
    func orWithinGroup() async throws {
        let s = try await Setup.make()
        let page = try await s.f.files.query(try await s.query([2: ["C1", "C2"]]))
        #expect(Set(page.rows.map(\.filename)) == ["file1.cbz", "file2.cbz", "file3.cbz"])
        #expect(page.totalCount == 3)
    }

    @Test("グループ間は AND [LF-09][LF-10]")
    func andAcrossGroups() async throws {
        let s = try await Setup.make()
        let page = try await s.f.files.query(try await s.query([2: ["C1"], 3: ["A1"]]))
        #expect(page.rows.map(\.filename) == ["file1.cbz"])
    }

    @Test("3 グループの AND")
    func threeGroups() async throws {
        let s = try await Setup.make()
        #expect(try await s.f.files.query(try await s.query([2: ["C1"], 3: ["A1"], 4: ["G1"]]))
            .rows.map(\.filename) == ["file1.cbz"])
        // G1 を持たない file2 は落ちる
        #expect(try await s.f.files.query(try await s.query([2: ["C1"], 3: ["A2"], 4: ["G1"]]))
            .rows.isEmpty)
    }

    @Test("選択が空なら絞り込まない [SR-01]")
    func emptySelectionMatchesAll() async throws {
        let s = try await Setup.make()
        #expect(try await s.f.files.query(try await s.query()).totalCount == 4)
    }

    @Test("ゴミ箱とアーカイブ済みを除く [FI-02][TR-02][LF-13]")
    func excludesTrashedAndArchived() async throws {
        let s = try await Setup.make()
        try await s.f.files.markTrashed([s.fileID["file1"]!], at: Date())
        #expect(try await s.f.files.query(try await s.query()).totalCount == 3)
        #expect(try await s.f.files.query(try await s.query([2: ["C1"]])).rows.map(\.filename)
                == ["file2.cbz"])
    }

    @Test("フォルダスコープ（直下のみ / 再帰）")
    func folderScope() async throws {
        let s = try await Setup.make()
        var q = try await s.query()
        q.scope = .folder(path: "フォルダ0", recursive: false)
        #expect(Set(try await s.f.files.query(q).rows.map(\.filename)) == ["file1.cbz", "file3.cbz"])

        // 深い階層を足して再帰の違いを見る
        _ = try await s.f.files.upsert(s.f.snapshot(inode: 100, path: "フォルダ0/奥/深い.cbz"))
        q.scope = .folder(path: "フォルダ0", recursive: false)
        #expect(try await s.f.files.query(q).totalCount == 2, "直下のみのはず")
        q.scope = .folder(path: "フォルダ0", recursive: true)
        #expect(try await s.f.files.query(q).totalCount == 3)
    }

    @Test("部分一致検索は正規化済みカラムで行う [SR-06][DB-03]")
    func search() async throws {
        let f = try await Fixture.make()
        _ = try await f.files.upsert(f.snapshot(inode: 1, path: "ＡＢＣ　作品.cbz"))
        _ = try await f.files.upsert(f.snapshot(inode: 2, path: "ぶらっくじゃっく.cbz"))
        var q = FileQuery(libraryID: f.libraryID)
        // 全角で検索しても半角の正規化形に当たる [N-02]
        q.searchText = "ＡＢＣ"
        #expect(try await f.files.query(q).totalCount == 1)
        q.searchText = "abc"
        #expect(try await f.files.query(q).totalCount == 1)
        // ひらがな→カタカナ統一 [SR-06]
        q.searchText = "ブラック"
        #expect(try await f.files.query(q).totalCount == 1)
        q.searchText = "存在しない"
        #expect(try await f.files.query(q).totalCount == 0)
    }

    @Test("LIKE のメタ文字はエスケープされる（検索文字列として扱う）")
    func likeMetaCharactersAreEscaped() async throws {
        let f = try await Fixture.make()
        _ = try await f.files.upsert(f.snapshot(inode: 1, path: "100%達成.cbz"))
        _ = try await f.files.upsert(f.snapshot(inode: 2, path: "無関係.cbz"))
        var q = FileQuery(libraryID: f.libraryID)
        q.searchText = "100%"
        #expect(try await f.files.query(q).totalCount == 1)
        q.searchText = "%"           // ワイルドカードとして解釈されてはいけない
        #expect(try await f.files.query(q).totalCount == 1)
        q.searchText = "_"
        #expect(try await f.files.query(q).totalCount == 0)
    }

    @Test("評価フィルタ [RT-01][RT-03]")
    func ratingFilter() async throws {
        let f = try await Fixture.make()
        for i in 0...5 {
            let id = try await f.files.upsert(f.snapshot(inode: UInt64(i + 1), path: "r\(i).cbz"))
            try await f.database.writer.write {
                try $0.execute(sql: "UPDATE managedFile SET rating = ? WHERE id = ?",
                               arguments: [i, id.rawValue])
            }
        }
        var q = FileQuery(libraryID: f.libraryID)
        q.ratingFilter = .init(minimum: 3)
        #expect(try await f.files.query(q).totalCount == 3)          // 3,4,5
        q.ratingFilter = .init(minimum: 0, unratedOnly: true)
        #expect(try await f.files.query(q).totalCount == 1)          // 0
    }

    @Test("ページングは総件数を一緒に返す [PF-10][FI-05]")
    func paging() async throws {
        let f = try await Fixture.make()
        _ = try await f.files.upsertBatch((1...10).map {
            f.snapshot(inode: UInt64($0), path: String(format: "%02d.cbz", $0))
        })
        var q = FileQuery(libraryID: f.libraryID, limit: 3)
        let first = try await f.files.query(q)
        #expect(first.rows.count == 3)
        #expect(first.totalCount == 10)
        #expect(first.rows.map(\.filename) == ["01.cbz", "02.cbz", "03.cbz"])
        q.offset = 9
        #expect(try await f.files.query(q).rows.map(\.filename) == ["10.cbz"])
    }

    @Test("巻数のソートは numeric < ordinal < none [SE-10][VM-15]")
    func volumeSorting() async throws {
        let f = try await Fixture.make()
        let plan: [(String, VolumeValue)] = [
            ("c.cbz", .none),
            ("b.cbz", .ordinal(rank: 1, raw: "上巻")),
            ("a.cbz", .numeric(3, raw: "第03巻")),
            ("d.cbz", .numeric(1, raw: "第01巻")),
        ]
        for (i, (name, volume)) in plan.enumerated() {
            let id = try await f.files.upsert(f.snapshot(inode: UInt64(i + 1), path: name))
            try await f.database.writer.write {
                try $0.execute(sql: "UPDATE managedFile SET volumeKind = ?, volumeNumber = ?, volumeRaw = ? WHERE id = ?",
                               arguments: [volume.kind.rawValue, volume.number, volume.raw, id.rawValue])
            }
        }
        var q = FileQuery(libraryID: f.libraryID)
        q.sort = .init(key: .volume)
        #expect(try await f.files.query(q).rows.map(\.filename)
                == ["d.cbz", "a.cbz", "b.cbz", "c.cbz"])
    }

    @Test("並び順の指定が効く")
    func sortKeys() async throws {
        let f = try await Fixture.make()
        _ = try await f.files.upsert(f.snapshot(inode: 1, path: "b.cbz", size: 300))
        _ = try await f.files.upsert(f.snapshot(inode: 2, path: "a.cbz", size: 100))
        var q = FileQuery(libraryID: f.libraryID)
        q.sort = .init(key: .fileSize, ascending: true)
        #expect(try await f.files.query(q).rows.map(\.filename) == ["a.cbz", "b.cbz"])
        q.sort = .init(key: .fileSize, ascending: false)
        #expect(try await f.files.query(q).rows.map(\.filename) == ["b.cbz", "a.cbz"])
    }
}

// MARK: - ラベル

@Suite("SQLiteLabelRepository [LB-01〜LB-07][RC-04][DB-02][IX-03][IX-04]")
struct LabelRepositoryTests {
    @Test("一意性は (グループ, 正規化名)。表示名は最初の原文 [LB-01][N-03][NM-06]")
    func ensureLabelDeduplicates() async throws {
        let f = try await Fixture.make()
        let group = try #require(try await f.labels.group(libraryID: f.libraryID, index: 2))
        let a = try await f.labels.ensureLabel(groupID: group.id, name: "ＡＢＣ")
        let b = try await f.labels.ensureLabel(groupID: group.id, name: "abc")
        let c = try await f.labels.ensureLabel(groupID: group.id, name: " a b c ")
        #expect(a == b, "全角と半角が別ラベルになった")
        #expect(a != c)
        let labels = try await f.labels.labels(groupID: group.id, includeArchived: false)
        #expect(labels.first { $0.id == a }?.name == "ＡＢＣ", "表示名は最初の原文であるべき")
    }

    @Test("NFD と NFC は同じラベルになる [R-03]")
    func nfdAndNFCUnify() async throws {
        let f = try await Fixture.make()
        let group = try #require(try await f.labels.group(libraryID: f.libraryID, index: 2))
        let a = try await f.labels.ensureLabel(
            groupID: group.id, name: "パピプペポ".decomposedStringWithCanonicalMapping)
        let b = try await f.labels.ensureLabel(
            groupID: group.id, name: "パピプペポ".precomposedStringWithCanonicalMapping)
        #expect(a == b)
    }

    @Test("件数は増分更新される [DB-02][IX-03]")
    func fileCountIsIncremental() async throws {
        let f = try await Fixture.make()
        let group = try #require(try await f.labels.group(libraryID: f.libraryID, index: 2))
        let label = try await f.labels.ensureLabel(groupID: group.id, name: "C1")
        func count() async throws -> Int {
            try await f.labels.labels(groupID: group.id, includeArchived: true)
                .first { $0.id == label }?.fileCount ?? -1
        }
        #expect(try await count() == 0)
        let f1 = try await f.files.upsert(f.snapshot(inode: 1, path: "1.cbz"))
        let f2 = try await f.files.upsert(f.snapshot(inode: 2, path: "2.cbz"))
        try await f.labels.assign(fileID: f1, labelID: label, origin: .auto)
        try await f.labels.assign(fileID: f2, labelID: label, origin: .manual)
        #expect(try await count() == 2)
        try await f.labels.assign(fileID: f1, labelID: label, origin: .manual)   // 二重付与
        #expect(try await count() == 2, "同じ組で二重に数えてはいけない")
        try await f.labels.unassign(fileID: f1, labelID: label, markManuallyRemoved: false)
        #expect(try await count() == 1)
    }

    @Test("再集計が増分更新のずれを直す [IX-04]")
    func recountRepairsDrift() async throws {
        let f = try await Fixture.make()
        let group = try #require(try await f.labels.group(libraryID: f.libraryID, index: 2))
        let label = try await f.labels.ensureLabel(groupID: group.id, name: "C1")
        let file = try await f.files.upsert(f.snapshot(inode: 1, path: "1.cbz"))
        try await f.labels.assign(fileID: file, labelID: label, origin: .auto)
        // 帳簿をわざと壊す
        try await f.database.writer.write {
            try $0.execute(sql: "UPDATE label SET fileCount = 999 WHERE id = ?",
                           arguments: [label.rawValue])
        }
        try await f.labels.recountAll(libraryID: f.libraryID)
        let after = try await f.labels.labels(groupID: group.id, includeArchived: true)
            .first { $0.id == label }?.fileCount
        #expect(after == 1)
    }

    @Test("ゴミ箱・アーカイブ済みは件数に数えない [TR-02][LF-13]")
    func countExcludesTrashed() async throws {
        let f = try await Fixture.make()
        let group = try #require(try await f.labels.group(libraryID: f.libraryID, index: 2))
        let label = try await f.labels.ensureLabel(groupID: group.id, name: "C1")
        let file = try await f.files.upsert(f.snapshot(inode: 1, path: "1.cbz"))
        try await f.labels.assign(fileID: file, labelID: label, origin: .auto)
        try await f.files.markTrashed([file], at: Date())
        try await f.labels.recountAll(libraryID: f.libraryID)
        #expect(try await f.labels.labels(groupID: group.id, includeArchived: true)
            .first { $0.id == label }?.fileCount == 0)
    }

    /// **再計算で復活させてはいけない** [RC-04]。
    @Test("手動で外したラベルは自動再計算で復活しない [RC-04]")
    func manuallyRemovedIsNotRevived() async throws {
        let f = try await Fixture.make()
        let group = try #require(try await f.labels.group(libraryID: f.libraryID, index: 2))
        let keep = try await f.labels.ensureLabel(groupID: group.id, name: "残す")
        let removed = try await f.labels.ensureLabel(groupID: group.id, name: "外した")
        let file = try await f.files.upsert(f.snapshot(inode: 1, path: "1.cbz"))

        try await f.labels.replaceAutoLabels(fileID: file, labelIDs: [keep, removed])
        try await f.labels.unassign(fileID: file, labelID: removed, markManuallyRemoved: true)

        // 再計算で両方が当たっても、外したものは付け直さない
        try await f.labels.replaceAutoLabels(fileID: file, labelIDs: [keep, removed])
        let assigned = try await f.labels.labelIDs(fileID: file)
        #expect(assigned.first { $0.labelID == keep }?.origin == .auto)
        #expect(assigned.first { $0.labelID == removed }?.origin == .manuallyRemoved)
    }

    @Test("手動で付けたラベルは自動再計算で消えない [RC-04]")
    func manualIsNotRemovedByRecalculation() async throws {
        let f = try await Fixture.make()
        let group = try #require(try await f.labels.group(libraryID: f.libraryID, index: 2))
        let manual = try await f.labels.ensureLabel(groupID: group.id, name: "手動")
        let auto = try await f.labels.ensureLabel(groupID: group.id, name: "自動")
        let file = try await f.files.upsert(f.snapshot(inode: 1, path: "1.cbz"))
        try await f.labels.assign(fileID: file, labelID: manual, origin: .manual)
        try await f.labels.replaceAutoLabels(fileID: file, labelIDs: [auto])
        let assigned = try await f.labels.labelIDs(fileID: file)
        #expect(Set(assigned.map(\.labelID)) == [manual, auto])
        #expect(assigned.first { $0.labelID == manual }?.origin == .manual)
    }

    @Test("自動ラベルの入れ替えで不要になったものは外れる [RC-01]")
    func autoLabelsAreReplaced() async throws {
        let f = try await Fixture.make()
        let group = try #require(try await f.labels.group(libraryID: f.libraryID, index: 2))
        let old = try await f.labels.ensureLabel(groupID: group.id, name: "旧")
        let new = try await f.labels.ensureLabel(groupID: group.id, name: "新")
        let file = try await f.files.upsert(f.snapshot(inode: 1, path: "1.cbz"))
        try await f.labels.replaceAutoLabels(fileID: file, labelIDs: [old])
        try await f.labels.replaceAutoLabels(fileID: file, labelIDs: [new])
        #expect(try await f.labels.labelIDs(fileID: file).map(\.labelID) == [new])
    }

    @Test("ラベルの統合 [LB-07]")
    func mergeLabels() async throws {
        let f = try await Fixture.make()
        let group = try #require(try await f.labels.group(libraryID: f.libraryID, index: 2))
        let a = try await f.labels.ensureLabel(groupID: group.id, name: "表記ゆれA")
        let b = try await f.labels.ensureLabel(groupID: group.id, name: "表記ゆれB")
        let f1 = try await f.files.upsert(f.snapshot(inode: 1, path: "1.cbz"))
        let f2 = try await f.files.upsert(f.snapshot(inode: 2, path: "2.cbz"))
        try await f.labels.assign(fileID: f1, labelID: a, origin: .auto)
        try await f.labels.assign(fileID: f2, labelID: b, origin: .auto)
        try await f.labels.assign(fileID: f1, labelID: b, origin: .auto)   // 両方持つ

        try await f.labels.merge(a, into: b)
        #expect(try await f.labels.labels(groupID: group.id, includeArchived: true).map(\.id) == [b])
        #expect(try await f.labels.labelIDs(fileID: f1).map(\.labelID) == [b])
        #expect(try await f.labels.labels(groupID: group.id, includeArchived: true)
            .first?.fileCount == 2)
    }

    @Test("改名と正規化名の追従 [LB-06]")
    func renameUpdatesNormalizedName() async throws {
        let f = try await Fixture.make()
        let group = try #require(try await f.labels.group(libraryID: f.libraryID, index: 2))
        let id = try await f.labels.ensureLabel(groupID: group.id, name: "旧名")
        try await f.labels.rename(id, to: "ＮＥＷ")
        let label = try #require(try await f.labels.labels(groupID: group.id, includeArchived: true).first)
        #expect(label.name == "ＮＥＷ")
        #expect(label.normalizedName == "new")
        // 正規化名が追従しているので、同じ値で ensure すると同じ ID になる
        #expect(try await f.labels.ensureLabel(groupID: group.id, name: "new") == id)
    }

    @Test("アーカイブとピン留め [LA-01][LB-03]")
    func archiveAndPin() async throws {
        let f = try await Fixture.make()
        let group = try #require(try await f.labels.group(libraryID: f.libraryID, index: 2))
        let id = try await f.labels.ensureLabel(groupID: group.id, name: "L")
        try await f.labels.setArchived([id], true)
        #expect(try await f.labels.labels(groupID: group.id, includeArchived: false).isEmpty)
        #expect(try await f.labels.labels(groupID: group.id, includeArchived: true).count == 1)
        try await f.labels.setArchived([id], false)
        try await f.labels.setPinned(id, true)
        #expect(try await f.labels.labels(groupID: group.id, includeArchived: false).first?.isPinned == true)
    }
}
