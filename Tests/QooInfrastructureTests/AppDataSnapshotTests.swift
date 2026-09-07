import Foundation
import QooKit
import Testing
@testable import QooInfrastructure

//
//  DB の外にあるデータの控え [BK-06]。
//
//  ここで守りたいのは 2 つ——**対で戻ること**（DB とブックマークは
//  `library.uuid` を介して対でしか意味を持たない）と、**肥大化しないこと**
//  （カバーの複製を世代ごとに写さない）。
//

@Suite("DB の外にあるデータの控え [BK-06]")
struct AppDataSnapshotTests {

    private struct Rig {
        let base: URL
        let location: AppDataSnapshot.Location
        let pool: URL

        init() throws {
            base = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("qoo-appdata-\(UUID().uuidString)")
            let app = base.appendingPathComponent("app")
            pool = base.appendingPathComponent("backups/usercovers")
            location = AppDataSnapshot.Location(
                registeredFolders: app.appendingPathComponent("registeredFolders.json"),
                volumeAccess: app.appendingPathComponent("volumeAccess.json"),
                appAssociations: app.appendingPathComponent("appAssociations.json"),
                userCovers: app.appendingPathComponent("usercovers"))
            try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        }

        func write(_ text: String, to url: URL) throws {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }

        /// カバーの複製を 1 件置く。名前は実物と同じ `<UUID>.<ext>` の形。
        @discardableResult
        func addCover(library: UUID, bytes: Int = 1024) throws -> String {
            let ref = "\(UUID().uuidString).jpg"
            let url = location.userCovers
                .appendingPathComponent(library.uuidString, isDirectory: true)
                .appendingPathComponent(ref, isDirectory: false)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try Data(repeating: 7, count: bytes).write(to: url)
            return ref
        }

        func text(at url: URL) -> String? {
            guard let data = try? Data(contentsOf: url) else { return nil }
            return String(decoding: data, as: UTF8.self)
        }

        func cleanup() { try? FileManager.default.removeItem(at: base) }
    }

    // MARK: - 往復

    @Test("一式を集めて、そのまま書き戻せる [BK-06]")
    func roundTrip() throws {
        let rig = try Rig(); defer { rig.cleanup() }
        try rig.write("{\"folders\":[1]}", to: rig.location.registeredFolders)
        try rig.write("{\"grants\":[2]}", to: rig.location.volumeAccess)
        try rig.write("{\"assoc\":3}", to: rig.location.appAssociations)

        let archive = try AppDataSnapshot.capture(rig.location, linkingCoversInto: rig.pool)
        #expect(archive.manifest.files.count == 3)

        // 取った後に書き換えても、書き戻せば取った時点へ戻る。
        try rig.write("{\"folders\":[]}", to: rig.location.registeredFolders)
        try AppDataSnapshot.restore(archive, to: rig.location, restoringCoversFrom: rig.pool)
        #expect(rig.text(at: rig.location.registeredFolders) == "{\"folders\":[1]}")
        #expect(rig.text(at: rig.location.volumeAccess) == "{\"grants\":[2]}")
    }

    @Test("その時点で無かったファイルは束に入らない [BK-06]")
    func absentFilesAreNotRecorded() throws {
        let rig = try Rig(); defer { rig.cleanup() }
        try rig.write("{}", to: rig.location.registeredFolders)
        // `volumeAccess` と `appAssociations` は書かない（許可 0 件の状態）。

        let archive = try AppDataSnapshot.capture(rig.location, linkingCoversInto: rig.pool)
        #expect(archive.manifest.files == [AppDataBundle.registeredFolders])
        // **空の中身を入れない**——入れると復元で「空の許可一覧」を書き戻し、
        // その時点で在った許可まで消すことになる。
        #expect(archive.files[AppDataBundle.volumeAccess] == nil)
    }

    @Test("束に無いファイルには触らない [BK-06]")
    func restoreDoesNotDeleteWhatTheBundleLacks() throws {
        let rig = try Rig(); defer { rig.cleanup() }
        try rig.write("{}", to: rig.location.registeredFolders)
        let archive = try AppDataSnapshot.capture(rig.location, linkingCoversInto: rig.pool)

        // 取った後に許可を足した。復元は「戻す」であって「消す」ではない。
        try rig.write("{\"later\":true}", to: rig.location.volumeAccess)
        try AppDataSnapshot.restore(archive, to: rig.location, restoringCoversFrom: rig.pool)
        #expect(rig.text(at: rig.location.volumeAccess) == "{\"later\":true}")
    }

