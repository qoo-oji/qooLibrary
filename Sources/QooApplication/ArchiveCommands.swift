import Foundation
import QooInfrastructure
import QooKit

/// [UD-03] Undo は生成された zip を削除する。元ファイルは不変なので対称性が
/// 保たれる [UD-09]。
public final class CompressCommand: Command {
    private let items: [URL]
    private let destinationName: String
    private let destinationFolder: URL
    private let conflictPolicy: ConflictPolicy
    private let compressor: ArchiveCompressor
    private let fileOps: FileOperationService
    private var resultURL: URL?

    public init(
        items: [URL], destinationName: String, destinationFolder: URL, conflictPolicy: ConflictPolicy = .keepBoth,
        compressor: ArchiveCompressor = .shared, fileOps: FileOperationService = .shared
    ) {
        self.items = items
        self.destinationName = destinationName
        self.destinationFolder = destinationFolder
        self.conflictPolicy = conflictPolicy
        self.compressor = compressor
        self.fileOps = fileOps
    }

    public var displayName: String { "「\(destinationName).zip」を作成" }
    public let isUndoable = true

    public func execute() async throws -> CommandResult {
        resultURL = try await compressor.compress(
            items, destinationName: destinationName, in: destinationFolder, conflictPolicy: conflictPolicy
        )
        return .success
    }

    public func undo() async throws -> UndoResult {
        guard let resultURL else { return .impossible(reason: "元に戻す対象がありません") }
        do {
            _ = try await fileOps.trash([resultURL])
            return .complete
        } catch {
            return .impossible(reason: error.localizedDescription)
        }
    }
}

/// [UD-03] Undo は生成物を削除する。元アーカイブは不変なので対称性が保たれる
/// [UD-09]。「ここに展開」は既存フォルダへ他のファイルと混在して書き込まれる
/// ため、フォルダ丸ごとではなく `ExtractResult.createdURLs`
/// （`SecureExtractor` が `promoteFromStaging` の結果から返す、実際に作られた
/// トップレベル項目）だけを削除する。
public final class ExtractCommand: Command {
    private let archiveURL: URL
    private let destination: URL
    private let extractor: SecureExtractor
    private let fileOps: FileOperationService
    private var createdURLs: [URL] = []

    public init(
        archiveURL: URL, destination: URL, extractor: SecureExtractor = .shared, fileOps: FileOperationService = .shared
    ) {
        self.archiveURL = archiveURL
        self.destination = destination
        self.extractor = extractor
        self.fileOps = fileOps
    }

    public var displayName: String { "「\(archiveURL.lastPathComponent)」を展開" }
    public let isUndoable = true

    public func execute() async throws -> CommandResult {
        let result = try await extractor.extract(archiveURL, options: ExtractOptions(destination: destination))
        createdURLs = result.createdURLs
        return .success
    }

    public func undo() async throws -> UndoResult {
        guard !createdURLs.isEmpty else { return .impossible(reason: "元に戻す対象がありません") }
        do {
            _ = try await fileOps.trash(createdURLs)
            return .complete
        } catch {
            return .impossible(reason: error.localizedDescription)
        }
    }
}
