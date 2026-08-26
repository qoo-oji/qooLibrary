//
//  孤立ファイルの整理が使うリポジトリ API [OR-01〜OR-04][ID-05][UD-03]。
//
//  削除と再紐づけは `managedFile` の行を物理的に消すので、Undo は
//  「行を作り直す」形になる（ラベル削除と同じ）。**元の ID へ全列そのまま
//  戻せることがこの一連の要**なので、そこを重点的に固定する。
//
import Testing
import Foundation
import GRDB
import QooKit
@testable import QooPersistence

@Suite("孤立ファイルの整理 [OR-01〜OR-04]")
struct OrphanRepositoryTests {

    /// 孤立 1 件と、同じ名前で生きている候補 1 件を用意する。
    struct Setup {
        let f: Fixture
        let orphan: FileID
        let group: LabelGroupSummary

        static func make(orphanSize: Int64 = 1000) async throws -> Setup {
            let f = try await Fixture.make()
            let group = try #require(try await f.labels.group(libraryID: f.libraryID, index: 2))
            let orphan = try await f.files.upsert(
                f.snapshot(inode: 1, path: "旧/作品名A 第01巻.cbz", size: orphanSize))
            try await f.files.setState(.orphaned, ids: [orphan])
            return Setup(f: f, orphan: orphan, group: group)
        }

        /// 同じ名前で生きているレコード（走査が新規として作ったもの）を足す。
        @discardableResult
        func addCandidate(inode: UInt64, path: String, size: Int64) async throws -> FileID {
            try await f.files.upsert(f.snapshot(inode: inode, path: path, size: size))
        }
    }

    // MARK: - 一覧 [OR-01][OR-02]

    @Test("孤立だけを返し、生きている行は返さない [OR-01]")
    func listsOnlyOrphanedRows() async throws {
        let s = try await Setup.make()
        try await s.addCandidate(inode: 2, path: "新/作品名A 第01巻.cbz", size: 1000)

        let rows = try await s.f.files.orphanedFiles(libraryID: s.f.libraryID)
        #expect(rows.map(\.row.id) == [s.orphan])
        #expect(rows[0].row.state == .orphaned)
    }

    @Test("同じ名前で生きている行を候補として出す [OR-02][ID-05]")
    func surfacesCandidatesByName() async throws {
        let s = try await Setup.make()
        let candidate = try await s.addCandidate(inode: 2, path: "新/作品名A 第01巻.cbz", size: 1000)

        let rows = try await s.f.files.orphanedFiles(libraryID: s.f.libraryID)
        #expect(rows[0].candidates.map(\.fileID) == [candidate])
        #expect(rows[0].candidates[0].sizeMatches)
        #expect(rows[0].candidates[0].relativePath == "新/作品名A 第01巻.cbz")
    }

    @Test("名前が違えば候補にしない")
    func doesNotSurfaceUnrelatedFiles() async throws {
        let s = try await Setup.make()
        try await s.addCandidate(inode: 2, path: "新/作品名B 第01巻.cbz", size: 1000)

        let rows = try await s.f.files.orphanedFiles(libraryID: s.f.libraryID)
        #expect(rows[0].candidates.isEmpty)
    }

    @Test("大きさも一致する候補を先に並べる")
    func ordersCandidatesBySizeMatchFirst() async throws {
        let s = try await Setup.make(orphanSize: 1000)
        // わざと「大きさの違うほう」を先に入れて、並べ替えが効くことを見る。
        try await s.addCandidate(inode: 2, path: "A/作品名A 第01巻.cbz", size: 55)
        let same = try await s.addCandidate(inode: 3, path: "B/作品名A 第01巻.cbz", size: 1000)

        let rows = try await s.f.files.orphanedFiles(libraryID: s.f.libraryID)
        #expect(rows[0].candidates.count == 2)
        #expect(rows[0].candidates[0].fileID == same)
        #expect(rows[0].candidates[0].sizeMatches)
        #expect(!rows[0].candidates[1].sizeMatches)
    }

