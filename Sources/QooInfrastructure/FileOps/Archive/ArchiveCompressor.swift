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
        conflictPolicy: ConflictPolicy = .keepBoth,
        progress: ProgressReporter? = nil,
        pauseToken: PauseToken? = nil
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
        // 総数はここで数える [ユーザー要望: 総ファイル数と残り件数を出したい]。
        // バックエンドは詰めながら数えるので総数を先には知れない。走査の
        // 上乗せは、実際に圧縮する時間に比べれば無視できる。
        //
        // **進捗表示の有無に関わらず数える**［監査で発見］。この値は空き容量の
        // 事前検査にも使うようになったため、進捗の都合で検査が抜けてはならない
        // （`ProgressTracker` が同じ理由で同じ形にしてある）。
        // 圧縮対象の木を丸ごと歩くので、相手がネットワーク上なら長い
        // [NV6-01]。協調プールで走らせない。
        let totals = await FileIO.perform { Self.totals(of: items) }
        var reporter: ProgressReporter?
        if let progress {
            reporter = ProgressThrottle.wrap(progress, totalItems: totals.files, totalBytes: totals.bytes)
        }

        // **圧縮には空き容量の事前検査が一切無かった**［監査で発見］。
        // アーカイブはいったんステージング（アプリコンテナ＝起動ボリューム）
        // に作られるため、保存先に十分な空きがあっても起動ボリュームが
        // 手薄だと途中で失敗する。しかもその失敗は libarchive の
        // 「Write error」という英語 1 語しか返さず、容量不足だと分からなかった。
        //
        // 圧縮後の大きさは事前には分からないので、**非圧縮時の総バイト数**を
        // 要求量とする（実際にはこれより小さくなるため、断りすぎない側では
        // なく安全側の見積もりになる）。
        try Self.checkStagingCapacity(stagingDir, required: totals.bytes)
        do {
            try await LibarchiveBackend.shared.compress(
                items, to: stagingArchive, options: options, passphrase: passphrase,
                progress: reporter, pauseToken: pauseToken
            )
        } catch {
            // 素のファイル名ではなく最終位置の絶対パスで書く（匿名化の対象に
            // なるのは絶対パスだけのため [LG2-06]）。
            Log.archive.error(
                "圧縮に失敗: \(Log.path(destinationFolder.appendingPathComponent("\(destinationName).\(ext)"))) — \(error.localizedDescription)"
            )
            throw error
        }

        let receipts = try await fileOps.move(
            [stagingArchive], to: destinationFolder,
            options: OpOptions(conflictPolicy: conflictPolicy, pauseToken: pauseToken)
        )
        guard let finalURL = receipts.first?.toURL else {
            Log.archive.error("圧縮結果を最終位置へ移せませんでした: \(Log.path(destinationFolder))")
            throw ExtractError.backendFailure("failed to move compressed archive to destination")
        }
        Log.archive.info("圧縮完了: \(Log.path(finalURL))")
        return finalURL
    }

    /// 作業領域に、非圧縮時の総バイト数ぶんの空きがあるか。
    ///
    /// 空きが分からないボリュームでは検査を飛ばす（`VolumeCapacity` の
    /// 判断に合わせる — 断る側に倒すと正当な操作までできなくなる）。
    private static func checkStagingCapacity(_ staging: URL, required: Int64) throws {
        guard required > 0, let available = VolumeCapacity.available(at: staging) else { return }
        let margin = VolumeCapacity.margin(
            requested: AppLimits.FileOperations.freeSpaceMargin, at: staging
        )
        guard available < required + margin else { return }
        Log.archive.error(
            "圧縮を開始前に中止: 作業領域の空き容量不足（必要 \(required) / 空き \(available)）"
        )
        throw ExtractError.insufficientStagingSpace(required: required, available: available)
    }

    /// 圧縮対象の総ファイル数・総バイト数（シンボリックリンクは辿らない）。
    ///
    /// - Note: **ブロッキング。`FileIO.perform` の中からのみ呼ぶ** [NV6-01]。
    private static func totals(of items: [URL]) -> (files: Int, bytes: Int64) {
        var files = 0
        var bytes: Int64 = 0
        let fm = FileManager.default
        for item in items {
            let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .isSymbolicLinkKey])
            if values?.isSymbolicLink == true { continue }
            if values?.isDirectory == true {
                guard let enumerator = fm.enumerator(
                    at: item, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
                    options: [.skipsHiddenFiles]
                ) else { continue }
                while let child = enumerator.nextObject() as? URL {
                    let childValues = try? child.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                    guard childValues?.isRegularFile == true else { continue }
                    files += 1
                    bytes += Int64(childValues?.fileSize ?? 0)
                }
            } else {
                files += 1
                bytes += Int64(values?.fileSize ?? 0)
            }
        }
        return (files, bytes)
    }
}
