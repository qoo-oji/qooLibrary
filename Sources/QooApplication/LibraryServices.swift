//
//  フェーズ 2 の合成根 [A-01][A-02][ST-01][CN-01]。
//
//  `QooPersistence`（DB）と `QooInfrastructure`（走査・監視）の**両方に依存して
//  よい唯一の層がここ**なので、接続を開き、リポジトリを組み立て、スキャンと
//  監視を配線する仕事をこのファイルに集める。上位（`qooLibraryApp`）は
//  `LibraryServices.shared` だけを見て、GRDB もリポジトリの実装型も知らない。
//
import Foundation
import Observation
import QooInfrastructure
import QooKit
import QooPersistence

/// ライブラリ機能の入口。アプリで単一 [ST-01][ST-02]。
///
/// ## 起動に失敗してもアプリは動き続ける［設計判断］
/// ストアを開けない（破損・スキーマが新しすぎる [MG-12]・ディスク不良）ときに
/// アプリごと起動しないのは過剰である——qooLibrary はフェーズ 1 の時点で
/// **ファイルマネージャーとして完結している**ので、ライブラリ機能だけを畳んで
/// 残りは従来どおり使えるほうが害が小さい。失敗は ``startupFailure`` に残し、
/// UI がその旨を提示する [ER-01]。
///
/// ## なぜ遅延して開くのか
/// `init()` では何もせず、``bootstrap()`` を起動時に 1 度呼ぶ。`QooDatabase.open`
/// は移行を伴い、初回はテーブル作成まで走るため、メインスレッドで待ってよい
/// 長さとは限らない。ローカル限定の I/O ではあるが `FileIO` へ逃がす
/// [NV6-01]——費用がほぼ無い一方、起動が固まる形は最も目につく壊れ方なので。
@MainActor
@Observable
public final class LibraryServices {
    public static let shared = LibraryServices()

    // MARK: - 外から見える状態

    /// DB に載っているライブラリ。**登録フォルダ（`registeredFolders.json`）とは
    /// 別物**——登録フォルダのうち、ユーザーが明示的にライブラリとして有効化した
    /// ものだけがここに現れる（後述の ``enable(registrationUUID:displayName:url:template:)``）。
    public private(set) var libraries: [LibrarySummary] = []

    /// プリセットのライブラリタイプ [11.4][LT-01]。有効化の選択肢に使う。
    public private(set) var presetTemplates: [LibraryTypeTemplate] = []

    /// 巻数フォーマットセットの定義 [11.3]。有効化画面がテンプレートから
    /// 草案を組み立てるのに要る（巻数はテンプレートが名前で参照する）。
    public var volumeSetDefinition: VolumeSetDefinition? { volumeSets }

    /// ストアを開けなかった理由。`nil` なら正常。
    public private(set) var startupFailure: StoreStartupFailure?

    /// DB の中身が変わるたびに増える [VM-10]。
    ///
    /// **ライブラリ表示モードの一覧は実体ではなく DB を描く**ので、
    /// `DirectoryObservation`（実体の変更）だけでは追随できない——外部で
    /// ファイルが増えても、走査が DB へ書き込むまで一覧に出る材料が無い。
    /// 走査が 1 本終わるたびにここを進め、中央ペインが `.task(id:)` の鍵に
    /// 混ぜて読み直す。
    ///
    /// **評価・ラベル・タイトルの編集はここを進めない**——あちらは
    /// `CommandStack.operationHistory.count` が同じ役目を果たしており、
    /// 2 つの合図を 1 つに畳むと「どちらで起きた変化か」が読めなくなる。
    public private(set) var contentRevision = 0


    /// ライブラリ機能が使えるか。UI はこれを見てメニュー項目の有効／無効を決める。
    public var isReady: Bool { database != nil }

    // MARK: - 内部

    private var database: QooDatabase?
    private var volumeSets: VolumeSetDefinition?
    private var libraryRepository: (any LibraryRepository)?
    private var fileRepository: (any ManagedFileRepository)?
    private var labelRepository: (any LabelRepository)?
    private var backupRepository: (any BackupRepository)?
    private var scanEngine: ScanEngine?
    /// ユーザー指定カバーの複製 [CV-06]。DB を開けていなくても場所は決まるので、
    /// リポジトリと違い常に持っている。
    private let userCoverStore: any UserCoverStoring
    private var didBootstrap = false
    /// 実体への追随 [SY-01〜SY-08][VD-01〜VD-11]。`bootstrap()` で組み立て、
    /// ``startSync()`` で動き出す。
    public private(set) var sync: LibrarySyncCoordinator?

    /// - Parameter userCoverStore: ユーザー指定カバーの複製の置き場所 [CV-06]。
    ///   **テストは独立した一時ディレクトリを渡すこと**（`bootstrap(storeURL:)` と
    ///   同じ理由）。既定も `swift test` 中は振り替わるが、テストどうしが
    ///   同じ場所を共有すると互いの複製を掃除し合う。
    public init(userCoverStore: any UserCoverStoring = DefaultUserCoverStore.shared) {
        self.userCoverStore = userCoverStore
    }

    // MARK: - 起動

