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
    private var activeAccessURLs: Set<URL> = []
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
        let resolvedURL = url.resolvingSymlinksInPath()
        let bookmarkData = try bookmarks.makeBookmark(for: resolvedURL)
        let grant = GrantedVolumeAccess(
            displayName: displayName ?? FileManager.default.displayName(atPath: resolvedURL.path),
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
        if let url = resolvedURL(for: grant), activeAccessURLs.contains(url) {
            url.stopAccessingSecurityScopedResource()
            activeAccessURLs.remove(url)
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
    }

    private func activateAccessIfPossible(_ grant: GrantedVolumeAccess) {
        guard let url = resolvedURL(for: grant) else { return }
        if url.startAccessingSecurityScopedResource() {
            activeAccessURLs.insert(url)
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: storageURL) else { return }
        grants = (try? JSONDecoder().decode([GrantedVolumeAccess].self, from: data)) ?? []
    }

    private func save() throws {
        try FileManager.default.createDirectory(
            at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(grants)
        try data.write(to: storageURL, options: .atomic)
    }
}
