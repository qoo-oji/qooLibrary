import Foundation
import QooKit

/// 圧縮の司令塔 [AR-10][AR-11][9.4 節]。`LibarchiveBackend.compress` で
/// ステージング（ユーザーに見えないアプリ内部の一時領域）へ zip を作り、
/// 完成した単一の zip だけを `FileOperationService.move` で最終位置へ移す
/// （`SecureExtractor` と同じ「ユーザーに見える書き込みだけ
/// `FileOperationService` を経由する」方針、EX-04 相当）。
public actor ArchiveCompressor {
    public static let shared = ArchiveCompressor()

    private let fileOps: FileOperationService
    /// テスト用に差し替え可能（既定は実際のアプリコンテナ配下）。
    /// `SecureExtractor` と同じ理由（他スイートとの並行実行時の共有
    /// ディレクトリ競合を避ける）。
    private let stagingRoot: URL

    public init(fileOps: FileOperationService = .shared, stagingRoot: URL = SecureExtractor.defaultStagingRoot()) {
        self.fileOps = fileOps
        self.stagingRoot = stagingRoot
    }

    /// `items` を `destinationName`.zip/.7z として `destinationFolder` に作る
    /// （拡張子は `options.format` に従う）。返り値は実際に作られたアーカイブの
    /// URL（衝突時は `.keepBoth`/`.replace` に従ってリネームされている場合が
    /// ある）。`options.encryption != .none` のときは `passphrase` が必須
    /// [環境設定「圧縮／展開」タブ]。
    @discardableResult
    public func compress(
        _ items: [URL],
        destinationName: String,
        in destinationFolder: URL,
        options: CompressionOptions = .default,
        passphrase: String? = nil,
        conflictPolicy: ConflictPolicy = .keepBoth
    ) async throws -> URL {
        guard !items.isEmpty else {
            throw ExtractError.backendFailure("no items to compress")
        }

        let stagingDir = stagingRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: stagingDir) // [EX-03] 相当、ユーザー非可視の一時領域
        }

        let ext = options.format == .zip ? "zip" : "7z"
        let stagingArchive = stagingDir.appendingPathComponent("\(destinationName).\(ext)")
        // 暗号化の有無は記録するが、**パスフレーズそのものは絶対にログへ
        // 書かない**（診断ログはユーザーが第三者へ共有する前提の成果物）。
        // 注釈はパスの**前**に（`SecureExtractor` と同じ理由）。宛先は
        // 「フォルダ + 名前」を連結した完全なパスとして 1 つの印に収める。
        Log.archive.info(
            "圧縮開始（\(options.format) / 暗号化 \(options.encryption)）: \(items.count) 件 → \(Log.path(destinationFolder.appendingPathComponent("\(destinationName).\(ext)")))"
        )
        do {
            try await LibarchiveBackend.shared.compress(items, to: stagingArchive, options: options, passphrase: passphrase)
        } catch {
            // 素のファイル名ではなく最終位置の絶対パスで書く（匿名化の対象に
            // なるのは絶対パスだけのため [LG2-06]）。
            Log.archive.error(
                "圧縮に失敗: \(Log.path(destinationFolder.appendingPathComponent("\(destinationName).\(ext)"))) — \(error.localizedDescription)"
            )
            throw error
        }

        let receipts = try await fileOps.move(
            [stagingArchive], to: destinationFolder, options: OpOptions(conflictPolicy: conflictPolicy)
        )
        guard let finalURL = receipts.first?.toURL else {
            Log.archive.error("圧縮結果を最終位置へ移せませんでした: \(Log.path(destinationFolder))")
            throw ExtractError.backendFailure("failed to move compressed archive to destination")
        }
        Log.archive.info("圧縮完了: \(Log.path(finalURL))")
        return finalURL
    }
}
