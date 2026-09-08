import Foundation
import QooKit
import Testing
@testable import QooApplication

//
//  登録解除で「データを残す」[RG-06 再訪][RG4-01〜10]。
//
//  **既定を反転させた変更なので、消す側と残す側の両方を固定する。**
//  残す側だけを試すと「常に残す」に退化しても落ちない。
//

@Suite("切り離しと結び直し [RG4-01〜10]", .serialized)
struct DetachedLibraryTests {

    /// 登録解除の既定はデータを残す [RG4-01]。行は 1 つも消えない。
    @Test("既定の解除ではライブラリ行が残り、オフラインになる")
    @MainActor
    func disableKeepsTheRowByDefault() async throws {
        let w = try ServicesWorkspace(tracksRegistrations: true)
        await w.registrations.set([w.registrationUUID])
        await w.bootstrap()
        try w.write("(同人誌) [サークル値A (著者値1)] 作品タイトル1 (ジャンル値1).cbz")
        let id = try await w.enable()
        _ = try await w.services.scan(libraryID: id)

        try await w.services.disable(registrationUUID: w.registrationUUID)

        // 登録はこのあと消える（`LibraryEnableAction.unregister` の順序）ので、
        // ここではまだ「登録のあるライブラリ」に見える。
        #expect(w.services.libraries.count == 1)
        let library = try #require(w.services.libraries.first)
        #expect(library.isOnline == false, "[RG4-08] 監視対象から外す")
        #expect(library.fileCount == 1, "行もファイルも消していない")
    }

