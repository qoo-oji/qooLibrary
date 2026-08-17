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
        try await FileIO.perform { try self.listEntriesBlocking(url) }
    }

    /// - Note: **ブロッキング。`FileIO.perform` の中からのみ呼ぶ** [NV6-01]。
    ///   アーカイブの読み書きは相手がネットワーク上なら往復が多く、応答が
    ///   無ければ戻ってこない。協調スレッドプールの上で走らせると、コア数ぶん
    ///   溜まった時点でアプリの `async` 処理が全部止まる。
    private func listEntriesBlocking(_ url: URL) throws -> ArchiveListing {
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
        try await FileIO.perform { try self.extractBlocking(url, to: staging, options: options) }
    }

    /// - Note: **ブロッキング。`FileIO.perform` の中からのみ呼ぶ** [NV6-01]。
    ///   アーカイブの読み書きは相手がネットワーク上なら往復が多く、応答が
    ///   無ければ戻ってこない。協調スレッドプールの上で走らせると、コア数ぶん
    ///   溜まった時点でアプリの `async` 処理が全部止まる。
    private func extractBlocking(_ url: URL, to staging: URL, options: ExtractOptions) throws -> ExtractResult {
        let fm = FileManager.default
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)

        let archiveFileSize = (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? nil
        let compressedSizeDenominator = Double(max(archiveFileSize ?? 1, 1))
        // [AR-02] 通常は `SecureExtractor` が `listEntries` の判定結果を
        // `options.encoding` に積んで渡してくる。直接 `extract` だけを呼ぶ
        // 呼び出し方（テスト等）のために UTF-8 へのフォールバックも用意する。
        let encoding = options.encoding ?? .utf8

        let reader = try Self.openReader(url, passphrase: options.passphrase)
        defer { Self.closeReader(reader) }

        var extractedCount = 0
        var rejected: [ExtractRejection] = []
        var renamed: [ExtractRename] = []
        var totalWritten: Int64 = 0
        var seenLowercasedPaths: Set<String> = []
        var entryCount = 0

        while true {
            if Cancellation.isRequested { throw ExtractError.cancelled }
            options.pauseToken?.waitWhilePaused()
            if Cancellation.isRequested { throw ExtractError.cancelled }

            var entryPtr: OpaquePointer?
            let rc = archive_read_next_header(reader, &entryPtr)
            if rc == ARCHIVE_EOF { break }
            guard rc == ARCHIVE_OK, let entryPtr else {
                let message = Self.errorMessage(reader)
                throw Self.passphraseError(from: message) ?? ExtractError.backendFailure(message)
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
                // **理由を捨てない** [ER-03]。以前はパスだけを英語で並べており、
                // 「なぜ作れないのか」（空き容量／権限／名前が長すぎる）が
                // ユーザーにもログにも残らなかった。`createFile` は失敗を
                // Bool でしか返さないので、直後の `errno` を読む。
                throw ExtractError.writeFailed(reason: PosixFailure.reason(errno) + (PosixFailure.recovery(errno).map { " " + $0 } ?? ""))
            }
            let handle = try FileHandle(forWritingTo: validated.targetURL)
            // 後始末を `defer` に一本化する。以前は throw のたびに
            // `try? handle.close()` を並べており、このループは中断・上限超過・
            // 書き込み失敗と抜け道が 6 つあって読みづらかった。
            //
            // - Note: **資源リークの修正ではない。** `FileHandle` は解放時に
            //   fd を閉じる（`throw` で抜けた場合も含めて実測で確認済み）ので、
            //   以前の書き方でも漏れてはいなかった。閉じる時点を明示にして、
            //   後から `throw` を足したときに考えなくて済むようにするためのもの。
            //
            // 正常終了時だけは `try` で閉じて**失敗を伝える** — 書き込みの
            // 最終フラッシュはここで失敗し得る（空き容量が尽きた場合など）。
            var closed = false
            defer { if !closed { try? handle.close() } }

            let bufferSize = 256 * 1024
            var buffer = [UInt8](repeating: 0, count: bufferSize)
            extractEntry: while true {
                let bytesRead = buffer.withUnsafeMutableBytes { ptr in
                    archive_read_data(reader, ptr.baseAddress, bufferSize)
                }
                if bytesRead < 0 {
                    let message = Self.errorMessage(reader)
                    throw Self.passphraseError(from: message, suppliedPassphrase: options.passphrase != nil)
                        ?? ExtractError.backendFailure(message)
                }
                if bytesRead == 0 { break extractEntry }

                // 宣言された非圧縮サイズを信用せず、書き出し中の実バイト数で
                // 判定する [EX-20]。
                totalWritten += Int64(bytesRead)
                if totalWritten > options.limits.maxUncompressedBytes {
                    throw ExtractError.expansionLimitExceeded(limit: options.limits.maxUncompressedBytes)
                }
                let ratio = Double(totalWritten) / compressedSizeDenominator
                if ratio > options.limits.ratioAbort {
                    throw ExtractError.compressionRatioExceeded(limit: options.limits.ratioAbort)
                }

                // **`write(contentsOf:)`（throwing 版）でなければならない。**
                // 非 throwing の `write(_:)` は失敗を Swift のエラーではなく
                // Objective-C 例外（`NSFileHandleOperationException`）で投げる。
                // Swift はこれを捕捉できないため、**展開先の空きが尽きた瞬間に
                // アプリがそのまま異常終了する**（実測: 20MB のボリュームへ
                // 展開して SIGABRT。同じ事故は SwiftyBeaver でも報告されている）。
                // Apple のドキュメントにも「no free space is left on the file
                // system」で例外を送出すると明記がある。
                do {
                    try handle.write(contentsOf: Data(bytes: buffer, count: bytesRead))
                } catch {
                    throw Self.writeFailure(error)
                }
                // 巨大な 1 エントリでもバーが動くよう、バイト単位でも報告する
                // （間引きは `ProgressThrottle` が行う）。
                options.progress?.report(OperationProgress(
                    completedBytes: totalWritten,
                    completedItems: extractedCount,
                    currentItemName: validated.targetURL.lastPathComponent
                ))

                if Cancellation.isRequested {
                    throw ExtractError.cancelled
                }
                // 巨大な 1 エントリの途中でも止まれるようにする。
                if let token = options.pauseToken, token.isPaused {
                    token.waitWhilePaused()
                    if Cancellation.isRequested {
                            throw ExtractError.cancelled
                    }
                }
            }
            try handle.close()
            closed = true
            extractedCount += 1
            options.progress?.report(OperationProgress(
                completedBytes: totalWritten,
                completedItems: extractedCount,
                currentItemName: validated.targetURL.lastPathComponent
            ))
        }

        return ExtractResult(
            extractedCount: extractedCount,
            rejected: rejected,
            renamedForCaseCollision: renamed,
            totalBytesWritten: totalWritten
        )
    }

    /// [9.6 節] `entry.pathname` に一致するエントリだけを読む。`listEntries`
    /// と同じデコード規則（`encoding` を使い、`decode(_:encoding:)` で
    /// NFC 正規化まで揃える）で都度デコードしながら先頭から走査し、一致した
    /// 時点で内容を読み切って返す。
    public func readEntry(_ url: URL, entry: ArchiveEntry, encoding: String.Encoding, maxBytes: Int) async throws -> Data {
        try await FileIO.perform { try self.readEntryBlocking(url, entry: entry, encoding: encoding, maxBytes: maxBytes) }
    }

    /// - Note: **ブロッキング。`FileIO.perform` の中からのみ呼ぶ** [NV6-01]。
    ///   アーカイブの読み書きは相手がネットワーク上なら往復が多く、応答が
    ///   無ければ戻ってこない。協調スレッドプールの上で走らせると、コア数ぶん
    ///   溜まった時点でアプリの `async` 処理が全部止まる。
    private func readEntryBlocking(_ url: URL, entry: ArchiveEntry, encoding: String.Encoding, maxBytes: Int) throws -> Data {
        let reader = try Self.openReader(url)
        defer { Self.closeReader(reader) }

        while true {
            var entryPtr: OpaquePointer?
            let rc = archive_read_next_header(reader, &entryPtr)
            if rc == ARCHIVE_EOF { throw ExtractError.entryNotFound(entry.pathname) }
            guard rc == ARCHIVE_OK, let entryPtr else {
                throw ExtractError.backendFailure(Self.errorMessage(reader))
            }

            let raw = Self.makeRawEntry(entryPtr)
            guard Self.decode(raw.rawPathnameBytes, encoding: encoding) == entry.pathname else {
                archive_read_data_skip(reader)
                continue
            }
            guard !raw.isDirectory, !raw.isSymlink, !raw.isSpecialEntry else {
                throw ExtractError.backendFailure("not a regular file: \(entry.pathname)")
            }

            var data = Data()
            let bufferSize = 256 * 1024
            var buffer = [UInt8](repeating: 0, count: bufferSize)
            while true {
                let bytesRead = buffer.withUnsafeMutableBytes { ptr in
                    archive_read_data(reader, ptr.baseAddress, bufferSize)
                }
                if bytesRead < 0 { throw ExtractError.backendFailure(Self.errorMessage(reader)) }
                if bytesRead == 0 { break }
                data.append(contentsOf: buffer[0..<bytesRead])
                if data.count > maxBytes { throw ExtractError.entryReadLimitExceeded(limit: maxBytes) } // [IM-02]
            }
            return data
        }
    }

    /// 圧縮 [AR-10][AR-11]。zip/7z に対応する（RAR は読み取り専用
    /// [AR-05][OS-06][LC-17]）。書き込み可能な形式が zip/7z の2つに増えたが、
    /// どちらも libarchive 自身の C API 切替（`archive_write_set_format_*`）で
    /// 完結し、libarchive 以外の書き込みバックエンドを想定する具体的な理由も
    /// 無いため、引き続き `ArchiveReading` のようなバックエンド抽象化・
    /// プロトコルは導入しない [YAGNI]。呼び出し側（`ArchiveCompressor`）が
    /// ステージングへの書き込みをこのメソッドに任せ、完成した単一のアーカイブ
    /// だけを `FileOperationService` 経由で最終位置へ移す。
    ///
    /// **7z は暗号化オプションを持たない**（libarchive の
    /// `archive_write_set_format_7zip.c` を確認済み、`compression`/
    /// `compression-level`/`threads` のみ）。そのため `options.format == .sevenZip`
    /// のときは `options.encryption`/`passphrase` を無視する
    /// （UI 側もこの組み合わせを選ばせない設計だが、防御的にここでも徹底する）。
    public func compress(
        _ items: [URL], to destination: URL, options: CompressionOptions,
        passphrase: String? = nil, progress: ProgressReporter? = nil,
        pauseToken: PauseToken? = nil
    ) async throws {
        try await FileIO.perform {
            try self.compressBlocking(
                items, to: destination, options: options,
                passphrase: passphrase, progress: progress, pauseToken: pauseToken
            )
        }
    }

    /// - Note: **ブロッキング。`FileIO.perform` の中からのみ呼ぶ** [NV6-01]。
    ///   圧縮は全バイトを読み書きするので、相手がネットワーク上なら最も長く
    ///   スレッドを占有する処理になる。
    private func compressBlocking(
        _ items: [URL], to destination: URL, options: CompressionOptions,
        passphrase: String?, progress: ProgressReporter?,
        pauseToken: PauseToken?
    ) throws {
        guard let writer = archive_write_new() else {
            throw ExtractError.backendFailure("archive_write_new returned NULL")
        }
        defer { archive_write_free(writer) }

        switch options.format {
        case .zip:
            archive_write_set_format_zip(writer)
            guard archive_write_set_options(writer, "zip:compression-level=\(options.zipLevel.rawValue)") == ARCHIVE_OK else {
                throw ExtractError.backendFailure(Self.errorMessage(writer))
            }
            if let encryptionValue = options.encryption.zipOptionValue {
                guard archive_write_set_options(writer, "zip:encryption=\(encryptionValue)") == ARCHIVE_OK else {
                    throw ExtractError.backendFailure(Self.errorMessage(writer))
                }
                guard let passphrase, !passphrase.isEmpty else {
                    throw ExtractError.passwordProtected
                }
                guard archive_write_set_passphrase(writer, passphrase) == ARCHIVE_OK else {
                    throw ExtractError.backendFailure(Self.errorMessage(writer))
                }
            }
        case .sevenZip:
            // **暗号化の指定は黙って無視せず拒否する**［フェーズ1完了時の
            // 監査で追加]。libarchive の 7z ライターに暗号化オプションは
            // 存在しないため、ここで受け入れると**パスワードを設定した
            // つもりの平文アーカイブ**ができてしまう。UI 側
            // （`FolderOperations.compressionOptions`）が正規化しているが、
            // 経路が増えても破れないようバックエンドでも守る。
            guard options.encryption == .none, passphrase == nil else {
                throw ExtractError.backendFailure(
                    "7z encryption is not supported; refusing to write an unencrypted archive for an encrypted request"
                )
            }
            archive_write_set_format_7zip(writer)
            guard archive_write_set_options(writer, "7zip:compression=\(options.sevenZipCodec.rawValue)") == ARCHIVE_OK else {
                throw ExtractError.backendFailure(Self.errorMessage(writer))
            }
        }

        guard archive_write_open_filename(writer, destination.path) == ARCHIVE_OK else {
            throw ExtractError.backendFailure(Self.errorMessage(writer))
        }

        var counter = CompressionCounter()
        for item in items {
            try Self.addRecursively(
                item, pathname: item.lastPathComponent, to: writer,
                progress: progress, pauseToken: pauseToken, counter: &counter
            )
        }

        guard archive_write_close(writer) == ARCHIVE_OK else {
            throw ExtractError.backendFailure(Self.errorMessage(writer))
        }
    }

    /// 圧縮の進み具合。ディレクトリを再帰する間、何件・何バイト詰め終えたかを
    /// 持ち回るだけの入れ物（総数は `ArchiveCompressor` が足す）。
    private struct CompressionCounter {
        var files = 0
        var bytes: Int64 = 0
    }

    private static func addRecursively(
        _ url: URL, pathname: String, to writer: OpaquePointer,
        progress: ProgressReporter?, pauseToken: PauseToken?, counter: inout CompressionCounter
    ) throws {
        // 中断・一時停止は項目の境界で受ける [EX-24 と同じ方針]。作りかけの
        // アーカイブはステージングにしか無く、`ArchiveCompressor` の `defer` が
        // 丸ごと捨てるので、途中で止めても半端な成果物は最終位置に残らない。
        if Cancellation.isRequested { throw ExtractError.cancelled }
        pauseToken?.waitWhilePaused()
        if Cancellation.isRequested { throw ExtractError.cancelled }

        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return }

        if isDirectory.boolValue {
            try Self.addDirectoryEntry(pathname: pathname + "/", to: writer)
            let children = try fm.contentsOfDirectory(
                at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            )
            for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                try addRecursively(
                    child, pathname: pathname + "/" + child.lastPathComponent, to: writer,
                    progress: progress, pauseToken: pauseToken, counter: &counter
                )
            }
        } else {
            try Self.addFileEntry(url, pathname: pathname, to: writer)
            counter.files += 1
            counter.bytes += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            progress?.report(OperationProgress(
                completedBytes: counter.bytes,
                completedItems: counter.files,
                currentItemName: url.lastPathComponent
            ))
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
            // **戻り値を捨ててはならない**［フェーズ1完了時の監査で発見]。
            // 以前は `_ =` で握りつぶしており、書き込み途中の失敗（圧縮開始後に
            // 空きが尽きた・I/O エラー）でもループが回り続け、close まで通れば
            // **中身の欠けた zip が「成功」として最終位置へ昇格**していた——
            // 「圧縮…」の上書き保存なら健全な既存アーカイブを壊れたもので
            // 置き換えることになる（監査観点 3 そのもの）。
            let written = chunk.withUnsafeBytes { ptr in
                archive_write_data(writer, ptr.baseAddress, chunk.count)
            }
            guard written == chunk.count else {
                throw ExtractError.backendFailure(
                    written < 0
                        ? Self.errorMessage(writer)
                        : "archive_write_data wrote \(written) of \(chunk.count) bytes"
                )
            }
        }
        guard archive_write_finish_entry(writer) == ARCHIVE_OK else {
            throw ExtractError.backendFailure(Self.errorMessage(writer))
        }
    }

    // MARK: - libarchive の薄いラッパー

    /// `passphrase` を渡すと zip の暗号化エントリの復号を試みる
    /// [環境設定「圧縮／展開」タブ]。libarchive はエントリ一覧（ファイル名）
    /// 自体は暗号化しないため、`passphrase` が `nil` でも `listEntries` は
    /// 成功する。
    private static func openReader(_ url: URL, passphrase: String? = nil) throws -> OpaquePointer {
        guard let a = archive_read_new() else {
            throw ExtractError.backendFailure("archive_read_new returned NULL")
        }
        archive_read_support_filter_all(a)
        archive_read_support_format_all(a)
        if let passphrase {
            archive_read_add_passphrase(a, passphrase)
        }
        let rc = archive_read_open_filename(a, url.path, 64 * 1024)
        guard rc == ARCHIVE_OK else {
            let message = Self.errorMessage(a)
            archive_read_free(a)
            throw ExtractError.backendFailure(message)
        }
        return a
    }

    /// `archive_read_data`/`archive_read_next_header` が返すパスフレーズ
    /// 関連のエラー文言を判別する [libarchive `archive_read_support_format_zip.c`
    /// の既知の文言、WebSearch で確認: "Passphrase required for this entry"/
    /// "Incorrect passphrase"]。該当しなければ `nil`。
    /// - Parameter suppliedPassphrase: パスフレーズを渡して展開しているか。
    ///
    ///   **渡しているのに復号後のデータが壊れていたら、まずパスワード違いを
    ///   疑う** [ER-03]。従来型の ZIP 暗号化（ZipCrypto）は 1 バイトの検査値
    ///   しか持たないため、誤ったパスワードでも **約 1/256 の確率でその検査を
    ///   通過し**、そのあと展開の段で「ZIP decompression failed (-3)」という
    ///   意味の分からない文言になる（既存テストが不定期に落ちる形で判明した。
    ///   アーカイブごとに乱数が変わるため確率的に再現する）。
    ///
    ///   ユーザーにとっては同じ「パスワードを間違えた」操作なのに、返る文言が
    ///   運任せで変わるのは受け入れられない。パスフレーズを渡している場面での
    ///   復号・展開の失敗は `incorrectPassphrase` に寄せる。
    private static func passphraseError(
        from message: String, suppliedPassphrase: Bool = false
    ) -> ExtractError? {
        if message.localizedCaseInsensitiveContains("assphrase") {
            return message.localizedCaseInsensitiveContains("ncorrect")
                ? .incorrectPassphrase
                : .passwordProtected
        }
        if suppliedPassphrase { return .incorrectPassphrase }
        return nil
    }

    /// `FileHandle.write(contentsOf:)` が投げた失敗を、原因の分かる
    /// `ExtractError` に翻訳する [ER-03]。
    ///
    /// Foundation は POSIX の失敗を `NSPOSIXErrorDomain` の `NSError` として
    /// 返すため、`errno` を取り出して `PosixFailure` に翻訳を任せる
    /// （コピー・移動と同じ説明になる）。それ以外は Foundation の文言をそのまま使う。
    static func writeFailure(_ error: any Error) -> ExtractError {
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain {
            return .writeFailed(reason: PosixFailure.reason(Int32(nsError.code)) + (PosixFailure.recovery(Int32(nsError.code)).map { " " + $0 } ?? ""))
        }
        if nsError.domain == NSCocoaErrorDomain,
           let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying.domain == NSPOSIXErrorDomain {
            return .writeFailed(reason: PosixFailure.reason(Int32(underlying.code)) + (PosixFailure.recovery(Int32(underlying.code)).map { " " + $0 } ?? ""))
        }
        return .writeFailed(reason: error.localizedDescription)
    }

    private static func closeReader(_ a: OpaquePointer) {
        archive_read_close(a)
        archive_read_free(a)
    }

    private static func errorMessage(_ a: OpaquePointer) -> String {
        // `archive_error_string` は文言が設定されていないとき NULL を返す
        // （ヘッダに nullability 注釈が無いため IUO でインポートされ、素の
        // `String(cString:)` に渡すとトラップする）[フェーズ1完了時の監査で
        // 発見]。エラーコードだけでも返せるようにフォールバックする。
        guard let cString = archive_error_string(a) else {
            return "archive error \(archive_errno(a))"
        }
        return String(cString: cString)
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
    /// `FileOperationService.nextAvailableName` と同じ規則 [CF-01]。衝突先の
    /// 名前に既に連番サフィックス（例: `name 2`）が付いている場合はそれを
    /// 剥がしてから採番する。剥がさないと `name 2` との衝突のたびに末尾へ
    /// さらに ` 2` が積み重なり `name 2 2` のようになってしまう
    /// [フェーズ1完了時の監査で発見: `FileOperationService` 側では既に
    /// 修正済みだったこの不具合が、同じ規則を持つはずのこちらの実装には
    /// 反映されていなかった]。
    private static func nextAvailableName(for url: URL) -> URL {
        let ext = url.pathExtension
        let rawBase = ext.isEmpty ? url.lastPathComponent : String(url.lastPathComponent.dropLast(ext.count + 1))
        let base = strippingTrailingCopyNumber(from: rawBase)
        let directory = url.deletingLastPathComponent()
        var n = 2
        while true {
            let candidateName = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            let candidate = directory.appendingPathComponent(candidateName)
            // `fileExists` はシンボリックリンクを**辿る**ため、リンク切れの
            // シンボリックリンクが候補名を占めていると「空いている」と誤判定し、
            // 直後の書き込みが EEXIST で失敗する。辿らない `attributesOfItem`
            // で判定する [フェーズ1完了時の監査で発見。完全削除のリンク切れ
            // 対応と同じ罠]。
            if (try? FileManager.default.attributesOfItem(atPath: candidate.path)) == nil {
                return candidate
            }
            n += 1
        }
    }

    private static func strippingTrailingCopyNumber(from name: String) -> String {
        guard let range = name.range(of: #" \d+$"#, options: .regularExpression) else { return name }
        return String(name[..<range.lowerBound])
    }
}
