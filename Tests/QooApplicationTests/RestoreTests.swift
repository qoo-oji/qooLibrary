import Foundation
import QooInfrastructure
import QooKit
import QooPersistence
import Testing
@testable import QooApplication

//
//  バックアップからの復元 [BK-03][IE-16][RB-03]。
//
//  **「終了 → 起動し直す」を模す**のがこの suite の骨。復元は動いている
//  アプリの中では行わず、次の起動で `QooDatabase.open` の前に差し替える
//  （`PendingRestore` の doc）ので、1 つの `LibraryServices` を使い回して
//  試すと**いちばん大事な性質——直前の起動でストアが開けたかどうかに
//  依存しないこと——を一度も通らない。**
//

@Suite("バックアップからの復元 [BK-03][IE-16]", .serialized)
struct RestoreTests {

    /// 同じストアと同じ `backups/` を指す `LibraryServices` を何度でも作れる。
    /// `bootstrap()` は 1 度きり [didBootstrap] なので、起動のたびに作り直す。
    @MainActor
    private final class Rig {
        let base: URL
        let storeURL: URL
        let backupDirectory: URL
        let coverDirectory: URL
        let templateStoreURL: URL
        /// DB の外にあるデータの置き場所 [BK-06]。**実データには触れない。**
        let appDirectory: URL

        init() {
            base = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("qoo-restore-\(UUID().uuidString)")
            storeURL = base.appendingPathComponent("store/qooLibrary.sqlite")
            backupDirectory = base.appendingPathComponent("backups")
            coverDirectory = base.appendingPathComponent("usercovers")
            templateStoreURL = base.appendingPathComponent("userTemplates.json")
            appDirectory = base.appendingPathComponent("app")
        }

        var appDataLocation: AppDataSnapshot.Location {
            AppDataSnapshot.Location(
                registeredFolders: appDirectory.appendingPathComponent("registeredFolders.json"),
                volumeAccess: appDirectory.appendingPathComponent("volumeAccess.json"),
                appAssociations: appDirectory.appendingPathComponent("appAssociations.json"),
                // **`DefaultUserCoverStore` と同じ場所を指す**——本番は
                // `userCoverStore.baseDirectory` を渡す。ずれていると
                // `manifest.userCovers` が常に空になり、カバーの取り込みも
                // 書き戻しも一度も通らない［code-review で発見］。
                userCovers: coverDirectory)
        }

        deinit { try? FileManager.default.removeItem(at: base) }

        var store: BackupStore { BackupStore(directory: backupDirectory) }
        // [BK-07] 既定は OFF なので、契機を試すテストは明示的に ON にする。
        var service: BackupService {
            BackupService(store: store, appVersion: "test",
                          appDataLocation: appDataLocation, launchInterval: .daily,
                          snapshotsBeforeDestructive: true, snapshotsBeforeMigration: true)
        }

        /// 1 回ぶんの起動。
        @discardableResult
        func launch() async -> LibraryServices {
            let services = LibraryServices(
                userCoverStore: DefaultUserCoverStore(baseDirectory: coverDirectory),
                userTemplateStore: UserTemplateStore(storageURL: templateStoreURL),
                backupService: service)
            await services.bootstrap(storeURL: storeURL)
            return services
        }

        func generations() throws -> [BackupGeneration] { try store.generations() }
    }

    /// ストアの中身に印を付けて、どの世代が入っているかを見分ける。
    /// **ファイルの取り違えを名前ではなく中身で確かめる**ため。
    private static func stamp(_ url: URL, _ mark: String) async throws {
        let db = try QooDatabase.open(at: url)
        try await db.writer.write { d in
            try d.execute(sql: "CREATE TABLE IF NOT EXISTS restore_probe (mark TEXT)")
            try d.execute(sql: "DELETE FROM restore_probe")
            try d.execute(sql: "INSERT INTO restore_probe (mark) VALUES (?)", arguments: [mark])
        }
        try db.writer.close()
    }

    private static func readStamp(_ url: URL) async throws -> String? {
        let db = try QooDatabase.open(at: url)
        defer { try? db.writer.close() }
        return try await db.writer.read { d in
            guard try d.tableExists("restore_probe") else { return nil }
            return try String.fetchOne(d, sql: "SELECT mark FROM restore_probe")
        }
    }

