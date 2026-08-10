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
    /// エントリ名の判定に使われたエンコーディング [AR-02][9.2 節]。zip/7z の
    /// UTF-8 フラグ未設定時は `ArchiveNameEncodingHeuristic` の判定結果、
    /// それ以外（フラグ設定済み・rar・tar.gz）は常に `.utf8`。
    public let detectedEncoding: String.Encoding

    public init(entries: [ArchiveEntry], detectedEncoding: String.Encoding = .utf8) {
        self.entries = entries
        self.detectedEncoding = detectedEncoding
    }
}
