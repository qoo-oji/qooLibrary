import Foundation
import QooInfrastructure
import QooKit
import Testing
@testable import QooApplication

//
//  合成根の統合テスト [フェーズ 2 の結線]。
//
//  `LibraryServices` は DB・リポジトリ・スキャンエンジンを束ねる唯一の場所
//  なので、ここが通ることが「アプリから呼べば動く」ことの最小の担保になる。
//  **必ず一時ディレクトリのストアを使う**——既定のままだと開発機の実ストアを
//  開いて書き換える（診断ログの出力先振り替えと同じ理由）。
//

/// 一時ディレクトリ上のストアと擬似ライブラリ。
@MainActor
final class ServicesWorkspace {
    let services: LibraryServices
    let storeDirectory: URL
    let libraryRoot: URL
    /// ユーザー指定カバーの複製 [CV-06]。**この作業領域ごとに分ける**——
    /// 既定の場所はテスト中も一時ディレクトリへ振り替わるが、そこを共有すると
    /// 互いの複製を掃除し合う（`purgeUnreferencedUserCovers` は「参照されて
    /// いないものを捨てる」ので、別のテストの複製は必ず未参照に見える）。
    let coverDirectory: URL
    /// ユーザー定義テンプレート [LT-02]。**作業領域ごとに分ける**——共有すると
    /// 互いのテンプレートが混ざる（`coverDirectory` と同じ理由）。
    let templateStoreURL: URL

    let registrationUUID = UUID()

    /// - Parameter operationLogRecorder: 走査の記録 [OH-03] を見たいテストが
    ///   **独立した書き手**を渡す。既定（`.shared`）のままだとテスト中は
    ///   繋がれない（`LibraryServices.attachOperationLog` 参照）。
    init(operationLogRecorder: OperationLogRecorder = .shared) throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("qoo-services-\(UUID().uuidString)")
        storeDirectory = base.appendingPathComponent("store")
        libraryRoot = base.appendingPathComponent("library")
        coverDirectory = base.appendingPathComponent("usercovers")
        templateStoreURL = base.appendingPathComponent("userTemplates.json")
        services = LibraryServices(
            userCoverStore: DefaultUserCoverStore(baseDirectory: coverDirectory),
            userTemplateStore: UserTemplateStore(storageURL: templateStoreURL),
            operationLogRecorder: operationLogRecorder)
        try FileManager.default.createDirectory(at: libraryRoot, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: storeDirectory.deletingLastPathComponent())
    }

    var storeURL: URL { storeDirectory.appendingPathComponent("qooLibrary.sqlite") }

    func bootstrap() async {
        await services.bootstrap(storeURL: storeURL)
    }

    func write(_ relativePath: String) throws {
        let url = libraryRoot.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: Data(repeating: 0x41, count: 16))
    }

    func template(_ key: String = "builtin.doujinshi-a") throws -> LibraryTypeTemplate {
        try #require(services.presetTemplates.first { $0.key == key })
    }

    /// 設定を 1 項目だけ変えて保存する。
    ///
    /// **草案を読んでから変えること。**`LibrarySettingsDraft` を新しく組み立てて
    /// 差し替える補助コードは、書いた時点では存在しなかった項目（意味束縛・
    /// ラベルグループの並び）を黙って落とす——`ScanWorkspace.init` で実際に
    /// 踏んで、「著者ラベルだけが付かない」という形で表面化した。
    func editSettings(_ id: LibraryID,
                      _ change: (inout LibrarySettingsDraft) -> Void) async throws {
        guard var draft = try await services.settingsDraft(libraryID: id) else {
            throw ServicesWorkspaceError.noSettings
        }
        change(&draft)
        try await services.updateSettings(draft, libraryID: id)
    }

    @discardableResult
    func enable(_ key: String = "builtin.doujinshi-a") async throws -> LibraryID {
        try await services.enable(
            registrationUUID: registrationUUID,
            displayName: "テストライブラリ",
            url: libraryRoot,
            bookmarkData: Data(),
            template: try template(key))
    }
}

enum ServicesWorkspaceError: Error { case noSettings }

@Suite("合成根 LibraryServices", .serialized)
struct LibraryServicesTests {

    @Test("ストアを開いてプリセットを読める")
    @MainActor
    func bootstrapOpensTheStore() async throws {
        let w = try ServicesWorkspace()
        await w.bootstrap()
        #expect(w.services.startupFailure == nil)
        #expect(w.services.isReady)
        #expect(w.services.presetTemplates.count == 8, "プリセットは 8 種 [11.4]")
        #expect(w.services.libraries.isEmpty, "有効化するまでライブラリは 0 件")
        #expect(FileManager.default.fileExists(atPath: w.storeURL.path))
    }