    /// ストアを開き、リポジトリとスキャンエンジンを組み立てる。
    /// 何度呼んでも 1 回しか効かない。
    ///
    /// - Parameter storeURL: 置き場所。既定（`nil`）は
    ///   `~/Library/Application Support/qooLibrary/qooLibrary.sqlite`。
    ///   **テストは必ず一時ディレクトリを渡すこと**——既定のままだと開発機の
    ///   実ストアを開いて書き換えてしまう（診断ログの出力先振り替えと同じ理由）。
    public func bootstrap(storeURL explicitStoreURL: URL? = nil) async {
        guard !didBootstrap else { return }
        didBootstrap = true

        // テンプレートはストアと独立に読める。ストアが開けなくても
        // 「どのライブラリタイプがあるか」は見せられるようにしておく。
        do {
            presetTemplates = try BuiltInTemplates.libraryTypes()
            volumeSets = try BuiltInTemplates.volumeSets()
        } catch {
            Log.app.error("テンプレートを読めない: \(String(describing: error))")
            startupFailure = .templatesUnavailable(String(describing: error))
            return
        }

        guard let storeURL = explicitStoreURL ?? Self.defaultStoreURL() else {
            startupFailure = .storeLocationUnavailable
            return
        }
        do {
            let opened = try await FileIO.perform {
                try QooDatabase.open(at: storeURL)
            }
            database = opened
            // `bootstrap()` はここへ来る前に必ず volumeSets を読んでいる
            // （読めなければ上で return する）。
            libraryRepository = SQLiteLibraryRepository(
                database: opened, volumeSets: volumeSets ?? .empty)
            fileRepository = SQLiteManagedFileRepository(database: opened)
            labelRepository = SQLiteLabelRepository(database: opened)
            backupRepository = SQLiteBackupRepository(database: opened)
            Log.app.info("ライブラリストアを開いた: \(Log.path(storeURL))")
            makeSyncCoordinator()
        } catch let error as QooDatabase.StoreError {
            startupFailure = StoreStartupFailure(error)
            Log.app.error("ライブラリストアを開けない: \(String(describing: error))")
            return
        } catch {
            startupFailure = .openFailed(String(describing: error))
            Log.app.error("ライブラリストアを開けない: \(String(describing: error))")
            return
        }
        await refreshLibraries()
    }

    /// 実体への追随を組み立てる。**開始はしない**——起動時に走査が始まる前に
    /// 登録フォルダの読み込み（`RegisteredFolderStore.loadAndActivateAll`）が
    /// 済んでいる必要があるので、開始はアプリ側が明示的に呼ぶ [ST-01]。
    private func makeSyncCoordinator() {
        guard let libraryRepository, sync == nil else { return }
        // `swift test` 中は組み立てない。既定の依存は
        // `RegisteredFolderStore.shared` と `LibraryWatcher.shared`（どちらも
        // アプリ全体で 1 つ）なので、**開発機の実際の登録フォルダに対して
        // FSEvents を張ってしまう** [`DiagnosticLog` のテスト時出力振り替えと
        // 同じ理由]。調整役のテストは独立インスタンスを組み立てて検証する。
        if RuntimeEnvironment.isRunningTests { return }
        let engine = makeScanEngineIfNeeded()
        sync = LibrarySyncCoordinator(dependencies: .init(
            libraries: libraryRepository,
            scan: { [weak engine] mode, url in
                guard let engine else { return .notRun }
                return try await engine.scan(mode, root: url)
            },
            fullScanInterval: Self.configuredFullScanInterval()))
        // 自動走査は `ScanEngine` を直に呼ぶので `scan(libraryID:)` を通らない。
        // **ここで拾わないと、外部でファイルが増えてもライブラリ表示モードの
        // 一覧が古いまま**になる（この受け口の最初の利用者）。
        sync?.onScanFinished = { [weak self] _, summary in
            guard summary.added > 0 || summary.updated > 0 || summary.orphaned > 0 else { return }
            Task { @MainActor in self?.contentRevision &+= 1 }
        }
        // 着脱で `isOnline` が変わったら**一覧の写しを取り直す** [VD-03][VD-05]。
        // これが無いと、開いたままの画面が古い状態を見続ける（孤立の整理
        // ウインドウが取り出しに追随しなかった。実機検証で発見）。
        sync?.onOnlineStateChanged = { [weak self] in
            Task { @MainActor in await self?.refreshLibraries() }
        }
    }

