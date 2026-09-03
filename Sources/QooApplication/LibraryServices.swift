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


    /// ライブラリ機能が使えるか。UI はこれを見てメニュー項目の有効／無効を決める。
    public var isReady: Bool { database != nil }

    /// 自動走査が終わったときに UI へ知らせる受け口 [ID-05]。
    ///
    /// **「自動走査はダイアログを出さない」という方針は、判断が要るものに
    /// 限って緩める**［ユーザー判断、2026-08］。孤立や未解決の件数は
    /// 「知らせるだけ」なので黙っていてよい——利用者が自分で消したファイルに
    /// 「N 件が見つからなくなりました」と出すのは雑音である。だが**差し替えの
    /// 確認 [ID-05] は放置すると記録が失われたままになる**ので、性質が違う。
    ///
    /// **FSEvents の自動追随が先に拾ってしまうため、これが無いと通知が実質
    /// 出ない**——実機検証で、差し替えたあと手動で再スキャンしても通知が
    /// 出ないことを確認した（既に新しい行があるので `.nameOnly` の経路を
    /// 通らない）。恒常的な到達手段がライブラリ設定だけになっていた。
    @ObservationIgnored
    public var onAutomaticScanFinished: ((LibraryID, ScanSummary) -> Void)?

    // MARK: - 内部

    private var database: QooDatabase?
    private var volumeSets: VolumeSetDefinition?
    private var libraryRepository: (any LibraryRepository)?
    private var fileRepository: (any ManagedFileRepository)?
    private var labelRepository: (any LabelRepository)?
    private var backupRepository: (any BackupRepository)?
    private var shelfRepository: (any ShelfRepository)?
    /// 通知履歴 [NT-01][NW-01〜08]。**ライブラリと無関係な通知も入る**
    /// ——`notificationRecord` は `library` への外部キーを持たず、対象は
    /// `targetJSON` に非正規化して持つ [07章 §7.3]。
    public private(set) var notificationHistory: (any NotificationHistoryStore)?
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
            shelfRepository = SQLiteShelfRepository(database: opened)
            notificationHistory = SQLiteNotificationHistoryStore(database: opened)
            Log.app.info("ライブラリストアを開いた: \(Log.path(storeURL))")
            makeSyncCoordinator()
            await attachNotificationHistory()
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

    /// 通知履歴を `NotificationRouter` へ繋ぐ [NT-01]。
    ///
    /// **`swift test` 中は繋がない**——`NotificationRouter.shared` はアプリ全体で
    /// 1 つなので、テストが作った一時ストアを共有ルーターへ繋ぐと、以後の
    /// すべてのテストの通知がそこへ落ちて互いに干渉する（`makeSyncCoordinator`
    /// と同じ理由）。ストア自体は `notificationHistory` から取れるので、
    /// 統合の検証は独立したルーターを組み立てて行う。
    private func attachNotificationHistory() async {
        guard let notificationHistory, !RuntimeEnvironment.isRunningTests else { return }
        await NotificationRouter.shared.attachHistoryStore(
            notificationHistory,
            retentionDays: NotificationRouter.configuredRetentionDays(),
            maxCount: NotificationRouter.configuredMaxCount())
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
        sync?.onScanFinished = { [weak self] id, summary in
            Task { @MainActor in
                if summary.added > 0 || summary.updated > 0 || summary.orphaned > 0 {
                    LibraryGeneration.shared.bump()
                }
                self?.onAutomaticScanFinished?(id, summary)
            }
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

    /// フォルダ名＝表示名 [RG3-31] を DB 側にも揃える。
    ///
    /// ストア（`RegisteredFolderStore`）は解決のたびに実フォルダ名へ追随して
    /// いる（`rememberResolvedPaths`）が、DB の `library.displayName` は
    /// 別に持っている——設定ウインドウの一覧・通知・`@libraryname` の照合が
    /// こちらを見るので、ずれたままだと改名が画面に出ない。**ストアの
    /// 同期済みの名前だけを見る**ので、ここではブックマークを解決しない
    /// （解決の費用と副作用はストア側に閉じる）。
    public func syncLibraryDisplayNames() async {
        guard let repository = libraryRepository else { return }
        let folders = await RegisteredFolderStore.shared.folders(kind: .library)
        var changed = false
        for folder in folders {
            guard let summary = libraries.first(where: { $0.uuid == folder.id }),
                  summary.displayName != folder.displayName else { continue }
            do {
                try await repository.setDisplayName(folder.displayName,
                                                    libraryID: summary.id)
                changed = true
                Log.app.info("ライブラリの表示名をフォルダ名へ追随: \(Log.redactable(folder.displayName)) [RG3-31]")
            } catch {
                Log.app.error("表示名を同期できない: \(String(describing: error))")
            }
        }
        if changed { await refreshLibraries() }
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
            otherLibraryTypeNames: libraries.map(\.libraryTypeName))
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
        // 設定の保存も DB を書く経路 [§19.13 #2]。`settingsRevision`（DB 列）は
        // パーサのキャッシュ鍵 [VT-02] で画面の合図ではないので、別に進める。
        LibraryGeneration.shared.bump()
    }

    // MARK: - ラベル [LF-01〜LF-14][PN-01〜PN-06]

    /// ラベルフィルタに並べるグループ [LF-01]。
    ///
    /// **見えるラベルが 0 件のグループを落とすのは呼び出し側の仕事**
    /// [LF-02][LA3-05]——`labelCount` は非表示のものも数える（フィールド編集
    /// ウインドウが空のグループを触れなくなるため）ので、フィルタは読んだ
    /// ラベルの `isVisible` から自分で判断する。
    public func labelGroups(libraryID: LibraryID) async throws -> [LabelGroupSummary] {
        guard let repository = labelRepository else { throw ServiceError.notReady }
        return try await repository.groups(libraryID: libraryID)
    }

    /// グループに属するラベル [LF-04]。**非表示のものも含めて返す** [LA3-03]
    /// ——出し分けは呼び出し側の都合で、`LabelSummary.isVisible` が判定を持つ。
    public func labels(groupID: LabelGroupID) async throws -> [LabelSummary] {
        guard let repository = labelRepository else { throw ServiceError.notReady }
        return try await repository.labels(groupID: groupID)
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

    // MARK: - シェルフ [SH-01〜SH-12]
    //
    // **Undo は `ShelfCommands` のコマンドが担う**ので、UI から直接ここを
    // 呼ばないこと（並び順 [SH-10] だけは例外で、フィールドの並び順
    // [LF-03] と同じくコマンドにしない——`setLabelGroupOrder` と同じ扱い）。

    public func shelves(libraryID: LibraryID) async throws -> [ShelfSummary] {
        guard let repository = shelfRepository else { throw ServiceError.notReady }
        return try await repository.shelves(libraryID: libraryID)
    }

    public func createShelf(libraryID: LibraryID, name: String,
                            condition: ShelfCondition) async throws -> ShelfID {
        guard let repository = shelfRepository else { throw ServiceError.notReady }
        return try await repository.create(libraryID: libraryID, name: name, condition: condition)
    }

    public func updateShelfCondition(_ id: ShelfID, _ condition: ShelfCondition) async throws {
        guard let repository = shelfRepository else { throw ServiceError.notReady }
        try await repository.updateCondition(id, condition)
    }

    public func renameShelf(_ id: ShelfID, to name: String) async throws {
        guard let repository = shelfRepository else { throw ServiceError.notReady }
        try await repository.rename(id, to: name)
    }

    public func deleteShelves(_ ids: [ShelfID]) async throws {
        guard let repository = shelfRepository else { throw ServiceError.notReady }
        try await repository.delete(ids)
    }

    /// 並べ替え [SH-10]。**全ウインドウ共有** [ST-23]。
    public func setShelfOrder(_ orderedIDs: [ShelfID]) async throws {
        guard let repository = shelfRepository else { throw ServiceError.notReady }
        try await repository.setOrder(orderedIDs)
    }

    public func shelfSnapshots(_ ids: [ShelfID]) async throws -> [ShelfSummary] {
        guard let repository = shelfRepository else { throw ServiceError.notReady }
        return try await repository.snapshot(ids: ids)
    }

    /// 写しを**同じ行 ID で**戻す [SH-11]。
    public func restoreShelves(_ shelves: [ShelfSummary]) async throws {
        guard let repository = shelfRepository else { throw ServiceError.notReady }
        try await repository.restore(shelves)
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

    /// 手動での非表示の切り替え [LA3-02]。
    public func setLabelHidden(_ ids: [LabelID], _ hidden: Bool) async throws {
        guard let repository = labelRepository else { throw ServiceError.notReady }
        try await repository.setHidden(ids, hidden)
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

    // MARK: - 孤立ファイルの整理 [OR-01][OR-04][ID-07]
    //
    // **Undo は `OrphanCommands` のコマンドが担う**ので、UI から直接
    // `deleteFiles` を呼ばないこと（呼ぶと ⌘Z で戻せない操作ができる。
    // `setRating` / `deleteLabels` と同じ約束）。

    public func orphanedFiles(libraryID: LibraryID) async throws -> [OrphanedFile] {
        guard let repository = fileRepository else { throw ServiceError.notReady }
        return try await repository.orphanedFiles(libraryID: libraryID)
    }

    // MARK: - 未解決ファイル [AL-30〜AL-34][UR-01〜UR-06]
    //
    // **Undo は `SetUnresolvedIgnoredCommand` が担う**ので、UI から直接
    // `setUnresolvedIgnored` を呼ばないこと（呼ぶと ⌘Z で戻せない操作が
    // できる。`setRating` / `deleteLabels` と同じ約束）。

    public func unresolvedFiles(libraryID: LibraryID, includeIgnored: Bool) async throws
        -> [UnresolvedFile]
    {
        guard let repository = fileRepository else { throw ServiceError.notReady }
        return try await repository.unresolvedFiles(libraryID: libraryID,
                                                    includeIgnored: includeIgnored)
    }

    /// 1 件だけの未解決の記録 [UR3-04]。右ペインが選択のたびに引く。
    public func unresolvedHint(id: FileID) async throws -> UnresolvedHint? {
        guard let repository = fileRepository else { throw ServiceError.notReady }
        return try await repository.unresolvedHint(id: id)
    }

    public func unresolvedFileCounts() async throws -> [LibraryID: UnresolvedCounts] {
        guard let repository = fileRepository else { throw ServiceError.notReady }
        return try await repository.unresolvedFileCounts()
    }

    public func setUnresolvedIgnored(_ ids: [FileID], _ ignored: Bool) async throws {
        guard let repository = fileRepository else { throw ServiceError.notReady }
        try await repository.setUnresolvedIgnored(ids, ignored)
    }

    /// 未解決ファイルを現在の設定でパースし直す [AL-34][UR-04]。
    ///
    /// **走査そのものではないが世代番号を進める**——ラベルが増えるので、
    /// ラベルフィルタと中央ペインが読み直す必要がある。
    /// 起点（`lastFSEventID`）は触らない：実ファイルを 1 つも見ていないので、
    /// 「どこまで実体を反映したか」は変わっていない。
    @discardableResult
    public func rematchUnresolved(libraryID: LibraryID) async throws -> RematchOutcome {
        guard let engine = makeScanEngineIfNeeded() else { throw ServiceError.notReady }
        let outcome = try await engine.rematchUnresolved(libraryID: libraryID)
        if outcome.resolved > 0 { LibraryGeneration.shared.bump() }
        return outcome
    }

    public func orphanedFileCounts() async throws -> [LibraryID: Int] {
        guard let repository = fileRepository else { throw ServiceError.notReady }
        return try await repository.orphanedFileCounts()
    }

    // MARK: - シリーズの提案 [SS-01〜SS-08、19章 §19.5]
    //
    // **Undo は `ApplySeriesSuggestionCommand` /
    // `SetSeriesSuggestionIgnoredCommand` が担う**ので、UI から直接
    // `updateSeriesSuggestionIgnored` を呼ばないこと（`setRating` と同じ約束）。

    /// 1 ライブラリぶんの提案を作る [SS-01〜SS-08]。
    ///
    /// **候補の集め方（DB）と判定（純粋関数）を分けてある。** ここは前者と
    /// 後者を繋ぐだけで、規則そのものは `SeriesSuggestionDetector` にある
    /// ——合成名のゴールデンで固定できる形を保つため。
    ///
    /// 費用は候補の件数に比例する。**プリセットはどれもファイル名フォーマット
    /// で `@series` を取らない**ので、候補は事実上ライブラリ全件になる
    /// ［実測: 実コーパスを 5 万件へ増やして 403 ms、うち畳み込みが 70 ms］。
    /// **左ペインの件数を全ライブラリぶん出さない**のはこのため（§15.15）。
    public func seriesSuggestions(libraryID: LibraryID) async throws
        -> SeriesSuggestionReport
    {
        guard let repository = fileRepository else { throw ServiceError.notReady }
        let candidates = try await repository.seriesSuggestionCandidates(
            libraryID: libraryID, circleFieldID: try await circleFieldID(libraryID: libraryID))
        let ignored = Set(candidates.filter(\.isIgnored).map(\.id))
        // メインアクタを塞がない——数百 ms かかりうる純粋な計算である。
        let suggestions = await Task.detached(priority: .userInitiated) {
            SeriesSuggestionDetector.detect(candidates)
        }.value
        return SeriesSuggestionReport(suggestions: suggestions, ignoredFileIDs: ignored)
    }

    /// `@circle` を束縛しているフィールド [SS-02][RWI-02]。
    ///
    /// サークルは `authorName` のような専用列を持たずラベルとして入るので、
    /// 「どのフィールドがサークルか」は設定からしか分からない。束縛が無ければ
    /// `nil`（著者名だけで揃える）。
    public func circleFieldID(libraryID: LibraryID) async throws -> LabelGroupID? {
        guard let repository = libraryRepository else { throw ServiceError.notReady }
        guard let snapshot = try await repository.settingsSnapshot(libraryID: libraryID),
              let index = snapshot.semanticBindings[.circle]
        else { return nil }
        return try await labelGroups(libraryID: libraryID).first { $0.index == index }?.id
    }

    public func updateSeriesSuggestionIgnored(set marks: [FileID: String],
                                              clear ids: [FileID]) async throws {
        guard let repository = fileRepository else { throw ServiceError.notReady }
        try await repository.updateSeriesSuggestionIgnored(set: marks, clear: ids)
    }

    public func seriesSuggestionIgnoredTitles(ids: [FileID]) async throws -> [FileID: String] {
        guard let repository = fileRepository else { throw ServiceError.notReady }
        return try await repository.seriesSuggestionIgnoredTitles(ids: ids)
    }

    // MARK: - ファイル保管庫 [FA-01〜FA-17][FAW-01〜FAW-05]

    public func archivedFiles(libraryID: LibraryID) async throws -> [ArchivedFile] {
        guard let repository = fileRepository else { throw ServiceError.notReady }
        return try await repository.archivedFiles(libraryID: libraryID)
    }

    // MARK: - 重複ファイル [DU-01〜DU-29]

    /// 同じ組の全メンバーを代表順で [DU-20]。
    public func duplicateGroupMembers(containing id: FileID,
                                      mode: DuplicateGrouping) async throws -> [FileRow] {
        guard let repository = fileRepository else { throw ServiceError.notReady }
        return try await repository.duplicateGroupMembers(containing: id, mode: mode)
    }

    /// 容器を開いてページ数と解像度を数え、DB へ控える [DU-21][DU-22][MD-02]。
    ///
    /// **数えられなければ何も書かない**——`nil` のままにしておけば、次に開いた
    /// ときに数え直す機会が残る。0 を書くと「数えた結果 0 件」と区別が付かない。
    @discardableResult
    public func measureArchiveMetadata(for url: URL, id: FileID) async throws
        -> ArchiveMetadata?
    {
        guard let repository = fileRepository else { throw ServiceError.notReady }
        guard let metadata = await ArchiveMetadataService.shared.metadata(for: url) else {
            return nil
        }
        try await repository.cacheArchiveMetadata(
            pageCount: metadata.imageCount,
            subfolderCount: metadata.subfolderCount,
            firstImageWidth: metadata.firstImageSize.map { Int($0.width) },
            firstImageHeight: metadata.firstImageSize.map { Int($0.height) },
            for: id)
        return metadata
    }

    public func archivedFileCounts() async throws -> [LibraryID: Int] {
        guard let repository = fileRepository else { throw ServiceError.notReady }
        return try await repository.archivedFileCounts()
    }

    public func filesUnder(libraryID: LibraryID, folderRelativePath: String) async throws
        -> [FileID: String]
    {
        guard let repository = fileRepository else { throw ServiceError.notReady }
        return try await repository.filesUnder(libraryID: libraryID,
                                               folderRelativePath: folderRelativePath)
    }

    /// 保管庫の出入りを DB へ記録する [FA-04][FA-05]。**実ファイルを動かした
    /// あとに呼ぶこと**（`FileVault.relocate` が返した着地点を渡す）。
    ///
    /// **世代番号を進める** [§19.13 #2]。保管庫の出入りは蔵書の一覧そのものが
    /// 変わる [FA-05][FA-12]。
    ///
    /// なお `VaultCommands` 経由なら `CommandStack` も進めるので二重になるが、
    /// **合図は「変わったこと」しか意味しない**ので害は無い——数える値では
    /// ないので、進みすぎることはあっても止まることが無いほうが大事。
    public func setFileArchived(_ moves: [VaultMove], archived: Bool) async throws {
        guard let repository = fileRepository else { throw ServiceError.notReady }
        try await repository.setArchived(moves, archived: archived)
        LibraryGeneration.shared.bump()
    }

    /// 同一性で行を引く [ID-02]。再紐づけのコマンドが「消される側」を
    /// **消す前に**控えるために使う。
    public func findFile(identity: FileIdentity) async throws -> FileID? {
        guard let repository = fileRepository else { throw ServiceError.notReady }
        return try await repository.find(identity: identity)
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

    /// 現在フォルダ直下の蔵書の「ファイル名 → 行 ID」[RL3-01]。
    ///
    /// 中央ペインのラベルメニューがフォルダ表示モードで使う（`LabelMenuModel`）。
    public func fileIDsByChildName(libraryID: LibraryID,
                                   relativePath: String) async throws -> [String: FileID] {
        guard let repository = fileRepository else { throw ServiceError.notReady }
        return try await repository.fileIDsByChildName(libraryID: libraryID,
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
    public func setFileFields(_ edit: FileFieldEdit, id: FileID,
                              protectedScopes: Set<ProtectionScope>) async throws {
        guard let repository = fileRepository else { throw ServiceError.notReady }
        try await repository.setFields(edit, id: id, protectedScopes: protectedScopes)
    }

    // MARK: - メタデータの保護 [PR-01〜PR-09]

    /// 保護スコープを読む [PR-05]。
    public func protectedScopes(ids: [FileID]) async throws
        -> [FileID: Set<ProtectionScope>]
    {
        guard let repository = fileRepository else { throw ServiceError.notReady }
        return try await repository.protectedScopes(ids: ids)
    }

    /// 保護スコープを書く [PR-05]。**Undo は `SetProtectionCommand` が担う**ので、
    /// UI から直接ここを呼ばないこと（`setRating` と同じ約束）。
    public func setProtectedScopes(_ scopes: [FileID: Set<ProtectionScope>]) async throws {
        guard let repository = fileRepository else { throw ServiceError.notReady }
        try await repository.setProtectedScopes(scopes)
    }

    /// 保護されていないスコープを自動値へ導き直す [PR-04]。
    ///
    /// **保護を外した直後に呼ぶ。** 解除しても次の走査まで手動値が残っていると、
    /// 「解除したのに何も起きない」ように見える。
    public func reapplyAutomaticMetadata(ids: [FileID], libraryID: LibraryID) async throws {
        guard let engine = makeScanEngineIfNeeded() else { throw ServiceError.notReady }
        try await engine.reapplyMetadata(fileIDs: ids, libraryID: libraryID)
    }

    /// 行 ID から直に引く [PR-04]。保護を外す前に「戻すための値」を控えるのに要る。
    public func fileRow(id: FileID) async throws -> FileRow? {
        guard let repository = fileRepository else { throw ServiceError.notReady }
        return try await repository.row(id: id)
    }

    /// 1 ファイルに付いているラベル [PR-04 の Undo]。
    public func fileLabelIDs(fileID: FileID) async throws -> [LabelID] {
        guard let repository = labelRepository else { throw ServiceError.notReady }
        return try await repository.labelIDs(fileID: fileID)
    }

    /// 1 ファイルの紐づけをちょうど揃える（保護は見ない）[PR-04 の Undo]。
    public func setFileLabels(fileID: FileID, labelIDs: Set<LabelID>) async throws {
        guard let repository = labelRepository else { throw ServiceError.notReady }
        try await repository.setLabels(fileID: fileID, labelIDs: labelIDs)
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
    /// - Returns: 書き込むべき値一式（走査が付けるはずの値）。
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
        return FileFieldEdit(title: merged.title, seriesName: merged.seriesName,
                             volume: merged.volume, authorName: merged.authorName)
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
        -> [FileID: Set<LabelID>]
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
    public func applyLabelAssignments(
        labelID: LabelID, _ changes: [LabelAssignmentChange],
        protectedScopes: [FileID: Set<ProtectionScope>]
    ) async throws {
        guard let repository = labelRepository else { throw ServiceError.notReady }
        try await repository.applyAssignments(labelID: labelID, changes,
                                              protectedScopes: protectedScopes)
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
        onProgress: (@Sendable (ScanProgress) -> Void)? = nil
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
        LibraryGeneration.shared.bump()
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
