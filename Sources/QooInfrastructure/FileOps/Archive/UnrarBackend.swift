#if !PERMISSIVE_ONLY_BUILD
import Foundation
import QooKit
import QooUnrarBridge

/// RAR の読み取り [AR-01b][LC-11]。`PERMISSIVE_ONLY_BUILD` ではこのファイル
/// 自体が `Package.swift` からビルド対象外になり、`LibarchiveBackend`
/// （libarchive 自身の RAR リーダー）にフォールバックする [LC-12][LC-13]。
///
/// `QooUnrarBridge` は UnRAR の RARDLL API を薄くラップしたもので、
/// `qoo_unrar_extract_all` は展開先ディレクトリへ直接書き出す
/// （libarchive のようなエントリ単位のストリーミング取得はできない）。
/// そのため libarchive バックエンドと異なり、
/// - 展開爆弾対策（実バイト数によるリアルタイム中断 [EX-20]）は不可能なので、
///   展開完了後にステージング全体の実サイズを検証し、超過していれば
///   ステージングごと破棄する事後チェックにしている。
/// - エントリ単位の安全でないパスは、展開前の一覧取得（`qoo_unrar_list`）で
///   検出し、1件でもあればアーカイブ全体を拒否する（部分展開はできない）。
///
/// ## 進捗・一時停止・中断はエントリ境界で受ける
/// `qoo_unrar_extract_all` は**1 エントリ書き出すたびにコールバックを呼ぶ**
/// ので、そこで進み具合を報告し、待ち、止められる［当初「一括 API なので
/// 何もできない」と記録していたが誤りだった。宣言を読み直して判明］。
/// コールバックは呼び出し元のスレッドで走るため、`Cancellation.isRequested` も
/// `PauseToken` もそのまま使える（`copyfile` の status コールバックと同じ形）。
///
/// **粒度は 1 エントリ**。`RARProcessFileW` は 1 エントリを書き終えるまで
/// 戻らないため、巨大な 1 ファイルの**途中**では止まれない。バイト単位まで
/// 踏み込むなら UnRAR の `UCM_PROCESSDATA` コールバックを使う拡張が要る
/// （ライセンス上は自作ラッパーなので改変は問題ない。改変対象は
/// `ThirdParty/unrar/` 配下の UnRAR 本体ソースではない）。
///
/// ステージングディレクトリの作成は `FileManager` を直接使う
/// （`SecureExtractor` のコメント参照。期待変更台帳・Undo の対象外の
/// ユーザー不可視な一時領域のため `FileOperationService` を経由しない
/// 意図的な例外）。そのため B-10 の対象外ディレクトリ
/// （`QooInfrastructure/FileOps/`）配下に置いている。
public struct UnrarBackend: ArchiveReading {
    public static let shared = UnrarBackend()

    public let supportedFormats: Set<ArchiveFormat> = [.rar]

    public init() {}

    public func canRead(_ url: URL) async -> Bool {
        ArchiveFormat.from(filename: url.lastPathComponent) == .rar
    }

    public func listEntries(_ url: URL) async throws -> ArchiveListing {
        try await FileIO.perform { try self.listEntriesBlocking(url) }
    }

    /// - Note: **ブロッキング。`FileIO.perform` の中からのみ呼ぶ** [NV6-01]。
    ///   アーカイブの読み書きは相手がネットワーク上なら往復が多く、応答が
    ///   無ければ戻ってこない。協調スレッドプールの上で走らせると、コア数ぶん
    ///   溜まった時点でアプリの `async` 処理が全部止まる。
    private func listEntriesBlocking(_ url: URL) throws -> ArchiveListing {
        let entries = try Self.list(url)
        return ArchiveListing(entries: entries)
    }

    public func extract(_ url: URL, to staging: URL, options: ExtractOptions) async throws -> ExtractResult {
        try await FileIO.perform { try self.extractBlocking(url, to: staging, options: options) }
    }