    /// 起動時にフルスキャンし直すまでの間隔 [SY-05]。環境設定で変更でき、
    /// `0` 以下なら無効。
    static func configuredFullScanInterval() -> TimeInterval? {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: fullScanIntervalDaysKey) != nil else {
            return AppLimits.Watch.defaultFullScanInterval
        }
        let days = defaults.double(forKey: fullScanIntervalDaysKey)
        return days > 0 ? days * 24 * 60 * 60 : nil
    }

    /// 環境設定の鍵。UI 側と共有する。
    public static let fullScanIntervalDaysKey = "qoo.library.fullScanIntervalDays"

    /// 実体への追随を始める [SY-01]。**登録フォルダを読み終えてから呼ぶこと。**
    public func startSync() async {
        await sync?.start()
    }

    /// 終了時に差分の起点を保存して止める [SY-02][WA-02]。
    public func stopSync() async {
        await sync?.stop()
    }

    /// 既定の置き場所 [07章 §7.1]。
    static func defaultStoreURL() -> URL? {
        guard let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return QooDatabase.defaultStoreURL(applicationSupport: appSupport)
    }

    // MARK: - 問い合わせ

    public func refreshLibraries() async {
        guard let repository = libraryRepository else { return }
        do {
            libraries = try await repository.libraries()
        } catch {
            Log.app.error("ライブラリ一覧を読めない: \(String(describing: error))")
        }
    }

    /// 登録フォルダ ID（フェーズ 1 の `registeredFolders.json` の `id`）で引く。
    ///
    /// **`library.uuid` は登録フォルダ ID をそのまま持つ** [07章 §7.3]ので、
    /// 上位層は UUID 1 つでフェーズ 1 の登録とフェーズ 2 のライブラリを行き来できる。
    public func library(registrationUUID uuid: UUID) -> LibrarySummary? {
        libraries.first { $0.uuid == uuid }
    }

    public func isEnabled(registrationUUID uuid: UUID) -> Bool {
        library(registrationUUID: uuid) != nil
    }

    // MARK: - 有効化・無効化

    /// 登録フォルダをライブラリとして有効化する [RG-01][LT-03]。
    ///
    /// **新しい UUID を振らない** [07章 §7.3]。フェーズ 1 の登録 ID をそのまま
    /// `library.uuid` に入れることで、環境設定の「起動時に開くフォルダ」・
    /// `NavigationRoot.registeredFolder(id:)`・ウインドウ状態復元が
    /// **一切の変更なしに**フェーズ 2 のライブラリを指せる。
    ///
    /// - Parameter url: 解決済みの根。呼び出し側が `RegisteredFolderStore` の
    ///   状態を見て `.online` のものだけを渡すこと——オフラインのまま登録すると
    ///   `resolvedPath`/`volumeUUID` を実測できない。
    @discardableResult
    public func enable(
        registrationUUID uuid: UUID,
        displayName: String,
        url: URL,
        bookmarkData: Data,
        template: LibraryTypeTemplate
    ) async throws -> LibraryID {
        // 既定の草案を作って委譲する。**有効化画面が見せるのと同じ関数**なので、
        // 「見たものが登録される」が経路によらず成り立つ。
        let draft = TemplateInstantiation.draft(
            from: template, volumeSets: volumeSets ?? .empty, displayName: displayName,
            otherLibraryTypeNames: libraries.map(\.libraryTypeName),
            otherLibraryDisplayNames: libraries.map(\.displayName))
        return try await enable(registrationUUID: uuid, displayName: displayName, url: url,
                                bookmarkData: bookmarkData, draft: draft, template: template)
    }

    /// 草案を指定して有効化する [LT-02][LS-01、ユーザー要望]。
    ///
    /// **有効化の時点で設定を調整できるようにするための経路。** 選ぶだけでは
    /// 「その選択で何がどう変わるか」が分からない、という指摘への答えで、
    /// 画面で編集した草案がそのまま登録される。`template` が `nil` なら
    /// 白紙から作ったカスタム [LT-02]。
    @discardableResult
    public func enable(
        registrationUUID uuid: UUID,
        displayName: String,
        url: URL,
        bookmarkData: Data,
        draft: LibrarySettingsDraft,
        template: LibraryTypeTemplate?
    ) async throws -> LibraryID {
        guard let repository = libraryRepository else { throw ServiceError.notReady }
        if let existing = try await repository.library(uuid: uuid) {
            return existing.id                                   // 冪等
        }
        // ボリューム識別子は I/O を伴うので逃がす [NV6-02]。
        //
        // **取れなくても空文字を入れない** [NV3-01]。SMB では `volumeUUIDString`
        // が必ず nil で、`?? ""` にするとマウント中の全共有が同一視される。
        // `VolumeIdentity` がマウント元から代替を導き、それでも取れなければ
        // 登録自体を断る——同一性を追えないライブラリを黙って作るほうが危ない。
        let resolved = try await FileIO.perform { () -> (String, String) in
            guard let volumeUUID = VolumeIdentity.identifier(for: url) else {
                throw ServiceError.volumeIdentityUnavailable
            }
            return (url.path, volumeUUID)
        }
        let registration = LibraryRegistration(
            uuid: uuid,
            displayName: displayName,
            bookmarkData: bookmarkData,
            resolvedPath: resolved.0,
            volumeUUID: resolved.1,
            libraryTypeID: LibraryTypeID(rawValue: 0)   // 実装側が presetKey で解決する
        )
        let id = try await repository.register(registration, draft: draft, template: template)
        Log.app.info("""
            ライブラリを有効化: \(Log.redactable(displayName)) \
            / タイプ \(template?.displayName ?? "カスタム") \
            / フォーマット \(draft.filenameFormats.count) 本 → \(Log.path(url))
            """)
        await refreshLibraries()
        await sync?.resync()          // 監視対象に加える [SY-01]
        return id
    }

    /// ライブラリとしての登録を解除する。**登録フォルダ自体は消さない**
    /// ——フォルダツリーからは従来どおり辿れる状態に戻るだけ。
    public func disable(registrationUUID uuid: UUID, keepLabels: Bool = false) async throws {
        guard let repository = libraryRepository else { throw ServiceError.notReady }
        guard let summary = try await repository.library(uuid: uuid) else { return }
        try await repository.unregister(id: summary.id, keepLabels: keepLabels)
        // ユーザー指定カバーの複製を片付ける [CV-06]。行が連鎖削除された時点で
        // 誰も参照していないので、起動時の掃除を待たずにここで捨ててよい
        // ——無効化は Undo できないため、「取り消した先に実体が無い」は起きない。
        await userCoverStore.removeAll(libraryUUID: summary.uuid)
        Log.app.info("ライブラリを無効化: \(Log.redactable(summary.displayName))")
        await refreshLibraries()
        await sync?.resync()          // 監視対象から外す
    }

    // MARK: - 設定の編集 [LS-01〜LS-03]

    /// 編集用の設定を読む [LS-01]。
    public func settingsDraft(libraryID: LibraryID) async throws -> LibrarySettingsDraft? {
        guard let repository = libraryRepository else { throw ServiceError.notReady }
        return try await repository.settingsDraft(libraryID: libraryID)
    }

    /// 設定を保存する [LS-01][LT-03]。
    ///
    /// **テンプレートは登録時に一度写されるだけの雛形**なので、以後の調整は
    /// すべてこの経路を通る。保存後に一覧を読み直すのは、表示名やタイプ名の
    /// 変更をフォルダツリーとメニューへ即座に反映するため。
    public func updateSettings(_ draft: LibrarySettingsDraft,
                               libraryID: LibraryID) async throws {
        guard let repository = libraryRepository else { throw ServiceError.notReady }
        try await repository.updateSettings(draft, libraryID: libraryID)
        Log.app.info("ライブラリ設定を保存: \(Log.redactable(draft.displayName))")
        await refreshLibraries()
    }

    // MARK: - ラベル [LF-01〜LF-14][PN-01〜PN-06]

    /// ラベルフィルタに並べるグループ [LF-01]。
    ///
    /// **ラベルが 0 件のグループを落とすのは呼び出し側の仕事** [LF-02][LA-09]
    /// ——`labelCount` はアーカイブ済みを数えないので、この値が 0 かどうかで
    /// 判定できる。ここで落としてしまうと、ラベルグループ編集ウインドウ
    /// （2-6）が空のグループを触れなくなる。
    public func labelGroups(libraryID: LibraryID) async throws -> [LabelGroupSummary] {
        guard let repository = labelRepository else { throw ServiceError.notReady }
        return try await repository.groups(libraryID: libraryID)
    }

    /// グループに属するラベル [LF-04]。既定でアーカイブ済みを含めない [LF-12][LA-02]。
    public func labels(groupID: LabelGroupID,
                       includeArchived: Bool = false) async throws -> [LabelSummary] {
        guard let repository = labelRepository else { throw ServiceError.notReady }
        return try await repository.labels(groupID: groupID, includeArchived: includeArchived)
    }

    /// ライブラリごとのアーカイブ済みラベル件数 [LA-01][15.3 節]。
    ///
    /// 保管庫の整理ウインドウが左ペインのグレーアウトに使う。**0 件の
    /// ライブラリはキーごと現れない**ので `?? 0` で読むこと。
    public func archivedLabelCounts() async throws -> [LibraryID: Int] {
        guard let repository = labelRepository else { throw ServiceError.notReady }
        return try await repository.archivedLabelCounts()
    }

    /// ピン留め [PN-04]。**ライブラリ単位の永続設定で全ウインドウ共有** [ST-23]。
    public func setLabelPinned(_ id: LabelID, _ pinned: Bool) async throws {
        guard let repository = labelRepository else { throw ServiceError.notReady }
        try await repository.setPinned(id, pinned)
    }

    /// グループの並べ替え [LF-03][LG-07]。こちらも全ウインドウ共有 [ST-23]。
    public func setLabelGroupOrder(_ orderedIDs: [LabelGroupID]) async throws {
        guard let repository = labelRepository else { throw ServiceError.notReady }
        try await repository.setGroupOrder(orderedIDs)
    }

    // MARK: - ラベルの編集 [LE-07〜LE-11][LB-05〜LB-07][CO-06]
    //
    // **Undo は `LabelCommands` のコマンドが担う**ので、UI から直接ここを
    // 呼ばないこと（呼ぶと ⌘Z で戻せない操作ができる。`setRating` /
    // `applyLabelAssignments` と同じ約束）。

    public func renameLabel(_ id: LabelID, to name: String) async throws {
        guard let repository = labelRepository else { throw ServiceError.notReady }
        try await repository.rename(id, to: name)
    }

    public func setLabelArchived(_ ids: [LabelID], _ archived: Bool) async throws {
        guard let repository = labelRepository else { throw ServiceError.notReady }
        try await repository.setArchived(ids, archived)
    }

    public func setLabelColor(_ id: LabelID, hex: String?) async throws {
        guard let repository = labelRepository else { throw ServiceError.notReady }
        try await repository.setColor(id, hex: hex)
    }

    public func deleteLabels(_ ids: [LabelID]) async throws {
        guard let repository = labelRepository else { throw ServiceError.notReady }
        try await repository.deleteLabels(ids)
    }

    public func mergeLabel(_ source: LabelID, into target: LabelID) async throws {
        guard let repository = labelRepository else { throw ServiceError.notReady }
        try await repository.merge(source, into: target)
    }

    /// 削除・統合を戻すための写し [LabelSnapshot]。
    public func labelSnapshots(_ ids: [LabelID]) async throws -> [LabelSnapshot] {
        guard let repository = labelRepository else { throw ServiceError.notReady }
        return try await repository.snapshot(labelIDs: ids)
    }

    /// 写しの状態へちょうど戻す [LabelSnapshot]。
    public func restoreLabels(_ snapshots: [LabelSnapshot]) async throws {
        guard let repository = labelRepository else { throw ServiceError.notReady }
        try await repository.restore(snapshots)
    }

    // MARK: - 孤立ファイルの整理 [OR-01〜OR-05][ID-05][ID-07]
    //
    // **Undo は `OrphanCommands` のコマンドが担う**ので、UI から直接
    // `reattachOrphan` / `deleteFiles` を呼ばないこと（呼ぶと ⌘Z で戻せない
    // 操作ができる。`setRating` / `deleteLabels` と同じ約束）。

    public func orphanedFiles(libraryID: LibraryID) async throws -> [OrphanedFile] {
        guard let repository = fileRepository else { throw ServiceError.notReady }
        return try await repository.orphanedFiles(libraryID: libraryID)
    }

    public func orphanedFileCounts() async throws -> [LibraryID: Int] {
        guard let repository = fileRepository else { throw ServiceError.notReady }
        return try await repository.orphanedFileCounts()
    }

    /// 同一性で行を引く [ID-02]。再紐づけのコマンドが「消される側」を
    /// **消す前に**控えるために使う。
    public func findFile(identity: FileIdentity) async throws -> FileID? {
        guard let repository = fileRepository else { throw ServiceError.notReady }
        return try await repository.find(identity: identity)
    }

    @discardableResult
    public func reattachOrphan(_ id: FileID, to snapshot: FileSnapshot) async throws -> FileID? {
        guard let repository = fileRepository else { throw ServiceError.notReady }
        return try await repository.reattachOrphan(id, to: snapshot)
    }

    public func deleteFiles(_ ids: [FileID]) async throws {
        guard let repository = fileRepository else { throw ServiceError.notReady }
        try await repository.deleteFiles(ids)
    }

    /// 削除・再紐づけを戻すための写し [ManagedFileSnapshot]。
    public func fileSnapshots(ids: [FileID]) async throws -> [ManagedFileSnapshot] {
        guard let repository = fileRepository else { throw ServiceError.notReady }
        return try await repository.fileSnapshots(ids: ids)
    }

    /// 写しの状態へちょうど戻す [ManagedFileSnapshot]。
    public func restoreFiles(_ snapshots: [ManagedFileSnapshot]) async throws {
        guard let repository = fileRepository else { throw ServiceError.notReady }
        try await repository.restoreFiles(snapshots)
    }

    /// 候補として提示した行から「観測結果」を組み立てる [OR-02]。
    ///
    /// 候補は**走査が実体を見て作った行**なので、DB の値をそのまま使えば
    /// 実ファイルに触らずに済む。**`isBookFolder` も走査の判定をそのまま運ぶ**
    /// ——ここで判定し直すと [IF-01] の規則が 2 箇所になる。
    public func observation(ofCandidate id: FileID) async throws -> FileSnapshot? {
        guard let repository = fileRepository else { throw ServiceError.notReady }
        guard let row = try await repository.row(id: id),
              let identity = try await repository.identity(of: id) else { return nil }
        return FileSnapshot(identity: identity, libraryID: row.libraryID,
                            relativePath: row.relativePath, filename: row.filename,
                            fileSize: row.fileSize, createdAt: row.createdAt,
                            modifiedAt: row.modifiedAt, isBookFolder: row.isBookFolder)
    }

    /// 手動で選んだファイルから「観測結果」を組み立てる [OR-03]。
    ///
    /// - **ライブラリの根の外は断る**［ユーザー判断］。外を指すレコードを作ると
    ///   相対パスの前提が壊れ、次の走査で必ず孤立し直す。
    /// - **`isBookFolder` は孤立レコードの現在値を運ぶ**——結び直す先は「同じ
    ///   本」のはずなので現状維持が素直で、[IF-01] の規則をここへ写さずに済む。
    /// - `stat(2)` と属性の読み取りを伴うので `FileIO` の上で行う [NV6-02]。
    public func observation(at url: URL, in library: LibrarySummary,
                            keeping orphan: FileRow) async throws -> FileSnapshot {
        let root = URL(fileURLWithPath: library.resolvedPath)
        guard let relative = Self.relativePath(of: url, under: root) else {
            throw OrphanEditError.outsideLibrary(libraryName: library.displayName)
        }
        let observed: (FileIdentity, Int64, Date, Date)? = await FileIO.perform {
            guard let identity = LibraryFileIdentity.of(url, volumeUUID: library.volumeUUID),
                  let values = try? url.resourceValues(forKeys: [
                    .fileSizeKey, .creationDateKey, .contentModificationDateKey])
            else { return nil }
            return (identity, Int64(values.fileSize ?? 0),
                    values.creationDate ?? Date(),
                    values.contentModificationDate ?? Date())
        }
        guard let observed else { throw OrphanEditError.unreadable(path: url.path) }
        return FileSnapshot(identity: observed.0, libraryID: library.id,
                            relativePath: relative,
                            filename: url.lastPathComponent,
                            fileSize: observed.1, createdAt: observed.2,
                            modifiedAt: observed.3, isBookFolder: orphan.isBookFolder)
    }

    /// ライブラリの根からの相対パス。根の外なら `nil`。
    ///
    /// **成分の境界で判定する**——素の `hasPrefix` だと `…/Doc` が
    /// `…/Documents` を覆う（`VolumeAccessStore.hasGrant` で同じ罠を踏んでいる）。
    nonisolated static func relativePath(of url: URL, under root: URL) -> String? {
        let rootComponents = root.standardizedFileURL.pathComponents
        let components = url.standardizedFileURL.pathComponents
        guard components.count > rootComponents.count,
              Array(components.prefix(rootComponents.count)) == rootComponents else {
            return nil
        }
        return components.dropFirst(rootComponents.count).joined(separator: "/")
    }

    // MARK: - 一覧の問い合わせ [FI-01〜FI-05][VM-02]

    /// 条件に該当する件数 [LF-11]。
    public func fileCount(_ q: FileQuery) async throws -> Int {
        guard let repository = fileRepository else { throw ServiceError.notReady }
        return try await repository.count(q)
    }

    /// ライブラリ表示モードの一覧 [VM-10〜VM-12][FI-05]。
    ///
    /// **`matchingChildNames` とは向きが逆**——あちらは「実体の一覧を絞る」ため
    /// 名前だけを返すが、こちらは**DB の行そのものを描く**ので `FileRow` を返す。
    /// フォルダ表示モードでファイル操作がすべて可能でなければならない [VM-03]
    /// という制約はライブラリ表示モードには無く [VM-13]、逆に対象拡張子外の
    /// ファイルは出してはならない [VM-10] ので、実体ではなく DB が一覧の源になる。
    ///
    /// **必ずページングする** [FI-05][PF-10]——`q.limit`/`q.offset` をそのまま
    /// 渡すこと。`FilePage.totalCount` は絞り込み後の総数なので、呼び出し側は
    /// 「あと何件あるか」を数え直さずに済む。
    public func files(_ q: FileQuery) async throws -> FilePage {
        guard let repository = fileRepository else { throw ServiceError.notReady }
        return try await repository.query(q)
    }

    /// フォルダ表示モードで残す子の名前 [VM-02]。
    ///
    /// 返るのは「該当ファイルの名前」と「該当ファイルを配下に持つフォルダの名前」
    /// の**両方**。中央ペインはこの集合で実ファイルの一覧を絞る——DB 側の
    /// 一覧をそのまま描くのではなく、**実体の一覧を絞る**形にしてあるのは、
    /// フォルダ表示モードではファイル操作がすべて可能でなければならない
    /// [VM-03] ためで、DB に載っていないもの（対象拡張子以外）もフィルタが
    /// 全 OFF なら従来どおり見える必要がある [VM-01]。
    public func matchingChildNames(_ q: FileQuery) async throws -> Set<String> {
        guard let repository = fileRepository else { throw ServiceError.notReady }
        return try await repository.matchingChildNames(q)
    }

    /// 現在フォルダ直下のブックフォルダの名前 [IF-17]。
    public func bookFolderChildNames(libraryID: LibraryID,
                                     relativePath: String) async throws -> Set<String> {
        guard let repository = fileRepository else { throw ServiceError.notReady }
        return try await repository.bookFolderChildNames(libraryID: libraryID,
                                                         relativePath: relativePath)
    }

    /// ブックフォルダの「開く」を関連付けアプリに任せるか [IF-18][AS-06]。
    ///
    /// **設定 1 つのために `LibrarySettingsSnapshot` 全体を公開しない**——
    /// あれはフォーマットのコンパイル結果を抱えており、上位が触ってよい
    /// 形ではない（`LibrarySettingsDraft` と使い分ける理由と同じ）。
    public func opensBookFolderWithApp(libraryID: LibraryID) async throws -> Bool {
        guard let libraries = libraryRepository else { throw ServiceError.notReady }
        return try await libraries.settingsSnapshot(libraryID: libraryID)?
            .opensBookFolderWithApp ?? false
    }

    /// 候補の相対パスのうち条件に該当するものを返す [LF-14]。
    ///
    /// 中央ペインの**再帰検索の結果**へフィルタを効かせるための経路。
    /// `matchingChildNames` は直下の子へ畳むので、深い階層のファイルを
    /// 1 件ずつ見分けるにはこちらが要る。
    public func matchingRelativePaths(_ q: FileQuery,
                                      among candidates: [String]) async throws -> Set<String> {
        guard let repository = fileRepository else { throw ServiceError.notReady }
        return try await repository.matchingRelativePaths(q, among: candidates)
    }

    // MARK: - 巻数の判断 [EM-30〜EM-35]

    /// `ComicInfo.xml` の `Number` と `Volume` が食い違っていて、まだ判断して
    /// いないファイル [EM-31]。
    public func filesAwaitingVolumeDecision(libraryID: LibraryID) async throws
        -> [VolumeDecisionCandidate]
    {
        guard let repository = fileRepository else { throw ServiceError.notReady }
        return try await repository.filesAwaitingVolumeDecision(libraryID: libraryID)
    }

    /// 判断を確定する [EM-33]。**再スキャンを要さない**——衝突していた 2 つの
    /// 値はどちらもキャッシュに残してあるので、選ばれた側を書き写すだけで済む。
    public func resolveVolumeConflicts(_ ids: [FileID],
                                       using source: ComicInfoVolumeSource) async throws {
        guard let repository = fileRepository else { throw ServiceError.notReady }
        try await repository.resolveVolumeConflicts(ids, using: source)
        Log.app.info("巻数の判断を確定: \(ids.count) 件 → \(source.rawValue)")
    }

    // MARK: - 評価 [RA-01〜RA-08]

    /// 選択中のファイルに対応する DB 行を引く。無ければ `nil`
    /// （対象拡張子外・まだ走査されていない・ライブラリの外）。
    ///
    /// **`FileIdentity` で引く**——`relativePath` の照合にすると、綴り（NFD/NFC・
    /// 大小文字）が 1 文字でも食い違った瞬間に黙って空振りする経路を新しく
    /// 作ることになる（差分スキャンで実際に踏んだ形、10章 §10.6）。同一性は
    /// 走査が書いたものそのものなので、綴りの一致に依存しない。
    ///
    /// - Note: `stat(2)` を伴うため `FileIO` の上で求める [NV6-02]。
    public func fileRow(at url: URL, in library: LibrarySummary) async throws -> FileRow? {
        guard let repository = fileRepository else { throw ServiceError.notReady }
        let identity = await FileIO.perform {
            LibraryFileIdentity.of(url, volumeUUID: library.volumeUUID)
        }
        guard let identity, let id = try await repository.find(identity: identity) else {
            return nil
        }
        return try await repository.row(id: id)
    }

    /// 星を書き込む [RA-01][RA-02]。**Undo は `SetRatingCommand` が担う**ので、
    /// UI から直接ここを呼ばないこと（呼ぶと ⌘Z で戻せない操作ができる）。
    public func setRating(_ stars: Int, ids: [FileID]) async throws {
        guard let repository = fileRepository else { throw ServiceError.notReady }
        try await repository.setRating(stars, ids: ids)
    }

    /// 同じシリーズの全巻 [RA-04]。件数の事前表示 [RA-05] と一括適用の両方が
    /// これを使う——別々に数えると「N 冊に適用します」と実際の件数がずれる。
    public func filesInSameSeries(as id: FileID) async throws -> [FileRow] {
        guard let repository = fileRepository else { throw ServiceError.notReady }
        return try await repository.filesInSameSeries(as: id)
    }

    // MARK: - タイトル編集 [RP-10〜RP-12]

    /// タイトル・シリーズ名・巻数・著者を書き込む [RP-10][RP-12]。
    ///
    /// **Undo は `SetFileFieldsCommand` が担う**ので、UI から直接ここを呼ばない
    /// こと（`setRating`/`applyLabelAssignments` と同じ約束）。
    public func setFileFields(_ edit: FileFieldEdit, id: FileID) async throws {
        guard let repository = fileRepository else { throw ServiceError.notReady }
        try await repository.setFields(edit, id: id)
    }

    /// ファイル名（と、読み取り済みの埋め込みメタデータ）から導き直す [RP-12]。
    ///
    /// ## 走査とまったく同じ手順を通す
    /// `FolderLabelResolver.resolve` → `EmbeddedMetadataMerge.apply` の順は
    /// `ScanEngine.reconcile` の④と同じ。別の導出を書くと「再取得したのに
    /// 次の再スキャンで違う値になる」——`RP-12` が戻したいのは
    /// **「走査が付けるはずの値」**であって、それに似た何かではない。
    ///
    /// ## ファイルを開き直さない
    /// 埋め込みメタデータは DB のキャッシュから読む [EM-07]。実体を開くと
    /// ネットワーク越しでは数秒待たされるうえ、印が変わっていなければ走査も
    /// 開かない [SE3-25] ので、開いても同じ値しか得られない。
    ///
    /// - Returns: 書き込むべき値一式。`titleOrigin` は `.auto` に戻る。
    public func rederivedFields(for row: FileRow) async throws -> FileFieldEdit {
        guard let repository = fileRepository,
              let libraries = libraryRepository else { throw ServiceError.notReady }
        guard let settings = try await libraries.settingsSnapshot(libraryID: row.libraryID) else {
            throw ServiceError.notReady
        }
        let nameWithoutExtension = (row.filename as NSString).deletingPathExtension
        let resolved = FolderLabelResolver.resolve(
            relativePath: row.relativePath,
            nameWithoutExtension: nameWithoutExtension,
            settings: settings,
            purpose: .libraryScan,
            endsWithBookFolder: row.isBookFolder)
        let embedded = try await repository.embeddedMetadataCache(ids: [row.id])[row.id]?.metadata
        let merged = EmbeddedMetadataMerge.apply(embedded, to: resolved, settings: settings)
        return FileFieldEdit(title: merged.title, titleOrigin: .auto,
                             seriesName: merged.seriesName, volume: merged.volume,
                             authorName: merged.authorName)
    }

    // MARK: - カバー画像 [CV-02〜CV-08]

    /// カバーの割り当てを書き込む [CV-02][CV-07]。
    ///
    /// **Undo は `SetCoverCommand` が担う**ので、UI から直接ここを呼ばないこと。
    public func setCover(_ assignment: CoverAssignment, id: FileID) async throws {
        guard let repository = fileRepository else { throw ServiceError.notReady }
        try await repository.setCover(assignment, id: id)
    }

    /// 画像データを複製として保存し、DB に書く参照を返す [CV-06]。
    ///
    /// **書き込みは `FileIO` の上で行う** [NV6-01]。置き場所はローカルだが、
    /// 呼び出し元（右ペイン）はメインアクタである。
    public func storeUserCover(_ data: Data, library: LibrarySummary) async throws -> String {
        let store = userCoverStore
        let uuid = library.uuid
        return try await FileIO.perform { try store.store(data, libraryUUID: uuid) }
    }

    /// 複製の場所 [CV-06]。存在するかは呼び出し側が判定する。
    public func userCoverURL(ref: String, library: LibrarySummary) -> URL {
        userCoverStore.url(forRef: ref, libraryUUID: library.uuid)
    }

    /// 参照されていない複製を捨てる [CV-06]。**起動時に一度だけ呼ぶ。**
    ///
    /// 差し替えと「既定に戻す」はその場では複製を消さない——どちらも ⌘Z で
    /// 戻せるので、消すと**取り消した先に実体が無い**状態を作る。`CommandStack`
    /// はメモリのみで再起動をまたがないため、起動時に参照されていない複製は
    /// もう誰も戻せない（`SecureExtractor.cleanupResidualStaging()` と同じ形）。
    public func purgeUnreferencedUserCovers() async {
        guard let libraries = libraryRepository, let files = fileRepository else { return }
        var referenced: [UUID: Set<String>] = [:]
        do {
            for library in try await libraries.libraries() {
                referenced[library.uuid] = try await files.userCoverRefs(libraryID: library.id)
            }
        } catch {
            // 引けなかったときは**何も捨てない**——「参照が 0 件」と
            // 「参照を読めなかった」を取り違えると、生きている複製を全部消す。
            Log.db.error("ユーザー指定カバーの参照を読めませんでした: \(error.localizedDescription)")
            return
        }
        await userCoverStore.purgeUnreferenced(referenced)
    }

    // MARK: - ラベル設定 [RL-01〜RL-07]

    /// 選択中のファイルに対応する DB 行をまとめて引く [RP-02]。
    ///
    /// **`stat(2)` は 1 度の `FileIO.perform` にまとめる** [NV6-02]——1 件ずつ
    /// 逃がすと、応答しない共有の上で選択が 50 件あれば 50 回ぶん待つことに
    /// なる（`ThumbnailService` で同じ形を直している）。
    ///
    /// 返すのは**引けたものだけ**。DB に行が無いもの（対象拡張子外・まだ走査
    /// されていない）は落ちるので、呼び出し側が件数の差で気づける。
    public func fileRows(at urls: [URL], in library: LibrarySummary) async throws -> [URL: FileRow] {
        guard let repository = fileRepository else { throw ServiceError.notReady }
        guard !urls.isEmpty else { return [:] }
        let volumeUUID = library.volumeUUID
        let identities: [(URL, FileIdentity)] = await FileIO.perform {
            urls.compactMap { url in
                LibraryFileIdentity.of(url, volumeUUID: volumeUUID).map { (url, $0) }
            }
        }
        var result: [URL: FileRow] = [:]
        for (url, identity) in identities {
            guard let id = try await repository.find(identity: identity),
                  let row = try await repository.row(id: id) else { continue }
            result[url] = row
        }
        return result
    }

    /// 選択中のファイルに付いているラベルを読む [RL-01][RL-04][RL-06]。
    public func labelAssignments(fileIDs: [FileID]) async throws
        -> [FileID: [LabelID: LabelOrigin]]
    {
        guard let repository = labelRepository else { throw ServiceError.notReady }
        return try await repository.assignments(fileIDs: fileIDs)
    }

    /// ラベルを作る（既にあればそれを返す）[RL-02][LB-01][N-03]。
    public func ensureLabel(groupID: LabelGroupID, name: String) async throws -> LabelID {
        guard let repository = labelRepository else { throw ServiceError.notReady }
        return try await repository.ensureLabel(groupID: groupID, name: name)
    }

    /// ラベルの紐づけを書き換える [RL-01][RL-07]。
    ///
    /// **Undo は `AssignLabelCommand` が担う**ので、UI から直接ここを呼ばない
    /// こと（呼ぶと ⌘Z で戻せない操作ができる。`setRating` と同じ約束）。
    public func applyLabelAssignments(labelID: LabelID,
                                      _ changes: [LabelAssignmentChange]) async throws {
        guard let repository = labelRepository else { throw ServiceError.notReady }
        try await repository.applyAssignments(labelID: labelID, changes)
    }

    // MARK: - バックアップ [IE-01〜IE-14][BK-05]

    /// DB を JSON へ写す [IE-01][IE-02]。
    ///
    /// 何を出し、何を出さないかは `BackupDocument`（`QooKit`）の型コメントが正。
    public func exportBackup(scope: BackupScope = .everything) async throws -> BackupDocument {
        guard let repository = backupRepository else { throw ServiceError.notReady }
        return try await repository.export(scope: scope, appVersion: Self.appVersion())
    }

    /// 取り込んだら何が起きるかを数える。**DB は変えない** [IE-11]。
    public func planImport(_ document: BackupDocument) async throws -> ImportPlan {
        guard let repository = backupRepository else { throw ServiceError.notReady }
        return try await repository.plan(document)
    }

    /// 取り込む [JS-08]。承認を得てから呼ぶこと——`planImport` の結果を
    /// 見せずに実行してはならない [IE-11]。
    @discardableResult
    public func importBackup(_ document: BackupDocument) async throws -> ImportPlan {
        guard let repository = backupRepository else { throw ServiceError.notReady }
        let plan = try await repository.import(document)
        Log.app.info("""
            バックアップを取り込んだ: ライブラリ \(plan.libraries.count) 件 \
            / ファイル更新 \(plan.filesUpdated) 件 / ラベル追加 \(plan.labelsAdded) 件 \
            / 取り込めないライブラリ \(plan.missingLibraries.count) 件
            """)
        await refreshLibraries()
        return plan
    }

    static func appVersion() -> String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    // MARK: - 削除 [RG-06]

    /// ライブラリを DB から消す [RG-06]。
    ///
    /// **`disable(registrationUUID:)` との違いは入口だけ**——あちらは
    /// フォルダツリーの登録行から、こちらは環境設定の一覧から呼ぶ。
    /// 消す範囲は同じ（`library` 行と、そこへ連鎖するファイル・ラベル）。
    ///
    /// 登録フォルダ側の状態（オフライン・ゴミ箱・消失 [1-17]）に依存しない。
    /// DB の行を消すだけでボリュームにも実ファイルにも触れないので、
    /// **縮退状態こそ片付けたい場面**で手段が消えてはならない
    /// ——実際に一度、無効化をオンライン条件で囲って「外付けを失うと
    /// 二度と片付けられない」欠陥を作った前例がある [LibraryMenuVisibility]。
    public func deleteLibrary(id: LibraryID, keepLabels: Bool = false) async throws {
        guard let repository = libraryRepository else { throw ServiceError.notReady }
        let summary = try await repository.library(id: id)
        try await repository.unregister(id: id, keepLabels: keepLabels)
        if let summary {
            await userCoverStore.removeAll(libraryUUID: summary.uuid)   // [CV-06]
        }
        Log.app.info("ライブラリを削除: \(Log.redactable(summary?.displayName ?? "?"))")
        await refreshLibraries()
        await sync?.resync()
    }

    // MARK: - スキャン

    /// 1 ライブラリを走査して DB を実体に合わせる [SY-01][FO-20]。
    ///
    /// **ファイルシステムに対しては読み取りしか行わない**（列挙と存在確認のみ）。
    /// 書き込み先は DB だけなので、途中で取り消しても利用者のファイルは変わらない。
    public func scan(
        libraryID: LibraryID,
        mode: ScanEngine.Mode? = nil,
        root: URL? = nil,
        onProgress: (@Sendable (Int, String) -> Void)? = nil
    ) async throws -> ScanSummary {
        guard let engine = makeScanEngineIfNeeded() else { throw ServiceError.notReady }
        let scanMode = mode ?? .full(libraryID: libraryID)
        // **起点は走査の「前」に控える** [SY-02]。走っている間に起きた変更は
        // 次回に再生されるほうが、取りこぼすより安い（スキャンは冪等 [FO-20]）。
        let eventID = FSEventsHistory.currentEventID()
        let summary = try await engine.scan(scanMode, root: root, onProgress: onProgress)
        // 手動の再スキャンと有効化直後の初回スキャンもここを通る。
        // **保存しないと、次の起動で毎回「起点が使えない」と判定されて
        // フルスキャンからやり直すことになる。**
        if !summary.cancelled, !summary.skipped {
            await saveCheckpoint(libraryID: libraryID, root: root,
                                 eventID: eventID, mode: scanMode)
        }
        await refreshLibraries()
        contentRevision &+= 1
        return summary
    }

    /// 走査の結果を「どこまで反映したか」として記録する [SY-02][SY-05][WA-10]。
    private func saveCheckpoint(libraryID: LibraryID, root: URL?,
                                eventID: UInt64, mode: ScanEngine.Mode) async {
        guard let repository = libraryRepository else { return }
        let resolvedRoot: URL?
        if let root {
            resolvedRoot = root
        } else {
            let summary = try? await repository.library(id: libraryID)
            resolvedRoot = summary.map { URL(fileURLWithPath: $0.resolvedPath) }
        }
        guard let url = resolvedRoot else { return }
        guard eventID != 0, eventID != FSEventsCheckpoint.sinceNowSentinel else { return }
        let deviceUUID = await FileIO.perform { FSEventsHistory.deviceUUID(for: url) }
        do {
            try await repository.setFSEventsCheckpoint(
                FSEventsCheckpoint(eventID: eventID, deviceUUID: deviceUUID),
                libraryID: libraryID)
            if case .full = mode {
                try await repository.setLastFullScanAt(Date(), libraryID: libraryID)
            }
        } catch {
            Log.watch.warning("差分の起点を保存できない: \(String(describing: error))")
        }
    }

    private func makeScanEngineIfNeeded() -> ScanEngine? {
        if let scanEngine { return scanEngine }
        guard let libraries = libraryRepository,
              let files = fileRepository,
              let labels = labelRepository else { return nil }
        let engine = ScanEngine(dependencies: .init(
            libraries: libraries, files: files, labels: labels))
        scanEngine = engine
        return engine
    }

    // MARK: - エラー

    public enum ServiceError: Error, Equatable {
        case notReady
        /// ボリューム識別子を取れない [NV3-01]。空文字で代用してはならない。
        case volumeIdentityUnavailable
    }
}

/// ストアを開けなかった理由 [MG-11][MG-12][RB-06]。
public enum StoreStartupFailure: Sendable, Equatable {
    /// アプリが知らない移行が適用済み＝ストアが新しすぎる [MG-12]。
    case schemaTooNew
    case migrationFailed(String)
    case openFailed(String)
    case storeLocationUnavailable
    case templatesUnavailable(String)

    init(_ error: QooDatabase.StoreError) {
        switch error {
        case .schemaTooNew: self = .schemaTooNew
        case .migrationFailed(let detail): self = .migrationFailed(detail)
        }
    }
}