    @Test("孤立どうしは候補にしない（生きている行だけ）")
    func doesNotOfferAnotherOrphanAsCandidate() async throws {
        let s = try await Setup.make()
        let other = try await s.addCandidate(inode: 2, path: "他/作品名A 第01巻.cbz", size: 1000)
        try await s.f.files.setState(.orphaned, ids: [other])

        let rows = try await s.f.files.orphanedFiles(libraryID: s.f.libraryID)
        #expect(rows.count == 2)
        #expect(rows.allSatisfy { $0.candidates.isEmpty })
    }

    @Test("ラベル件数は manuallyRemoved を数えない [RC-04]")
    func labelCountExcludesManuallyRemoved() async throws {
        let s = try await Setup.make()
        let kept = try await s.f.labels.ensureLabel(groupID: s.group.id, name: "サークル値A")
        let removed = try await s.f.labels.ensureLabel(groupID: s.group.id, name: "サークル値B")
        try await s.f.labels.assign(fileID: s.orphan, labelID: kept, origin: .manual)
        try await s.f.labels.assign(fileID: s.orphan, labelID: removed, origin: .manuallyRemoved)

        let rows = try await s.f.files.orphanedFiles(libraryID: s.f.libraryID)
        #expect(rows[0].labelCount == 1)
    }

    @Test("他のライブラリの孤立は混ざらない")
    func scopesToTheGivenLibrary() async throws {
        let s = try await Setup.make()
        let other = try await Fixture.make()
        let id = try await other.files.upsert(other.snapshot(inode: 9, path: "別.cbz"))
        try await other.files.setState(.orphaned, ids: [id])

        #expect(try await s.f.files.orphanedFiles(libraryID: s.f.libraryID).count == 1)
    }

    // MARK: - 再紐づけ [OR-02][OR-03][ID-04]

    @Test("候補側のレコードを消して、孤立側を結び直す［ユーザー判断］")
    func reattachRemovesTheDuplicateAndKeepsTheOrphanRow() async throws {
        let s = try await Setup.make()
        let candidate = try await s.addCandidate(inode: 2, path: "新/作品名A 第01巻.cbz", size: 1000)
        let label = try await s.f.labels.ensureLabel(groupID: s.group.id, name: "サークル値A")
        try await s.f.labels.assign(fileID: s.orphan, labelID: label, origin: .manual)
        try await s.f.files.setRating(4, ids: [s.orphan])

        let observed = s.f.snapshot(inode: 2, path: "新/作品名A 第01巻.cbz", size: 1000)
        let removed = try await s.f.files.reattachOrphan(s.orphan, to: observed)

        #expect(removed == candidate)
        #expect(try await s.f.files.row(id: candidate) == nil)
        let row = try #require(try await s.f.files.row(id: s.orphan))
        // 孤立側の行が生き残り、ラベルと評価がそのまま残る [ID-04]。
        #expect(row.state == .active)
        #expect(row.relativePath == "新/作品名A 第01巻.cbz")
        #expect(row.rating == 4)
        #expect(try await s.f.labels.labelIDs(fileID: s.orphan).map(\.labelID) == [label])
        // 同一性が観測したものへ移っている。
        #expect(try await s.f.files.find(identity: observed.identity) == s.orphan)
    }

    @Test("候補が DB に無くても結び直せる（手動選択）[OR-03]")
    func reattachWorksWhenNoDuplicateExists() async throws {
        let s = try await Setup.make()
        let observed = s.f.snapshot(inode: 7, path: "どこか/別名.cbz", size: 2000)

        let removed = try await s.f.files.reattachOrphan(s.orphan, to: observed)

        #expect(removed == nil)
        let row = try #require(try await s.f.files.row(id: s.orphan))
        #expect(row.state == .active)
        #expect(row.filename == "別名.cbz")
        #expect(row.fileSize == 2000)
    }

