import Foundation
import Testing
@testable import QooInfrastructure
@testable import QooKit

//
//  アーカイブ／フォルダの中からカバーに使うページを選ぶ [CV-05][TH-06]。
//

@Suite("カバーにするページの候補 [CV-05]")
struct ArchiveCoverPickerTests {

    private final class Workspace {
        let root: URL
        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("qoo-coverpick-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
        deinit { try? FileManager.default.removeItem(at: root) }
    }

    private func makeArchive(in w: Workspace, entries: [String]) throws -> URL {
        let url = w.root.appendingPathComponent("book.cbz")
        let page = TestImageFixture.makePNGData(width: 8, height: 8)
        try ArchiveFixtureBuilder.makeZip(at: url, entries: entries.map {
            .file($0, contents: $0.hasSuffix(".txt") ? Data("メモ".utf8) : page)
        })
        return url
    }

    @Test("アーカイブ内の画像だけを自然順で並べる [CV-05]")
    func listsImageEntriesNaturally() async throws {
        let w = try Workspace()
        let url = try makeArchive(in: w, entries: ["010.png", "002.png", "info.txt", "001.png"])
        let candidates = await ArchiveCoverPicker(url: url).candidates()
        #expect(candidates.map(\.name) == ["001.png", "002.png", "010.png"],
                "テキストは候補にせず、10 は 2 の後ろへ")
    }

    @Test("候補の件数を区切れる")
    func respectsLimit() async throws {
        let w = try Workspace()
        let url = try makeArchive(in: w, entries: ["001.png", "002.png", "003.png"])
        #expect(await ArchiveCoverPicker(url: url).candidates(limit: 2).count == 2)
    }

    @Test("候補の中身を読める [CV-05]")
    func readsCandidateData() async throws {
        let w = try Workspace()
        let url = try makeArchive(in: w, entries: ["001.png", "002.png"])
        let picker = ArchiveCoverPicker(url: url)
        let candidate = try #require(await picker.candidates().first)
        let data = try #require(await picker.data(for: candidate))
        #expect(DefaultImageLoader().imageSize(from: data) == CGSize(width: 8, height: 8))
    }

    /// **同時に要求されても 1 本ずつ処理する** [TH-02]。solid 圧縮の 7z / RAR は
    /// N 件目を取り出すのに 1〜N 件目を復号するため、可視セルぶんを一斉に
    /// 走らせると費用が積の形で効く。
    @Test("同時要求でも全件正しく返る")
    func concurrentRequestsAllResolve() async throws {
        let w = try Workspace()
        let names = (1...12).map { String(format: "%03d.png", $0) }
        let url = try makeArchive(in: w, entries: names)
        let picker = ArchiveCoverPicker(url: url)
        let candidates = await picker.candidates()
        let results = await withTaskGroup(of: Bool.self) { group in
            for candidate in candidates {
                group.addTask { await picker.data(for: candidate) != nil }
            }
            var all: [Bool] = []
            for await ok in group { all.append(ok) }
            return all
        }
        #expect(results.count == 12)
        #expect(results.allSatisfy { $0 })
    }

    @Test("フォルダ直下の画像も候補にする [IF-14]")
    func listsFolderChildren() async throws {
        let w = try Workspace()
        let folder = w.root.appendingPathComponent("book", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in ["002.png", "001.png"] {
            try TestImageFixture.makePNGData(width: 8, height: 8)
                .write(to: folder.appendingPathComponent(name))
        }
        try Data("メモ".utf8).write(to: folder.appendingPathComponent("メモ.txt"))
        let picker = ArchiveCoverPicker(url: folder)
        #expect(await picker.candidates().map(\.name) == ["001.png", "002.png"])
        let candidate = try #require(await picker.candidates().first)
        #expect(await picker.data(for: candidate) != nil)
    }

    @Test("中を見られない種別では候補が空")
    func nonContainerHasNoCandidates() async throws {
        let w = try Workspace()
        let url = w.root.appendingPathComponent("メモ.txt")
        try Data("メモ".utf8).write(to: url)
        #expect(await ArchiveCoverPicker(url: url).candidates().isEmpty)
    }
}
