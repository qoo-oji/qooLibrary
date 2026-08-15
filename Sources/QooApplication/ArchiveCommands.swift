import Foundation
import QooInfrastructure
import QooKit

/// [UD-03] Undo は生成された zip を削除する。元ファイルは不変なので対称性が
/// 保たれる [UD-09]。
public final class CompressCommand: Command {
    private let items: [URL]
    private let destinationName: String
    private let destinationFolder: URL
    private let options: CompressionOptions
    private let passphrase: String?
    private let conflictPolicy: ConflictPolicy
    private let progress: ProgressReporter?
    private let pauseToken: PauseToken?
    private let compressor: ArchiveCompressor
    private let fileOps: FileOperationService
    /// 実行後に作成されたアーカイブの URL。呼び出し側が実行直後に選択状態を
    /// 更新するために公開している [ユーザー要望: 「ここに圧縮」後、
    /// 作成した圧縮ファイルを選択した状態にしてほしい]。
    public private(set) var resultURL: URL?

    public init(
        items: [URL], destinationName: String, destinationFolder: URL,
        options: CompressionOptions = .default, passphrase: String? = nil,
        conflictPolicy: ConflictPolicy = .keepBoth, progress: ProgressReporter? = nil,
        pauseToken: PauseToken? = nil,
        compressor: ArchiveCompressor = .shared, fileOps: FileOperationService = .shared
    ) {
        self.items = items
        self.destinationName = destinationName
        self.destinationFolder = destinationFolder
        self.options = options
        self.passphrase = passphrase
        self.conflictPolicy = conflictPolicy
        self.progress = progress
        self.pauseToken = pauseToken
        self.compressor = compressor
        self.fileOps = fileOps
    }

    public var displayName: String {
        let ext = options.format == .zip ? "zip" : "7z"
        return "「\(destinationName).\(ext)」を作成"
    }

    public var logDescription: String {
        let ext = options.format == .zip ? "zip" : "7z"
        let target = destinationFolder.appendingPathComponent("\(destinationName).\(ext)")
        // パスフレーズそのものは絶対に書かない（暗号化の有無だけ残す）。
        return Self.logDescription("compress(\(options.format)/\(options.encryption))", items, to: target)
    }

    public let isUndoable = true
    /// [ユーザー要望] 圧縮は数秒かかることがあり、完了が分かる手がかりが要る
    /// （`QooProgressPresenter` のオーバーレイを追加したのと同じ理由）。
    public let completionSound: SystemSoundEffect? = .operationComplete

    public func execute() async throws -> CommandResult {
        resultURL = try await compressor.compress(
            items, destinationName: destinationName, in: destinationFolder,
            options: options, passphrase: passphrase, conflictPolicy: conflictPolicy,
            progress: progress, pauseToken: pauseToken
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
    private let limits: ExtractLimits
    private let passphrase: String?
    private let progress: ProgressReporter?
    private let pauseToken: PauseToken?
    private let extractor: SecureExtractor
    private let fileOps: FileOperationService
    private var createdURLs: [URL] = []

    public init(
        archiveURL: URL, destination: URL, limits: ExtractLimits = .default, passphrase: String? = nil,
        progress: ProgressReporter? = nil, pauseToken: PauseToken? = nil,
        extractor: SecureExtractor = .shared, fileOps: FileOperationService = .shared
    ) {
        self.archiveURL = archiveURL
        self.destination = destination
        self.limits = limits
        self.passphrase = passphrase
        self.progress = progress
        self.pauseToken = pauseToken
        self.extractor = extractor
        self.fileOps = fileOps
    }

    public var displayName: String { "「\(archiveURL.lastPathComponent)」を展開" }

    public var logDescription: String { "extract: \(Log.path(archiveURL)) → \(Log.path(destination))" }

    public let isUndoable = true
    /// [ユーザー要望] 圧縮と同じ理由。複数アーカイブの一括展開では
    /// `CompositeCommand` がまとめるため、鳴るのは 1 回だけ。
    public let completionSound: SystemSoundEffect? = .operationComplete

    public func execute() async throws -> CommandResult {
        let options = ExtractOptions(
            destination: destination, limits: limits, passphrase: passphrase,
            progress: progress, pauseToken: pauseToken
        )
        let result = try await extractor.extract(archiveURL, options: options)
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