    /// - Note: **ブロッキング。`FileIO.perform` の中からのみ呼ぶ** [NV6-01]。
    ///   アーカイブの読み書きは相手がネットワーク上なら往復が多く、応答が
    ///   無ければ戻ってこない。協調スレッドプールの上で走らせると、コア数ぶん
    ///   溜まった時点でアプリの `async` 処理が全部止まる。
    private func extractBlocking(_ url: URL, to staging: URL, options: ExtractOptions) throws -> ExtractResult {
        let fm = FileManager.default
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)

        let entries = try Self.list(url)
        if entries.count > options.limits.maxEntries { // [EX-21]
            throw ExtractError.tooManyEntries(limit: options.limits.maxEntries)
        }

        // 安全でないエントリが1件でもあれば、部分展開できないためアーカイブ
        // 全体を拒否する [EX-10〜EX-13、上記の設計判断を参照]。
        var rejected: [ExtractRejection] = []
        for entry in entries {
            let outcome = EntryPathValidation.validate(
                pathname: entry.pathname,
                isDirectory: entry.isDirectory,
                isSymlink: entry.isSymlink,
                isSpecialEntry: entry.isSpecialEntry,
                followSymlinks: options.followSymlinks,
                stagingRoot: staging
            )
            if case .rejected(let reason) = outcome {
                rejected.append(ExtractRejection(entry: entry.pathname, reason: reason))
            }
        }
        guard rejected.isEmpty else {
            throw ExtractError.backendFailure(
                "archive contains \(rejected.count) unsafe entr\(rejected.count == 1 ? "y" : "ies") "
                    + "(\(rejected.map(\.entry).joined(separator: ", "))); refusing to extract any of it"
            )
        }

        if Cancellation.isRequested { throw ExtractError.cancelled }
        let box = CallbackBox()
        box.collectsEntries = false
        box.progress = options.progress
        box.pauseToken = options.pauseToken
        try Self.extractAll(url, to: staging, box: box)
        if Cancellation.isRequested { throw ExtractError.cancelled }

        // 実バイト数によるリアルタイム中断ができないため、展開後に検証する
        // （上記コメント参照）。
        let totalWritten = try Self.directorySize(staging)
        if totalWritten > options.limits.maxUncompressedBytes {
            throw ExtractError.expansionLimitExceeded(limit: options.limits.maxUncompressedBytes)
        }
        let archiveFileSize = (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? nil
        let ratio = Double(totalWritten) / Double(max(archiveFileSize ?? 1, 1))
        if ratio > options.limits.ratioAbort {
            throw ExtractError.compressionRatioExceeded(limit: options.limits.ratioAbort)
        }

        let extractedCount = entries.filter { !$0.isDirectory }.count
        return ExtractResult(
            extractedCount: extractedCount,
            rejected: [],
            renamedForCaseCollision: [], // UnRAR 自身が書き込むため、この経路では検出できない [既知の制限]
            totalBytesWritten: totalWritten
        )
    }

    /// [9.6 節] `qoo_unrar_extract_one` は一括展開と違いエントリ単位の
    /// ストリーミングができないため、一時ファイルへ書き出してから読み直す
    /// （`UnrarBackend` は元々ステージングへ直接 `FileManager` で書き込む
    /// 意図的な例外なので、一時ファイルの扱いも同じ方針でよい）。`encoding`
    /// は使わない — `QooUnrarBridge` は最初から UTF-8 で返すため
    /// `listEntries` 同様デコードの再判定が不要 [AR-03 のコメント参照]。
    public func readEntry(_ url: URL, entry: ArchiveEntry, encoding: String.Encoding, maxBytes: Int) async throws -> Data {
        try await FileIO.perform { try self.readEntryBlocking(url, entry: entry, encoding: encoding, maxBytes: maxBytes) }
    }

