import Foundation
import QooInfrastructure
import QooKit
import QooPersistence
import Testing
@testable import QooApplication

//
//  自動バックアップの契機と世代 [BK-01][BK-02][MG-10]。
//
//  `ServicesWorkspace` は作業領域ごとに独立した `BackupService` を注入して
//  いるので（`LibraryServices.takesAutomaticSnapshots`）、**契機の配線を
//  end-to-end で試せる**——テストどうしが世代を剪定し合うこともない。
//

@Suite("自動バックアップ [BK-01][BK-02][MG-10]", .serialized)
struct BackupServiceTests {

    /// `BackupService` 単体を試すための一式。
    ///
    /// **`LibraryServices` の内部へは手を伸ばさない**——テストのために
    /// 合成根へアクセサを足すのではなく、同じ部品を独立に組み立てる
    /// （`LabelEditorModel.candidates` を切り出したのと同じ判断）。
    private struct Rig {
        let database: QooDatabase
        let repository: SQLiteBackupRepository
        let store: BackupStore

        init(directory: URL, documents: Int? = nil, stores: Int? = nil) throws {
            database = try QooDatabase.inMemory()
            repository = SQLiteBackupRepository(database: database)
            store = BackupStore(directory: directory)
            self.documents = documents
            self.stores = stores
        }
        private let documents: Int?
        private let stores: Int?

        var service: BackupService {
            BackupService(store: store, appVersion: "test",
                          documentGenerations: documents, storeGenerations: stores)
        }
    }

