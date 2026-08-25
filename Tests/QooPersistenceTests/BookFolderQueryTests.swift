import Foundation
import GRDB
import QooKit
import Testing
@testable import QooPersistence

//
//  フォルダ表示モードでブックフォルダに印を出すための問い合わせ [IF-17][BF-08]。
//
//  ブックフォルダは「サブフォルダを持たず、直下に対象拡張子ファイルが 0 件かつ
//  画像ファイルが 1 件以上」のフォルダ [IF-01]。走査が出した答え
//  （`isBookFolder`）を引くだけで、ここでは規則を計算し直さない。
//

@Suite("直下のブックフォルダ [IF-17]")
struct BookFolderQueryTests {

    private func snapshot(_ f: Fixture, inode: UInt64, path: String,
                          isBookFolder: Bool) -> FileSnapshot {
        FileSnapshot(identity: FileIdentity(volumeUUID: "VOL", inode: inode),
                     libraryID: f.libraryID, relativePath: path,
                     filename: (path as NSString).lastPathComponent,
                     fileSize: 1, createdAt: .distantPast, modifiedAt: .distantPast,
                     isBookFolder: isBookFolder)
    }

    @Test("直下のブックフォルダだけを返す [IF-17]")
    func returnsOnlyDirectChildren() async throws {
        let f = try await Fixture.make()
        _ = try await f.files.upsert(snapshot(f, inode: 1, path: "直下の本", isBookFolder: true))
        _ = try await f.files.upsert(snapshot(f, inode: 2, path: "直下のアーカイブ.cbz",
                                              isBookFolder: false))
        // **深い所のブックフォルダは返さない**——`作品A` は通常のフォルダで、
        // 印を付ける対象ではない（`matchingChildNames` のように畳まない）。
        _ = try await f.files.upsert(snapshot(f, inode: 3, path: "作品A/第01巻",
                                              isBookFolder: true))

        let names = try await f.files.bookFolderChildNames(libraryID: f.libraryID,
                                                           relativePath: "")
        #expect(names == ["直下の本"])
    }

    @Test("現在のフォルダを基準にする [IF-17]")
    func isRelativeToTheCurrentFolder() async throws {
        let f = try await Fixture.make()
        _ = try await f.files.upsert(snapshot(f, inode: 1, path: "作品A/第01巻",
                                              isBookFolder: true))
        _ = try await f.files.upsert(snapshot(f, inode: 2, path: "作品A/第02巻",
                                              isBookFolder: true))
        _ = try await f.files.upsert(snapshot(f, inode: 3, path: "作品B/第01巻",
                                              isBookFolder: true))

        let a = try await f.files.bookFolderChildNames(libraryID: f.libraryID,
                                                       relativePath: "作品A")
        #expect(a == ["第01巻", "第02巻"])
        #expect(try await f.files.bookFolderChildNames(libraryID: f.libraryID,
                                                       relativePath: "") .isEmpty)
    }

    /// **濁点を含むフォルダ名で 1 件も一致しない**、という形の誤りを防ぐ。
    /// SQLite の `substr`/`instr` はコードポイントで数えるが Swift の
    /// `String.count` は書記素で数えるので、位置を `String.count` から作ると
    /// NFD のファイル名（macOS の既定）でずれる [10章 §10.6 の実測]。
    @Test("濁点を含むフォルダ名でも直下と判定できる [NFD]")
    func handlesDecomposedFolderNames() async throws {
        let f = try await Fixture.make()
        let parent = "フォルダ".decomposedStringWithCanonicalMapping
        _ = try await f.files.upsert(
            snapshot(f, inode: 1, path: "\(parent)/第01巻", isBookFolder: true))

        let names = try await f.files.bookFolderChildNames(libraryID: f.libraryID,
                                                           relativePath: parent)
        #expect(names == ["第01巻"])
    }

    /// ゴミ箱・保管庫の除外 [FI-02] は `whereClause` が持っている。
    /// 自前で書き直すと、除外条件が片方だけ古くなる。
    @Test("ゴミ箱の行は返さない [FI-02]")
    func excludesTrashedRows() async throws {
        let f = try await Fixture.make()
        let id = try await f.files.upsert(snapshot(f, inode: 1, path: "消えた本",
                                                   isBookFolder: true))
        _ = try await f.files.upsert(snapshot(f, inode: 2, path: "残る本", isBookFolder: true))
        try await f.database.writer.write {
            try $0.execute(sql: "UPDATE managedFile SET state = 'trashed' WHERE id = ?",
                           arguments: [id.rawValue])
        }

        let names = try await f.files.bookFolderChildNames(libraryID: f.libraryID,
                                                           relativePath: "")
        #expect(names == ["残る本"])
    }
}
