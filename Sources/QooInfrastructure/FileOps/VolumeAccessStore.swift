import Foundation
import QooKit

public struct GrantedVolumeAccess: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public var displayName: String
    public var bookmarkData: Data

    public init(id: UUID = UUID(), displayName: String, bookmarkData: Data) {
        self.id = id
        self.displayName = displayName
        self.bookmarkData = bookmarkData
    }
}

/// ボリューム／フォルダへのユーザー許可アクセスの永続化 [ユーザー要望、要件
/// 定義書には無い]。フルディスクアクセスは App Sandbox のカーネルレベルの
/// ファイル読み取り制限を回避しないことが実機検証で判明した（CLAUDE.md 1-4
/// 節「将来検討」の訂正参照）ため、代わりに `NSOpenPanel` によるユーザーの
/// 明示的な選択で Security-Scoped Bookmark を作り、フォルダツリーでの
/// ボリューム閲覧に使う。`RegisteredFolderStore` と同じ配置理由・同じ actor
/// パターン（JSON 永続化、`FileOperationService` を経由しない）だが、
/// ライブラリ／テンポラリの種別や入れ子禁止といったドメイン制約は無い、より
/// 単純な「許可したボリューム／フォルダの一覧」だけを扱う。
public actor VolumeAccessStore {
    public static let shared = VolumeAccessStore()

    private let storageURL: URL
    private let bookmarks: BookmarkResolving
    private var grants: [GrantedVolumeAccess] = []
    /// 解決済み URL ごとの有効なアクセス数。`Set<URL>` だと同じ URL に対する
    /// 複数の許可を1件として扱ってしまい、片方を取り消すともう片方の
    /// `startAccessingSecurityScopedResource` が `stop` で対応づけられないまま
    /// 残ってしまう [フェーズ1完了時のリソースリーク監査で追加]。
    private var activeAccessCounts: [URL: Int] = [:]
    /// 初回読み込みのメモ化 [NV6-05]。`RegisteredFolderStore.loadTask` と同じ
    /// 理由——解決の await 中の actor 再入で二重読み込み・空読みをしないため。
    private var loadTask: Task<Void, Never>?
    /// ブックマーク解決 1 回あたりの上限時間 [NV6-05]。テストでは短縮できる。
    private let resolutionDeadline: Duration

    public init(
        storageURL: URL? = nil,
        bookmarks: BookmarkResolving = SecurityScopedBookmarkResolver(),
        resolutionDeadline: Duration = .seconds(AppLimits.FileOperations.bookmarkResolutionTimeoutSeconds)
    ) {
        if let storageURL {
            self.storageURL = storageURL
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            self.storageURL = appSupport.appendingPathComponent("qooLibrary/volumeAccess.json")
        }
        self.bookmarks = bookmarks
        self.resolutionDeadline = resolutionDeadline
    }

    /// 起動時に一度だけ呼ぶ。`RegisteredFolderStore.loadAndActivateAll()` と
    /// 同じく、登録されている間はアプリ終了までスコープを保持し続ける。
    public func loadAndActivateAll() async {
        await ensureLoaded()
    }

    public func grantedAccess() async -> [GrantedVolumeAccess] {
        await ensureLoaded()
        return grants.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    /// 指定した場所が、既存の許可のいずれかに覆われているか
    /// [1-16 移動メニューの Finder 準拠、標準の場所をプロンプト無しで開くため]。
    ///
    /// - Parameter requiringExactMatch: `true` にすると **その場所そのもの**
    ///   への許可だけを数え、祖先への許可は覆っているとみなさない。
    ///   デスクトップ・書類のような TCC 保護フォルダ用
    ///   （`/` を許可してあってもサンドボックス層を通るだけで TCC は通らず、
    ///   毎回ダイアログが出る。実測は `qooLibrary.entitlements` のコメント参照）。
    ///
    /// **実際に読めるかどうかは試さない** [設計判断]。TCC 保護フォルダに
    /// 触ること自体がダイアログの引き金になり得るため、「触らずに分かる材料」
    /// ＝自分が持っている許可だけで判定する。判定が保守的に外れた場合の害は
    /// 「一度だけ余分にパネルが出る」ことに留まり、逆向きの誤り（本来出すべき
    /// パネルを出さない）よりはるかに軽い。
    public func hasGrant(covering url: URL, requiringExactMatch: Bool) async -> Bool {
        await ensureLoaded()
        let targetPath = url.resolvingSymlinksInPath().standardizedFileURL.path
        let snapshot = grants
        let resolutions = await bookmarks.resolveMany(
            snapshot.map { (id: $0.id, data: $0.bookmarkData) }, waitingAtMost: resolutionDeadline
        )
        for grant in snapshot {
            guard case .resolved(let grantURL, _)? = resolutions[grant.id] else { continue }
            let grantPath = grantURL.standardizedFileURL.path
            if grantPath == targetPath { return true }
            guard !requiringExactMatch else { continue }
            // 祖先判定は成分の境界で行う（`/Users/foo` が `/Users/foobar` を
            // 覆っていると誤らないため）。`/` は末尾スラッシュを持つので
            // そのまま前方一致でよい。
            let prefix = grantPath.hasSuffix("/") ? grantPath : grantPath + "/"
            if targetPath.hasPrefix(prefix) { return true }
        }
        return false
    }

    /// 解決済みの URL。ボリューム未接続等でオフラインの場合は `nil`。
    ///
    /// 解決は `FileIO` 経由・上限時間付き [NV6-05]。上限を超えた解決は
    /// 「応答なし」（＝ `nil`）として扱う。
    public func resolvedURL(for grant: GrantedVolumeAccess) async -> URL? {
        let resolution = await bookmarks.resolve(grant.bookmarkData, waitingAtMost: resolutionDeadline)
        guard case .resolved(let url, _) = resolution else { return nil }
        return url
    }

    @discardableResult
    public func grantAccess(to url: URL, displayName: String?) async throws -> GrantedVolumeAccess {
        await ensureLoaded()
        let requestedURL = url.resolvingSymlinksInPath()
        // 同じ場所への許可が既にあれば重複して追加しない
        // [フェーズ1完了時の監査で追加: 同じフォルダを2回許可すると、
        // 取り消し操作がどちらか一方の `stopAccessingSecurityScopedResource`
        // としか対応づかず、もう片方の許可を取り消しても実際には解放されない
        // というリークの温床になっていた]。パス文字列で比較する
        // （`RegisteredFolderStore.checkNotNested` と同じ理由 — ブックマーク
        // 解決後の `URL` は末尾スラッシュ等の表現差で素の `==` では一致しない
        // ことがある）。
        //
        // 解決の await 中の actor 再入により、同時に走る `grantAccess` 同士では
        // 「チェック後・追加前」に相手の追加が割り込む余地がある。許可は
        // 環境設定のパネル経由で 1 件ずつしか起きず、万一重複しても
        // `activeAccessCounts` が参照カウントで守っている（リークには戻らない）
        // ため、ここでは防がない [NV6-05 の async 化に伴う注記]。
        let requestedPath = requestedURL.standardizedFileURL.path
        let snapshot = grants
        let resolutions = await bookmarks.resolveMany(
            snapshot.map { (id: $0.id, data: $0.bookmarkData) }, waitingAtMost: resolutionDeadline
        )
        if let existing = snapshot.first(where: { grant in
            guard case .resolved(let grantURL, _)? = resolutions[grant.id] else { return false }
            return grantURL.standardizedFileURL.path == requestedPath
        }) {
            return existing
        }
        let bookmarkData = try bookmarks.makeBookmark(for: requestedURL)
        let grant = GrantedVolumeAccess(
            displayName: displayName ?? FileManager.default.displayName(atPath: requestedURL.path),
            bookmarkData: bookmarkData
        )
        grants.append(grant)
        await activateAccessIfPossible(grant)
        try save()
        return grant
    }

    public func revokeAccess(_ id: UUID) async throws {
        await ensureLoaded()
        guard let grant = grants.first(where: { $0.id == id }) else { return }
        if let url = await resolvedURL(for: grant), let count = activeAccessCounts[url] {
            if count <= 1 {
                url.stopAccessingSecurityScopedResource()
                activeAccessCounts.removeValue(forKey: url)
            } else {
                activeAccessCounts[url] = count - 1
            }
        }
        grants.removeAll { $0.id == id }
        try save()
    }

    private func ensureLoaded() async {
        if loadTask == nil {
            loadTask = Task { await performInitialLoad() }
        }
        await loadTask?.value
    }

    private func performInitialLoad() async {
        load()
        // 全許可を**並行に**解決する [NV6-05]（`RegisteredFolderStore` と同じ
        // 理由——逐次だとサーバ不在時の起動待ちが「件数 × 上限時間」になる）。
        let resolutions = await bookmarks.resolveMany(
            grants.map { (id: $0.id, data: $0.bookmarkData) }, waitingAtMost: resolutionDeadline
        )
        for grant in grants {
            activateAccess(grant, resolution: resolutions[grant.id] ?? .offline(reason: .invalidBookmark))
        }
        Log.sandbox.info("ボリューム許可を読み込みました: \(grants.count) 件 / アクセス開始 \(activeAccessCounts.count) 件")
    }

    private func activateAccessIfPossible(_ grant: GrantedVolumeAccess) async {
        let resolution = await bookmarks.resolve(grant.bookmarkData, waitingAtMost: resolutionDeadline)
        activateAccess(grant, resolution: resolution)
    }

    private func activateAccess(_ grant: GrantedVolumeAccess, resolution: BookmarkResolution) {
        guard case .resolved(let url, _) = resolution else {
            // 「アクセス権がありません」表示の原因がここに出る。許可したはずの
            // ボリュームが未接続・削除されているのか、ブックマークが無効に
            // なったのかを切り分けられるようにしておく [SB-05]。
            // 解決できないので絶対パスが無い。表示名は書き出し時に匿名化
            // されるよう印を付ける [LG2-06]。
            Log.sandbox.warning("ボリューム許可のブックマークを解決できません: \(Log.redactable(grant.displayName))")
            return
        }
        if url.startAccessingSecurityScopedResource() {
            activeAccessCounts[url, default: 0] += 1
            Log.sandbox.debug("ボリューム許可のアクセスを開始: \(Log.path(url))")
        } else {
            Log.sandbox.warning("ボリューム許可のセキュリティスコープを開始できません: \(Log.path(url))")
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: storageURL) else { return }
        guard let decoded = try? JSONDecoder().decode([GrantedVolumeAccess].self, from: data) else {
            // デコードに失敗したまま `grants = []` として処理を続けると、次に
            // 何か1件でも許可・取り消しをした瞬間の `save()` が壊れた内容ごと
            // 上書きしてしまい、以前の許可がすべて復元不能になる
            // [フェーズ1完了時の監査で追加]。元ファイルには触れず隣へ退避して
            // から空の状態で続行することで、少なくとも手動での調査・復旧の
            // 余地を残す。
            let corruptBackup = storageURL.deletingLastPathComponent()
                .appendingPathComponent("\(storageURL.lastPathComponent).corrupt-\(UUID().uuidString)")
            try? FileManager.default.moveItem(at: storageURL, to: corruptBackup)
            Log.sandbox.error(
                "ボリューム許可の永続化ファイルを読めません。\(corruptBackup.path) へ退避し、許可なしで続行します"
            )
            return
        }
        grants = decoded
    }

    private func save() throws {
        try FileManager.default.createDirectory(
            at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(grants)
        try data.write(to: storageURL, options: .atomic)
    }
}