    /// 「戻したい状態」の複製を 1 世代作る。中身に印を付けて返す。
    @MainActor
    private static func makeGeneration(_ rig: Rig, mark: String,
                                       bundlingAppData: Bool = false) async throws
        -> BackupGeneration
    {
        try await stamp(rig.storeURL, mark)
        let now = Date()
        let destination = try rig.store.prepareStoreDestination(reason: .launch, date: now)
        let db = try QooDatabase.open(at: rig.storeURL)
        try QooDatabase.backup(writer: db.writer, to: destination)
        try db.writer.close()
        if bundlingAppData {
            // `restoreAppData` は**名前で対を引く**ので `date` を揃える。
            let archive = try AppDataSnapshot.capture(rig.appDataLocation,
                                                      linkingCoversInto: rig.store.userCoverPool)
            _ = try rig.store.writeAppData(archive, reason: .launch, date: now)
        }
        return try #require(try rig.generations().first { $0.url == destination })
    }

    /// 登録の中身に印を付ける。**DB の外にあるデータが戻るか**を見るため。
    @MainActor
    private static func stampRegistrations(_ rig: Rig, _ mark: String) throws {
        try FileManager.default.createDirectory(at: rig.appDirectory,
                                                withIntermediateDirectories: true)
        try Data(mark.utf8).write(to: rig.appDataLocation.registeredFolders)
    }

    @MainActor
    private static func readRegistrations(_ rig: Rig) -> String? {
        guard let data = try? Data(contentsOf: rig.appDataLocation.registeredFolders)
        else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - 通し [BK-03][IE-16]

    @Test("予約すると、次の起動で差し替わる [BK-03][IE-16]")
    @MainActor
    func restoreHappensOnTheNextLaunch() async throws {
        let rig = Rig()
        await rig.launch()
        let old = try await Self.makeGeneration(rig, mark: "old")

        // 復元したい状態を作ったあと、ストアを進めておく。
        try await Self.stamp(rig.storeURL, "new")
        #expect(try await Self.readStamp(rig.storeURL) == "new")

        // 予約だけ。**この時点では何も差し替わらない**——利用者が終了する
        // までは、まだ考え直せる。
        try await rig.service.requestRestore(old)
        #expect(try await Self.readStamp(rig.storeURL) == "new", "予約しただけでは動かさない")
        #expect(rig.service.pendingRestore() != nil)

        // 起動し直す。
        let services = await rig.launch()
        #expect(try await Self.readStamp(rig.storeURL) == "old", "複製の中身に戻る")
        let outcome = try #require(services.restoreOutcome)
        #expect(outcome.succeeded)
        #expect(outcome.restoredFrom == old.fileName)
        #expect(rig.service.pendingRestore() == nil, "印は消える")
    }

    @Test("差し替え前のストアが退避される [BK-03]")
    @MainActor
    func thePreviousStoreIsKept() async throws {
        let rig = Rig()
        await rig.launch()
        let old = try await Self.makeGeneration(rig, mark: "old")
        try await Self.stamp(rig.storeURL, "new")

        try await rig.service.requestRestore(old)
        let services = await rig.launch()

        // **「戻したら戻しすぎた」を取り返せなくてはならない。**
        let previous = try #require(services.restoreOutcome?.previousStoreURL)
        #expect(try await Self.readStamp(previous) == "new")
        let archived = try rig.generations().filter { $0.reason == .beforeRestore }
        #expect(archived.filter { $0.kind == .store }.count == 1, "世代として一覧に出る")
        // 対の束も残る [BK-06][BK3-11]——無いと、この退避から戻したときに
        // `registeredFolders.json` が戻らず DB と食い違う。
        #expect(archived.contains { $0.kind == .appData })
    }

    @Test("退避した世代からもう一度戻せる [BK-03]")
    @MainActor
    func theArchivedStoreCanItselfBeRestored() async throws {
        let rig = Rig()
        await rig.launch()
        let old = try await Self.makeGeneration(rig, mark: "old")
        try await Self.stamp(rig.storeURL, "new")
        try await rig.service.requestRestore(old)
        await rig.launch()

        // 戻しすぎたので、退避されたほうへ戻す。
        let archived = try #require(try rig.generations()
            .first { $0.reason == .beforeRestore && $0.kind == .store })
        try await rig.service.requestRestore(archived)
        await rig.launch()
        #expect(try await Self.readStamp(rig.storeURL) == "new")
    }