    @Test("再紐づけのあと、タイトルでの検索に出る [SR-03]")
    func reattachRebuildsTheSearchKey() async throws {
        let s = try await Setup.make()
        // 手動タイトルを持つ孤立レコード。`updateInPlace` は searchKey に
        // stem しか書かないので、作り直さないとこの語で引けなくなる。
        try await s.f.files.setFields(
            FileFieldEdit(title: "ZZZTitle", titleOrigin: .manual, seriesName: nil,
                          volume: .none, authorName: nil),
            id: s.orphan)
        let observed = s.f.snapshot(inode: 2, path: "新/作品名A 第01巻.cbz", size: 1000)
        try await s.f.files.reattachOrphan(s.orphan, to: observed)

        var q = FileQuery(libraryID: s.f.libraryID, mode: .libraryFlat)
        q.searchText = "zzztitle"
        #expect(try await s.f.files.query(q).rows.map(\.id) == [s.orphan])
    }

    // MARK: - 同一性の確認 [ID-05][ID-11]

    @Test("確認待ちは候補を持つものだけ [ID-05]")
    func awaitingDecisionOnlyIncludesRowsWithCandidates() async throws {
        let s = try await Setup.make()
        // 候補なしの孤立を 1 件足す（名前が違うので候補が付かない）。
        let lonely = try await s.addCandidate(inode: 8, path: "旧/別作品.cbz", size: 10)
        try await s.f.files.setState(.orphaned, ids: [lonely])
        try await s.addCandidate(inode: 2, path: "新/作品名A 第01巻.cbz", size: 1000)

        let pending = try await s.f.files.identityMatchesAwaitingDecision(libraryID: s.f.libraryID)
        #expect(pending.map(\.row.id) == [s.orphan])
    }

    /// **同じ場所の差し替えは、別の場所の同名ファイルより確からしい** [ID-09]。
    @Test("同じパスの候補には印が付き、先に並ぶ [ID-09]")
    func samePathCandidatesAreMarkedAndSortedFirst() async throws {
        let s = try await Setup.make()
        try await s.addCandidate(inode: 2, path: "別/作品名A 第01巻.cbz", size: 55)
        // 孤立と同じ場所に、大きさの違うファイルが置き直された（差し替え）。
        let replaced = try await s.addCandidate(inode: 3, path: "旧/作品名A 第01巻.cbz", size: 77)

        let pending = try await s.f.files.identityMatchesAwaitingDecision(libraryID: s.f.libraryID)
        let candidates = try #require(pending.first?.candidates)
        #expect(candidates.first?.fileID == replaced)
        #expect(candidates.first?.samePath == true)
        #expect(candidates.last?.samePath == false)
    }

    @Test("承認すると孤立側が生き残り、候補側は消える [ID-05]")
    func acceptingKeepsTheOrphanRow() async throws {
        let s = try await Setup.make()
        let candidate = try await s.addCandidate(inode: 2, path: "新/作品名A 第01巻.cbz", size: 1000)
        let label = try await s.f.labels.ensureLabel(groupID: s.group.id, name: "サークル値A")
        try await s.f.labels.assign(fileID: s.orphan, labelID: label, origin: .manual)

        let removed = try await s.f.files.acceptIdentityMatches(
            [IdentityMatch(orphanID: s.orphan, candidateID: candidate)])

        #expect(removed == [candidate])
        let row = try #require(try await s.f.files.row(id: s.orphan))
        #expect(row.state == .active)
        #expect(row.relativePath == "新/作品名A 第01巻.cbz")
        #expect(try await s.f.labels.labelIDs(fileID: s.orphan).map(\.labelID) == [label])
        #expect(try await s.f.files.row(id: candidate) == nil)
    }

