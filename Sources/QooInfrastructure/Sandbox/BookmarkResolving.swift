import Foundation

/// Security-Scoped Bookmark の生成・解決を集約する [SB-02]。
/// ブックマーク解決は必ずこの型を通す。解決失敗時は例外を投げず `.offline`
/// を返す（フォルダツリーの表示を壊さないため）[SB-05]。
public protocol BookmarkResolving: Sendable {
    /// 登録時にブックマークを生成する。FS-02/FS-03 の検証を通過していることが前提。
    func makeBookmark(for url: URL) throws -> Data // [RG-07]

    /// 起動時・マウント時に解決する。失敗は throw せず `.offline` を返す。 [SB-05]
    func resolve(_ data: Data) -> BookmarkResolution

    /// 解決した URL に対する startAccessing/stopAccessing をスコープ管理する。
    func withAccess<T: Sendable>(_ data: Data, _ body: @Sendable (URL) async throws -> T) async throws -> T
}

public enum BookmarkResolution: Sendable, Equatable {
    case resolved(url: URL, isStale: Bool)
    case offline(reason: OfflineReason)
}

public enum OfflineReason: Sendable, Equatable {
    case volumeNotMounted
    case permissionDenied
    case invalidBookmark
}

public enum BookmarkAccessError: Error, Sendable, Equatable {
    case offline(OfflineReason)
    case accessDenied
}