    private static func temporaryDirectory() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("qoo-backupsvc-\(UUID().uuidString)")
    }

    // MARK: - 起動時 [BK-01]

    @Test("起動でスナップショットが取られる [BK-01]")
    @MainActor
    func bootstrapTakesSnapshots() async throws {
        let w = try ServicesWorkspace()
        await w.bootstrap()

        let generations = try w.backupGenerations()
        #expect(generations.contains { $0.reason == .launch }, "起動時に取る [BK-01]")
        // 起動時は DB 全体に及ぶ契機なので JSON とストア複製の両方 [copiesStore]。
        let kinds = Set(generations.filter { $0.reason == .launch }.map(\.kind))
        #expect(kinds == [.document, .store])

        // **新規ストアでは移行前スナップショットを取らない**——`open` は移行が
        // 未適用なら必ずフックを呼ぶ（`SchemaTests` がその契約を固定している）が、
        // まだテーブルが 1 つも無いので写すものが無い。ここを分けないと、
        // 初回起動が毎回「バックアップに失敗」として記録される。
        #expect(!generations.contains { $0.reason == .schemaMigration })
    }

    /// **実際の経路で試す**——`QooDatabase.open` は移行が未適用なら必ず
    /// フックを呼ぶので、新規ストアでもフックは走る。走ったうえで
    /// 「写すものが無い」と判断できることを見る。
    @Test("新規ストアには移行前スナップショットを取らない [MG-10]")
    func migrationSnapshotSkipsAFreshStore() throws {
        let directory = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = BackupService(store: BackupStore(directory: directory), appVersion: "test")
        let storeURL = directory.appendingPathComponent("qoo.sqlite")

        _ = try QooDatabase.open(at: storeURL) { handle in
            #expect(!handle.hasExistingSchema, "新規ストアにはまだテーブルが無い")
            let outcome = try service.snapshotBeforeMigration(handle)
            #expect(outcome == nil)
        }
        let generations = try BackupStore(directory: directory).generations()
        #expect(generations.isEmpty)
    }

    /// **移行前は JSON とストア複製の両方**——要件 MG-10 が名指しで両方を
    /// 要求している唯一の契機で、R-14（移行の失敗でラベルや評価を失う）への
    /// 直接の備えだから。
    @Test("移行前は JSON とストア複製の両方を取る [MG-10]")
    func migrationSnapshotWritesBoth() throws {
        let rig = try Rig(directory: Self.temporaryDirectory())
        // `Rig.database` は移行済みなので、移行前の DB と同じ形をしている。
        #expect(rig.database.synchronousHandle.hasExistingSchema)

        let taken = try rig.service.snapshotBeforeMigration(rig.database.synchronousHandle)
        let outcome = try #require(taken)
        #expect(!outcome.skippedAsUnhealthy)
        #expect(outcome.storeURL != nil)
        let kinds = Set(try rig.store.generations().map(\.kind))
        #expect(kinds == [.document, .store])
    }

    /// **毎起動では取らない**——10 世代が「今日の 10 回の起動」で埋まると
    /// 履歴として役に立たない。
    @Test("起動時スナップショットは間隔を空ける [BK-01]")
    func launchSnapshotIsThrottled() async throws {
        let rig = try Rig(directory: Self.temporaryDirectory())
        let first = try await rig.service.snapshotOnLaunch(
            repository: rig.repository, database: rig.database)
        #expect(first != nil, "1 回目は取る")

        let second = try await rig.service.snapshotOnLaunch(
            repository: rig.repository, database: rig.database)
        #expect(second == nil, "24 時間経っていなければ取らない")
        #expect(try rig.store.generations().filter { $0.kind == .document }.count == 1)
    }

    @Test("間隔を過ぎていれば取る [BK-01]")
    func launchSnapshotResumesAfterTheInterval() async throws {
        let rig = try Rig(directory: Self.temporaryDirectory())
        _ = try await rig.service.snapshotOnLaunch(
            repository: rig.repository, database: rig.database)
        let later = Date().addingTimeInterval(AppLimits.Backup.launchSnapshotInterval + 60)
        let outcome = try await rig.service.snapshotOnLaunch(
            repository: rig.repository, database: rig.database, now: later)
        #expect(outcome != nil)
        #expect(try rig.store.generations().filter { $0.kind == .document }.count == 2)
    }

    // MARK: - 破壊的な操作の直前 [BK-02]

    @Test("ライブラリの削除の前に取る [BK-02、ユーザー判断で追加]")
    @MainActor
    func libraryDeleteTakesASnapshot() async throws {
        let w = try ServicesWorkspace()
        await w.bootstrap()
        let id = try await w.enable()
        #expect(try w.backupGenerations().filter { $0.reason == .libraryDelete }.isEmpty)

        try await w.services.deleteLibrary(id: id)

        let taken = try w.backupGenerations().filter { $0.reason == .libraryDelete }
        #expect(!taken.isEmpty, "連鎖でラベル・評価が全部消えるので必ず残す")
        #expect(Set(taken.map(\.kind)) == [.document, .store])
    }

    @Test("JSON の取り込みの前に取る [JS-07][IE-12]")
    @MainActor
    func importTakesASnapshot() async throws {
        let w = try ServicesWorkspace()
        await w.bootstrap()
        try await w.enable()
        let document = try await w.services.exportBackup(scope: .everything)

        _ = try await w.services.importBackup(document)

        #expect(!(try w.backupGenerations().filter { $0.reason == .jsonImport }.isEmpty))
    }

    /// **ラベルの一括削除は JSON だけ**——そのライブラリの中に閉じる操作で、
    /// 複製（10 万件で 71 MB）まで取ると 3 世代が小さな操作で埋まる。
    @Test("大規模なラベル削除は JSON だけを取る [BK-02][copiesStore]")
    @MainActor
    func bulkLabelDeleteTakesOnlyTheDocument() async throws {
        let w = try ServicesWorkspace()
        await w.bootstrap()
        let id = try await w.enable()
        // しきい値ちょうどまで届く数のラベルを作る。
        let fields = try await w.services.fields(libraryID: id)
        let field = try #require(fields.first)
        var ids: [LabelID] = []
        for index in 0 ..< AppLimits.Backup.bulkOperationThreshold {
            ids.append(try await w.services.ensureLabel(fieldID: field.id, name: "ラベル\(index)"))
        }

        try await w.services.deleteLabels(ids)

        let taken = try w.backupGenerations().filter { $0.reason == .bulkLabelDelete }
        #expect(!taken.isEmpty)
        #expect(Set(taken.map(\.kind)) == [.document], "ストア複製は取らない")
    }

    /// **1 件の削除では取らない**——日常的な編集 10 回で全世代が埋まると、
    /// 起動時と移行前の世代を押し出して安全網としてかえって弱くなる
    /// ［code-review で発見］。少数の削除は ⌘Z が同じ行 ID へ戻す。
    @Test("少数のラベル削除では取らない [BK-02「大規模な」]")
    @MainActor
    func smallLabelDeleteTakesNothing() async throws {
        let w = try ServicesWorkspace()
        await w.bootstrap()
        let id = try await w.enable()
        let fields = try await w.services.fields(libraryID: id)
        let label = try await w.services.ensureLabel(fieldID: #require(fields.first).id, name: "ひとつ")

        try await w.services.deleteLabels([label])

        #expect(try w.backupGenerations().filter { $0.reason == .bulkLabelDelete }.isEmpty)
    }

    @Test("消す対象が無ければ取らない")
    @MainActor
    func emptyDeleteTakesNothing() async throws {
        let w = try ServicesWorkspace()
        await w.bootstrap()
        try await w.services.deleteLabels([])
        #expect(try w.backupGenerations().filter { $0.reason == .bulkLabelDelete }.isEmpty)
    }

    // MARK: - 剪定 [BK2-03]

    @Test("剪定はスナップショットの後。世代数を超えない [BK2-03]")
    func pruningKeepsTheConfiguredNumber() async throws {
        // 環境設定に触れずに世代数を絞る（`UserDefaults` はプロセス共有で、
        // テストが書き換えると他のテストの前提を壊す）。
        let rig = try Rig(directory: Self.temporaryDirectory(), documents: 2, stores: 1)
        for offset in 0 ..< 4 {
            _ = try await rig.service.snapshot(
                reason: .jsonImport, repository: rig.repository, database: rig.database,
                now: Date().addingTimeInterval(Double(offset)))
        }
        let generations = try rig.store.generations()
        #expect(generations.filter { $0.kind == .document }.count == 2)
        #expect(generations.filter { $0.kind == .store }.count == 1)
    }

    /// **世代は毎回新しい名前で書く。** 既存の世代を上書きすることが
    /// 構造的に無いことが、「良いバックアップを壊れた状態で上書きする」
    /// ［外部調査］への答えになっている。
    @Test("同じ契機を続けて取っても上書きしない")
    func snapshotsNeverOverwriteEachOther() async throws {
        let rig = try Rig(directory: Self.temporaryDirectory(), documents: 50, stores: 50)
        var urls: Set<URL> = []
        for _ in 0 ..< 3 {
            let outcome = try await rig.service.snapshot(
                reason: .beforeRestore, repository: rig.repository, database: rig.database)
            urls.insert(try #require(outcome.documentURL))
        }
        #expect(urls.count == 3, "3 回とも別のファイルへ書く")
    }

    // MARK: - code-review で見つかった経路

    /// **古いスキーマでも複製は必ず残る**［code-review が実測で発見］。
    ///
    /// 移行前のストアは定義上「アプリが知らない古いスキーマ」なので、現行の
    /// record 型による JSON の書き出しは*失敗するのが普通*。JSON を先に書くと
    /// その失敗が**スキーマに依存しない複製まで巻き添えにし**、MG-10 と R-14 が
    /// 守ろうとしている当の状況で保護がゼロになっていた。
    @Test("古いスキーマでも移行前の複製は残る [MG-10][R-14]")
    func migrationSnapshotKeepsTheCopyWhenJSONFails() throws {
        let directory = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = BackupService(store: BackupStore(directory: directory), appVersion: "test")
        let source = StaleSchemaSource(storeContents: "old database bytes")

        let outcome = try #require(try service.snapshotBeforeMigration(source))
        #expect(outcome.documentURL == nil, "古いスキーマでは JSON を書けない")
        #expect(outcome.storeURL != nil, "複製は残る")
        let generations = try BackupStore(directory: directory).generations()
        #expect(generations.map(\.kind) == [.store])
    }

    /// **移行前の世代は日常的な契機に押し出されない**［code-review で発見］。
    /// 押し出されて困るのは、まさに移行が失敗したときである [R-14]。
    @Test("移行前の世代は別枠で守られる [MG-10]")
    func migrationGenerationsAreProtected() async throws {
        let directory = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let rig = try Rig(directory: directory, documents: 1, stores: 1)
        _ = try rig.service.snapshotBeforeMigration(rig.database.synchronousHandle)
        #expect(try rig.store.generations().contains { $0.reason == .schemaMigration })

        // 日常的な契機を、世代数の枠を何度も超えるまで繰り返す。
        for offset in 0 ..< 5 {
            _ = try await rig.service.snapshot(
                reason: .jsonImport, repository: rig.repository, database: rig.database,
                now: Date().addingTimeInterval(Double(offset)))
        }
        let left = try rig.store.generations()
        #expect(left.contains { $0.reason == .schemaMigration && $0.kind == .store })
        #expect(left.contains { $0.reason == .schemaMigration && $0.kind == .document })
    }

    /// **ライブラリの無効化も同じ範囲を消す**［code-review で発見］——
    /// 違うのは入口だけで、しかも日常的に使われるのはこちら（フォルダツリー）。
    @Test("ライブラリの無効化の前にも取る [BK-02]")
    @MainActor
    func disableTakesASnapshot() async throws {
        let w = try ServicesWorkspace()
        await w.bootstrap()
        _ = try await w.enable()
        #expect(try w.backupGenerations().filter { $0.reason == .libraryDelete }.isEmpty)

        try await w.services.disable(registrationUUID: w.registrationUUID)

        #expect(!(try w.backupGenerations().filter { $0.reason == .libraryDelete }.isEmpty))
    }

    /// **複製に失敗したら宛先を残さない**［code-review が実測で発見］——
    /// 宛先は 1 ページも写す前に作られるので、残すと中身の無いファイルが
    /// 「正常な世代」として枠を食う。
    @Test("複製に失敗したら世代を残さない")
    func failedCopyLeavesNothing() throws {
        let directory = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = BackupService(store: BackupStore(directory: directory), appVersion: "test")
        let source = StaleSchemaSource(storeContents: nil)   // 複製が失敗する

        #expect(throws: (any Error).self) {
            try service.snapshotBeforeMigration(source)
        }
        let generations = try BackupStore(directory: directory).generations()
        #expect(generations.isEmpty)
    }

    /// **複製先に `-wal` / `-shm` を作らない**［code-review が実測で発見］——
    /// `generations()` は解釈しないので、残ると誰にも見えないまま容量を食う。
    @Test("複製先に付随ファイルを残さない")
    func storeCopyLeavesNoSidecars() async throws {
        let directory = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let rig = try Rig(directory: directory)
        _ = try await rig.service.snapshot(
            reason: .jsonImport, repository: rig.repository, database: rig.database)

        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(!names.contains { $0.hasSuffix("-wal") || $0.hasSuffix("-shm") },
                "見えない付随ファイルが残っている: \(names)")
    }
}

/// 古いスキーマの移行前ストアを模す。
///
/// **実装型（`PreMigrationSnapshot`）では組み立てられない**——現行の
/// マイグレーションを当てたストアしか作れないので、「JSON は書けないが
/// 複製はできる」という、MG-10 がいちばん守りたい状況を再現できない。
private struct StaleSchemaSource: PreMigrationSource {
    /// `nil` なら複製も失敗する。
    var storeContents: String?

    var hasExistingSchema: Bool { true }
    func integrityCheck() throws -> Bool { true }

    func exportDocument(appVersion: String?) throws -> BackupDocument {
        // v14 未満で実際に起きる形（`label.isHidden` が無い）。
        throw StaleSchemaError.columnNotFound
    }

    func copyStore(to destination: URL) throws {
        // **本物と同じく、1 ページも写す前に宛先を作る**［code-review が
        // `QooDatabase.backup` で実測］。ここを省くと後始末 [BK3-09] を試せない。
        FileManager.default.createFile(atPath: destination.path, contents: Data(count: 4096))
        guard let storeContents else { throw StaleSchemaError.copyFailed }
        try storeContents.write(to: destination, atomically: true, encoding: .utf8)
    }

    enum StaleSchemaError: Error { case columnNotFound, copyFailed }
}
