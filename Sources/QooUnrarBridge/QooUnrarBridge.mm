// QooUnrarBridge.mm — Objective-C++ wrapper around the UnRAR "RARDLL" API.
//
// This code uses portions of the UnRAR source code (raros.hpp, dll.hpp,
// vendored unmodified alongside this file — see
// ThirdParty/unrar/license.txt). Per the UnRAR source license: this code
// may not be used to develop a RAR (WinRAR) compatible archiver, and this
// paragraph must be retained in any redistribution of this file.
// [LC-20][LC-26][B-04]
//
// Design rationale [B-03][設計判断]: UnRAR is a C++ library. Rather than
// import its C++ headers directly into Swift (via a `CUnrar` C-interop
// target, as CLibarchive does for the pure-C libarchive), calls are
// confined to this single Objective-C++ file, which exposes only a plain
// C API (QooUnrarBridge.h) to the rest of the app. This trades a small
// amount of indirection for build stability, and gives Foundation
// (NSString/NSFileManager) as a convenient, already-available bridge
// between UnRAR's wchar_t-based Unicode paths and Swift's UTF-8 String.

#import "include/QooUnrarBridge.h"
#import <Foundation/Foundation.h>

#include "raros.hpp"  // defines _UNIX for __APPLE__, required by dll.hpp
#include "dll.hpp"

#include <string.h>
#include <wchar.h>

