#if !PERMISSIVE_ONLY_BUILD
import Foundation
import QooKit
import QooUnrarBridge

/// RAR の読み取り [AR-01b][LC-11]。`PERMISSIVE_ONLY_BUILD` ではこのファイル
/// 自体が `Package.swift` からビルド対象外になり、`LibarchiveBackend`
/// （libarchive 自身の RAR リーダー）にフォールバックする [LC-12][LC-13]。
///
/// `QooUnrarBridge` は UnRAR の RARDLL API を薄くラップしたもので、
/// `qoo_unrar_extract_all` は **すべてのエントリを一括で** 展開先ディレクトリ
/// へ直接書き出す（libarchive のようなエントリ単位のストリーミング取得や
/// 途中キャンセルはできない）[設計判断]。そのため libarchive バックエンドと
/// 異なり、
/// - 展開爆弾対策（実バイト数によるリアルタイム中断 [EX-20]）は不可能なので、
///   展開完了後にステージング全体の実サイズを検証し、超過していれば
///   ステージングごと破棄する事後チェックにしている。
/// - エントリ単位の安全でないパスは、展開前の一覧取得（`qoo_unrar_list`）で
///   検出し、1件でもあればアーカイブ全体を拒否する（部分展開はできない）。
/// より踏み込んだ対応（UnRAR の `UCM_PROCESSDATA` コールバックを使った
/// バイト単位の途中中断）が必要になった場合は `QooUnrarBridge.mm` の拡張を
/// 検討する（ライセンス上は自作ラッパーなので改変は問題ない。改変対象は
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
        let entries = try Self.list(url)
        return ArchiveListing(entries: entries)
    }

    public func extract(_ url: URL, to staging: URL, options: ExtractOptions) async throws -> ExtractResult {
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

        if Task.isCancelled { throw ExtractError.cancelled }
        try Self.extractAll(url, to: staging)
        if Task.isCancelled { throw ExtractError.cancelled }

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

    private final class CallbackBox {
        var entries: [ArchiveEntry] = []
    }

    private static let entryCallback: QooUnrarEntryCallback = { entryPtr, contextPtr in
        guard let entryPtr, let contextPtr else { return }
        let box = Unmanaged<CallbackBox>.fromOpaque(contextPtr).takeUnretainedValue()
        let name = String(cString: entryPtr.pointee.utf8Path)
        let size = Int64(entryPtr.pointee.unpackedSize)
        let isDirectory = entryPtr.pointee.isDirectory != 0
        // QooUnrarBridge の C API はシンボリックリンク／特殊ファイルの情報を
        // 公開していないため、常に false として扱う [既知の制限]。
        box.entries.append(ArchiveEntry(
            pathname: name, uncompressedSize: size, isDirectory: isDirectory,
            isSymlink: false, isSpecialEntry: false
        ))
    }

    private static func list(_ url: URL) throws -> [ArchiveEntry] {
        let box = CallbackBox()
        let boxPtr = Unmanaged.passUnretained(box).toOpaque()
        var errorBuffer = [CChar](repeating: 0, count: 512)

        let rc: Int32 = errorBuffer.withUnsafeMutableBufferPointer { errBuf in
            url.path.withCString { archiveCStr in
                qoo_unrar_list(archiveCStr, entryCallback, boxPtr, errBuf.baseAddress, Int32(errBuf.count))
            }
        }
        guard rc == 0 else {
            throw ExtractError.backendFailure(Self.errorMessage(from: errorBuffer, code: rc))
        }
        return box.entries
    }

    private static func extractAll(_ url: URL, to destination: URL) throws {
        let box = CallbackBox()
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