    /// **一度答えた組を毎回聞き直しては使い物にならない** [ID-11]。
    @Test("却下した組は以後の確認に出てこない [ID-11]")
    func rejectedMatchesAreNotAskedAgain() async throws {
        let s = try await Setup.make()
        let candidate = try await s.addCandidate(inode: 2, path: "新/作品名A 第01巻.cbz", size: 1000)
        let match = IdentityMatch(orphanID: s.orphan, candidateID: candidate)

        try await s.f.files.rejectIdentityMatches([match])

        #expect(try await s.f.files.identityMatchesAwaitingDecision(libraryID: s.f.libraryID)
            .isEmpty)
        // **見つからないファイルの一覧からは消えない**——実体はまだ無いので、
        // 利用者が削除するまで残る [OR-01][OR-04]。
        #expect(try await s.f.files.orphanedFiles(libraryID: s.f.libraryID).count == 1)
    }

    @Test("却下を取り消すと、また確認に出てくる [ID-11]")
    func clearingARejectionMakesItAskAgain() async throws {
        let s = try await Setup.make()
        let candidate = try await s.addCandidate(inode: 2, path: "新/作品名A 第01巻.cbz", size: 1000)
        let match = IdentityMatch(orphanID: s.orphan, candidateID: candidate)
        try await s.f.files.rejectIdentityMatches([match])

        try await s.f.files.clearIdentityRejections([match])

        #expect(try await s.f.files.identityMatchesAwaitingDecision(libraryID: s.f.libraryID)
            .count == 1)
    }

    /// 却下の記録は組の片方が消えれば意味を持たない（`ON DELETE CASCADE`）。
    @Test("孤立レコードを削除すると却下の記録も消える")
    func deletingTheOrphanClearsTheRejection() async throws {
        let s = try await Setup.make()
        let candidate = try await s.addCandidate(inode: 2, path: "新/作品名A 第01巻.cbz", size: 1000)
        try await s.f.files.rejectIdentityMatches(
            [IdentityMatch(orphanID: s.orphan, candidateID: candidate)])

        try await s.f.files.deleteFiles([s.orphan])

        let count = try await s.f.database.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM identityRejection") ?? -1
        }
        #expect(count == 0)
    }

    @Test("却下は空でも二重でも落ちない")
    func rejectToleratesEmptyAndDuplicateInput() async throws {
        let s = try await Setup.make()
        let candidate = try await s.addCandidate(inode: 2, path: "新/作品名A 第01巻.cbz", size: 1000)
        let match = IdentityMatch(orphanID: s.orphan, candidateID: candidate)
        try await s.f.files.rejectIdentityMatches([])
        try await s.f.files.rejectIdentityMatches([match])
        try await s.f.files.rejectIdentityMatches([match])
        #expect(try await s.f.files.identityMatchesAwaitingDecision(libraryID: s.f.libraryID)
            .isEmpty)
    }

    // MARK: - 削除 [OR-04]

    @Test("削除すると紐づけも消える [OR-04]")
    func deleteRemovesAssignments() async throws {
        let s = try await Setup.make()
        let label = try await s.f.labels.ensureLabel(groupID: s.group.id, name: "サークル値A")
        try await s.f.labels.assign(fileID: s.orphan, labelID: label, origin: .manual)

        try await s.f.files.deleteFiles([s.orphan])

        #expect(try await s.f.files.row(id: s.orphan) == nil)
        #expect(try await s.f.labels.labelIDs(fileID: s.orphan).isEmpty)
    }

    @Test("削除は空でも存在しない ID でも落ちない")
    func deleteToleratesEmptyInput() async throws {
        let s = try await Setup.make()
        try await s.f.files.deleteFiles([])
        try await s.f.files.deleteFiles([FileID(rawValue: 9999)])
    }

    // MARK: - 写しと復元（Undo の土台）[UD-03]

    /// **列を足して写し忘れると落ちる検査。**
    ///
    /// `ManagedFileRecord` を JSON へ符号化して丸ごと突き合わせるので、
    /// フィールドを列挙せずに全列を検査できる（`LibrarySettingsPayloadTests`
    /// の往復検査と同じ考え方）。**Optional をすべて非 nil で埋める**のが
    /// 要点——`JSONEncoder` は nil のキーを省くので、標本が nil のままだと
    /// 写し漏れがあっても両側から同じように消えて一致してしまう
    /// （`BackupTests` で実際に踏んだ空振り）。
    @Test("削除 → 復元で、全列が元のまま戻る")
    func everyColumnSurvivesADeleteAndRestore() async throws {
        let s = try await Setup.make()
        try await s.f.fillEveryOptionalColumn(of: s.orphan)
        let label = try await s.f.labels.ensureLabel(groupID: s.group.id, name: "サークル値A")
        try await s.f.labels.assign(fileID: s.orphan, labelID: label, origin: .manuallyRemoved)
        let before = try await s.f.recordJSON(id: s.orphan)
        #expect(before.count >= 38, "標本が全列を埋めていない（Optional が nil のまま）")

        let snapshots = try await s.f.files.fileSnapshots(ids: [s.orphan])
        try await s.f.files.deleteFiles([s.orphan])
        try await s.f.files.restoreFiles(snapshots)

        #expect(try await s.f.recordJSON(id: s.orphan) == before)
        // 紐づけは origin ごと戻る——`manuallyRemoved` を落とすと、⌘Z のあと
        // 再スキャンで外したはずのラベルが復活する [RC-04]。
        let assignments = try await s.f.labels.labelIDs(fileID: s.orphan)
        #expect(assignments.map(\.labelID) == [label])
        #expect(assignments.map(\.origin) == [.manuallyRemoved])
    }

    @Test("復元は元の行 ID を取り戻す")
    func restoreBringsBackTheSameRowID() async throws {
        let s = try await Setup.make()
        let snapshots = try await s.f.files.fileSnapshots(ids: [s.orphan])
        try await s.f.files.deleteFiles([s.orphan])
        // 削除した ID が再利用されないことを、間に別の行を作って確かめる。
        let inserted = try await s.f.files.upsert(s.f.snapshot(inode: 42, path: "割り込み.cbz"))
        #expect(inserted != s.orphan)

        try await s.f.files.restoreFiles(snapshots)
        #expect(try await s.f.files.row(id: s.orphan) != nil)
    }

    @Test("復元でラベルの件数が直る [DB-02]")
    func restoreRecountsLabels() async throws {
        let s = try await Setup.make()
        let label = try await s.f.labels.ensureLabel(groupID: s.group.id, name: "サークル値A")
        let live = try await s.addCandidate(inode: 5, path: "生きている.cbz", size: 10)
        try await s.f.labels.assign(fileID: live, labelID: label, origin: .auto)
        try await s.f.files.setState(.active, ids: [s.orphan])
        try await s.f.labels.assign(fileID: s.orphan, labelID: label, origin: .auto)
        #expect(try await s.f.labels.labels(groupID: s.group.id, includeArchived: true)
            .first { $0.id == label }?.fileCount == 2)

        let snapshots = try await s.f.files.fileSnapshots(ids: [s.orphan])
        try await s.f.files.deleteFiles([s.orphan])
        #expect(try await s.f.labels.labels(groupID: s.group.id, includeArchived: true)
            .first { $0.id == label }?.fileCount == 1)

        try await s.f.files.restoreFiles(snapshots)
        #expect(try await s.f.labels.labels(groupID: s.group.id, includeArchived: true)
            .first { $0.id == label }?.fileCount == 2)
    }

    /// **孤立にした時点で件数が減らなければならない** [DB-02][LE-03]。
    ///
    /// この検査を後から足したのは、変異検証で `setState` の数え直しを外しても
    /// 1 件も落ちなかったため——**走査が孤立にしたあと件数が古いまま残る**
    /// という、まさに今回直した既存の欠陥を誰も見張っていなかった
    /// （`fileCount` は「生きていて保管庫にも入っていない」ファイルだけを数える）。
    @Test("孤立にすると件数から外れ、戻すと数え直される [DB-02]")
    func changingStateUpdatesLabelCounts() async throws {
        let s = try await Setup.make()
        let label = try await s.f.labels.ensureLabel(groupID: s.group.id, name: "サークル値A")
        let live = try await s.addCandidate(inode: 5, path: "生きている.cbz", size: 10)
        try await s.f.labels.assign(fileID: live, labelID: label, origin: .auto)

        func count() async throws -> Int? {
            try await s.f.labels.labels(groupID: s.group.id, includeArchived: true)
                .first { $0.id == label }?.fileCount
        }
        #expect(try await count() == 1)

        try await s.f.files.setState(.orphaned, ids: [live])
        #expect(try await count() == 0, "孤立にしたら数から外れる")

        try await s.f.files.setState(.active, ids: [live])
        #expect(try await count() == 1, "戻したら数に入る")
    }

    @Test("再紐づけの Undo は、消した候補側も一緒に戻る")
    func restoringBothSidesUndoesAReattach() async throws {
        let s = try await Setup.make()
        let candidate = try await s.addCandidate(inode: 2, path: "新/作品名A 第01巻.cbz", size: 1000)
        let before = try await s.f.files.fileSnapshots(ids: [s.orphan, candidate])

        let observed = s.f.snapshot(inode: 2, path: "新/作品名A 第01巻.cbz", size: 1000)
        try await s.f.files.reattachOrphan(s.orphan, to: observed)
        try await s.f.files.restoreFiles(before)

        let orphan = try #require(try await s.f.files.row(id: s.orphan))
        #expect(orphan.state == .orphaned)
        #expect(orphan.relativePath == "旧/作品名A 第01巻.cbz")
        let revived = try #require(try await s.f.files.row(id: candidate))
        #expect(revived.relativePath == "新/作品名A 第01巻.cbz")
        // 同一性の UNIQUE 制約に阻まれず、候補側が inode を取り戻している。
        #expect(try await s.f.files.find(identity: observed.identity) == candidate)
    }

    @Test("写しは存在しない ID を飛ばす")
    func snapshotSkipsMissingRows() async throws {
        let s = try await Setup.make()
        let snapshots = try await s.f.files.fileSnapshots(
            ids: [s.orphan, FileID(rawValue: 9999)])
        #expect(snapshots.map(\.id) == [s.orphan])
    }
}

