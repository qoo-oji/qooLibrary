import Foundation
import QooKit

/// アーカイブの読み取り抽象化 [9.1 節]。バックエンド差し替えが呼び出し側に
/// 波及しない構造とする [AB-01][MT-04]。
///
/// 仕様書の `listEntries(_:encoding:)`/`readEntry(_:entry:maxBytes:)` の
/// うち、`encoding` 引数（文字化けヒューリスティックの統合）と
/// `readEntry`（カバー画像用の単一エントリ読み込み、1-9 で使用）は現時点
/// では未実装 [1-7 のスコープ外、次段階で追加]。
public protocol ArchiveReading: Sendable {
    var supportedFormats: Set<ArchiveFormat> { get }
    func canRead(_ url: URL) async -> Bool
    /// エントリ一覧のみを読む（展開しない）。
    func listEntries(_ url: URL) async throws -> ArchiveListing
    /// ステージングディレクトリへ展開する [EX-01]。エントリごとの安全検証
    /// （EX-10〜EX-15）と展開爆弾対策（EX-20〜EX-21）はバックエンド内部で行う。
    func extract(_ url: URL, to staging: URL, options: ExtractOptions) async throws -> ExtractResult
}
