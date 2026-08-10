import Foundation

/// ボリューム内で一意なファイル識別子。DB の主たる同一性キー [ID-01]。
/// `Foundation` のみに依存する値型 [A-01]。
public struct FileIdentity: Sendable, Hashable, Codable {
    public let volumeUUID: String
    public let inode: UInt64

    public init(volumeUUID: String, inode: UInt64) {
        self.volumeUUID = volumeUUID
        self.inode = inode
    }
}
