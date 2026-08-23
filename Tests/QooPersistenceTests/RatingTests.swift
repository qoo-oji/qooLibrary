import Testing
import Foundation
import GRDB
import QooKit
@testable import QooPersistence

/// 評価の読み書き [RA-01〜RA-08]。
@Suite("評価 [RA-01〜RA-08]")
struct RatingTests {

    /// シリーズ名を書き込む。`seriesKey`（正規化済み）は
    /// `applyParsedFields` が組み立てる——テストでも製品と同じ経路を通す。
    private func setSeries(_ f: Fixture, _ id: FileID, _ name: String?,
                           volume: Double? = nil) async throws {
        try await f.files.applyParsedFields(
            ParsedFileFields(
                matchedFormatID: UUID(), title: nil, seriesName: name,
                volume: volume.map { VolumeValue(kind: .numeric, number: $0, raw: "\($0)") }
                    ?? VolumeValue.none,
                authorName: nil, labelValues: [:], libraryTypeMismatch: false, spans: []),
            to: id)
    }

    @Test("星を書き込み、読み戻せる [RA-01]")
    func setAndRead() async throws {
        let f = try await Fixture.make()
        let id = try await f.files.upsert(f.snapshot(inode: 1, path: "a.cbz"))
        #expect(try await f.files.row(id: id)?.rating == 0)   // 既定は未評価

        try await f.files.setRating(4, ids: [id])
        #expect(try await f.files.row(id: id)?.rating == 4)
    }

    @Test("0 を書けば解除になる [RA-02]")
    func zeroClears() async throws {
        let f = try await Fixture.make()
        let id = try await f.files.upsert(f.snapshot(inode: 1, path: "a.cbz"))
        try await f.files.setRating(5, ids: [id])
        try await f.files.setRating(0, ids: [id])
        #expect(try await f.files.row(id: id)?.rating == 0)
    }

    @Test("範囲外は 0〜5 へ丸める")
    func clampsOutOfRange() async throws {
        let f = try await Fixture.make()
        let id = try await f.files.upsert(f.snapshot(inode: 1, path: "a.cbz"))
        try await f.files.setRating(9, ids: [id])
        #expect(try await f.files.row(id: id)?.rating == 5)
        try await f.files.setRating(-3, ids: [id])
        #expect(try await f.files.row(id: id)?.rating == 0)
    }

    @Test("渡した ID 以外には触れない")
    func leavesOtherFilesAlone() async throws {
        let f = try await Fixture.make()
        let a = try await f.files.upsert(f.snapshot(inode: 1, path: "a.cbz"))
        let b = try await f.files.upsert(f.snapshot(inode: 2, path: "b.cbz"))
        try await f.files.setRating(3, ids: [a])
        #expect(try await f.files.row(id: a)?.rating == 3)
        #expect(try await f.files.row(id: b)?.rating == 0)
    }

    /// **これが崩れると評価が黙って消える。** 走査は `updateInPlace` で
    /// パス・サイズ・更新日時だけを書き換える設計だが、SQL に `rating` を
    /// 足してしまうと再スキャンのたびに 0 へ戻る——しかもユーザーには
    /// 「なぜか星が消えている」としか見えない。
    @Test("再スキャンで消えない [ID-08]")
    func survivesRescan() async throws {
        let f = try await Fixture.make()
        let id = try await f.files.upsert(f.snapshot(inode: 1, path: "a.cbz"))
        try await f.files.setRating(4, ids: [id])
        // 同じ同一性・違うパスとサイズ（＝改名して中身が変わった状態）で再投入。
        _ = try await f.files.upsert(f.snapshot(inode: 1, path: "sub/renamed.cbz", size: 9999))
        let row = try #require(try await f.files.row(id: id))
        #expect(row.relativePath == "sub/renamed.cbz")
        #expect(row.rating == 4)
    }

    // MARK: - シリーズ [RA-04][RA-05][RA-07]

    @Test("同じシリーズの全巻が返り、基準のファイル自身も含む [RA-04]")
    func seriesIncludesAnchor() async throws {
        let f = try await Fixture.make()
        let v1 = try await f.files.upsert(f.snapshot(inode: 1, path: "1.cbz"))
        let v2 = try await f.files.upsert(f.snapshot(inode: 2, path: "2.cbz"))
        let other = try await f.files.upsert(f.snapshot(inode: 3, path: "x.cbz"))
        try await setSeries(f, v1, "作品名A", volume: 1)
        try await setSeries(f, v2, "作品名A", volume: 2)
        try await setSeries(f, other, "作品名B", volume: 1)

        let rows = try await f.files.filesInSameSeries(as: v1)
        #expect(Set(rows.map(\.id)) == [v1, v2])
    }

