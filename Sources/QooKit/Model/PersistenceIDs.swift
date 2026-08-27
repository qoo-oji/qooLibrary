//
//  永続化層の識別子 [07章 §7.3][A-02]。
//
//  **内部の行 ID は `Int64`（rowid）**。UUID 文字列に対し投入 3 倍速・DB サイズ
//  1/2.8 という実測差がある（`Spikes/README.md`「T-03 / T-04」）。JSON 入出力の
//  同一性キーはもともと自然キー（相対パス + ファイル名 等）なので [JS-04]、
//  外部仕様は変わらない。
//
//  型を分けているのは、`FileID` を `LabelID` の引数へ渡すような取り違えを
//  コンパイラに止めさせるため。
//
import Foundation

/// 行 ID の共通の形。`QooPersistence` が rowid をそのまま入れる。
public protocol PersistenceID: Hashable, Sendable, Codable, CustomStringConvertible {
    var rawValue: Int64 { get }
    init(rawValue: Int64)
}

extension PersistenceID {
    public var description: String { "\(Self.self)(\(rawValue))" }
}

public struct LibrarySeq: Hashable, Sendable, Codable, PersistenceID {
    public let rawValue: Int64
    public init(rawValue: Int64) { self.rawValue = rawValue }
}
public typealias LibraryID = LibrarySeq

public struct FileID: Hashable, Sendable, Codable, PersistenceID {
    public let rawValue: Int64
    public init(rawValue: Int64) { self.rawValue = rawValue }
}

public struct LabelID: Hashable, Sendable, Codable, PersistenceID {
    public let rawValue: Int64
    public init(rawValue: Int64) { self.rawValue = rawValue }
}

public struct LabelGroupID: Hashable, Sendable, Codable, PersistenceID {
    public let rawValue: Int64
    public init(rawValue: Int64) { self.rawValue = rawValue }
}

public struct LibraryTypeID: Hashable, Sendable, Codable, PersistenceID {
    public let rawValue: Int64
    public init(rawValue: Int64) { self.rawValue = rawValue }
}

public struct TemporaryFolderID: Hashable, Sendable, Codable, PersistenceID {
    public let rawValue: Int64
    public init(rawValue: Int64) { self.rawValue = rawValue }
}

/// 通知履歴の行 ID [NT-01][NW-01]。
///
/// **仕様書 §2.4 の `NotificationHistoryStore` は `[UUID]` を取る形で書かれて
/// いるが、それは永続化が SwiftData だった頃の記述**。GRDB へ切り替えた際の
/// 決定（T-03 ②「内部の行 ID は `Int64`（rowid）」）に揃える——`notificationRecord`
/// も `autoIncrementedPrimaryKey` なので、UUID 列を別に持つ理由が無い。
public struct NotificationID: Hashable, Sendable, Codable, PersistenceID {
    public let rawValue: Int64
    public init(rawValue: Int64) { self.rawValue = rawValue }
}
