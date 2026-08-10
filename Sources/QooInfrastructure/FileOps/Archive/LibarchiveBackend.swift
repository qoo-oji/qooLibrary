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

    /// [AR-02][9.2 節] zip/7z の UTF-8 フラグ未設定時のエンコーディングを
    /// この 1 回のアーカイブ走査で判定し、返却する `ArchiveEntry.pathname` は
    /// すべてその判定結果でデコード済みにする。`ArchiveListing.detectedEncoding`
    /// を `SecureExtractor` が `extract` の `ExtractOptions.encoding` へ引き
    /// 継ぐことで、`extract` 側は再判定なしに同じデコード結果を再現できる。
    public func listEntries(_ url: URL) async throws -> ArchiveListing {
        let applyHeuristic = Self.shouldApplyEncodingHeuristic(for: url) // [AR-03]

        let reader = try Self.openReader(url)
        defer { Self.closeReader(reader) }

        var rawEntries: [RawEntry] = []
        while true {
            var entryPtr: OpaquePointer?
            let rc = archive_read_next_header(reader, &entryPtr)
            if rc == ARCHIVE_EOF { break }
            guard rc == ARCHIVE_OK, let entryPtr else {
                throw ExtractError.backendFailure(Self.errorMessage(reader))
            }
            rawEntries.append(Self.makeRawEntry(entryPtr))
            archive_read_data_skip(reader)
        }

        let encoding = Self.detectEncoding(rawEntries.map(\.rawPathnameBytes), applyHeuristic: applyHeuristic)
        let entries = rawEntries.map { raw in
            ArchiveEntry(
                pathname: Self.decode(raw.rawPathnameBytes, encoding: encoding),
                uncompressedSize: raw.uncompressedSize,
                isDirectory: raw.isDirectory,
                isSymlink: raw.isSymlink,
                isSpecialEntry: raw.isSpecialEntry
            )
        }
        return ArchiveListing(entries: entries, detectedEncoding: encoding)
    }

    /// [EX-01〜EX-24] ステージングへの展開。パス検証（EX-10〜EX-15）と
    /// 展開爆弾対策（EX-20〜EX-21、実バイト数をその場で計測）を行う。
    /// 圧縮比の分母はアーカイブファイル自身の圧縮後サイズを使う。
    public func extract(_ url: URL, to staging: URL, options: ExtractOptions) async throws -> ExtractResult {
        let fm = FileManager.default
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)

        let archiveFileSize = (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? nil
        let compressedSizeDenominator = Double(max(archiveFileSize ?? 1, 1))
        // [AR-02] 通常は `SecureExtractor` が `listEntries` の判定結果を
        // `options.encoding` に積んで渡してくる。直接 `extract` だけを呼ぶ
        // 呼び出し方（テスト等）のために UTF-8 へのフォールバックも用意する。
        let encoding = options.encoding ?? .utf8

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

            let raw = Self.makeRawEntry(entryPtr)
            let entry = ArchiveEntry(
                pathname: Self.decode(raw.rawPathnameBytes, encoding: encoding),
                uncompressedSize: raw.uncompressedSize,
                isDirectory: raw.isDirectory,
                isSymlink: raw.isSymlink,
                isSpecialEntry: raw.isSpecialEntry
            )
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

    /// 圧縮 [AR-10][AR-11]。zip のみ対応する（RAR は読み取り専用
    /// [AR-05][OS-06][LC-17]）。書き込み可能な形式が zip 一択で、
    /// libarchive 以外の書き込みバックエンドを想定する具体的な理由が無いため
    /// `ArchiveReading` のようなバックエンド抽象化・プロトコルは導入しない
    /// [YAGNI]。呼び出し側（`ArchiveCompressor`）がステージングへの書き込み
    /// をこのメソッドに任せ、完成した単一の zip だけを
    /// `FileOperationService` 経由で最終位置へ移す。
    public func compress(_ items: [URL], to destinationZip: URL) async throws {
        guard let writer = archive_write_new() else {
            throw ExtractError.backendFailure("archive_write_new returned NULL")
        }
        defer { archive_write_free(writer) }

        archive_write_set_format_zip(writer)

        guard archive_write_open_filename(writer, destinationZip.path) == ARCHIVE_OK else {
            throw ExtractError.backendFailure(Self.errorMessage(writer))
        }

        for item in items {
            try Self.addRecursively(item, pathname: item.lastPathComponent, to: writer)
        }

        guard archive_write_close(writer) == ARCHIVE_OK else {
            throw ExtractError.backendFailure(Self.errorMessage(writer))
        }
    }

    private static func addRecursively(_ url: URL, pathname: String, to writer: OpaquePointer) throws {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return }

        if isDirectory.boolValue {
            try Self.addDirectoryEntry(pathname: pathname + "/", to: writer)
            let children = try fm.contentsOfDirectory(
                at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            )
            for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                try addRecursively(child, pathname: pathname + "/" + child.lastPathComponent, to: writer)
            }
        } else {
            try Self.addFileEntry(url, pathname: pathname, to: writer)
        }
    }

    /// [設計判断][9.4 節] エントリ名は NFC に正規化してから UTF-8 として
    /// 明示的に書き込む。macOS の Foundation API は濁点・半濁点等を結合文字
    /// に分解した NFD でファイル名を返すことが多く、そのまま zip に書くと
    /// NFC を前提とする Windows 側の展開ツールで文字化けする
    /// （Mac 製 zip アーカイバでよく知られた問題）。
    private static func normalizedUTF8Pathname(_ pathname: String) -> String {
        pathname.precomposedStringWithCanonicalMapping
    }

    private static func addDirectoryEntry(pathname: String, to writer: OpaquePointer) throws {
        guard let entryPtr = archive_entry_new() else {
            throw ExtractError.backendFailure("archive_entry_new returned NULL")
        }
        defer { archive_entry_free(entryPtr) }

        // `archive_entry_set_pathname_utf8` は内部で「現在のロケール」向けの
        // 互換フィールドも同時に導出しようとし、Swift プロセスのように
        // ロケールが未初期化な環境（常に "C"/POSIX）では
        // "Can't translate pathname ... to current locale" で失敗する
        // （実測で確認済み）。プロセス全体に影響する `setlocale` の副作用を
        // 避けるため、ロケールに依存しない素の `archive_entry_set_pathname`
        // へ、正規化済みの UTF-8 バイト列をそのまま渡す（Swift の `String` →
        // C 文字列変換は常に UTF-8）。
        archive_entry_set_pathname(entryPtr, Self.normalizedUTF8Pathname(pathname))
        archive_entry_set_perm(entryPtr, 0o755)
        archive_entry_set_filetype(entryPtr, UInt32(modeTypeDirectory))
        archive_entry_set_size(entryPtr, 0)
        guard archive_write_header(writer, entryPtr) == ARCHIVE_OK else {
            throw ExtractError.backendFailure(Self.errorMessage(writer))
        }
    }

    private static func addFileEntry(_ url: URL, pathname: String, to writer: OpaquePointer) throws {
        guard let entryPtr = archive_entry_new() else {
            throw ExtractError.backendFailure("archive_entry_new returned NULL")
        }
        defer { archive_entry_free(entryPtr) }

        let fm = FileManager.default
        let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? nil

        // `archive_entry_set_pathname_utf8` は内部で「現在のロケール」向けの
        // 互換フィールドも同時に導出しようとし、Swift プロセスのように
        // ロケールが未初期化な環境（常に "C"/POSIX）では
        // "Can't translate pathname ... to current locale" で失敗する
        // （実測で確認済み）。プロセス全体に影響する `setlocale` の副作用を
        // 避けるため、ロケールに依存しない素の `archive_entry_set_pathname`
        // へ、正規化済みの UTF-8 バイト列をそのまま渡す（Swift の `String` →
        // C 文字列変換は常に UTF-8）。
        archive_entry_set_pathname(entryPtr, Self.normalizedUTF8Pathname(pathname))
        archive_entry_set_perm(entryPtr, 0o644)
        archive_entry_set_filetype(entryPtr, UInt32(modeTypeRegularFile))
        archive_entry_set_size(entryPtr, la_int64_t(size ?? 0))
        guard archive_write_header(writer, entryPtr) == ARCHIVE_OK else {
            throw ExtractError.backendFailure(Self.errorMessage(writer))
        }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let bufferSize = 256 * 1024
        while let chunk = try handle.read(upToCount: bufferSize), !chunk.isEmpty {
            chunk.withUnsafeBytes { ptr in
                _ = archive_write_data(writer, ptr.baseAddress, chunk.count)
            }
        }
        archive_write_finish_entry(writer)
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
    private static let modeTypeRegularFile: mode_t = 0o100000
    private static let modeTypeDirectory: mode_t = 0o040000
    private static let modeTypeSymlink: mode_t = 0o120000
    private static let modeTypeSocket: mode_t = 0o140000
    private static let modeTypeCharDevice: mode_t = 0o020000
    private static let modeTypeBlockDevice: mode_t = 0o060000
    private static let modeTypeFIFO: mode_t = 0o010000

    /// デコード前の生バイト列を保持するエントリ。`archive_entry_pathname`
    /// が返す `const char *` は、zip の UTF-8 フラグが立っていなければ
    /// アーカイブに格納されたバイト列をほぼそのまま返す（libarchive 自身は
    /// 積極的な文字コード変換をしない）。ここを `String(cString:)` で直接
    /// 文字列化すると、有効な UTF-8 でないバイト列は U+FFFD に置換されて
    /// 元の文字が失われる（実機検証で Shift_JIS 名の zip が文字化けした
    /// 原因）。そのため一度 `Data` のまま保持し、`ArchiveNameEncodingHeuristic`
    /// の判定結果で改めてデコードする [AR-02]。
    private struct RawEntry {
        let rawPathnameBytes: Data
        let uncompressedSize: Int64
        let isDirectory: Bool
        let isSymlink: Bool
        let isSpecialEntry: Bool
    }

    private static func rawPathnameBytes(_ entryPtr: OpaquePointer) -> Data {
        guard let cString = archive_entry_pathname(entryPtr) else { return Data() }
        return Data(bytes: cString, count: strlen(cString))
    }

    private static func makeRawEntry(_ entryPtr: OpaquePointer) -> RawEntry {
        let rawBytes = Self.rawPathnameBytes(entryPtr)
        let filetype = archive_entry_filetype(entryPtr) & modeTypeMask
        let isDirectory = filetype == modeTypeDirectory || rawBytes.last == UInt8(ascii: "/")
        let isSymlink = filetype == modeTypeSymlink
        let isSpecial = filetype == modeTypeSocket || filetype == modeTypeCharDevice
            || filetype == modeTypeBlockDevice || filetype == modeTypeFIFO
            || archive_entry_hardlink_is_set(entryPtr) != 0
        let size = archive_entry_size_is_set(entryPtr) != 0 ? archive_entry_size(entryPtr) : 0
        return RawEntry(
            rawPathnameBytes: rawBytes,
            uncompressedSize: size,
            isDirectory: isDirectory,
            isSymlink: isSymlink,
            isSpecialEntry: isSpecial
        )
    }

    /// 指定エンコーディングでデコードする。失敗したら（判定が外れていた等）
    /// 無応答よりはマシなので、読める文字だけでも残す最終手段として
    /// 不正なバイト列を置換文字に変えつつ UTF-8 として解釈する。
    ///
    /// 最後に NFC へ正規化する。libarchive（内部で使う iconv 実装）は
    /// macOS 上で zip のパス名を読む際、実際にディスクへ書かれているバイト列
    /// が NFC でも、読み出し時に HFS+ 互換の NFD へ分解して返すことがある
    /// （`compress` で書いた zip を Python の `zipfile` で直接調べると NFC の
    /// ままだが、同じファイルをこの `LibarchiveBackend` で読み直すと NFD に
    /// なる、という実測で確認した挙動）。書き込み時の正規化（9.4 節）だけでは
    /// 往復一貫性が保てないため、読み込み側でも矯正する。
    private static func decode(_ rawBytes: Data, encoding: String.Encoding) -> String {
        let decoded = String(data: rawBytes, encoding: encoding) ?? String(decoding: rawBytes, as: UTF8.self)
        return decoded.precomposedStringWithCanonicalMapping
    }

    /// 対象は zip / 7z のみ [AR-03]。RAR はアーカイブ自身がエンコーディング
    /// 情報を持つため対象外（`QooUnrarBridge` は最初から UTF-8 で返す）。
    /// tar.gz も慣例的に UTF-8 のため対象外とする。
    private static func shouldApplyEncodingHeuristic(for url: URL) -> Bool {
        switch ArchiveFormat.from(filename: url.lastPathComponent) {
        case .zip, .sevenZip: true
        case .rar, .tarGz, nil: false
        }
    }

    private static func detectEncoding(_ rawNames: [Data], applyHeuristic: Bool) -> String.Encoding {
        guard applyHeuristic else { return .utf8 }
        // 全エントリが有効な UTF-8 としてデコードできるなら、実質的に
        // UTF-8 フラグが立っていた場合と同じとみなしてよい [EN-04]。
        if rawNames.allSatisfy({ String(data: $0, encoding: .utf8) != nil }) {
            return .utf8
        }
        return ArchiveNameEncodingHeuristic.evaluate(rawNames: rawNames).first?.encoding ?? .utf8
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