// MARK: - 検査の道具

extension Fixture {
    /// 行の全列を JSON として読む。**列を足して写し忘れたら往復検査が落ちる**
    /// ようにするための観測手段で、製品コードは使わない。
    func recordJSON(id: FileID) async throws -> [String: String] {
        try await database.writer.read { db in
            let record = try #require(try ManagedFileRecord.fetchOne(db, key: id.rawValue))
            let data = try JSONEncoder().encode(record)
            let object = try #require(try JSONSerialization.jsonObject(with: data)
                                        as? [String: Any])
            return object.mapValues { String(describing: $0) }
        }
    }

    /// Optional の列をすべて非 nil で埋める。`JSONEncoder` は nil のキーを
    /// 省くので、これをやらないと往復検査が空振りする。
    func fillEveryOptionalColumn(of id: FileID) async throws {
        try await database.writer.write { db in
            try db.execute(sql: """
                UPDATE managedFile SET
                    title = ?, titleOrigin = ?, seriesName = ?, seriesKey = ?,
                    volumeNumber = ?, volumeKind = ?, volumeRaw = ?, authorName = ?,
                    rating = ?, coverImageRef = ?, coverImageSource = ?,
                    isArchived = 1, archivedFromPath = ?, archivedAt = ?,
                    isBookFolder = 1, isDuplicateRepresentativePinned = 1,
                    pageCount = ?, subfolderCount = ?,
                    firstImageWidth = ?, firstImageHeight = ?,
                    trashedAt = ?, lastParsedFormatID = ?, libraryTypeMismatch = 1,
                    metadataStamp = ?, metadataSource = ?, metadataJSON = ?,
                    hasVolumeConflict = 1
                WHERE id = ?
                """, arguments: ["作品名A", ValueOrigin.manual.rawValue, "作品名A", "さくひんめいa",
                                 1.5, VolumeValue.Kind.numeric.rawValue, "第01巻", "著者値A",
                                 3, "cover-ref", CoverSource.userSpecified.rawValue,
                                 "旧/作品名A 第01巻.cbz", 700.0,
                                 12, 3, 1440, 2048,
                                 800.0, "format-1",
                                 "900|1000", "comicinfo", "{\"title\":\"作品名A\"}",
                                 id.rawValue])
        }
    }
}