    @Test("退避すると対の束も残る [BK-06][BK3-11]")
    @MainActor
    func theArchivedStoreGetsAPairedBundle() async throws {
        let rig = Rig()
        await rig.launch()
        try Self.stampRegistrations(rig, "v1")
        let old = try await Self.makeGeneration(rig, mark: "old")
        try await Self.stamp(rig.storeURL, "new")
        try await rig.service.requestRestore(old)
        await rig.launch()

        // **片方だけの世代を作らない** [BK3-11]。退避した `.store` の隣に
        // 同じ名前の `.appData` が要る——無いと、その退避から戻したときに
        // `registeredFolders.json` が戻らず DB と食い違う。
        let archived = try rig.generations().filter { $0.reason == .beforeRestore }
        let stems = Set(archived.map { ($0.fileName as NSString).deletingPathExtension })
        #expect(stems.count == 1, "store と appData の名前が対になっていない")
        #expect(archived.contains { $0.kind == .store })
        #expect(archived.contains { $0.kind == .appData })
    }

    @Test("退避から戻すと DB の外にあるデータも一緒に戻る [BK-06][IE-16]")
    @MainActor
    func restoringTheArchivedStoreAlsoBringsBackAppData() async throws {
        let rig = Rig()
        await rig.launch()

        // v1——ここへ戻れる世代を 1 つ作る（DB と束の両方）。
        try Self.stampRegistrations(rig, "v1")
        let old = try await Self.makeGeneration(rig, mark: "old", bundlingAppData: true)

        // v2——いまの状態。「戻しすぎた」ときはここへ帰ってくる。
        try await Self.stamp(rig.storeURL, "new")
        try Self.stampRegistrations(rig, "v2")

        // 1 回目。DB も登録も v1 になる。
        try await rig.service.requestRestore(old)
        await rig.launch()
        #expect(try await Self.readStamp(rig.storeURL) == "old")
        #expect(Self.readRegistrations(rig) == "v1")

        // 2 回目——退避へ戻す。**両方 v2 でなければならない。**
        // `library.uuid` は登録フォルダ ID そのもの [§7.3] なので、DB だけ
        // v2 で登録が v1 のままだと**行が指す登録が存在しない**状態になる
        // ——BK-06 が塞ごうとした食い違いを、復元の側で作ることになる。
        let archived = try #require(try rig.generations()
            .first { $0.reason == .beforeRestore && $0.kind == .store })
        try await rig.service.requestRestore(archived)
        await rig.launch()
        #expect(try await Self.readStamp(rig.storeURL) == "new")
        #expect(Self.readRegistrations(rig) == "v2", "DB は戻ったのに登録が戻っていない")
    }

    @Test("復元するとユーザー指定カバーも共有プールから戻る [BK-06][CV-08]")
    @MainActor
    func restoringAlsoBringsBackUserCovers() async throws {
        let rig = Rig()
        await rig.launch()

        // ライブラリ UUID の下に 1 枚置く（`AppDataSnapshot` はその形しか
        // 数えない）。カバーは**元画像が消えている前提**の複製 [CV-08] で、
        // 再生成できない。
        let library = UUID().uuidString
        let cover = rig.coverDirectory.appendingPathComponent(library)
            .appendingPathComponent("cover.png")
        try FileManager.default.createDirectory(at: cover.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("image".utf8).write(to: cover)
        let old = try await Self.makeGeneration(rig, mark: "old", bundlingAppData: true)

        // **アプリ自身が消す経路**（起動時の掃除・ライブラリの削除）を模す。
        try FileManager.default.removeItem(at: cover)

        try await rig.service.requestRestore(old)
        await rig.launch()
        #expect(FileManager.default.fileExists(atPath: cover.path),
                "共有プールから戻っていない [CV-08]")
    }

    @Test("退避が起きなければ束も書かない [BK3-11]")
    @MainActor
    func noBundleIsWrittenWhenThereIsNothingToArchive() async throws {
        let rig = Rig()
        await rig.launch()
        try Self.stampRegistrations(rig, "v1")
        let old = try await Self.makeGeneration(rig, mark: "old", bundlingAppData: true)

        // ストアがまだ無い状態での復元（初回起動で予約を拾う形）。
        try FileManager.default.removeItem(at: rig.storeURL)
        try await rig.service.requestRestore(old)
        await rig.launch()

        // 退避していないので `beforeRestore` の世代は 1 つも無い
        // ——**束だけが孤児として残る形を作らない**（対の相手がいない束は
        // `generations()` に出るのに、そこから戻す DB が存在しない）。
        #expect(try rig.generations().allSatisfy { $0.reason != .beforeRestore })
    }

    @Test("退避したストアは 1 ファイルに畳まれる [BK-04]")
    @MainActor
    func theArchivedStoreIsASingleFile() async throws {
        let rig = Rig()
        await rig.launch()
        let old = try await Self.makeGeneration(rig, mark: "old")
        try await Self.stamp(rig.storeURL, "new")
        try await rig.service.requestRestore(old)
        let services = await rig.launch()

        // 退避したのは**ライブストア**なので WAL のまま `-wal` を連れてくる。
        // 畳んでおかないと、任意フォルダへ書き出す [BK-04] ときに本体だけが
        // 写り、**直前のトランザクションが落ちる**——しかも
        // `generations()` は sidecar を解釈しないので誰にも見えない。
        let archived = try #require(services.restoreOutcome?.previousStoreURL)
        for suffix in ["-wal", "-shm"] {
            let sidecar = URL(fileURLWithPath: archived.path + suffix)
            #expect(!FileManager.default.fileExists(atPath: sidecar.path),
                    "付随ファイルが残っている: \(sidecar.lastPathComponent)")
        }
        // 畳んだあとも中身は読める。
        #expect(try await Self.readStamp(archived) == "new")
    }

    @Test("第 1 段が書いた世代を検分しても付随ファイルを残さない [BK-03]")
    @MainActor
    func inspectingALegacyGenerationLeavesNoSidecars() async throws {
        let rig = Rig()
        await rig.launch()
        try await Self.stamp(rig.storeURL, "old")

        // 第 1 段（2026-09-05）の世代と同じ形——**素のファイルコピー**なので
        // ヘッダが WAL のまま。検分するには一度その形で開いて畳むしかなく、
        // その最中に `-shm` が作られる［実測］。捨てないと**誰にも見えない
        // まま容量を食い、剪定にもかからない**。
        let legacy = try rig.store.prepareStoreDestination(reason: .launch)
        try FileManager.default.copyItem(at: rig.storeURL, to: legacy)
        let generation = try #require(try rig.generations().first { $0.url == legacy })

        try await rig.service.requestRestore(generation)
        for suffix in ["-wal", "-shm"] {
            let sidecar = URL(fileURLWithPath: legacy.path + suffix)
            #expect(!FileManager.default.fileExists(atPath: sidecar.path),
                    "検分が \(suffix) を残した")
        }
        rig.service.cancelPendingRestore()
    }

    // MARK: - 断る [MG-12][RB-03]

    @Test("壊れた複製では予約させない [RB-03]")
    @MainActor
    func aCorruptGenerationIsRefusedUpFront() async throws {
        let rig = Rig()
        await rig.launch()
        let generation = try await Self.makeGeneration(rig, mark: "old")
        // 中身を潰す。**押した直後に断る**——終了して起動し直してから
        // 「戻せませんでした」と言われるより、そこで分かるほうがよい。
        try Data(repeating: 0x41, count: 4096).write(to: generation.url)

        await #expect(throws: (any Error).self) { try await rig.service.requestRestore(generation) }
        #expect(rig.service.pendingRestore() == nil, "予約されない")
    }

    @Test("アプリより新しい複製では予約させない [MG-12]")
    @MainActor
    func aTooNewGenerationIsRefusedUpFront() async throws {
        let rig = Rig()
        await rig.launch()
        let generation = try await Self.makeGeneration(rig, mark: "old")
        // アプリが知らない移行が適用済み＝新しすぎる。**戻すとその瞬間から
        // 起動できなくなる**ので、戻す前に弾く。
        let db = try QooDatabase.open(at: generation.url)
        try await db.writer.write { d in
            try d.execute(sql: "INSERT INTO grdb_migrations (identifier) VALUES (?)",
                          arguments: ["v9999_fromTheFuture"])
        }
        try db.writer.close()

        await #expect(throws: BackupService.RestoreError.unusable(
            .sourceTooNew(generation.fileName))) {
            try await rig.service.requestRestore(generation)
        }
    }

    @Test("JSON の世代は復元の対象ではない [IE-16]")
    @MainActor
    func jsonGenerationsAreNotRestoreSources() async throws {
        let rig = Rig()
        await rig.launch()
        // JSON はライブラリの行を作れない（ブックマークを持てない）ので、
        // 戻し方は「取り込み」[IE-11] のほうである。
        let json = try #require(try rig.generations().first { $0.kind == .document })
        await #expect(throws: BackupService.RestoreError.notAStoreCopy) {
            try await rig.service.requestRestore(json)
        }
    }

    // MARK: - 失敗しても起動する [RB-03]

    @Test("世代が消えていても起動は続き、現ストアは無傷 [RB-03]")
    @MainActor
    func aVanishedGenerationDoesNotBreakTheLaunch() async throws {
        let rig = Rig()
        await rig.launch()
        let old = try await Self.makeGeneration(rig, mark: "old")
        try await Self.stamp(rig.storeURL, "new")
        try await rig.service.requestRestore(old)
        // 予約したあとで世代が消える（利用者が消した・剪定された）。
        try FileManager.default.removeItem(at: old.url)

        let services = await rig.launch()
        #expect(services.isReady, "復元に失敗しただけで起動できなくなってはならない")
        #expect(try await Self.readStamp(rig.storeURL) == "new", "現ストアは無傷")
        #expect(services.restoreOutcome?.failure == .generationMissing(old.fileName))
        #expect(rig.service.pendingRestore() == nil,
                "印は失敗しても消す——残すと起動のたびに同じ失敗を繰り返す")
    }

    @Test("差し替え先の古い -wal を残さない")
    @MainActor
    func staleWriteAheadLogsAreRemoved() async throws {
        let rig = Rig()
        await rig.launch()
        let old = try await Self.makeGeneration(rig, mark: "old")
        try await Self.stamp(rig.storeURL, "new")

        // 別の DB の WAL が新しいストアの隣に残ると、SQLite はそれを再生
        // しようとする——**破損を自分で作り込む形**になる。
        let wal = URL(fileURLWithPath: rig.storeURL.path + "-wal")
        try Data(repeating: 0x7F, count: 512).write(to: wal)

        try await rig.service.requestRestore(old)
        await rig.launch()
        #expect(try await Self.readStamp(rig.storeURL) == "old")
    }

    @Test("ストアが無く -wal だけ残っていても差し替えられる")
    @MainActor
    func aStrayWriteAheadLogWithoutAStoreIsCleared() async throws {
        let rig = Rig()
        await rig.launch()
        let old = try await Self.makeGeneration(rig, mark: "old")

        // ストア本体だけが失われ、`-wal` が取り残された状態（異常終了の後に
        // 本体を手で消す等）。**退避が sidecar を連れて行く経路を通らない**
        // 唯一の形なので、差し替え側の掃除はここでだけ意味を持つ。
        //
        // ただし**この検査は掃除そのものを固定していない**［実測、2026-09-06］
        // ——掃除を外しても通る。SQLite は WAL の magic・salt・チェックサムを
        // DB と突き合わせ、**一致しない WAL は無視して捨てる**ため、
        // 取り残された sidecar は実害を生まない。ここで確かめているのは
        // 「取り残しがあっても復元できる」という結果のほうである。
        try FileManager.default.removeItem(at: rig.storeURL)
        try Data(repeating: 0x7F, count: 512)
            .write(to: URL(fileURLWithPath: rig.storeURL.path + "-wal"))

        try await rig.service.requestRestore(old)
        let services = await rig.launch()
        #expect(services.isReady)
        #expect(try await Self.readStamp(rig.storeURL) == "old")
    }

    // MARK: - 起動時の健全性 [RB-03][RB-06][MG-12]

    @Test("健全なストアでは復元を提案しない [RB-03]")
    @MainActor
    func aHealthyStoreProposesNothing() async throws {
        let rig = Rig()
        let services = await rig.launch()
        #expect(services.storeHealth == .healthy)
        #expect(!services.storeHealth.needsRecovery)
    }

    @Test("破損したストアは起動時に見つかる [RB-03]")
    @MainActor
    func aCorruptStoreIsFoundAtLaunch() async throws {
        let rig = Rig()
        await rig.launch()
        // 中身を増やしてページを複数にしてから、**ヘッダではなく中ほど**を
        // 潰す。ヘッダを壊すと `open` 自体が落ちて別の経路（`openFailed`）に
        // なり、**「開けたが壊れている」という RB-03 の状況を一度も通らない。**
        let db = try QooDatabase.open(at: rig.storeURL)
        try await db.writer.write { d in
            try d.execute(sql: "CREATE TABLE bulk (a TEXT)")
            for i in 0 ..< 400 {
                try d.execute(sql: "INSERT INTO bulk VALUES (?)",
                              arguments: [String(repeating: "x", count: 200) + "\(i)"])
            }
        }
        try await db.writer.writeWithoutTransaction {
            try $0.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
        }
        try db.writer.close()

        let handle = try FileHandle(forUpdating: rig.storeURL)
        try handle.seek(toOffset: 8192)
        try handle.write(contentsOf: Data(repeating: 0x5A, count: 4096))
        try handle.close()

        let services = await rig.launch()
        #expect(services.storeHealth == .corrupt, "破損を検出できていない")
        #expect(services.storeHealth.needsRecovery, "復元を提案すべき状態")
    }

    @Test("起動の失敗が見えた時点で、健全性も既に確定している [RB-03][RB-06]")
    @MainActor
    func startupFailureIsNeverVisibleBeforeStoreHealth() async throws {
        // **`startupFailure` は「起動が終わった」の合図として外から見張られて
        // いる**（`BackupRestoreAction.waitUntilBootstrapFinished`）。見張り側は
        // それを見た直後に `storeHealth` で復元を提案するかどうかを決めるので、
        // **2 つの間に中断点があってはならない**——あると、検分（実 I/O）の
        // 最中に見張りが動き出し、まだ既定の `.healthy` を読んで**提案を
        // 黙って飛ばす**［実機検証で発見、2026-09-06。破損させたストアで
        // 起動しても提案が 1 度も出なかった］。
        let rig = Rig()
        try FileManager.default.createDirectory(
            at: rig.storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        // SQLite として開けないファイル。`QooDatabase.open` が投げ、
        // `bootstrap` の catch（検分 → 失敗の記録）を通る。
        try Data("これはデータベースではない".utf8).write(to: rig.storeURL)

        let services = LibraryServices(
            userCoverStore: DefaultUserCoverStore(baseDirectory: rig.coverDirectory),
            userTemplateStore: UserTemplateStore(storageURL: rig.templateStoreURL),
            backupService: rig.service)

        // 見張りと同じ形で覗く。**同じメインアクタの上に居る**ので、
        // `bootstrap` が中断したときにだけ動ける＝中断点が観測点になる。
        //
        // **`Task.yield()` で回すこと。** `Task.sleep` にすると、覗く間隔より
        // 検分のほうが速く終わってしまい（開けないファイルは即座に失敗する）
        // **壊れた順序でも素通りする**［変異検証で空振りして判明］。
        let watcher = Task { @MainActor in
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline {
                if services.startupFailure != nil { return services.storeHealth }
                await Task.yield()
            }
            return StoreHealth.healthy
        }
        await services.bootstrap(storeURL: rig.storeURL)
        let seen = await watcher.value

        #expect(services.startupFailure != nil, "開けないストアなので失敗が残るはず")
        #expect(services.storeHealth == .corrupt)
        #expect(seen == .corrupt,
                "失敗が見えた時点で健全性がまだ .healthy だった——提案が黙って飛ぶ")
    }

    @Test("アプリより新しいストアは更新を促す状態になる [MG-12][RB-06]")
    @MainActor
    func aTooNewStoreIsDistinguishedFromCorruption() async throws {
        let rig = Rig()
        await rig.launch()
        let db = try QooDatabase.open(at: rig.storeURL)
        try await db.writer.write { d in
            try d.execute(sql: "INSERT INTO grdb_migrations (identifier) VALUES (?)",
                          arguments: ["v9999_fromTheFuture"])
        }
        try db.writer.close()

        let services = await rig.launch()
        #expect(services.startupFailure == .schemaTooNew)
        // **破損と区別する** [RB-06]——ここで「壊れています」と言うと、
        // 利用者は古い控えへ戻して**それ以降の内容を捨ててしまう**。
        // 正しい次の一手はアプリの更新である。
        #expect(services.storeHealth == .tooNew)
    }
}