    /// - Note: **ブロッキング。`FileIO.perform` の中からのみ呼ぶ** [NV6-01]。
    ///   アーカイブの読み書きは相手がネットワーク上なら往復が多く、応答が
    ///   無ければ戻ってこない。協調スレッドプールの上で走らせると、コア数ぶん
    ///   溜まった時点でアプリの `async` 処理が全部止まる。
    private func readEntryBlocking(_ url: URL, entry: ArchiveEntry, encoding: String.Encoding, maxBytes: Int) throws -> Data {
        // **展開する前に宣言サイズで断る** [IM-02][2026-08 全体点検 F2]。
        // `qoo_unrar_extract_one` は上限を受け取れない一括 API のため、
        // 事後チェックだけだと巨大エントリの全量が一時ファイル（＝起動
        // ボリューム）へ書き出されてから捨てられる——上限 512MB のつもりが
        // 数十 GB のエントリで起動ボリュームを埋め得る。宣言値は信用しない
        // 方針 [EX-20] なので、これは事後の実測チェックの**代わり**ではなく
        // **前段**（宣言値が正直な普通のアーカイブで無駄な書き出しを避ける）。
        // 小さく偽った宣言値は従来どおり展開後の実測チェックが捕まえる。
        if entry.uncompressedSize > Int64(maxBytes) {
            throw ExtractError.entryReadLimitExceeded(limit: maxBytes)
        }
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let tempFile = tempDir.appendingPathComponent("entry")

        var errorBuffer = [CChar](repeating: 0, count: 512)
        let rc: Int32 = errorBuffer.withUnsafeMutableBufferPointer { errBuf in
            url.path.withCString { archiveCStr in
                entry.pathname.withCString { entryCStr in
                    tempFile.path.withCString { destCStr in
                        qoo_unrar_extract_one(archiveCStr, entryCStr, destCStr, errBuf.baseAddress, Int32(errBuf.count))
                    }
                }
            }
        }
        guard rc == 0 else {
            if rc == QOO_UNRAR_ERROR_ENTRY_NOT_FOUND {
                throw ExtractError.entryNotFound(entry.pathname)
            }
            throw ExtractError.backendFailure(Self.errorMessage(from: errorBuffer, code: rc))
        }

        let size = (try? FileManager.default.attributesOfItem(atPath: tempFile.path)[.size] as? Int) ?? nil
        if let size, size > maxBytes {
            throw ExtractError.entryReadLimitExceeded(limit: maxBytes)
        }
        return try Data(contentsOf: tempFile)
    }

    // MARK: - QooUnrarBridge の呼び出し

    /// コールバックとやり取りする箱。一覧（`list`）と展開（`extractAll`）で
    /// 同じコールバックを共有し、どちらの用途かは詰めた中身で決まる。
    private final class CallbackBox {
        /// 一覧用。展開時は集めない（数万件を二重に持つ意味が無い）。
        var collectsEntries = true
        var entries: [ArchiveEntry] = []
        /// 展開用。
        var progress: ProgressReporter?
        var pauseToken: PauseToken?
        var writtenBytes: Int64 = 0
        var fileCount = 0
    }

