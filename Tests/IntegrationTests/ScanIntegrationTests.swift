import Testing
import Foundation
import GRDB
import QooKit
@testable import QooInfrastructure
@testable import QooPersistence

//
//  スキャンの統合テスト [16章 §16.4]。
//
//  一時ディレクトリに擬似ライブラリを作り、**実ファイルを列挙して DB へ収束**
//  させる経路をそのまま試す。`QooInfrastructure`（列挙）と `QooPersistence`
//  （リポジトリ）は相互依存しない [A-01] ため、片方のテストターゲットからは
//  この経路を書けない。
//

/// `@Sendable` な進捗コールバックから触る箱。
final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return _value }
    func observe(_ n: Int) { lock.lock(); _value = max(_value, n); lock.unlock() }
}

/// 一時ディレクトリ上の擬似ライブラリ。
final class ScanWorkspace {
    let root: URL
    let database: QooDatabase
    let libraries: SQLiteLibraryRepository
    let files: SQLiteManagedFileRepository
    let labels: SQLiteLabelRepository
    let engine: ScanEngine
    let libraryID: LibraryID
    let volumeUUID: String

    init(preset: String = "builtin.doujinshi-a", targetExtensions: Set<String> = ["cbz"],
         metadata: (any EmbeddedMetadataReading)? = nil,
         readsEmbeddedMetadata: Bool = true,
         isDataless: (@Sendable (URL) -> Bool)? = nil) async throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("qoo-scan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        database = try QooDatabase.inMemory()
        let sets = try BuiltInTemplates.volumeSets()
        let template = try #require(try BuiltInTemplates.libraryTypes().first { $0.key == preset })
        libraries = SQLiteLibraryRepository(database: database, volumeSets: sets)
        files = SQLiteManagedFileRepository(database: database)
        labels = SQLiteLabelRepository(database: database)

        volumeUUID = VolumeIdentity.identifier(for: root) ?? "TESTVOL"
        libraryID = try await libraries.register(
            LibraryRegistration(uuid: UUID(), displayName: "テスト", bookmarkData: Data(),
                                resolvedPath: root.path, volumeUUID: volumeUUID,
                                libraryTypeID: LibraryTypeID(rawValue: 0)),
            template: template)
        // 画像拡張子だけを足す。**`settingsJSON` を丸ごと差し替えてはならない**
        // ——以前はそうしており、テンプレート由来の意味束縛 [RW-13] や
        // ラベルグループの並びを静かに落としていた（`@author` を束縛したときに
        // 「著者ラベルだけが付かない」という形で発覚した）。草案を読んで必要な
        // 部分だけ変え、製品と同じ `updateSettings` を通す。
        var draft = try #require(try await libraries.settingsDraft(libraryID: libraryID))
        draft.targetExtensions = Array(targetExtensions)
        draft.imageExtensions = Array(BookFolderDetector.defaultImageExtensions)
        draft.readsEmbeddedMetadata = readsEmbeddedMetadata
        try await libraries.updateSettings(draft, libraryID: libraryID)
        engine = ScanEngine(dependencies: .init(
            libraries: libraries, files: files, labels: labels,
            metadata: metadata ?? EmbeddedMetadataReader(),
            isDataless: isDataless ?? { CloudMaterialization.isDataless($0) }))
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func write(_ relativePath: String, bytes: Int = 16) throws {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path,
                                       contents: Data(repeating: 0x41, count: bytes))
    }

    func remove(_ relativePath: String) throws {
        try FileManager.default.removeItem(at: root.appendingPathComponent(relativePath))
    }

    func move(_ from: String, to: String) throws {
        let dst = root.appendingPathComponent(to)
        try FileManager.default.createDirectory(
            at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: root.appendingPathComponent(from), to: dst)
    }

    /// ディスク上の綴りでの相対パス。**FSEvents が渡してくるのはこの形**
    /// （実測: 濁点は NFC で作っても NFD で返る）。差分スキャンのテストで
    /// リテラルを渡すと、その 1 点だけ実運用と違う条件を試すことになる。
    func onDiskRelativePath(_ relativePath: String) throws -> String {
        let listed = try FileManager.default.contentsOfDirectory(
            at: root.appendingPathComponent(relativePath).deletingLastPathComponent(),
            includingPropertiesForKeys: nil)
        let leaf = (relativePath as NSString).lastPathComponent
        let onDisk = listed.first { $0.lastPathComponent == leaf }?.lastPathComponent ?? leaf
        let parent = (relativePath as NSString).deletingLastPathComponent
        return parent.isEmpty ? onDisk : parent + "/" + onDisk
    }

