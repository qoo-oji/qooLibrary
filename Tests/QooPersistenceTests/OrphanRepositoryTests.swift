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
        let field: FieldSummary

        static func make(orphanSize: Int64 = 1000) async throws -> Setup {
            let f = try await Fixture.make()
            let field = try #require(try await f.labels.field(libraryID: f.libraryID, index: 2))
            let orphan = try await f.files.upsert(
                f.snapshot(inode: 1, path: "旧/作品名A 第01巻.cbz", size: orphanSize))
            try await f.files.setState(.orphaned, ids: [orphan])
            return Setup(f: f, orphan: orphan, field: field)
        }

        /// 生きているレコードを 1 件足す（走査が新規として作ったものに相当）。
        @discardableResult
        func addLiveFile(inode: UInt64, path: String, size: Int64) async throws -> FileID {
            try await f.files.upsert(f.snapshot(inode: inode, path: path, size: size))
        }
    }

    // MARK: - 一覧 [OR-01][OR-02]

    @Test("孤立だけを返し、生きている行は返さない [OR-01]")
    func listsOnlyOrphanedRows() async throws {
        let s = try await Setup.make()
        try await s.addLiveFile(inode: 2, path: "新/作品名A 第01巻.cbz", size: 1000)

        let rows = try await s.f.files.orphanedFiles(libraryID: s.f.libraryID)
        #expect(rows.map(\.row.id) == [s.orphan])
        #expect(rows[0].row.state == .orphaned)
    }

    @Test("ラベル件数は manuallyRemoved を数えない [RC-04]")
    func labelCountExcludesManuallyRemoved() async throws {
        let s = try await Setup.make()
        let kept = try await s.f.labels.ensureLabel(fieldID: s.field.id, name: "サークル値A")
        let removed = try await s.f.labels.ensureLabel(fieldID: s.field.id, name: "サークル値B")
        try await s.f.labels.assign(fileID: s.orphan, labelID: kept)
        try await s.f.labels.assign(fileID: s.orphan, labelID: removed)

        let rows = try await s.f.files.orphanedFiles(libraryID: s.f.libraryID)
        #expect(rows[0].labelCount == 2)
    }

    @Test("他のライブラリの孤立は混ざらない")
    func scopesToTheGivenLibrary() async throws {
        let s = try await Setup.make()
        let other = try await Fixture.make()
        let id = try await other.files.upsert(other.snapshot(inode: 9, path: "別.cbz"))
        try await other.files.setState(.orphaned, ids: [id])

        #expect(try await s.f.files.orphanedFiles(libraryID: s.f.libraryID).count == 1)
    }

    // MARK: - 削除 [OR-04]

    @Test("削除すると紐づけも消える [OR-04]")
    func deleteRemovesAssignments() async throws {
        let s = try await Setup.make()
        let label = try await s.f.labels.ensureLabel(fieldID: s.field.id, name: "サークル値A")
        try await s.f.labels.assign(fileID: s.orphan, labelID: label)

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
        let label = try await s.f.labels.ensureLabel(fieldID: s.field.id, name: "サークル値A")
        try await s.f.labels.assign(fileID: s.orphan, labelID: label)
        let before = try await s.f.recordJSON(id: s.orphan)
        #expect(before.count >= 38, "標本が全列を埋めていない（Optional が nil のまま）")

        let snapshots = try await s.f.files.fileSnapshots(ids: [s.orphan])
        try await s.f.files.deleteFiles([s.orphan])
        try await s.f.files.restoreFiles(snapshots)

        #expect(try await s.f.recordJSON(id: s.orphan) == before)
        // 紐づけも戻る。保護スコープは `managedFile` の列なので、上の
        // 全列比較（`recordJSON`）が同時に検査している [PR-09]。
        #expect(try await s.f.labels.labelIDs(fileID: s.orphan) == [label])
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
        let label = try await s.f.labels.ensureLabel(fieldID: s.field.id, name: "サークル値A")
        let live = try await s.addLiveFile(inode: 5, path: "生きている.cbz", size: 10)
        try await s.f.labels.assign(fileID: live, labelID: label)
        try await s.f.files.setState(.active, ids: [s.orphan])
        try await s.f.labels.assign(fileID: s.orphan, labelID: label)
        #expect(try await s.f.labels.labels(fieldID: s.field.id)
            .first { $0.id == label }?.fileCount == 2)

        let snapshots = try await s.f.files.fileSnapshots(ids: [s.orphan])
        try await s.f.files.deleteFiles([s.orphan])
        #expect(try await s.f.labels.labels(fieldID: s.field.id)
            .first { $0.id == label }?.fileCount == 1)

        try await s.f.files.restoreFiles(snapshots)
        #expect(try await s.f.labels.labels(fieldID: s.field.id)
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
        let label = try await s.f.labels.ensureLabel(fieldID: s.field.id, name: "サークル値A")
        let live = try await s.addLiveFile(inode: 5, path: "生きている.cbz", size: 10)
        try await s.f.labels.assign(fileID: live, labelID: label)

        func count() async throws -> Int? {
            try await s.f.labels.labels(fieldID: s.field.id)
                .first { $0.id == label }?.fileCount
        }
        #expect(try await count() == 1)

        try await s.f.files.setState(.orphaned, ids: [live])
        #expect(try await count() == 0, "孤立にしたら数から外れる")

        try await s.f.files.setState(.active, ids: [live])
        #expect(try await count() == 1, "戻したら数に入る")
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
                    title = ?, protectedScopes = ?, seriesName = ?, seriesKey = ?,
                    volumeNumber = ?, volumeKind = ?, volumeRaw = ?, authorName = ?,
                    rating = ?, coverImageRef = ?, coverImageSource = ?,
                    isArchived = 1, archivedFromPath = ?, archivedAt = ?,
                    isBookFolder = 1,
                    pageCount = ?, subfolderCount = ?,
                    firstImageWidth = ?, firstImageHeight = ?,
                    trashedAt = ?, lastParsedFormatID = ?, libraryTypeMismatch = 1,
                    metadataStamp = ?, metadataSource = ?, metadataJSON = ?,
                    hasVolumeConflict = 1
                WHERE id = ?
                """, arguments: ["作品名A", ProtectionScopeCoding.encode([.basic]), "作品名A", "さくひんめいa",
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
