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

    /// `items` を `destinationName`.zip として `destinationFolder` に作る。
    /// 返り値は実際に作られた zip の URL（衝突時は `.keepBoth`/`.replace`
    /// に従ってリネームされている場合がある）。
    @discardableResult
    public func compress(
        _ items: [URL],
        destinationName: String,
        in destinationFolder: URL,
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

        let stagingZip = stagingDir.appendingPathComponent("\(destinationName).zip")
        try await LibarchiveBackend.shared.compress(items, to: stagingZip)

        let receipts = try await fileOps.move(
            [stagingZip], to: destinationFolder, options: OpOptions(conflictPolicy: conflictPolicy)
        )
        guard let finalURL = receipts.first?.toURL else {
            throw ExtractError.backendFailure("failed to move compressed archive to destination")
        }
        return finalURL
    }
}
