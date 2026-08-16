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

    /// **`.withoutMounting` を必ず付ける** [RG3-01][NV-91]。理由はプロトコル側の
    /// コメント参照——解決はマウントを起こす副作用があり、ネットワークボリューム
    /// では起動時のブロックと認証ダイアログにつながる。
    public func resolve(_ data: Data) -> BookmarkResolution {
        resolve(data, allowingMount: false)
    }

    /// マウントを許す解決。**ユーザーの明示的な操作からのみ**。
    public func resolveAllowingMount(_ data: Data) -> BookmarkResolution {
        resolve(data, allowingMount: true)
    }

    private func resolve(_ data: Data, allowingMount: Bool) -> BookmarkResolution {
        var isStale = false
        var options: URL.BookmarkResolutionOptions = .withSecurityScope
        if !allowingMount { options.insert(.withoutMounting) }
        do {
            let url = try URL(
                resolvingBookmarkData: data,
                options: options,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            if isStale {
                Log.sandbox.debug("ブックマークが stale です（再作成が望ましい）: \(Log.path(url))")
            }
            return .resolved(url: url, isStale: isStale)
        } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
            // ボリューム未接続時、解決先が見つからない形でエラーになる。
            Log.sandbox.debug("ブックマークの解決に失敗（未接続と判定）: \(error.localizedDescription)")
            return .offline(reason: .volumeNotMounted)
        } catch {
            // [設計判断] CocoaError だけでは「権限拒否」と「ブックマーク自体が壊れている」を
            // 確実には区別できない（API が明確なコードを返さないため）。両者を区別する必要が
            // 生じたら、TCC 保護領域への読み取り試行（B-21 と同じ手法）を併用する。
            // その判別材料として、生のエラーだけは診断ログに残しておく。
            Log.sandbox.debug("ブックマークの解決に失敗（無効と判定）: \(error)")
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
