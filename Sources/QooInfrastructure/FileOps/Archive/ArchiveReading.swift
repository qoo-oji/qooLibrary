import Foundation
import QooKit

/// アーカイブの読み取り抽象化 [9.1 節]。バックエンド差し替えが呼び出し側に
/// 波及しない構造とする [AB-01][MT-04]。
public protocol ArchiveReading: Sendable {
    var supportedFormats: Set<ArchiveFormat> { get }
    func canRead(_ url: URL) async -> Bool
    /// エントリ一覧のみを読む（展開しない）。
    func listEntries(_ url: URL) async throws -> ArchiveListing
    /// ステージングディレクトリへ展開する [EX-01]。エントリごとの安全検証
    /// （EX-10〜EX-15）と展開爆弾対策（EX-20〜EX-21）はバックエンド内部で行う。
    func extract(_ url: URL, to staging: URL, options: ExtractOptions) async throws -> ExtractResult
    /// カバー画像・サムネイル生成用に、アーカイブ全体を展開せず単一エントリ
    /// だけを読む [9.6 節、1-9 で追加]。`encoding` は `listEntries` が返した
    /// `ArchiveListing.detectedEncoding` をそのまま渡す（`entry.pathname` は
    /// その encoding でデコード済みの文字列であるため、同じ encoding で
    /// アーカイブを再走査しないと一致しない）。`maxBytes` を超えるエントリは
    /// `ExtractError.entryReadLimitExceeded` [IM-02]。
    func readEntry(_ url: URL, entry: ArchiveEntry, encoding: String.Encoding, maxBytes: Int) async throws -> Data
}