    /// 孤立を含めて全レコードを読む。`query` は `active` しか返さない。
    func allRows() async throws -> [(path: String, state: FileState)] {
        try await database.writer.read { db in
            try Row.fetchAll(db, sql: "SELECT relativePath, state FROM managedFile").map {
                ($0["relativePath"] as String,
                 FileState(rawValue: $0["state"] as String) ?? .active)
            }
        }
    }

    func rows() async throws -> [FileRow] {
        try await files.query(FileQuery(libraryID: libraryID, limit: 1000)).rows
    }

    func scanFull() async throws -> ScanSummary {
        try await engine.scan(.full(libraryID: libraryID), root: root)
    }
}

@Suite("スキャンの統合 [10.3][FO-20][SY-12][ID-01〜ID-08]", .serialized)
struct ScanIntegrationTests {

    @Test("実ファイルを列挙して DB へ取り込む")
    func fullScanImports() async throws {
        let w = try await ScanWorkspace()
        try w.write("(同人誌) [サークルA (作家A)] 作品1 (オリジナル).cbz")
        try w.write("(同人誌) [サークルB] 作品2 (原作B).cbz")
        try w.write("読み飛ばす.txt")

        let summary = try await w.scanFull()
        #expect(summary.added == 2, "対象拡張子だけを取り込むべき")
        #expect(summary.updated == 0)
        let rows = try await w.rows()
        #expect(Set(rows.map(\.filename)).count == 2)
    }

    /// **同じイベントを 2 回処理しても結果が変わらない** [FO-20][SY-12]。
    @Test("スキャンは冪等 [FO-20][SY-12]")
    func scanIsIdempotent() async throws {
        let w = try await ScanWorkspace()
        try w.write("(同人誌) [サークルA (作家A)] 作品1 (オリジナル).cbz")
        let first = try await w.scanFull()
        let second = try await w.scanFull()
        let third = try await w.scanFull()
        #expect(first.added == 1)
        #expect(second.added == 0)
        #expect(second.updated == 1)
        #expect(third.added == 0)
        #expect(try await w.rows().count == 1)
        // ラベルも増殖しない
        let group = try #require(try await w.labels.group(libraryID: w.libraryID, index: 2))
        #expect(try await w.labels.labels(groupID: group.id, includeArchived: true).count == 1)
    }

    @Test("パース結果が DB へ書き戻される [RC-01]")
    func parsedFieldsArePersisted() async throws {
        let w = try await ScanWorkspace()
        try w.write("(同人誌) [サークルA (作家A)] 作品タイトル 総集編 (オリジナル).cbz")
        _ = try await w.scanFull()
        let row = try #require(try await w.rows().first)
        #expect(row.title == "作品タイトル 総集編")
        #expect(row.seriesName == "作品タイトル")
        // VS-Doujin の「総集編」は**区切り専用**。シリーズ名は切るが巻数は持たない
        // [2026-08 の仕様変更で序列巻数を廃止]。
        #expect(row.volume.kind == VolumeValue.Kind.none)
    }

