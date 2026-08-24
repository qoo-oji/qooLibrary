import Foundation
import Testing
@testable import QooInfrastructure
@testable import QooKit

//
//  ユーザー指定カバーの複製 [CV-06][CV-08][TH-04]。
//

@Suite("ユーザー指定カバーの複製 [CV-06][CV-08]")
struct UserCoverStoreTests {

    private func makeStore() throws -> (DefaultUserCoverStore, URL) {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("qoo-usercover-\(UUID().uuidString)", isDirectory: true)
        return (DefaultUserCoverStore(baseDirectory: base), base)
    }

    @Test("画像を複製として保存し、参照から引ける [CV-06]")
    func storesAndResolves() async throws {
        let (store, base) = try makeStore()
        defer { try? FileManager.default.removeItem(at: base) }
        let library = UUID()
        let ref = try store.store(TestImageFixture.makePNGData(width: 8, height: 8),
                                  libraryUUID: library)
        let url = store.url(forRef: ref, libraryUUID: library)
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(url.pathExtension == "png", "元の形式のまま保つ [TH-04]")
    }

    /// **画像として読めないものを受け取らない。** 書いてから気づくと、参照だけが
    /// 残って表示が既定へ落ちる——画面からは何が起きたか読み取れない。
    @Test("画像でないデータは拒否する")
    func rejectsNonImageData() throws {
        let (store, base) = try makeStore()
        defer { try? FileManager.default.removeItem(at: base) }
        #expect(throws: UserCoverStoreError.notAnImage) {
            _ = try store.store(Data("これは画像ではありません".utf8), libraryUUID: UUID())
        }
    }

    /// **元画像が消えても複製は残る** [CV-08]。これがこの型の存在理由。
    @Test("元画像を消しても複製は残る [CV-08]")
    func copySurvivesTheOriginal() async throws {
        let (store, base) = try makeStore()
        defer { try? FileManager.default.removeItem(at: base) }
        let source = base.appendingPathComponent("source.png")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try TestImageFixture.makePNGData(width: 8, height: 8).write(to: source)
        let library = UUID()
        let ref = try store.store(try Data(contentsOf: source), libraryUUID: library)
        try FileManager.default.removeItem(at: source)
        #expect(FileManager.default.fileExists(
            atPath: store.url(forRef: ref, libraryUUID: library).path))
    }

    @Test("保存のたびに別の名前を振る")
    func refsAreUnique() throws {
        let (store, base) = try makeStore()
        defer { try? FileManager.default.removeItem(at: base) }
        let library = UUID()
        let data = TestImageFixture.makePNGData(width: 8, height: 8)
        #expect(try store.store(data, libraryUUID: library)
                != (try store.store(data, libraryUUID: library)))
    }

    // MARK: - 掃除

    @Test("参照されている複製は残し、されていないものだけ捨てる [CV-06]")
    func purgeKeepsReferenced() async throws {
        let (store, base) = try makeStore()
        defer { try? FileManager.default.removeItem(at: base) }
        let library = UUID()
        let data = TestImageFixture.makePNGData(width: 8, height: 8)
        let kept = try store.store(data, libraryUUID: library)
        let dropped = try store.store(data, libraryUUID: library)

        await store.purgeUnreferenced([library: [kept]])

        #expect(FileManager.default.fileExists(
            atPath: store.url(forRef: kept, libraryUUID: library).path))
        #expect(!FileManager.default.fileExists(
            atPath: store.url(forRef: dropped, libraryUUID: library).path))
    }

    /// DB から消えたライブラリ（登録解除・削除）のぶんは丸ごと捨てる。
    @Test("DB に無いライブラリの複製は丸ごと捨てる")
    func purgeRemovesUnknownLibraries() async throws {
        let (store, base) = try makeStore()
        defer { try? FileManager.default.removeItem(at: base) }
        let gone = UUID()
        let ref = try store.store(TestImageFixture.makePNGData(width: 8, height: 8),
                                  libraryUUID: gone)
        await store.purgeUnreferenced([:])
        #expect(!FileManager.default.fileExists(atPath: store.url(forRef: ref, libraryUUID: gone).path))
    }

    /// **見覚えのない名前には触らない。** こちらが作ったものだと確かめられない
    /// ものを消すと、取り違えたときに取り返しがつかない。
    @Test("UUID でない名前のディレクトリには触らない")
    func purgeLeavesForeignDirectories() async throws {
        let (store, base) = try makeStore()
        defer { try? FileManager.default.removeItem(at: base) }
        let foreign = base.appendingPathComponent("だいじなもの", isDirectory: true)
        try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: true)
        await store.purgeUnreferenced([:])
        #expect(FileManager.default.fileExists(atPath: foreign.path))
    }

    @Test("ライブラリを消すとそのぶんだけ捨てる")
    func removeAllDropsOneLibraryOnly() async throws {
        let (store, base) = try makeStore()
        defer { try? FileManager.default.removeItem(at: base) }
        let data = TestImageFixture.makePNGData(width: 8, height: 8)
        let a = UUID(), b = UUID()
        let refA = try store.store(data, libraryUUID: a)
        let refB = try store.store(data, libraryUUID: b)
        await store.removeAll(libraryUUID: a)
        #expect(!FileManager.default.fileExists(atPath: store.url(forRef: refA, libraryUUID: a).path))
        #expect(FileManager.default.fileExists(atPath: store.url(forRef: refB, libraryUUID: b).path))
    }
}
