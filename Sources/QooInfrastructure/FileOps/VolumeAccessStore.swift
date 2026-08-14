import Foundation

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
    private var didLoad = false

    public init(storageURL: URL? = nil, bookmarks: BookmarkResolving = SecurityScopedBookmarkResolver()) {
        if let storageURL {
            self.storageURL = storageURL
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            self.storageURL = appSupport.appendingPathComponent("qooLibrary/volumeAccess.json")
        }
        self.bookmarks = bookmarks
    }

    /// 起動時に一度だけ呼ぶ。`RegisteredFolderStore.loadAndActivateAll()` と
    /// 同じく、登録されている間はアプリ終了までスコープを保持し続ける。
    public func loadAndActivateAll() {
        ensureLoaded()
    }

    public func grantedAccess() -> [GrantedVolumeAccess] {
        ensureLoaded()
        return grants.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    /// 解決済みの URL。ボリューム未接続等でオフラインの場合は `nil`。
    public func resolvedURL(for grant: GrantedVolumeAccess) -> URL? {
        guard case .resolved(let url, _) = bookmarks.resolve(grant.bookmarkData) else { return nil }
        return url
    }

    @discardableResult
    public func grantAccess(to url: URL, displayName: String?) throws -> GrantedVolumeAccess {
        ensureLoaded()
        let requestedURL = url.resolvingSymlinksInPath()
        // 同じ場所への許可が既にあれば重複して追加しない
        // [フェーズ1完了時の監査で追加: 同じフォルダを2回許可すると、
        // 取り消し操作がどちらか一方の `stopAccessingSecurityScopedResource`
        // としか対応づかず、もう片方の許可を取り消しても実際には解放されない
        // というリークの温床になっていた]。パス文字列で比較する
        // （`RegisteredFolderStore.checkNotNested` と同じ理由 — ブックマーク
        // 解決後の `URL` は末尾スラッシュ等の表現差で素の `==` では一致しない
        // ことがある）。
        let requestedPath = requestedURL.standardizedFileURL.path
        if let existing = grants.first(where: { resolvedURL(for: $0)?.standardizedFileURL.path == requestedPath }) {
            return existing
        }
        let bookmarkData = try bookmarks.makeBookmark(for: requestedURL)
        let grant = GrantedVolumeAccess(
            displayName: displayName ?? FileManager.default.displayName(atPath: requestedURL.path),
            bookmarkData: bookmarkData
        )
        grants.append(grant)
        activateAccessIfPossible(grant)
        try save()
        return grant
    }

    public func revokeAccess(_ id: UUID) throws {
        ensureLoaded()
        guard let grant = grants.first(where: { $0.id == id }) else { return }
        if let url = resolvedURL(for: grant), let count = activeAccessCounts[url] {
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

    private func ensureLoaded() {
        guard !didLoad else { return }
        didLoad = true
        load()
        for grant in grants {
            activateAccessIfPossible(grant)
        }
        Log.sandbox.info("ボリューム許可を読み込みました: \(grants.count) 件 / アクセス開始 \(activeAccessCounts.count) 件")
    }

    private func activateAccessIfPossible(_ grant: GrantedVolumeAccess) {
        guard let url = resolvedURL(for: grant) else {
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