    /// **登録フォルダ ID をそのまま `library.uuid` にする** [07章 §7.3]。
    /// 新しい UUID を振ると、環境設定の「起動時に開くフォルダ」・
    /// `NavigationRoot.registeredFolder(id:)`・ウインドウ状態復元が全部
    /// 指し先を失う。
    @Test("有効化は登録フォルダ ID を引き継ぐ [07章 §7.3]")
    @MainActor
    func enableInheritsTheRegistrationUUID() async throws {
        let w = try ServicesWorkspace()
        await w.bootstrap()
        try await w.enable()

        #expect(w.services.libraries.count == 1)
        let summary = try #require(w.services.library(registrationUUID: w.registrationUUID))
        #expect(summary.uuid == w.registrationUUID, "新しい UUID を振ってはいけない")
        #expect(w.services.isEnabled(registrationUUID: w.registrationUUID))
    }

    @Test("同じ登録を二度有効化しても増えない")
    @MainActor
    func enableIsIdempotent() async throws {
        let w = try ServicesWorkspace()
        await w.bootstrap()
        let first = try await w.enable()
        let second = try await w.enable()
        #expect(first == second)
        #expect(w.services.libraries.count == 1)
    }

    @Test("無効化するとライブラリだけが消える")
    @MainActor
    func disableRemovesTheLibrary() async throws {
        let w = try ServicesWorkspace()
        await w.bootstrap()
        try await w.enable()
        try await w.services.disable(registrationUUID: w.registrationUUID)
        #expect(w.services.libraries.isEmpty)
        #expect(!w.services.isEnabled(registrationUUID: w.registrationUUID))
    }

    /// 結線の本命。**アプリ層の入口から実ファイルが DB に入る**ところまで。
    @Test("有効化 → スキャンで実ファイルが DB に入る")
    @MainActor
    func scanImportsRealFiles() async throws {
        let w = try ServicesWorkspace()
        await w.bootstrap()
        try w.write("(同人誌) [サークルA (作家A)] 作品1 (オリジナル).cbz")
        try w.write("(同人誌) [サークルB] 作品2 (原作B).cbz")
        let id = try await w.enable()

        let summary = try await w.services.scan(libraryID: id, root: w.libraryRoot)
        #expect(summary.added == 2)
        #expect(summary.skipped == false)
        #expect(w.services.libraries.first?.fileCount == 2, "有効化後に一覧が更新される")
    }

    /// **要件定義書 11.4 節: 対象拡張子は全テンプレート共通で
    /// `zip, cbz, rar, cbr, 7z, cb7, pdf, epub`。**
    ///
    /// これが空だと `LibraryEnumerator` が「すべてのファイルが対象」と読み、
    /// 初回スキャンが `.DS_Store` やメモの `.txt` まで蔵書として取り込む。
    @Test("既定の対象拡張子だけを取り込む [AL-11][要件 11.4]")
    @MainActor
    func scanHonoursTheDefaultTargetExtensions() async throws {
        let w = try ServicesWorkspace()
        await w.bootstrap()
        try w.write("(同人誌) [サークルA (作家A)] 作品1 (オリジナル).cbz")
        try w.write("メモ.txt")
        try w.write(".DS_Store")
        let id = try await w.enable()

        let summary = try await w.services.scan(libraryID: id, root: w.libraryRoot)
        #expect(summary.added == 1, "対象拡張子以外を取り込んではいけない")
    }

    @Test("スキャンは冪等 [FO-20][SY-12]")
    @MainActor
    func scanIsIdempotent() async throws {
        let w = try ServicesWorkspace()
        await w.bootstrap()
        try w.write("(同人誌) [サークルA (作家A)] 作品1 (オリジナル).cbz")
        let id = try await w.enable()

        let first = try await w.services.scan(libraryID: id, root: w.libraryRoot)
        let second = try await w.services.scan(libraryID: id, root: w.libraryRoot)
        #expect(first.added == 1)
        #expect(second.added == 0)
        #expect(second.orphaned == 0, "2 回目で孤立が出るなら収束していない")
    }

