import CLibarchive
import Foundation
import QooKit

/// zip/7z/tarGz の読み取り [AR-01][LC-14]。`PERMISSIVE_ONLY_BUILD` では
/// UnRAR を組み込まないため、RAR もここ（libarchive 自身の RAR リーダー）
/// で読む [LC-12][LC-13]。
///
/// `extract` はステージングディレクトリ（ユーザーに見えないアプリ内部の
/// 一時領域）へ直接 `FileManager` で書き込む。`SecureExtractor` のコメントに
/// ある通り、期待変更台帳・Undo の対象外のため `FileOperationService` を
/// 経由しない意図的な例外であり、そのため B-10 の対象外ディレクトリ
/// （`QooInfrastructure/FileOps/`）配下に置いている。
public struct LibarchiveBackend: ArchiveReading {
    public static let shared = LibarchiveBackend()

    public var supportedFormats: Set<ArchiveFormat> {
        #if PERMISSIVE_ONLY_BUILD
        [.zip, .sevenZip, .tarGz, .rar]
        #else
        [.zip, .sevenZip, .tarGz]
        #endif
    }

    public init() {}

    public func canRead(_ url: URL) async -> Bool {
        guard let format = ArchiveFormat.from(filename: url.lastPathComponent) else { return false }
        return supportedFormats.contains(format)
    }

    public func listEntries(_ url: URL) async throws -> ArchiveListing {
        let reader = try Self.openReader(url)
        defer { Self.closeReader(reader) }

        var entries: [ArchiveEntry] = []
        while true {
            var entryPtr: OpaquePointer?
            let rc = archive_read_next_header(reader, &entryPtr)
            if rc == ARCHIVE_EOF { break }
            guard rc == ARCHIVE_OK, let entryPtr else {
                throw ExtractError.backendFailure(Self.errorMessage(reader))
            }
            entries.append(Self.makeEntry(entryPtr))
            archive_read_data_skip(reader)
        }
        return ArchiveListing(entries: entries)
    }

    /// [EX-01〜EX-24] ステージングへの展開。パス検証（EX-10〜EX-15）と
    /// 展開爆弾対策（EX-20〜EX-21、実バイト数をその場で計測）を行う。
    /// 圧縮比の分母はアーカイブファイル自身の圧縮後サイズを使う。
    public func extract(_ url: URL, to staging: URL, options: ExtractOptions) async throws -> ExtractResult {
        let fm = FileManager.default
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)