    /// 呼び出し側にシリーズ名を渡させる形にすると、ここが黙って漏れる。
    @Test("表記ゆれのある巻も同じシリーズとして拾う（`seriesKey` で照合）")
    func seriesMatchesOnNormalizedKey() async throws {
        let f = try await Fixture.make()
        let a = try await f.files.upsert(f.snapshot(inode: 1, path: "1.cbz"))
        let b = try await f.files.upsert(f.snapshot(inode: 2, path: "2.cbz"))
        try await setSeries(f, a, "作品名Ａ")        // 全角
        try await setSeries(f, b, "作品名A")         // 半角
        let rows = try await f.files.filesInSameSeries(as: a)
        #expect(Set(rows.map(\.id)) == [a, b])
    }

    @Test("シリーズ名を持たなければ空 [RA-07]")
    func noSeriesReturnsEmpty() async throws {
        let f = try await Fixture.make()
        let id = try await f.files.upsert(f.snapshot(inode: 1, path: "a.cbz"))
        #expect(try await f.files.filesInSameSeries(as: id).isEmpty)
    }

    @Test("ゴミ箱のレコードは含めない")
    func excludesTrashed() async throws {
        let f = try await Fixture.make()
        let a = try await f.files.upsert(f.snapshot(inode: 1, path: "1.cbz"))
        let b = try await f.files.upsert(f.snapshot(inode: 2, path: "2.cbz"))
        try await setSeries(f, a, "作品名A", volume: 1)
        try await setSeries(f, b, "作品名A", volume: 2)
        try await f.files.markTrashed([b], at: Date())
        #expect(try await f.files.filesInSameSeries(as: a).map(\.id) == [a])
    }

    /// 外付けを抜いているあいだに全巻へ適用したら、挿し直したときだけ
    /// 1 冊違う——という形にしない。
    @Test("孤立・オフラインのレコードは含める [ID-08]")
    func includesOrphaned() async throws {
        let f = try await Fixture.make()
        let a = try await f.files.upsert(f.snapshot(inode: 1, path: "1.cbz"))
        let b = try await f.files.upsert(f.snapshot(inode: 2, path: "2.cbz"))
        try await setSeries(f, a, "作品名A", volume: 1)
        try await setSeries(f, b, "作品名A", volume: 2)
        try await f.files.setState(.orphaned, ids: [b])
        #expect(Set(try await f.files.filesInSameSeries(as: a).map(\.id)) == [a, b])
    }

    @Test("別のライブラリの同名シリーズは混ざらない")
    func doesNotCrossLibraries() async throws {
        let f = try await Fixture.make()
        let other = try await f.libraries.register(
            LibraryRegistration(uuid: UUID(), displayName: "別", bookmarkData: Data(),
                                resolvedPath: "/tmp/lib2", volumeUUID: "VOL2",
                                libraryTypeID: LibraryTypeID(rawValue: 0)),
            template: try #require(try BuiltInTemplates.libraryTypes()
                .first { $0.key == "builtin.doujinshi-a" }))
        let mine = try await f.files.upsert(f.snapshot(inode: 1, path: "1.cbz"))
        let theirs = try await f.files.upsert(
            FileSnapshot(identity: FileIdentity(volumeUUID: "VOL2", inode: 1),
                         libraryID: other, relativePath: "1.cbz", filename: "1.cbz",
                         fileSize: 1, createdAt: Date(), modifiedAt: Date()))
        try await setSeries(f, mine, "作品名A", volume: 1)
        try await setSeries(f, theirs, "作品名A", volume: 1)
        #expect(try await f.files.filesInSameSeries(as: mine).map(\.id) == [mine])
    }

    @Test("900 件を超えても全件に書ける（分割の境界）")
    func writesBeyondTheChunkBoundary() async throws {
        let f = try await Fixture.make()
        var ids: [FileID] = []
        for i in 0..<1_000 {
            ids.append(try await f.files.upsert(f.snapshot(inode: UInt64(i + 1), path: "\(i).cbz")))
        }
        try await f.files.setRating(2, ids: ids)
        #expect(try await f.files.row(id: ids[0])?.rating == 2)
        #expect(try await f.files.row(id: ids[950])?.rating == 2)
    }
}