    /// ストアを開けなくてもアプリは動き続ける［設計判断］。
    @Test("開けないストアでも起動を止めない")
    @MainActor
    func aBrokenStoreDoesNotStopTheApp() async throws {
        let w = try ServicesWorkspace()
        // ストアの場所を「ディレクトリを作れない」場所にする（既存ファイルの下）。
        let blocker = w.storeDirectory.deletingLastPathComponent()
            .appendingPathComponent("blocker")
        try FileManager.default.createDirectory(
            at: blocker.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: blocker.path, contents: Data())

        await w.services.bootstrap(storeURL: blocker.appendingPathComponent("x.sqlite"))
        #expect(w.services.startupFailure != nil)
        #expect(!w.services.isReady, "使えないことは分かるが、投げてはいけない")
    }
}

@Suite("スキャンの砦（孤立の暴発を防ぐ）", .serialized)
struct ScanSafetyTests {

    /// **外部ボリュームを抜いただけでラベル紐づけを一括で失ってはならない**
    /// [R-01][SB-05][ID-08]。
    ///
    /// 根が消えている状態でスキャンが走っても、孤立にせず見送ること。
    /// `isOnline` を更新する経路（VD-01〜06）が入るまでの間、これが実質の砦。
    @Test("根が消えていたら孤立させず見送る")
    @MainActor
    func aVanishedRootDoesNotOrphanEverything() async throws {
        let w = try ServicesWorkspace()
        await w.bootstrap()
        try w.write("(同人誌) [サークル値0 (著者値0)] 作品タイトル0 第01巻 (ジャンル値0).cbz")
        try w.write("(同人誌) [サークル値1 (著者値1)] 作品タイトル1.cbz")
        let id = try await w.enable()
        let first = try await w.services.scan(libraryID: id, root: w.libraryRoot)
        #expect(first.added == 2)

        // ボリュームごと消えた状況を作る。
        try FileManager.default.removeItem(at: w.libraryRoot)

        let second = try await w.services.scan(libraryID: id, root: w.libraryRoot)
        #expect(second.skipped, "根が無いなら走査そのものを見送るべき")
        #expect(second.orphaned == 0, "根が消えただけで全件を孤立にしてはならない")
    }

}

@Suite("縮退したライブラリの後始末", .serialized)
struct DisableDegradedLibraryTests {

    /// **ボリュームを失っても無効化できなければならない。**
    ///
    /// 無効化は DB の行を消すだけで、ボリュームにも実ファイルにも触れない。
    /// ここがオンラインを要求すると、**外付けを失ったライブラリを二度と
    /// 片付けられなくなる**——縮退状態こそ片付けたい場面である。
    /// （実機検証で、メニュー側をオンライン条件で塞いでいて実際に踏んだ。）
    @Test("根が消えていても無効化できる")
    @MainActor
    func aLibraryCanBeDisabledAfterItsVolumeIsGone() async throws {
        let w = try ServicesWorkspace()
        await w.bootstrap()
        try w.write("(同人誌) [サークル値0 (著者値0)] 作品タイトル0 第01巻 (ジャンル値0).cbz")
        let id = try await w.enable()
        #expect(try await w.services.scan(libraryID: id, root: w.libraryRoot).added == 1)

        // ボリュームごと消えた状況。
        try FileManager.default.removeItem(at: w.libraryRoot)

        try await w.services.disable(registrationUUID: w.registrationUUID)
        #expect(w.services.libraries.isEmpty, "根が無くても無効化できるべき")
        #expect(!w.services.isEnabled(registrationUUID: w.registrationUUID))
    }

    /// 無効化したらファイルのレコードも残さない。残ると、同じフォルダを
    /// 再登録したときに古い行が二重に見える。
    @Test("無効化でファイルのレコードも消える")
    @MainActor
    func disablingRemovesTheFileRowsToo() async throws {
        let w = try ServicesWorkspace()
        await w.bootstrap()
        try w.write("(同人誌) [サークル値0 (著者値0)] 作品タイトル0 第01巻 (ジャンル値0).cbz")
        try w.write("(同人誌) [サークル値1 (著者値1)] 作品タイトル1.cbz")
        let id = try await w.enable()
        #expect(try await w.services.scan(libraryID: id, root: w.libraryRoot).added == 2)

        try await w.services.disable(registrationUUID: w.registrationUUID)

        // 同じ登録 ID で入れ直すと、前回のレコードが残っていないことが分かる。
        let again = try await w.enable()
        let summary = try await w.services.scan(libraryID: again, root: w.libraryRoot)
        #expect(summary.added == 2, "前回のレコードが残っていれば「更新」になるはず")
        #expect(summary.updated == 0)
    }
}

