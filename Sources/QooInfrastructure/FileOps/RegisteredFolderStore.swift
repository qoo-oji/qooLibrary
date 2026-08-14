import Foundation

public enum RegisteredFolderKind: String, Codable, Sendable, Equatable {
    case library, temporary
}

public struct RegisteredFolder: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public var kind: RegisteredFolderKind
    public var displayName: String // [RG-05]
    public var bookmarkData: Data // [RG-07]

    public init(id: UUID = UUID(), kind: RegisteredFolderKind, displayName: String, bookmarkData: Data) {
        self.id = id
        self.kind = kind
        self.displayName = displayName
        self.bookmarkData = bookmarkData
    }
}

public enum RegisteredFolderError: Error, Sendable, Equatable {
    case nestedRegistration // [RG-03][RG-04]
    case unsupportedFileSystem(VolumeRejection) // [RG-08]
}

/// フォルダ登録の永続化 [8.7 節、RG-01〜RG-08]。1-13 の時点ではまだ SwiftData
/// （`Library`/`TemporaryFolder` モデル）が無いため、ロードマップの注記通り
/// **「エイリアス相当」**に留める: 実フォルダへの参照（Security-Scoped
/// Bookmark）と表示名だけを持つ軽量なレコードを JSON で永続化する。
/// ラベル・テンプレート・初回フルスキャン等のドメイン処理（8.7 節 疑似コードの
/// ⑤）は一切行わない（フェーズ2で `LibraryRepository`〈SwiftData 版〉に
/// 置き換える想定、07章 §7.5 参照）。
///
/// JSON ファイルへの書き込みはアプリ内部の永続化データであり、期待変更台帳・
/// Undo・操作履歴の対象外（ユーザーへ見える最終位置ではない）ため、
/// `SecureExtractor`/`CoverImageCache` と同じ理由で `FileOperationService` を
/// 経由しない。この理由により、本ファイルは FileOps 隔離検査（B-10）の対象外
/// ディレクトリ（`QooInfrastructure/FileOps/`）に置く。
public actor RegisteredFolderStore {
    public static let shared = RegisteredFolderStore()

    private let storageURL: URL
    private let bookmarks: BookmarkResolving
    private let volumeChecker: VolumeEligibilityChecking
    private var folders: [RegisteredFolder] = []
    private var activeAccessURLs: Set<URL> = []
    private var didLoad = false

    /// テストでは独立したストレージ・依存を注入できる（`SecureExtractor`/
    /// `ArchiveCompressor` の `stagingRoot` 注入と同じ設計判断）。
    public init(
        storageURL: URL? = nil,
        bookmarks: BookmarkResolving = SecurityScopedBookmarkResolver(),
        volumeChecker: VolumeEligibilityChecking = VolumeEligibilityChecker()
    ) {
        if let storageURL {
            self.storageURL = storageURL
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            self.storageURL = appSupport.appendingPathComponent("qooLibrary/registeredFolders.json")
        }
        self.bookmarks = bookmarks
        self.volumeChecker = volumeChecker
    }

    /// 起動時に一度だけ呼ぶ。保存済みの登録フォルダを読み込み、それぞれの
    /// Security-Scoped Bookmark へのアクセスを開始する。
    ///
    /// **個々の読み取り操作のたびに start/stop するのではなく、登録されている
    /// 間はアプリ終了までスコープを保持し続ける方針**にした
    /// [1-2 の実機検証で確認済みのパターン: ブックマーク解決後にアクセスを
    /// 開始したまま保てば、再起動をまたいでも同じフォルダへアクセスできる]。
    /// これにより `FolderTreeNode.children(of:)`/`FolderContentView.reload()`
    /// など、すでに実装済みの素の `FileManager` 呼び出し（読み取り専用、FileOps
    /// 隔離検査の対象外）を一切変更せずに登録フォルダにも対応できる。
    public func loadAndActivateAll() {
        ensureLoaded()
    }

    public func folders(kind: RegisteredFolderKind) -> [RegisteredFolder] {
        ensureLoaded()
        return folders
            .filter { $0.kind == kind }
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    /// 解決済みの URL。ボリューム未接続等でオフラインの場合は `nil` [SB-05]。
    public func resolvedURL(for folder: RegisteredFolder) -> URL? {
        guard case .resolved(let url, _) = bookmarks.resolve(folder.bookmarkData) else { return nil }
        return url
    }

    @discardableResult
    public func register(url: URL, kind: RegisteredFolderKind, displayName: String?) async throws -> RegisteredFolder {
        ensureLoaded()
        let resolvedURL = url.resolvingSymlinksInPath() // [SL-07]
        try checkNotNested(resolvedURL)

        switch try await volumeChecker.evaluate(resolvedURL) { // [RG-08][FS-01〜FS-05]
        case .rejected(let reason):
            throw RegisteredFolderError.unsupportedFileSystem(reason)
        case .eligible:
            break // ネットワークボリューム等の警告 [FS-06] の提示は呼び出し側（UI）の責務
        }

        let bookmarkData = try bookmarks.makeBookmark(for: resolvedURL) // [RG-07]
        let folder = RegisteredFolder(
            kind: kind, displayName: displayName ?? resolvedURL.lastPathComponent, bookmarkData: bookmarkData
        )
        folders.append(folder)
        activateAccessIfPossible(folder)
        try save()
        return folder
    }

    /// [RG-06 の簡易版] フェーズ1にはラベルドメインが無いため「削除するか
    /// 保持するか」の選択肢自体が意味を持たない。登録レコードを削除するのみ。
    public func unregister(_ id: UUID) throws {
        ensureLoaded()
        guard let folder = folders.first(where: { $0.id == id }) else { return }
        if let url = resolvedURL(for: folder), activeAccessURLs.contains(url) {
            url.stopAccessingSecurityScopedResource()
            activeAccessURLs.remove(url)
        }
        folders.removeAll { $0.id == id }
        try save()
    }

    /// [RG-05] 実フォルダ名とは別の表示名に変更する。
    public func rename(_ id: UUID, to displayName: String) throws {
        ensureLoaded()
        guard let index = folders.firstIndex(where: { $0.id == id }) else { return }
        folders[index].displayName = displayName
        try save()
    }

    /// 初回アクセス時に一度だけ永続化データを読み込み、ブックマークへの
    /// アクセスを開始する。呼び出し元（アプリ起動時の明示呼び出しと、
    /// `FolderTreePane` 側の初回表示）のどちらが先に到達しても安全なように、
    /// すべての公開メソッドの先頭でこれを呼ぶ。
    private func ensureLoaded() {
        guard !didLoad else { return }
        didLoad = true
        load()
        for folder in folders {
            activateAccessIfPossible(folder)
        }
    }

    private func activateAccessIfPossible(_ folder: RegisteredFolder) {
        guard let url = resolvedURL(for: folder) else { return }
        if url.startAccessingSecurityScopedResource() {
            activeAccessURLs.insert(url)
        }
    }

    /// [RG-03][RG-04] 既存の登録フォルダ（ライブラリ・テンポラリ双方）との
    /// 祖先・子孫関係、および同一フォルダの二重登録を禁止する。
    private func checkNotNested(_ candidate: URL) throws {
        let candidatePath = candidate.standardizedFileURL.path
        for existing in folders {
            guard let existingURL = resolvedURL(for: existing) else { continue }
            let existingPath = existingURL.standardizedFileURL.path
            if candidatePath == existingPath
                || candidatePath.hasPrefix(existingPath + "/")
                || existingPath.hasPrefix(candidatePath + "/") {
                throw RegisteredFolderError.nestedRegistration
            }
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: storageURL) else { return }
        guard let decoded = try? JSONDecoder().decode([RegisteredFolder].self, from: data) else {
            // デコードに失敗したまま `folders = []` として処理を続けると、次に
            // 何か1件でも登録・解除・改名をした瞬間の `save()` が壊れた内容
            // ごと上書きしてしまい、以前登録していたライブラリ／テンポラリ
            // フォルダがすべて復元不能になる [フェーズ1完了時の監査で追加、
            // `VolumeAccessStore.load()` と同じ対策]。元ファイルには触れず
            // 隣へ退避してから空の状態で続行し、手動での調査・復旧の余地を
            // 残す。
            let corruptBackup = storageURL.deletingLastPathComponent()
                .appendingPathComponent("\(storageURL.lastPathComponent).corrupt-\(UUID().uuidString)")
            try? FileManager.default.moveItem(at: storageURL, to: corruptBackup)
            return
        }
        folders = decoded
    }

    private func save() throws {
        try FileManager.default.createDirectory(
            at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(folders)
        try data.write(to: storageURL, options: .atomic)
    }
}