namespace {

constexpr size_t kPathBufferCount = 4096;

NSString *WideToString(const wchar_t *wide) {
    if (wide == nullptr) { return @""; }
    size_t length = wcslen(wide);
    return [[NSString alloc] initWithBytes:wide
                                     length:length * sizeof(wchar_t)
                                   encoding:NSUTF32LittleEndianStringEncoding];
}

// `buffer` must hold at least `bufferCount` wchar_t, including the
// terminator. Longer paths are truncated (fine for a T-13 verification
// spike; a production implementation would size dynamically).
void StringToWideBuffer(NSString *string, wchar_t *buffer, size_t bufferCount) {
    NSData *data = [string dataUsingEncoding:NSUTF32LittleEndianStringEncoding];
    size_t count = MIN(data.length / sizeof(wchar_t), bufferCount - 1);
    memcpy(buffer, data.bytes, count * sizeof(wchar_t));
    buffer[count] = 0;
}

void SetError(char *errorBuffer, int errorBufferSize, NSString *message) {
    if (errorBuffer == nullptr || errorBufferSize <= 0) { return; }
    strlcpy(errorBuffer, message.UTF8String, (size_t)errorBufferSize);
}

bool LooksUnsafe(NSString *entryName) {
    if ([entryName hasPrefix:@"/"]) { return true; }
    for (NSString *component in [entryName componentsSeparatedByString:@"/"]) {
        if ([component isEqualToString:@".."]) { return true; }
    }
    return false;
}

// destinationDir == nil means "list only" (RAR_OM_LIST, always RAR_SKIP).
int RunArchive(const char *archivePathUTF8,
               NSString *_Nullable destinationDir,
               QooUnrarEntryCallback _Nullable callback,
               void *_Nullable context,
               char *_Nullable errorBuffer,
               int errorBufferSize) {
    NSString *archivePath = [NSString stringWithUTF8String:archivePathUTF8];
    wchar_t archivePathW[kPathBufferCount];
    StringToWideBuffer(archivePath, archivePathW, kPathBufferCount);

    RAROpenArchiveDataEx archiveData;
    memset(&archiveData, 0, sizeof(archiveData));
    archiveData.ArcNameW = archivePathW;
    archiveData.OpenMode = destinationDir != nil ? RAR_OM_EXTRACT : RAR_OM_LIST;

    HANDLE handle = RAROpenArchiveEx(&archiveData);
    if (archiveData.OpenResult != 0 || handle == nullptr) {
        SetError(errorBuffer, errorBufferSize,
                 [NSString stringWithFormat:@"RAROpenArchiveEx failed (code %u)", archiveData.OpenResult]);
        return QOO_UNRAR_ERROR_OPEN_FAILED;
    }

    NSFileManager *fm = NSFileManager.defaultManager;
    if (destinationDir != nil) {
        [fm createDirectoryAtPath:destinationDir withIntermediateDirectories:YES attributes:nil error:nil];
    }

    int result = 0;
    while (true) {
        RARHeaderDataEx headerData;
        memset(&headerData, 0, sizeof(headerData));
        int readResult = RARReadHeaderEx(handle, &headerData);
        if (readResult == ERAR_END_ARCHIVE) { break; }
        if (readResult != 0) {
            SetError(errorBuffer, errorBufferSize,
                     [NSString stringWithFormat:@"RARReadHeaderEx failed (code %d)", readResult]);
            result = QOO_UNRAR_ERROR_HEADER_FAILED;
            break;
        }

        NSString *entryName = WideToString(headerData.FileNameW);
        BOOL isDirectory = (headerData.Flags & RHDF_DIRECTORY) != 0;
        // Minimal path-traversal guard, mirroring the zip spike / the
        // spirit of EX-10/EX-11. The real SecureExtractor (09章 §9.3)
        // supersedes this once it exists.
        BOOL unsafe = destinationDir != nil && LooksUnsafe(entryName);

        int processResult;
        if (destinationDir == nil || unsafe) {
            processResult = RARProcessFileW(handle, RAR_SKIP, nullptr, nullptr);
        } else if (isDirectory) {
            NSString *dirPath = [destinationDir stringByAppendingPathComponent:entryName];
            [fm createDirectoryAtPath:dirPath withIntermediateDirectories:YES attributes:nil error:nil];
            processResult = RARProcessFileW(handle, RAR_SKIP, nullptr, nullptr);
        } else {
            NSString *destPath = [destinationDir stringByAppendingPathComponent:entryName];
            [fm createDirectoryAtPath:destPath.stringByDeletingLastPathComponent
                withIntermediateDirectories:YES attributes:nil error:nil];
            wchar_t destPathW[kPathBufferCount];
            StringToWideBuffer(destPath, destPathW, kPathBufferCount);
            processResult = RARProcessFileW(handle, RAR_EXTRACT, nullptr, destPathW);
        }

        if (processResult != 0) {
            SetError(errorBuffer, errorBufferSize,
                     [NSString stringWithFormat:@"RARProcessFileW failed (code %d)", processResult]);
            result = QOO_UNRAR_ERROR_PROCESS_FAILED;
            break;
        }

        if (callback != nullptr && !unsafe) {
            QooUnrarEntry entry;
            entry.utf8Path = entryName.UTF8String;
            entry.unpackedSize = ((uint64_t)headerData.UnpSizeHigh << 32) | headerData.UnpSize;
            entry.isDirectory = isDirectory ? 1 : 0;
            // The callback may block (to pause) and may ask to stop. This is
            // the only place a walk can be interrupted: RARProcessFileW is
            // blocking, so the granularity is one entry.
            if (callback(&entry, context) != 0) {
                result = QOO_UNRAR_ERROR_CANCELLED;
                break;
            }
        }
    }

    RARCloseArchive(handle);
    return result;
}

// Extracts exactly one matching entry and stops scanning immediately,
// rather than walking the whole archive like RunArchive does. Used for
// thumbnail generation, where extracting an entire (possibly large)
// archive just to read its first image would be wasteful [設計判断、
// QooUnrarBridge.h の qoo_unrar_extract_one コメント参照].
int ExtractOneEntry(const char *archivePathUTF8,
                     NSString *targetEntryName,
                     NSString *destinationFile,
                     char *_Nullable errorBuffer,
                     int errorBufferSize) {
    NSString *archivePath = [NSString stringWithUTF8String:archivePathUTF8];
    wchar_t archivePathW[kPathBufferCount];
    StringToWideBuffer(archivePath, archivePathW, kPathBufferCount);

    RAROpenArchiveDataEx archiveData;
    memset(&archiveData, 0, sizeof(archiveData));
    archiveData.ArcNameW = archivePathW;
    archiveData.OpenMode = RAR_OM_EXTRACT;

    HANDLE handle = RAROpenArchiveEx(&archiveData);
    if (archiveData.OpenResult != 0 || handle == nullptr) {
        SetError(errorBuffer, errorBufferSize,
                 [NSString stringWithFormat:@"RAROpenArchiveEx failed (code %u)", archiveData.OpenResult]);
        return QOO_UNRAR_ERROR_OPEN_FAILED;
    }

    NSFileManager *fm = NSFileManager.defaultManager;
    [fm createDirectoryAtPath:destinationFile.stringByDeletingLastPathComponent
        withIntermediateDirectories:YES attributes:nil error:nil];

    int result = QOO_UNRAR_ERROR_ENTRY_NOT_FOUND;
    while (true) {
        RARHeaderDataEx headerData;
        memset(&headerData, 0, sizeof(headerData));
        int readResult = RARReadHeaderEx(handle, &headerData);
        if (readResult == ERAR_END_ARCHIVE) { break; }
        if (readResult != 0) {
            SetError(errorBuffer, errorBufferSize,
                     [NSString stringWithFormat:@"RARReadHeaderEx failed (code %d)", readResult]);
            result = QOO_UNRAR_ERROR_HEADER_FAILED;
            break;
        }

        NSString *entryName = WideToString(headerData.FileNameW);
        BOOL isDirectory = (headerData.Flags & RHDF_DIRECTORY) != 0;

        if (!isDirectory && [entryName isEqualToString:targetEntryName]) {
            wchar_t destPathW[kPathBufferCount];
            StringToWideBuffer(destinationFile, destPathW, kPathBufferCount);
            int processResult = RARProcessFileW(handle, RAR_EXTRACT, nullptr, destPathW);
            if (processResult != 0) {
                SetError(errorBuffer, errorBufferSize,
                         [NSString stringWithFormat:@"RARProcessFileW failed (code %d)", processResult]);
                result = QOO_UNRAR_ERROR_PROCESS_FAILED;
            } else {
                result = 0;
            }
            break; // found it (or failed extracting it) — no need to keep scanning
        }
        RARProcessFileW(handle, RAR_SKIP, nullptr, nullptr);
    }

    RARCloseArchive(handle);
    if (result == QOO_UNRAR_ERROR_ENTRY_NOT_FOUND) {
        SetError(errorBuffer, errorBufferSize, [NSString stringWithFormat:@"entry not found: %@", targetEntryName]);
    }
    return result;
}

}  // namespace

int qoo_unrar_list(const char *archivePathUTF8,
                    QooUnrarEntryCallback callback,
                    void *context,
                    char *errorBuffer,
                    int errorBufferSize) {
    return RunArchive(archivePathUTF8, nil, callback, context, errorBuffer, errorBufferSize);
}

int qoo_unrar_extract_all(const char *archivePathUTF8,
                           const char *destinationDirUTF8,
                           QooUnrarEntryCallback callback,
                           void *context,
                           char *errorBuffer,
                           int errorBufferSize) {
    NSString *destinationDir = [NSString stringWithUTF8String:destinationDirUTF8];
    return RunArchive(archivePathUTF8, destinationDir, callback, context, errorBuffer, errorBufferSize);
}

int qoo_unrar_extract_one(const char *archivePathUTF8,
                           const char *entryPathUTF8,
                           const char *destinationFileUTF8,
                           char *errorBuffer,
                           int errorBufferSize) {
    NSString *entryName = [NSString stringWithUTF8String:entryPathUTF8];
    NSString *destinationFile = [NSString stringWithUTF8String:destinationFileUTF8];
    return ExtractOneEntry(archivePathUTF8, entryName, destinationFile, errorBuffer, errorBufferSize);
}