    @Test("アプリより新しい束は書き戻さない [IE-14 と同じ規則]")
    func refusesANewerBundle() throws {
        let rig = try Rig(); defer { rig.cleanup() }
        try rig.write("{\"old\":true}", to: rig.location.registeredFolders)
        var archive = try AppDataSnapshot.capture(rig.location, linkingCoversInto: rig.pool)
        archive.manifest.version = AppDataManifest.currentVersion + 1

        #expect(throws: AppDataSnapshot.Failure.self) {
            try AppDataSnapshot.restore(archive, to: rig.location, restoringCoversFrom: rig.pool)
        }
    }

    // MARK: - カバーの複製（肥大化しないこと）

    @Test("カバーは束に入らず、共有プールへリンクされる [BK-06]")
    func coversAreLinkedNotEmbedded() throws {
        let rig = try Rig(); defer { rig.cleanup() }
        let library = UUID()
        let ref = try rig.addCover(library: library, bytes: 4096)

        let archive = try AppDataSnapshot.capture(rig.location, linkingCoversInto: rig.pool)
        // 束には**参照だけ**。中身は入らない（入れると世代数倍に膨らむ）。
        #expect(archive.manifest.userCovers[library.uuidString] == [ref])
        #expect(archive.files[AppDataBundle.userCoverPool] == nil)
        let encoded = try BackupCoding.encode(archive)
        #expect(encoded.count < 4096, "束にカバーの中身が混ざっている")

        let pooled = rig.pool.appendingPathComponent(library.uuidString)
            .appendingPathComponent(ref)
        #expect(FileManager.default.fileExists(atPath: pooled.path))
    }

    @Test("プールの実体は元と同じ inode を共有する（容量を食わない）[BK-06]")
    func poolSharesTheInode() throws {
        let rig = try Rig(); defer { rig.cleanup() }
        let library = UUID()
        let ref = try rig.addCover(library: library)
        _ = try AppDataSnapshot.capture(rig.location, linkingCoversInto: rig.pool)

        let original = rig.location.userCovers
            .appendingPathComponent(library.uuidString).appendingPathComponent(ref)
        let pooled = rig.pool.appendingPathComponent(library.uuidString)
            .appendingPathComponent(ref)
        let a = try FileManager.default.attributesOfItem(atPath: original.path)
        let b = try FileManager.default.attributesOfItem(atPath: pooled.path)
        #expect(a[.systemFileNumber] as? Int == b[.systemFileNumber] as? Int,
                "ハードリンクではなく複製になっている（容量が世代数倍に膨らむ）")
    }

    @Test("2 世代取ってもプールの実体は 1 つ [BK-06]")
    func twoGenerationsShareOneCopy() throws {
        let rig = try Rig(); defer { rig.cleanup() }
        let library = UUID()
        try rig.addCover(library: library)
        _ = try AppDataSnapshot.capture(rig.location, linkingCoversInto: rig.pool)
        _ = try AppDataSnapshot.capture(rig.location, linkingCoversInto: rig.pool)

        let pooled = rig.pool.appendingPathComponent(library.uuidString)
        let entries = try FileManager.default.contentsOfDirectory(atPath: pooled.path)
        #expect(entries.count == 1)
    }

    @Test("元から消えたカバーもプールから戻せる [CV-08]")
    func coversSurviveDeletionOfTheOriginal() throws {
        let rig = try Rig(); defer { rig.cleanup() }
        let library = UUID()
        let ref = try rig.addCover(library: library)
        let archive = try AppDataSnapshot.capture(rig.location, linkingCoversInto: rig.pool)

        // ライブラリを削除した状況（`UserCoverStore.removeAll`）。
        try FileManager.default.removeItem(
            at: rig.location.userCovers.appendingPathComponent(library.uuidString))

        try AppDataSnapshot.restore(archive, to: rig.location, restoringCoversFrom: rig.pool)
        let restored = rig.location.userCovers
            .appendingPathComponent(library.uuidString).appendingPathComponent(ref)
        #expect(FileManager.default.fileExists(atPath: restored.path))
    }

    @Test("復元はカバーを足すだけで、いま在るものを消さない [BK-06]")
    func restoreAddsCoversWithoutRemoving() throws {
        let rig = try Rig(); defer { rig.cleanup() }
        let library = UUID()
        try rig.addCover(library: library)
        let archive = try AppDataSnapshot.capture(rig.location, linkingCoversInto: rig.pool)

        // 取った後に差し替えた複製。**消さない**——参照されなくなっても
        // 起動時の掃除が片付ける一方、消すと ⌘Z の戻り先が無くなる。
        let newer = try rig.addCover(library: library)
        try AppDataSnapshot.restore(archive, to: rig.location, restoringCoversFrom: rig.pool)

        let survivor = rig.location.userCovers
            .appendingPathComponent(library.uuidString).appendingPathComponent(newer)
        #expect(FileManager.default.fileExists(atPath: survivor.path))
    }

    @Test("ライブラリ UUID でないディレクトリは数えない")
    func ignoresNonLibraryDirectories() throws {
        let rig = try Rig(); defer { rig.cleanup() }
        try rig.write("x", to: rig.location.userCovers
            .appendingPathComponent("not-a-uuid").appendingPathComponent("a.jpg"))

        let archive = try AppDataSnapshot.capture(rig.location, linkingCoversInto: rig.pool)
        #expect(archive.manifest.userCovers.isEmpty)
    }
}
