// T-13 technical verification spike (zip/7z half): drives libarchive from
// Swift through the CLibarchive wrapper to list and extract an archive into
// a staging directory, mirroring the intended shape of `ArchiveReading`
// (09_インフラ_アーカイブと画像.md §9.1) and the staging pattern (§9.3 [EX-01]).
//
// This proves the SwiftPM + xcframework + C-interop pipeline works end to
// end. It intentionally does NOT implement the full security model
// (EX-10〜EX-24 path traversal / decompression-bomb checks) — that belongs
// to the real `SecureExtractor` implementation in a later phase.
//
// Usage: LibarchiveSpike list <archive>
//        LibarchiveSpike extract <archive> <destinationDir>

import CLibarchive
import Foundation

enum SpikeError: Error, CustomStringConvertible {
    case archive(String)
    case usage

    var description: String {
        switch self {
        case .archive(let message): return "libarchive error: \(message)"
        case .usage: return "usage: LibarchiveSpike <list|extract> <archive> [destinationDir]"
        }
    }
}

func openReader(_ path: String) throws -> OpaquePointer {
    guard let a = archive_read_new() else {
        throw SpikeError.archive("archive_read_new returned NULL")
    }
    archive_read_support_filter_all(a)
    archive_read_support_format_all(a)
    let rc = archive_read_open_filename(a, path, 64 * 1024)
    guard rc == ARCHIVE_OK else {
        let message = String(cString: archive_error_string(a))
        archive_read_free(a)
        throw SpikeError.archive(message)
    }
    return a
}

func closeReader(_ a: OpaquePointer) {
    archive_read_close(a)
    archive_read_free(a)
}

func listEntries(_ path: String) throws {
    let a = try openReader(path)
    defer { closeReader(a) }

    var count = 0
    while true {
        var entry: OpaquePointer?
        let rc = archive_read_next_header(a, &entry)
        if rc == ARCHIVE_EOF { break }
        guard rc == ARCHIVE_OK, let entry else {
            throw SpikeError.archive(String(cString: archive_error_string(a)))
        }
        let name = String(cString: archive_entry_pathname(entry))
        let size = archive_entry_size(entry)
        print("  \(name)\t\(size) bytes")
        archive_read_data_skip(a)
        count += 1
    }
    print("==> \(count) entries listed from \(path)")
}

func extract(_ path: String, to destinationDir: String) throws {
    let fm = FileManager.default
    try fm.createDirectory(atPath: destinationDir, withIntermediateDirectories: true)

    let a = try openReader(path)
    defer { closeReader(a) }

    var extractedCount = 0
    while true {
        var entry: OpaquePointer?
        let rc = archive_read_next_header(a, &entry)
        if rc == ARCHIVE_EOF { break }
        guard rc == ARCHIVE_OK, let entry else {
            throw SpikeError.archive(String(cString: archive_error_string(a)))
        }
        let name = String(cString: archive_entry_pathname(entry))

        // Minimal path-traversal guard, matching the spirit of EX-10/EX-11
        // (the real SecureExtractor does this properly with resolved paths).
        guard !name.hasPrefix("/"), !name.split(separator: "/").contains("..") else {
            print("  ! rejected unsafe entry path: \(name)")
            continue
        }

        let destURL = URL(fileURLWithPath: destinationDir).appendingPathComponent(name)
        let isDirectory = name.hasSuffix("/")

        if isDirectory {
            try fm.createDirectory(at: destURL, withIntermediateDirectories: true)
            continue
        }

        try fm.createDirectory(
            at: destURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        guard fm.createFile(atPath: destURL.path, contents: nil) else {
            throw SpikeError.archive("could not create \(destURL.path)")
        }
        let handle = try FileHandle(forWritingTo: destURL)
        defer { try? handle.close() }

        var writtenBytes: Int64 = 0
        let bufferSize = 64 * 1024
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while true {
            let bytesRead = buffer.withUnsafeMutableBytes { ptr in
                archive_read_data(a, ptr.baseAddress, bufferSize)
            }
            if bytesRead < 0 {
                throw SpikeError.archive(String(cString: archive_error_string(a)))
            }
            if bytesRead == 0 { break }
            handle.write(Data(bytes: buffer, count: bytesRead))
            writtenBytes += Int64(bytesRead)
        }
        print("  extracted \(name) (\(writtenBytes) bytes) -> \(destURL.path)")
        extractedCount += 1
    }
    print("==> \(extractedCount) entries extracted to \(destinationDir)")
}

let args = CommandLine.arguments
do {
    guard args.count >= 3 else { throw SpikeError.usage }
    switch args[1] {
    case "list":
        try listEntries(args[2])
    case "extract":
        guard args.count >= 4 else { throw SpikeError.usage }
        try extract(args[2], to: args[3])
    default:
        throw SpikeError.usage
    }
} catch {
    FileHandle.standardError.write("\(error)\n".data(using: .utf8)!)
    exit(1)
}