    @Test("ラベルが付与される [RC-01]")
    func labelsAreAssigned() async throws {
        let w = try await ScanWorkspace()
        try w.write("(同人誌) [サークルA (作家A)] 作品1 (オリジナル).cbz")
        try w.write("(同人誌) [サークルA (作家B)] 作品2 (オリジナル).cbz")
        _ = try await w.scanFull()

        let circle = try #require(try await w.labels.group(libraryID: w.libraryID, index: 2))
        let author = try #require(try await w.labels.group(libraryID: w.libraryID, index: 3))
        let genre = try #require(try await w.labels.group(libraryID: w.libraryID, index: 4))
        #expect(try await w.labels.labels(groupID: circle.id, includeArchived: false)
            .map(\.name) == ["サークルA"])
        #expect(Set(try await w.labels.labels(groupID: author.id, includeArchived: false)
            .map(\.name)) == ["作家A", "作家B"])
        #expect(try await w.labels.labels(groupID: genre.id, includeArchived: false)
            .first?.fileCount == 2)
    }

    /// **inode が同じなら同じレコード** [ID-02]。改名しても紐づけは失われない。
    @Test("改名を追従し、ラベルを保つ [ID-02]")
    func renameKeepsIdentityAndLabels() async throws {
        let w = try await ScanWorkspace()
        try w.write("(同人誌) [サークルA (作家A)] 旧題 (オリジナル).cbz")
        _ = try await w.scanFull()
        let before = try #require(try await w.rows().first)

        try w.move("(同人誌) [サークルA (作家A)] 旧題 (オリジナル).cbz",
                   to: "サブフォルダ/(同人誌) [サークルA (作家A)] 新題 (オリジナル).cbz")
        let summary = try await w.scanFull()
        #expect(summary.added == 0, "同じ inode なので新規にならない")
        let after = try #require(try await w.rows().first)
        #expect(after.id == before.id)
        #expect(after.filename.contains("新題"))
        #expect(after.relativePath.hasPrefix("サブフォルダ/"))
        #expect(after.state == .active)
    }

    /// **消えたファイルは削除せず孤立にする** [ID-06][ID3-04][R-01]。
    @Test("消えたファイルは孤立になる。削除しない [ID-06]")
    func missingBecomesOrphaned() async throws {
        let w = try await ScanWorkspace()
        try w.write("(同人誌) [サークルA] 残る (オリジナル).cbz")
        try w.write("(同人誌) [サークルA] 消える (オリジナル).cbz")
        _ = try await w.scanFull()
        try w.remove("(同人誌) [サークルA] 消える (オリジナル).cbz")

        let summary = try await w.scanFull()
        #expect(summary.orphaned == 1)
        // 一覧（active のみ）からは消えるが、レコードは残る
        #expect(try await w.rows().count == 1)
        #expect(try await w.libraries.totalFileCount() == 2)
    }

    /// **オフラインでは孤立判定を一切行わない** [SB-05][ID-08][R-01]。
    /// 外部ボリュームを抜いただけでラベル紐づけを一括で失う事故を防ぐ最後の砦。
    @Test("オフラインのライブラリはスキャンしない [SB-05][ID-08]")
    func offlineLibraryIsNotScanned() async throws {
        let w = try await ScanWorkspace()
        try w.write("(同人誌) [サークルA] 作品 (オリジナル).cbz")
        _ = try await w.scanFull()
        try w.remove("(同人誌) [サークルA] 作品 (オリジナル).cbz")

        try await w.libraries.setOnline(false, libraryID: w.libraryID)
        let summary = try await w.scanFull()
        #expect(summary.skipped, "オフラインなのに走った")
        #expect(summary.orphaned == 0, "オフラインで孤立判定をしてはいけない")
        #expect(try await w.rows().count == 1, "レコードが active のまま残るべき")
    }

    /// 別ボリュームへ移した等で inode が変わっても、パスとサイズで再照合する [ID-03][ID-04]。
    @Test("inode が変わっても同一相対パス + 同一サイズなら再照合する [ID-03][ID-04]")
    func reidentifyByPathAndSize() async throws {
        let w = try await ScanWorkspace()
        try w.write("(同人誌) [サークルA] 作品 (オリジナル).cbz", bytes: 64)
        _ = try await w.scanFull()
        let before = try #require(try await w.rows().first)

        // inode を変える（削除して同じ内容で作り直す = 別ファイルになる）
        try w.remove("(同人誌) [サークルA] 作品 (オリジナル).cbz")
        try w.write("(同人誌) [サークルA] 作品 (オリジナル).cbz", bytes: 64)

        let summary = try await w.scanFull()
        #expect(summary.reidentified == 1, "再照合されるべき")
        #expect(summary.added == 0)
        let after = try #require(try await w.rows().first)
        #expect(after.id == before.id, "同じレコードであるべき（ラベルが維持される）")
        #expect(try await w.libraries.totalFileCount() == 1)
    }

    /// 同じ場所で中身が入れ替わっても、ラベル・評価・手で直したタイトルは
    /// そのまま引き継がれる。**確認は挟まない**［ID-09〜ID-15 撤回、§19.8］
    /// ——差し替えは日常的に起きる。危険な取り違え（生きている行の横取り）は
    /// [ID3-08] のガードが防ぐ（`IdentityRowTheftTests`）。
    @Test("同じ場所での差し替えを黙って引き継ぐ [ID-03]③")
    func replacementIsCarriedOverByDefault() async throws {
        let w = try await ScanWorkspace()
        try w.write("(同人誌) [サークルA] 作品 (オリジナル).cbz", bytes: 64)
        _ = try await w.scanFull()
        let before = try #require(try await w.rows().first)
        try w.remove("(同人誌) [サークルA] 作品 (オリジナル).cbz")
        try w.write("(同人誌) [サークルA] 作品 (オリジナル).cbz", bytes: 999)

        let summary = try await w.scanFull()
        #expect(summary.reidentified == 1)
        #expect(summary.orphaned == 0)
        let after = try #require(try await w.rows().first)
        #expect(after.id == before.id, "同じレコードであるべき（ラベルが維持される）")
    }

    /// 移動と差し替えが同時に起きた形（[ID-03]③b、名前しか一致しない）でも
    /// 自動で引き継ぐ。**かつてはここだけ確認ダイアログに回していた**
    /// [ID-05][ID-13] が、同一性確認の撤去 [§19.8] で全確度が自動になった。
    /// 無関係な同名ファイルの横取りは [ID3-08] のガードが防ぐ。
    @Test("移動＋差し替え（名前だけ一致）も自動で引き継ぐ [ID-03]③")
    func moveWithReplacementIsCarriedOverAutomatically() async throws {
        let w = try await ScanWorkspace()
        try w.write("旧/(同人誌) [サークルA] 作品 (オリジナル).cbz", bytes: 64)
        _ = try await w.scanFull()
        let before = try #require(try await w.rows().first)
        try w.remove("旧/(同人誌) [サークルA] 作品 (オリジナル).cbz")
        try w.write("新/(同人誌) [サークルA] 作品 (オリジナル).cbz", bytes: 999)

        let summary = try await w.scanFull()
        #expect(summary.reidentified == 1)
        #expect(summary.added == 0)
        #expect(summary.orphaned == 0)
        let after = try #require(try await w.rows().first)
        #expect(after.id == before.id, "同じレコードであるべき（ラベルが維持される）")
        #expect(after.relativePath.hasPrefix("新/"))
    }

    @Test("ブックフォルダを 1 冊として登録する [IF-01][IF-10][IF-12]")
    func bookFolderIsOneRecord() async throws {
        let w = try await ScanWorkspace()
        for i in 1...5 {
            try w.write("(同人誌) [サークルA] 画像作品 (オリジナル)/\(String(format: "%03d", i)).jpg")
        }
        try w.write("(同人誌) [サークルA] 通常 (オリジナル).cbz")

        let summary = try await w.scanFull()
        #expect(summary.bookFoldersDetected == 1)
        #expect(summary.added == 2, "ブックフォルダ 1 件 + 通常 1 件")
        let rows = try await w.rows()
        #expect(rows.first { $0.isBookFolder }?.filename == "(同人誌) [サークルA] 画像作品 (オリジナル)")
        // 配下の画像は登録しない [IF-12]
        #expect(!rows.contains { $0.filename.hasSuffix(".jpg") })
    }

    /// **孤立にしてはいけない** [IF-05]。実体はまだそこにあり、ラベルも維持する。
    @Test("サブフォルダができたら 1 冊扱いが解除される。孤立にはしない [IF-05]")
    func bookFolderIsReleasedWhenSubfolderAppears() async throws {
        let w = try await ScanWorkspace()
        try w.write("画像作品/001.jpg")
        _ = try await w.scanFull()
        let book = try #require(try await w.rows().first)
        #expect(book.isBookFolder)

        // ラベルを手で付けておき、解除で失われないことを確かめる
        let group = try #require(try await w.labels.group(libraryID: w.libraryID, index: 2))
        let label = try await w.labels.ensureLabel(groupID: group.id, name: "手動ラベル")
        try await w.labels.assign(fileID: book.id, labelID: label, origin: .manual)

        try w.write("画像作品/追加/002.jpg")
        let summary = try await w.scanFull()

        #expect(summary.bookFoldersReleased == [book.id], "1 冊扱いの解除として報告すべき")
        #expect(summary.orphaned == 0, "実体はあるのに孤立にしてはいけない [IF-05]")
        let after = try #require(try await w.files.row(id: book.id))
        #expect(after.state == .active, "通常フォルダに戻すだけ [IF-05]")
        #expect(!after.isBookFolder)
        #expect(try await w.labels.labelIDs(fileID: book.id).map(\.labelID).contains(label),
                "ラベル紐づけを維持すべき [IF-05]")
        // 中の `追加` は条件を満たすので新しい 1 冊として検出される
        #expect(summary.bookFoldersDetected == 1)
    }

    @Test("シンボリックリンクは対象外 [SL-03]")
    func symlinksAreSkipped() async throws {
        let w = try await ScanWorkspace()
        try w.write("(同人誌) [サークルA] 実体 (オリジナル).cbz")
        try FileManager.default.createSymbolicLink(
            at: w.root.appendingPathComponent("(同人誌) [サークルA] リンク (オリジナル).cbz"),
            withDestinationURL: w.root.appendingPathComponent("(同人誌) [サークルA] 実体 (オリジナル).cbz"))
        let summary = try await w.scanFull()
        #expect(summary.added == 1)
        #expect(try await w.rows().count == 1)
    }

    @Test("フォルダスコープのスキャンは範囲外を孤立にしない [SY-06]")
    func folderScopeDoesNotOrphanOutside() async throws {
        let w = try await ScanWorkspace()
        try w.write("A/(同人誌) [サークルA] 中 (オリジナル).cbz")
        try w.write("B/(同人誌) [サークルA] 外 (オリジナル).cbz")
        _ = try await w.scanFull()
        try w.remove("B/(同人誌) [サークルA] 外 (オリジナル).cbz")

        let summary = try await w.engine.scan(
            .folder(libraryID: w.libraryID, relativePath: "A", recursive: true), root: w.root)
        #expect(summary.orphaned == 0, "範囲外を孤立にしてはいけない")
        #expect(try await w.rows().count == 2)
    }

    @Test("500 件を超えてもバッチ境界で処理される [SE3-05]")
    func largeScanBatches() async throws {
        let w = try await ScanWorkspace()
        for i in 1...1200 {
            try w.write("(同人誌) [サークル\(i % 7)] 作品\(i) (オリジナル).cbz", bytes: 8)
        }
        let lastProgress = ProgressBox()
        let summary = try await w.engine.scan(.full(libraryID: w.libraryID), root: w.root) { n, _ in
            lastProgress.observe(n)
        }
        #expect(summary.added == 1200)
        #expect(lastProgress.value == 1200)
        #expect(try await w.libraries.totalFileCount() == 1200)
    }
}

