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
                    try await f.labels.assign(fileID: id, labelID: s.labelID[label]!)
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

    /// **`String.count` は書記素クラスタ、SQLite の `substr` はコードポイント**
    /// [実測]。macOS のファイル名は NFD で来るので（`フォルダ` は 4 文字だが
    /// 5 コードポイント）、濁点を含むフォルダ名では位置が 1 つずれ、
    /// **「直下だけ」の照合が 1 件も一致しなくなる**。差分スキャンの孤立判定と
    /// フォルダ表示モードの一覧がまとめて空振りする形だった。
    @Test("濁点を含むフォルダでも「直下だけ」の照合が効く")
    func nonRecursiveFolderScopeWorksWithDecomposedNames() async throws {
        let f = try await Fixture.make(preset: "builtin.doujinshi-a")
        let nfd = "フォルダ".decomposedStringWithCanonicalMapping
        #expect(nfd.count == 4 && nfd.unicodeScalars.count == 5, "標本が NFD であること")

        _ = try await f.files.upsert(f.snapshot(inode: 1, path: "\(nfd)/直下.cbz", size: 10))
        _ = try await f.files.upsert(f.snapshot(inode: 2, path: "\(nfd)/深い/孫.cbz", size: 10))
        _ = try await f.files.upsert(f.snapshot(inode: 3, path: "よそ/別.cbz", size: 10))

        var q = FileQuery(libraryID: f.libraryID)
        q.scope = .folder(path: nfd, recursive: false)
        let direct = try await f.files.query(q)
        #expect(Set(direct.rows.map(\.filename)) == ["直下.cbz"], "孫も他所も含めない")

        q.scope = .folder(path: nfd, recursive: true)
        let all = try await f.files.query(q)
        #expect(Set(all.rows.map(\.filename)) == ["直下.cbz", "孫.cbz"])
    }

    /// 同じずれは孤立の判定にも効いている（差分スキャンが使う経路）。
    @Test("濁点を含むフォルダでも unseen の「直下だけ」が効く [ID-06]")
    func unseenNonRecursiveScopeWorksWithDecomposedNames() async throws {
        let f = try await Fixture.make(preset: "builtin.doujinshi-a")
        let nfd = "フォルダ".decomposedStringWithCanonicalMapping
        let kept = try await f.files.upsert(f.snapshot(inode: 1, path: "\(nfd)/残る.cbz", size: 10))
        _ = try await f.files.upsert(f.snapshot(inode: 2, path: "\(nfd)/消える.cbz", size: 10))
        _ = try await f.files.upsert(f.snapshot(inode: 3, path: "\(nfd)/深い/孫.cbz", size: 10))

        let unseen = try await f.files.unseen(
            libraryID: f.libraryID, scope: .folder(path: nfd, recursive: false), seen: [kept])
        #expect(unseen.map(\.filename) == ["消える.cbz"], "孫を巻き添えにしない")
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
        q.ratingFilter = .init(stars: 3)                             // 以上
        #expect(try await f.files.query(q).totalCount == 3)          // 3,4,5
        // [RT-03] 「星と完全一致」。以上との差が出る値で確かめる——`.exact` を
        // `.atLeast` として実装しても星 5 では同じ件数になり、空振りする。
        q.ratingFilter = .init(stars: 3, mode: .exact)
        #expect(try await f.files.query(q).totalCount == 1)          // 3 だけ
        q.ratingFilter = .unrated
        #expect(try await f.files.query(q).totalCount == 1)          // 0
        // 範囲外は丸める（決して一致しない条件を作らせない）。
        #expect(FileQuery.RatingFilter(stars: 9).stars == 5)
        #expect(FileQuery.RatingFilter(stars: -1).stars == 0)
    }

    /// フォルダ表示モードでフィルタを掛けたときに何を残すか [VM-02][LF-14]。
    ///
    /// 「該当ファイル」だけでなく「**該当ファイルを配下に持つフォルダ**」も
    /// 残さないと、フィルタを掛けた瞬間に下の階層へ掘っていけなくなる。
    @Test("該当ファイルと、それを配下に持つフォルダの名前が取れる [VM-02]")
    func matchingChildNames() async throws {
        let s = try await Setup.make()
        // Setup は フォルダ0/{file1,file3}、フォルダ1/{file2,file4} を作る。
        let all = try await s.f.files.matchingChildNames(s.query())
        #expect(all == ["フォルダ0", "フォルダ1"])

        // A1 が付くのは file1（フォルダ0）と file3（フォルダ0）だけ。
        // **配下に該当が無いフォルダ1 は落ちる。**
        let a1 = try await s.f.files.matchingChildNames(s.query([3: ["A1"]]))
        #expect(a1 == ["フォルダ0"])

        // フォルダの中まで降りるとファイル名で返る。
        var inFolder = try await s.query([3: ["A1"]])
        inFolder.scope = .folder(path: "フォルダ0", recursive: false)
        #expect(try await s.f.files.matchingChildNames(inFolder) == ["file1.cbz", "file3.cbz"])
    }

    /// `recursive: false` を渡されても配下全体を見る。直下だけに絞ると
    /// 「該当ファイルを配下に持つフォルダ」を落とす。
    @Test("直下指定でも配下全体から畳む [VM-02]")
    func matchingChildNamesIgnoresRecursiveFlag() async throws {
        let f = try await Fixture.make()
        _ = try await f.files.upsert(f.snapshot(inode: 1, path: "a.cbz"))
        _ = try await f.files.upsert(f.snapshot(inode: 2, path: "sub/b.cbz"))
        _ = try await f.files.upsert(f.snapshot(inode: 3, path: "sub/deep/c.cbz"))
        var q = FileQuery(libraryID: f.libraryID)
        q.scope = .folder(path: "", recursive: false)
        #expect(try await f.files.matchingChildNames(q) == ["a.cbz", "sub"])
        q.scope = .folder(path: "sub", recursive: false)
        #expect(try await f.files.matchingChildNames(q) == ["b.cbz", "deep"])
    }

    /// 再帰検索の結果へフィルタを効かせる経路 [LF-14]。
    @Test("候補のうち条件に該当するものだけ返る [LF-14]")
    func matchingRelativePaths() async throws {
        let s = try await Setup.make()
        let q = try await s.query([2: ["C1"]])          // file1, file2 が該当
        let candidates = ["フォルダ0/file1.cbz", "フォルダ1/file2.cbz",
                          "フォルダ0/file3.cbz", "存在しない.cbz"]
        let matched = try await s.f.files.matchingRelativePaths(q, among: candidates)
        #expect(matched == ["フォルダ0/file1.cbz", "フォルダ1/file2.cbz"])
        // **候補に無いものは返らない**——DB 側の該当を全部返す実装にすると、
        // 検索結果に無いファイルまで一覧へ紛れ込む。
        #expect(try await s.f.files.matchingRelativePaths(q, among: []).isEmpty)
    }

    /// ホスト変数の上限を越える候補でも落とさない [LF-14]。
    ///
    /// **このテストは分割の有無を見分けられない**（変異検証で確認済み）——
    /// この環境の SQLite は上限が高く、1 回にまとめても結果は正しい。
    /// 実際に壊れるのは速度で、1,805 件を 1 回で問うと 0.20 秒 → 11.14 秒に
    /// なる（実測）。ここで固定しているのは「分割しても取りこぼさない」ことだけ。
    @Test("候補が上限を越えても分割して問い合わせる [LF-14]")
    func matchingRelativePathsSplitsLargeCandidateSets() async throws {
        let f = try await Fixture.make()
        let count = SQLiteManagedFileRepository.maxBoundParameters * 2 + 5
        _ = try await f.files.upsertBatch((0..<count).map {
            f.snapshot(inode: UInt64($0 + 1), path: String(format: "%05d.cbz", $0))
        })
        let candidates = (0..<count).map { String(format: "%05d.cbz", $0) }
        let matched = try await f.files.matchingRelativePaths(
            FileQuery(libraryID: f.libraryID), among: candidates)
        #expect(matched.count == count)
    }

    /// **濁点を含むフォルダ名**でも畳めること。`substr` の位置を
    /// `String.count` で数えると 1 つずれて空振りする（`sqliteOffsetAfter`
    /// のコメント参照）。
    @Test("濁点を含むフォルダ名でも子の名前を畳める [実測]")
    func matchingChildNamesUnderComposedFolderName() async throws {
        let f = try await Fixture.make()
        let parent = "ガジェット"      // NFD で来る想定の濁点入り
        _ = try await f.files.upsert(f.snapshot(inode: 1, path: "\(parent)/x.cbz"))
        _ = try await f.files.upsert(f.snapshot(inode: 2, path: "\(parent)/なか/y.cbz"))
        var q = FileQuery(libraryID: f.libraryID)
        q.scope = .folder(path: parent, recursive: false)
        #expect(try await f.files.matchingChildNames(q) == ["x.cbz", "なか"])
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

    @Test("巻数のソートは numeric < none。同点はファイル名順 [VM-15]")
    func volumeSorting() async throws {
        let f = try await Fixture.make()
        let plan: [(String, VolumeValue)] = [
            ("c.cbz", .none),
            // 区切り専用パターン（`上巻` など）に一致したファイルは巻数を持たない
            // [2026-08 の仕様変更で序列巻数を廃止]。
            ("b.cbz", .none),
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

@Suite("SQLiteLabelRepository [LB-01〜LB-07][PR-01][DB-02][IX-03][IX-04]")
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
        let labels = try await f.labels.labels(groupID: group.id)
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
            try await f.labels.labels(groupID: group.id)
                .first { $0.id == label }?.fileCount ?? -1
        }
        #expect(try await count() == 0)
        let f1 = try await f.files.upsert(f.snapshot(inode: 1, path: "1.cbz"))
        let f2 = try await f.files.upsert(f.snapshot(inode: 2, path: "2.cbz"))
        try await f.labels.assign(fileID: f1, labelID: label)
        try await f.labels.assign(fileID: f2, labelID: label)
        #expect(try await count() == 2)
        try await f.labels.assign(fileID: f1, labelID: label)   // 二重付与
        #expect(try await count() == 2, "同じ組で二重に数えてはいけない")
        try await f.labels.unassign(fileID: f1, labelID: label)
        #expect(try await count() == 1)
    }

    /// **非正規化列を撤去したので「ずれ」という概念が無くなった** [DB-02 撤回]。
    /// 帳簿を壊す手段がそもそも無いことを、`label` に件数の列が生えていない
    /// ことで固定する——将来また非正規化を持ち込むなら、これが落ちる。
    @Test("ラベルに件数の列を持たない [DB-02 撤回][§19.13 #1]")
    func labelTableHasNoDenormalizedCount() async throws {
        let f = try await Fixture.make()
        let columns = try await f.database.writer.read { db in
            try Row.fetchAll(db, sql: "PRAGMA table_info(label)").map { $0["name"] as String }
        }
        #expect(!columns.contains("fileCount"))
        #expect(columns.contains("isHidden"))
        #expect(!columns.contains("isArchived"), "ファイル側の保管庫と綴りを分けた [v14]")
    }

    @Test("ゴミ箱・保管庫のファイルは件数に数えない [TR-02][LF-13][FA-05]")
    func countExcludesTrashed() async throws {
        let f = try await Fixture.make()
        let group = try #require(try await f.labels.group(libraryID: f.libraryID, index: 2))
        let label = try await f.labels.ensureLabel(groupID: group.id, name: "C1")
        let file = try await f.files.upsert(f.snapshot(inode: 1, path: "1.cbz"))
        try await f.labels.assign(fileID: file, labelID: label)
        try await f.files.markTrashed([file], at: Date())
        #expect(try await f.labels.labels(groupID: group.id)
            .first { $0.id == label }?.fileCount == 0)
    }

    /// **保護されたフィールドは丸ごと据え置く** [PR-01][PR-02]。
    @Test("保護されたフィールドは走査が動かさない [PR-01][PR-02]")
    func manuallyRemovedIsNotRevived() async throws {
        let f = try await Fixture.make()
        let group = try #require(try await f.labels.group(libraryID: f.libraryID, index: 2))
        let keep = try await f.labels.ensureLabel(groupID: group.id, name: "残す")
        let removed = try await f.labels.ensureLabel(groupID: group.id, name: "外した")
        let file = try await f.files.upsert(f.snapshot(inode: 1, path: "1.cbz"))

        try await f.labels.replaceAutoLabels(fileID: file, labelIDs: [keep, removed])
        try await f.labels.unassign(fileID: file, labelID: removed)
        // 外したフィールドは保護される [PR-03]（製品では `AssignLabelCommand` が
        // 同じトランザクションで立てる）。
        try await f.files.setProtectedScopes([file: [.field(group.id)]])

        // 再計算で両方が当たっても、保護されたフィールドには触れない
        try await f.labels.replaceAutoLabels(fileID: file, labelIDs: [keep, removed])
        let assigned = Set(try await f.labels.labelIDs(fileID: file))
        #expect(assigned == [keep], "保護されたフィールドへ付け足してはいけない")
    }

    @Test("保護されたフィールドのラベルは走査で消えない [PR-01]")
    func manualIsNotRemovedByRecalculation() async throws {
        let f = try await Fixture.make()
        let group = try #require(try await f.labels.group(libraryID: f.libraryID, index: 2))
        let manual = try await f.labels.ensureLabel(groupID: group.id, name: "手動")
        let auto = try await f.labels.ensureLabel(groupID: group.id, name: "自動")
        let file = try await f.files.upsert(f.snapshot(inode: 1, path: "1.cbz"))
        try await f.labels.assign(fileID: file, labelID: manual)
        try await f.files.setProtectedScopes([file: [.field(group.id)]])   // [PR-03]
        try await f.labels.replaceAutoLabels(fileID: file, labelIDs: [auto])
        // 保護されたフィールドは丸ごと据え置き——`auto` も足されない [PR-01]。
        #expect(Set(try await f.labels.labelIDs(fileID: file)) == [manual])
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
        #expect(try await f.labels.labelIDs(fileID: file) == [new])
    }

    @Test("ラベルの統合 [LB-07]")
    func mergeLabels() async throws {
        let f = try await Fixture.make()
        let group = try #require(try await f.labels.group(libraryID: f.libraryID, index: 2))
        let a = try await f.labels.ensureLabel(groupID: group.id, name: "表記ゆれA")
        let b = try await f.labels.ensureLabel(groupID: group.id, name: "表記ゆれB")
        let f1 = try await f.files.upsert(f.snapshot(inode: 1, path: "1.cbz"))
        let f2 = try await f.files.upsert(f.snapshot(inode: 2, path: "2.cbz"))
        try await f.labels.assign(fileID: f1, labelID: a)
        try await f.labels.assign(fileID: f2, labelID: b)
        try await f.labels.assign(fileID: f1, labelID: b)   // 両方持つ

        try await f.labels.merge(a, into: b)
        #expect(try await f.labels.labels(groupID: group.id).map(\.id) == [b])
        #expect(try await f.labels.labelIDs(fileID: f1) == [b])
        #expect(try await f.labels.labels(groupID: group.id)
            .first?.fileCount == 2)
    }

    @Test("改名と正規化名の追従 [LB-06]")
    func renameUpdatesNormalizedName() async throws {
        let f = try await Fixture.make()
        let group = try #require(try await f.labels.group(libraryID: f.libraryID, index: 2))
        let id = try await f.labels.ensureLabel(groupID: group.id, name: "旧名")
        try await f.labels.rename(id, to: "ＮＥＷ")
        let label = try #require(try await f.labels.labels(groupID: group.id).first)
        #expect(label.name == "ＮＥＷ")
        #expect(label.normalizedName == "new")
        // 正規化名が追従しているので、同じ値で ensure すると同じ ID になる
        #expect(try await f.labels.ensureLabel(groupID: group.id, name: "new") == id)
    }

    /// **フィールドのラベル数は非表示のものも数える** [LA3-03]。
    ///
    /// フィールド編集ウインドウは非表示のラベルを一覧に出す唯一の場所なので、
    /// ここで除くと「ラベルはあるのに空のフィールド」に見え、隠したラベルを
    /// 表示に戻す手段が遠のく。
    ///
    /// **ラベルフィルタの出し分けにこの値を使わない** [LA3-05] のはそのため
    /// ——あちらは読んだラベルの `isVisible` から自分で判断する。
    @Test("フィールドのラベル数は非表示のものも数える [LA3-03]")
    func groupLabelCountIncludesHiddenLabels() async throws {
        let f = try await Fixture.make()
        let group = try #require(try await f.labels.group(libraryID: f.libraryID, index: 2))
        let id = try await f.labels.ensureLabel(groupID: group.id, name: "L")
        #expect(try await f.labels.group(libraryID: f.libraryID, index: 2)?.labelCount == 1)

        try await f.labels.setHidden([id], true)
        #expect(try await f.labels.group(libraryID: f.libraryID, index: 2)?.labelCount == 1,
                "隠しても数える——このフィールドを触れなくしてはならない")
        #expect(try await f.labels.groups(libraryID: f.libraryID)
            .first { $0.id == group.id }?.labelCount == 1)
    }

    /// **リポジトリは非表示のものも返す** [LA3-03]——出し分けは呼び出し側の
    /// 都合で、判定は `LabelSummary.isVisible` が持つ。以前は `includeArchived`
    /// で読む側が選んでいたが、意味の違う一覧が 2 通りできる形だった。
    @Test("手動での非表示とピン留め [LA3-02][LB-03]")
    func hideAndPin() async throws {
        let f = try await Fixture.make()
        let group = try #require(try await f.labels.group(libraryID: f.libraryID, index: 2))
        let id = try await f.labels.ensureLabel(groupID: group.id, name: "L")
        try await f.labels.setHidden([id], true)
        let hidden = try await f.labels.labels(groupID: group.id)
        #expect(hidden.count == 1, "一覧からは消えない——出し分けは呼び出し側 [LA3-03]")
        #expect(hidden.first?.isHidden == true)
        #expect(hidden.first?.isVisible == false)
        try await f.labels.setHidden([id], false)
        try await f.labels.setPinned(id, true)
        #expect(try await f.labels.labels(groupID: group.id).first?.isPinned == true)
    }

    /// ラベルフィルタでの並べ替え [LF-03][LG-07][ST-23]。
    @Test("グループの表示順を保存できる [LF-03][LG-07]")
    func groupOrdering() async throws {
        let f = try await Fixture.make()
        let groups = try await f.labels.groups(libraryID: f.libraryID)
        #expect(groups.count >= 3)
        let reversed = groups.reversed().map(\.id)
        try await f.labels.setGroupOrder(reversed)
        let after = try await f.labels.groups(libraryID: f.libraryID)
        #expect(after.map(\.id) == reversed)
        // **同点を作らない**——`groups()` は `displayOrder, groupIndex` の順なので、
        // 重複が残ると利用者の並べ替えが黙って `groupIndex` 順へ戻る。
        #expect(Set(after.map(\.displayOrder)).count == after.count)
    }
}
