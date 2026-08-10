import Foundation

/// `BookmarkResolving` の既定実装。状態を持たないため struct で十分 [SB-02][SB-05]。
public struct SecurityScopedBookmarkResolver: BookmarkResolving {
    public init() {}

    public func makeBookmark(for url: URL) throws -> Data {
        try url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    public func resolve(_ data: Data) -> BookmarkResolution {
        var isStale = false
        do {
            let url = try URL(
                resolvingBookmarkData: data,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            return .resolved(url: url, isStale: isStale)
        } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
            // ボリューム未接続時、解決先が見つからない形でエラーになる。
            return .offline(reason: .volumeNotMounted)
        } catch {
            // [設計判断] CocoaError だけでは「権限拒否」と「ブックマーク自体が壊れている」を
            // 確実には区別できない（API が明確なコードを返さないため）。両者を区別する必要が
            // 生じたら、TCC 保護領域への読み取り試行（B-21 と同じ手法）を併用する。
            return .offline(reason: .invalidBookmark)
        }
    }

    public func withAccess<T: Sendable>(
        _ data: Data,
        _ body: @Sendable (URL) async throws -> T
    ) async throws -> T {
        let url: URL
        switch resolve(data) {
        case .resolved(let resolvedURL, _):
            url = resolvedURL
        case .offline(let reason):
            throw BookmarkAccessError.offline(reason)
        }
        guard url.startAccessingSecurityScopedResource() else {
            throw BookmarkAccessError.accessDenied
        }
        defer { url.stopAccessingSecurityScopedResource() }
        return try await body(url)
    }
}
