// T-13 technical verification spike (RAR half): drives UnRAR from Swift
// through the QooUnrarBridge Objective-C++ wrapper to list and extract a
// .rar archive. Mirrors LibarchiveSpike's shape for easy comparison.
//
// Not built under PERMISSIVE_ONLY_BUILD (QooUnrarBridge doesn't exist
// there).
//
// Usage: UnrarSpike list <archive.rar>
//        UnrarSpike extract <archive.rar> <destinationDir>

import Foundation
import QooUnrarBridge

enum SpikeError: Error, CustomStringConvertible {
    case unrar(code: Int32, message: String)
    case usage

    var description: String {
        switch self {
        case .unrar(let code, let message): return "UnRAR error \(code): \(message)"
        case .usage: return "usage: UnrarSpike <list|extract> <archive.rar> [destinationDir]"
        }
    }
}

final class CallbackBox {
    var count = 0
}

nonisolated(unsafe) let entryCallback: QooUnrarEntryCallback = { entryPtr, contextPtr in
    guard let entryPtr, let contextPtr else { return 0 }
    let box = Unmanaged<CallbackBox>.fromOpaque(contextPtr).takeUnretainedValue()
    box.count += 1
    let name = String(cString: entryPtr.pointee.utf8Path)
    let size = entryPtr.pointee.unpackedSize
    let kind = entryPtr.pointee.isDirectory != 0 ? "dir " : "file"
    print("  [\(kind)] \(name)\t\(size) bytes")
    return 0 // 0 で続行（`QooUnrarBridge.h` 参照）
}

func run(_ mode: String, _ archivePath: String, _ destinationDir: String?) throws {
    let box = CallbackBox()
    let boxPtr = Unmanaged.passUnretained(box).toOpaque()
    var errorBuffer = [CChar](repeating: 0, count: 512)

    let rc: Int32 = errorBuffer.withUnsafeMutableBufferPointer { errBuf in
        archivePath.withCString { archiveCStr in
            if let destinationDir {
                return destinationDir.withCString { destCStr in
                    qoo_unrar_extract_all(
                        archiveCStr, destCStr, entryCallback, boxPtr,
                        errBuf.baseAddress, Int32(errBuf.count))
                }
            } else {
                return qoo_unrar_list(
                    archiveCStr, entryCallback, boxPtr,
                    errBuf.baseAddress, Int32(errBuf.count))
            }
        }
    }

    if rc != 0 {
        let nullIndex = errorBuffer.firstIndex(of: 0) ?? errorBuffer.endIndex
        let message = String(decoding: errorBuffer[..<nullIndex].map { UInt8(bitPattern: $0) }, as: UTF8.self)
        throw SpikeError.unrar(code: rc, message: message)
    }
    let verb = destinationDir != nil ? "extracted" : "listed"
    print("==> \(box.count) entries \(verb) from \(archivePath)")
}

let args = CommandLine.arguments
do {
    guard args.count >= 3 else { throw SpikeError.usage }
    switch args[1] {
    case "list":
        try run("list", args[2], nil)
    case "extract":
        guard args.count >= 4 else { throw SpikeError.usage }
        try run("extract", args[2], args[3])
    default:
        throw SpikeError.usage
    }
} catch {
    FileHandle.standardError.write("\(error)\n".data(using: .utf8)!)
    exit(1)
}