        let archiveFileSize = (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? nil
        let compressedSizeDenominator = Double(max(archiveFileSize ?? 1, 1))

        let reader = try Self.openReader(url)
        defer { Self.closeReader(reader) }

        var extractedCount = 0
        var rejected: [ExtractRejection] = []
        var renamed: [ExtractRename] = []
        var totalWritten: Int64 = 0
        var seenLowercasedPaths: Set<String> = []
        var entryCount = 0

        while true {
            if Task.isCancelled { throw ExtractError.cancelled }

            var entryPtr: OpaquePointer?
            let rc = archive_read_next_header(reader, &entryPtr)
            if rc == ARCHIVE_EOF { break }
            guard rc == ARCHIVE_OK, let entryPtr else {
                throw ExtractError.backendFailure(Self.errorMessage(reader))
            }

            entryCount += 1
            if entryCount > options.limits.maxEntries { // [EX-21]
                throw ExtractError.tooManyEntries(limit: options.limits.maxEntries)
            }

            let entry = Self.makeEntry(entryPtr)
            let validation = EntryPathValidation.validate(
                pathname: entry.pathname,
                isDirectory: entry.isDirectory,
                isSymlink: entry.isSymlink,
                isSpecialEntry: entry.isSpecialEntry,
                followSymlinks: options.followSymlinks,
                stagingRoot: staging
            )

            var validated: EntryPathValidation.ValidatedEntry
            switch validation {
            case .accepted(let entry):
                validated = entry
            case .rejected(let reason):
                rejected.append(ExtractRejection(entry: entry.pathname, reason: reason))
                archive_read_data_skip(reader)
                continue
            }

            if entry.isDirectory {
                try fm.createDirectory(at: validated.targetURL, withIntermediateDirectories: true)
                archive_read_data_skip(reader)
                continue
            }

            // 大文字小文字のみ異なるエントリの衝突 [EX-15]
            let lowerKey = validated.relativePath.lowercased()
            if seenLowercasedPaths.contains(lowerKey) {
                let renamedURL = Self.nextAvailableName(for: validated.targetURL)
                renamed.append(ExtractRename(from: validated.relativePath, to: renamedURL.lastPathComponent))
                validated = EntryPathValidation.ValidatedEntry(relativePath: validated.relativePath, targetURL: renamedURL)
            }
            seenLowercasedPaths.insert(lowerKey)

            try fm.createDirectory(at: validated.targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard fm.createFile(atPath: validated.targetURL.path, contents: nil) else {
                throw ExtractError.backendFailure("could not create \(validated.targetURL.path)")
            }
            let handle = try FileHandle(forWritingTo: validated.targetURL)

            let bufferSize = 256 * 1024
            var buffer = [UInt8](repeating: 0, count: bufferSize)
            extractEntry: while true {
                let bytesRead = buffer.withUnsafeMutableBytes { ptr in
                    archive_read_data(reader, ptr.baseAddress, bufferSize)
                }
                if bytesRead < 0 {
                    try? handle.close()
                    throw ExtractError.backendFailure(Self.errorMessage(reader))
                }
                if bytesRead == 0 { break extractEntry }

                // 宣言された非圧縮サイズを信用せず、書き出し中の実バイト数で
                // 判定する [EX-20]。
                totalWritten += Int64(bytesRead)
                if totalWritten > options.limits.maxUncompressedBytes {
                    try? handle.close()
                    throw ExtractError.expansionLimitExceeded(limit: options.limits.maxUncompressedBytes)
                }
                let ratio = Double(totalWritten) / compressedSizeDenominator
                if ratio > options.limits.ratioAbort {
                    try? handle.close()
                    throw ExtractError.compressionRatioExceeded(limit: options.limits.ratioAbort)
                }

                handle.write(Data(bytes: buffer, count: bytesRead))

                if Task.isCancelled {
                    try? handle.close()
                    throw ExtractError.cancelled
                }
            }
            try handle.close()
            extractedCount += 1
        }

        return ExtractResult(
            extractedCount: extractedCount,
            rejected: rejected,
            renamedForCaseCollision: renamed,
            totalBytesWritten: totalWritten
        )
    }

    // MARK: - libarchive の薄いラッパー

    private static func openReader(_ url: URL) throws -> OpaquePointer {
        guard let a = archive_read_new() else {
            throw ExtractError.backendFailure("archive_read_new returned NULL")
        }
        archive_read_support_filter_all(a)
        archive_read_support_format_all(a)
        let rc = archive_read_open_filename(a, url.path, 64 * 1024)
        guard rc == ARCHIVE_OK else {
            let message = String(cString: archive_error_string(a))
            archive_read_free(a)
            throw ExtractError.backendFailure(message)
        }
        return a
    }

    private static func closeReader(_ a: OpaquePointer) {
        archive_read_close(a)
        archive_read_free(a)
    }

    private static func errorMessage(_ a: OpaquePointer) -> String {
        String(cString: archive_error_string(a))
    }

    // `AE_IFDIR` 等の C マクロは `((__LA_MODE_T)0040000)` という cast 式のため
    // ClangImporter がインポートできない。POSIX の st_mode ビットパターン
    // （archive_entry.h の定義と同値）をそのまま数値リテラルで持つ。整数
    // リテラルは `archive_entry_filetype` の戻り値の型に自動適合するため、
    // 具体的な型（macOS では mode_t = UInt16）を意識しなくてよい。
    private static let modeTypeMask: mode_t = 0o170000
    private static let modeTypeDirectory: mode_t = 0o040000
    private static let modeTypeSymlink: mode_t = 0o120000
    private static let modeTypeSocket: mode_t = 0o140000
    private static let modeTypeCharDevice: mode_t = 0o020000
    private static let modeTypeBlockDevice: mode_t = 0o060000
    private static let modeTypeFIFO: mode_t = 0o010000

    private static func makeEntry(_ entryPtr: OpaquePointer) -> ArchiveEntry {
        let rawName = String(cString: archive_entry_pathname(entryPtr))
        let filetype = archive_entry_filetype(entryPtr) & modeTypeMask
        let isDirectory = filetype == modeTypeDirectory || rawName.hasSuffix("/")
        let isSymlink = filetype == modeTypeSymlink
        let isSpecial = filetype == modeTypeSocket || filetype == modeTypeCharDevice
            || filetype == modeTypeBlockDevice || filetype == modeTypeFIFO
            || archive_entry_hardlink_is_set(entryPtr) != 0
        let size = archive_entry_size_is_set(entryPtr) != 0 ? archive_entry_size(entryPtr) : 0
        return ArchiveEntry(
            pathname: rawName,
            uncompressedSize: size,
            isDirectory: isDirectory,
            isSymlink: isSymlink,
            isSpecialEntry: isSpecial
        )
    }

    /// Finder に倣い `name 2.ext` の形式で連番を付与する（`FileOperationService`
    /// と同じ規則、ただし展開処理はステージング配下でしか動かないため独立実装）。
    private static func nextAvailableName(for url: URL) -> URL {
        let ext = url.pathExtension
        let base = ext.isEmpty ? url.lastPathComponent : String(url.lastPathComponent.dropLast(ext.count + 1))
        let directory = url.deletingLastPathComponent()
        var n = 2
        while true {
            let candidateName = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            let candidate = directory.appendingPathComponent(candidateName)
            if !FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            n += 1
        }
    }
}