    /// 登録が消えた時点で切り離しになり、``libraries`` から外れる [RG4-02][RG4-06]。
    @Test("登録が消えると切り離しとして数えられ、通常の一覧から外れる")
    @MainActor
    func rowBecomesDetachedOnceTheRegistrationIsGone() async throws {
        let w = try ServicesWorkspace(tracksRegistrations: true)
        await w.registrations.set([w.registrationUUID])
        await w.bootstrap()
        try w.write("(同人誌) [サークル値A (著者値1)] 作品タイトル1 (ジャンル値1).cbz")
        let id = try await w.enable()
        _ = try await w.services.scan(libraryID: id)

        try await w.services.disable(registrationUUID: w.registrationUUID)
        await w.registrations.set([])                 // 登録解除
        await w.services.noteRegistrationsChanged()

        #expect(w.services.libraries.isEmpty,
                "設定・メンテナンス・フィールド編集・改訂検出はここを読む [RG4-06]")
        #expect(w.services.detachedLibraries.count == 1)
        #expect(w.services.detachedLibraries.first?.id == id)
    }

    /// 同じフォルダを登録し直すと、**同じ行**へ戻る [RG4-03]。
    @Test("結び直すと同じ行 ID・同じ UUID で、ラベルと評価が無傷のまま戻る")
    @MainActor
    func reattachingReusesTheSameRow() async throws {
        let w = try ServicesWorkspace(tracksRegistrations: true)
        await w.registrations.set([w.registrationUUID])
        await w.bootstrap()
        try w.write("(同人誌) [サークル値A (著者値1)] 作品タイトル1 (ジャンル値1).cbz")
        let id = try await w.enable()
        _ = try await w.services.scan(libraryID: id)
        let files = try await w.services.files(FileQuery(libraryID: id))
        let file = try #require(files.rows.first)
        try await w.services.setRating(4, ids: [file.id])
        let labelsBefore = try await Self.labelCount(w, id)

        try await w.services.disable(registrationUUID: w.registrationUUID)
        await w.registrations.set([])
        await w.services.noteRegistrationsChanged()

        // 再登録（`RegisteredFolderStore.register(reusingID:)` に相当）。
        let detached = try #require(await w.services.detachedLibrary(matching: w.libraryRoot))
        #expect(detached.uuid == w.registrationUUID, "[RG4-03] 同じ UUID で登録し直す")
        await w.registrations.set([detached.uuid])
        await w.services.noteRegistrationsChanged()
        let reattached = try await w.enable()

        #expect(reattached == id, "行を作り直さない——作ると旧行が永久に孤児になる")
        #expect(w.services.libraries.count == 1, "二重に増えない")
        #expect(w.services.detachedLibraries.isEmpty)
        let after = try await w.services.files(FileQuery(libraryID: id))
        #expect(after.rows.first?.rating == 4, "手で付けた評価が生きている")
        #expect(try await Self.labelCount(w, id) == labelsBefore)
    }

    /// 消す側は従来どおり [RG4-01]。
    @Test("keepData: false なら連鎖削除される")
    @MainActor
    func deletingStillCascades() async throws {
        let w = try ServicesWorkspace(tracksRegistrations: true)
        await w.registrations.set([w.registrationUUID])
        await w.bootstrap()
        try w.write("(同人誌) [サークル値A (著者値1)] 作品タイトル1 (ジャンル値1).cbz")
        let id = try await w.enable()
        _ = try await w.services.scan(libraryID: id)

        try await w.services.disable(registrationUUID: w.registrationUUID, keepData: false)
        await w.registrations.set([])
        await w.services.noteRegistrationsChanged()

        #expect(w.services.libraries.isEmpty)
        #expect(w.services.detachedLibraries.isEmpty, "行そのものが無い")
    }

    // MARK: - 照合の規則 [RG4-04]

    /// 別ボリュームの同名フォルダを結び直さない。
    ///
    /// **実機では別ボリュームを用意しないと再現できない**ので、規則そのものを
    /// 純粋関数として試す（`LibraryServices.firstMatch`）。
    @Test("ボリュームが違えば、パスが同じでも結び直さない")
    func matchRequiresBothVolumeAndPath() {
        let a = Self.summary(uuid: UUID(), path: "/Volumes/A/蔵書", volume: "VOL-A")
        let b = Self.summary(uuid: UUID(), path: "/Volumes/A/蔵書", volume: "VOL-B")
        let normalize: (String) -> String = { $0 }

        #expect(LibraryServices.firstMatch(in: [a, b], volumeUUID: "VOL-B",
                                          normalizedPath: "/Volumes/A/蔵書",
                                          normalize: normalize)?.uuid == b.uuid)
        #expect(LibraryServices.firstMatch(in: [a], volumeUUID: "VOL-B",
                                           normalizedPath: "/Volumes/A/蔵書",
                                           normalize: normalize) == nil,
                "ボリューム識別子を落とすと、別ライブラリのラベルと評価が丸ごと乗り移る")
        #expect(LibraryServices.firstMatch(in: [a], volumeUUID: "VOL-A",
                                           normalizedPath: "/Volumes/A/別の蔵書",
                                           normalize: normalize) == nil,
                "パスだけが違っても結び直さない")
    }

    /// 綴りの揺れで外れない [RG4-04]。
    ///
    /// **標本はシンボリックリンクで作る。** 一時ディレクトリの `/var` は
    /// `resolvingSymlinksInPath()` が `/private` を剥がす特別扱いのせいで
    /// 正規化前後が同じ文字列になり、**この主張を 1 度も通らない**
    /// ［実測して書き直した］。`SL-07` で実際に扱うのもリンク経由の登録である。
    @Test("パスは両側を同じ関数で正規化してから比べる")
    func pathsAreNormalizedOnBothSides() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("qoo-detach-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let real = root.appendingPathComponent("蔵書")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("リンク")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        #expect(link.path != real.path, "標本が主張の前提を満たしていること")

        // 登録の経路によっては、リンク側の綴りが `resolvedPath` に入る。
        let library = Self.summary(uuid: UUID(), path: link.path, volume: "VOL")
        #expect(LibraryServices.firstMatch(in: [library], volumeUUID: "VOL",
                                           normalizedPath: LibraryServices.normalizePath(real.path))
                != nil,
                "片側だけ正規化すると、同じフォルダなのに結び直せない")
    }

    /// 生きているラベルの総数。**紐づけが消えていないことの手掛かり**として使う。
    @MainActor
    private static func labelCount(_ w: ServicesWorkspace, _ id: LibraryID) async throws -> Int {
        var total = 0
        for field in try await w.services.fields(libraryID: id) {
            total += try await w.services.labels(fieldID: field.id).count
        }
        return total
    }

    private static func summary(uuid: UUID, path: String, volume: String) -> LibrarySummary {
        LibrarySummary(id: LibraryID(rawValue: 1), uuid: uuid, displayName: "L",
                       resolvedPath: path, volumeUUID: volume,
                       libraryTypeID: LibraryTypeID(rawValue: 1),
                       isOnline: false, isReadOnlyDueToFS: false,
                       fileCount: 0, settingsRevision: 0)
    }
}
