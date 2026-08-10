import Foundation

/// アーカイブ内の 1 エントリ（一覧取得のみ、展開しない）[9.1 節]。
public struct ArchiveEntry: Sendable, Equatable {
    public let pathname: String
    public let uncompressedSize: Int64
    public let isDirectory: Bool
    public let isSymlink: Bool
    /// ハードリンク・デバイスファイル・FIFO 等、通常のファイル/ディレクトリ/
    /// シンボリックリンク以外の特殊エントリ [EX-13]。
    public let isSpecialEntry: Bool

    public init(
        pathname: String,
        uncompressedSize: Int64,
        isDirectory: Bool,
        isSymlink: Bool,
        isSpecialEntry: Bool = false
    ) {
        self.pathname = pathname
        self.uncompressedSize = uncompressedSize
        self.isDirectory = isDirectory
        self.isSymlink = isSymlink
        self.isSpecialEntry = isSpecialEntry
    }
}

/// エントリ一覧の結果 [9.1 節]。
public struct ArchiveListing: Sendable, Equatable {
    public let entries: [ArchiveEntry]

    public init(entries: [ArchiveEntry]) {
        self.entries = entries
    }
}