//
//  バックアップと削除 [IE-01〜IE-14][MG-24][RG-06]。
//
//  **ここが「削除しても戻せる」ことの担保**。リセットタブはこの 2 つの口
//  （`exportBackup` / `deleteLibrary`）しか呼ばないので、合成根で往復が
//  通れば、UI に残るのはパネルの提示とボタンの結線だけになる。
//
@Suite("バックアップと削除 [IE-01][MG-24][RG-06]", .serialized)
struct LibraryBackupServicesTests {

    @Test("書き出した JSON を読み戻せる [IE-01][IE-03]")
    @MainActor
    func exportProducesReadableJSON() async throws {
        let w = try ServicesWorkspace()
        await w.bootstrap()
        try await w.enable()

        let document = try await w.services.exportBackup()
        #expect(document.libraries.count == 1)
        #expect(document.schemaVersion == BackupDocument.currentSchemaVersion)

        let data = try BackupCoding.encode(document)
        let decoded = try BackupCoding.decode(data)
        #expect(decoded.libraries.first?.displayName == "テストライブラリ")
        // ラベルグループはテンプレートから展開済み [LT-03]。設定が
        // 書き出しに乗っていることの確認。
        #expect((decoded.libraries.first?.labelGroups.count ?? 0) > 0)
        #expect((decoded.libraries.first?.filenameFormats.count ?? 0) > 0)
    }

    @Test("削除はライブラリの行を消す [RG-06]")
    @MainActor
    func deleteRemovesTheLibrary() async throws {
        let w = try ServicesWorkspace()
        await w.bootstrap()
        let id = try await w.enable()
        #expect(w.services.libraries.count == 1)

        try await w.services.deleteLibrary(id: id)
        #expect(w.services.libraries.isEmpty)
        #expect(w.services.library(registrationUUID: w.registrationUUID) == nil)
    }

    /// **これが MG-24 の復旧手順そのもの**：書き出す → 消す → 有効化し直す →
    /// 取り込む。ここが通らないなら、リセットタブの削除ボタンを出しては
    /// いけない［ユーザーからの制約: 一括削除より先にエクスポート/インポート］。
    @Test("削除したライブラリの設定を、有効化し直して取り込むと戻せる [MG-24]")
    @MainActor
    func settingsSurviveDeleteAndReimport() async throws {
        let w = try ServicesWorkspace()
        await w.bootstrap()
        let id = try await w.enable()

        // ユーザーが手を入れた設定を作る [LS-01]。テンプレートの雛形から
        // ずらしておかないと、再有効化しただけで同じ状態に戻ってしまい、
        // 取り込みが効いたのかどうか区別できない。
        var draft = try #require(try await w.services.settingsDraft(libraryID: id))
        draft.fields[0].name = "自分で付けた名前"
        draft.fields[0].colorHexLight = "#123456"
        draft.filenameFormats.append(FilenameFormatDraft(source: "@title", isEnabled: true))
        let formatCount = draft.filenameFormats.count
        try await w.services.updateSettings(draft, libraryID: id)

        let document = try await w.services.exportBackup()

        // 消す。
        try await w.services.deleteLibrary(id: id)
        #expect(w.services.libraries.isEmpty)

        // 取り込みはライブラリを作らない——**まず有効化し直す**のが正しい
        // 手順であることを、ここで固定する。
        let planBefore = try await w.services.planImport(document)
        #expect(planBefore.libraries.first?.kind == .missing)

        let restoredID = try await w.enable()
        let applied = try await w.services.importBackup(document)
        #expect(applied.libraries.first?.kind == .update)

        let restored = try #require(try await w.services.settingsDraft(libraryID: restoredID))
        #expect(restored.fields[0].name == "自分で付けた名前")
        #expect(restored.fields[0].colorHexLight == "#123456")
        #expect(restored.filenameFormats.count == formatCount)
        #expect(restored.filenameFormats.contains { $0.source == "@title" })
    }

    @Test("ストアを開けていなければ書き出しも削除も断る [ER-03]")
    @MainActor
    func refusesWhenTheStoreIsNotReady() async throws {
        let services = LibraryServices()   // bootstrap しない
        await #expect(throws: LibraryServices.ServiceError.notReady) {
            _ = try await services.exportBackup()
        }
        await #expect(throws: LibraryServices.ServiceError.notReady) {
            try await services.deleteLibrary(id: LibraryID(rawValue: 1))
        }
    }
}