    /// **戻り値 0 で続行、非 0 で中断**（`QooUnrarBridge.h` 参照）。
    /// C の関数ポインタへ変換されるため、外の値を捕捉してはならない。
    private static let entryCallback: QooUnrarEntryCallback = { entryPtr, contextPtr in
        guard let entryPtr, let contextPtr else { return 0 }
        let box = Unmanaged<CallbackBox>.fromOpaque(contextPtr).takeUnretainedValue()
        // `utf8Path` は注釈の無い C ポインタ（IUO）。ブリッジ側は非 nil を
        // 保証するようになったが、NULL のまま `String(cString:)` へ渡すと
        // トラップするため、こちらでも受け止める［フェーズ1完了時の監査で
        // 追加した二重の守り］。
        guard let namePtr = entryPtr.pointee.utf8Path else { return 0 }
        let name = String(cString: namePtr)
        // 宣言サイズは攻撃者が自由に書ける uint64。素の `Int64(_:)` は
        // `Int64.max` を超える値でトラップする [`Int64.addingClamped` 参照]。
        let size = Int64(clamping: entryPtr.pointee.unpackedSize)
        let isDirectory = entryPtr.pointee.isDirectory != 0
        if box.collectsEntries {
            // QooUnrarBridge の C API はシンボリックリンク／特殊ファイルの情報を
            // 公開していないため、常に false として扱う [既知の制限]。
            box.entries.append(ArchiveEntry(
                pathname: name, uncompressedSize: size, isDirectory: isDirectory,
                isSymlink: false, isSpecialEntry: false
            ))
        }
        if !isDirectory {
            // 総数は `SecureExtractor` がディレクトリを除いて数えているので、
            // こちらも数えない（進捗が総数を超えないようにする）。
            box.fileCount += 1
            // 宣言サイズの合算は飽和させる（素の `+=` は細工されたヘッダで
            // トラップする）[`Int64.addingClamped` 参照]。
            box.writtenBytes = box.writtenBytes.addingClamped(size)
        }
        box.progress?.report(OperationProgress(
            completedBytes: box.writtenBytes,
            completedItems: box.fileCount,
            currentItemName: (name as NSString).lastPathComponent
        ))
        // 一時停止はここで待つ。待っている間もキャンセルは効く。
        box.pauseToken?.waitWhilePaused()
        return Cancellation.isRequested ? 1 : 0
    }

    private static func list(_ url: URL) throws -> [ArchiveEntry] {
        let box = CallbackBox()
        box.collectsEntries = true
        let boxPtr = Unmanaged.passUnretained(box).toOpaque()
        var errorBuffer = [CChar](repeating: 0, count: 512)

        let rc: Int32 = errorBuffer.withUnsafeMutableBufferPointer { errBuf in
            url.path.withCString { archiveCStr in
                qoo_unrar_list(archiveCStr, entryCallback, boxPtr, errBuf.baseAddress, Int32(errBuf.count))
            }
        }
        if rc == QOO_UNRAR_ERROR_CANCELLED { throw ExtractError.cancelled }
        guard rc == 0 else {
            throw ExtractError.backendFailure(Self.errorMessage(from: errorBuffer, code: rc))
        }
        return box.entries
    }

    private static func extractAll(_ url: URL, to destination: URL, box: CallbackBox) throws {
        let boxPtr = Unmanaged.passUnretained(box).toOpaque()
        var errorBuffer = [CChar](repeating: 0, count: 512)

        let rc: Int32 = errorBuffer.withUnsafeMutableBufferPointer { errBuf in
            url.path.withCString { archiveCStr in
                destination.path.withCString { destCStr in
                    qoo_unrar_extract_all(
                        archiveCStr, destCStr, entryCallback, boxPtr,
                        errBuf.baseAddress, Int32(errBuf.count)
                    )
                }
            }
        }
        // 中断は失敗ではない。ここまでに書いたものはステージングにしか無く、
        // `SecureExtractor` の `defer` が丸ごと捨てる [EX-24]。
        if rc == QOO_UNRAR_ERROR_CANCELLED { throw ExtractError.cancelled }
        guard rc == 0 else {
            throw ExtractError.backendFailure(Self.errorMessage(from: errorBuffer, code: rc))
        }
    }

    private static func errorMessage(from buffer: [CChar], code: Int32) -> String {
        let nullIndex = buffer.firstIndex(of: 0) ?? buffer.endIndex
        let message = String(decoding: buffer[..<nullIndex].map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return message.isEmpty ? "UnRAR error \(code)" : message
    }

    private static func directorySize(_ url: URL) throws -> Int64 {
        var total: Int64 = 0
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]
        ) else { return 0 }
        for case let fileURL as URL in enumerator {
            let values = try fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values.isRegularFile == true {
                total += Int64(values.fileSize ?? 0)
            }
        }
        return total
    }
}
#endif