@Suite("スキャンの砦: 根の同一性 [R-01][SB-05][ID-08]", .serialized)
struct ScanRootSanityTests {

    /// **同じマウントポイントに別のボリュームが載った**場合。
    ///
    /// macOS は `/Volumes/<名前>` を使い回すので、外部ディスクを抜いて別の
    /// ディスクを挿すと、パスは同じまま中身だけが別物になる。存在確認だけ
    /// では列挙が成功してしまい、**観測されなかった＝ライブラリ全件が孤立**
    /// になる——外部ボリュームを抜き差ししただけでラベル紐づけを一括で失う
    /// 事故そのもの。
    @Test("別のボリュームが同じ場所に載っていたら走査を見送る")
    func aDifferentVolumeAtTheSamePathDoesNotOrphanEverything() async throws {
        let w = try await ScanWorkspace()
        try w.write("(同人誌) [サークル値0 (著者値0)] 作品タイトル0 第01巻 (ジャンル値0).cbz")
        try w.write("(同人誌) [サークル値1 (著者値1)] 作品タイトル1.cbz")
        #expect(try await w.scanFull().added == 2)

        // 登録済みのボリューム識別子だけを別物にする。DB から見れば
        // 「同じパスに別のボリュームが載っている」のと区別がつかない。
        let id = w.libraryID.rawValue
        try await w.database.writer.write { db in
            try db.execute(sql: "UPDATE library SET volumeUUID = ? WHERE id = ?",
                           arguments: ["VOLUME-THAT-IS-NOT-HERE", id])
        }

        let summary = try await w.scanFull()
        #expect(summary.skipped, "ボリュームが一致しないなら走査を見送るべき")
        #expect(summary.orphaned == 0, "別ボリュームを理由に全件を孤立にしてはならない")
        #expect(try await w.rows().allSatisfy { $0.state != .orphaned })
    }

    @Test("根が消えていたら走査を見送る")
    func aVanishedRootDoesNotOrphanEverything() async throws {
        let w = try await ScanWorkspace()
        try w.write("(同人誌) [サークル値0 (著者値0)] 作品タイトル0 第01巻 (ジャンル値0).cbz")
        #expect(try await w.scanFull().added == 1)

        try FileManager.default.removeItem(at: w.root)

        let summary = try await w.scanFull()
        #expect(summary.skipped)
        #expect(summary.orphaned == 0)
        #expect(try await w.rows().allSatisfy { $0.state != .orphaned })
    }
}
